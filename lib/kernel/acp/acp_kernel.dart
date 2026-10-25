import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'acp_catalog.dart';
import 'acp_config_option.dart';
import 'acp_mcp.dart';
import 'acp_transport.dart';

/// Adapts an ACP JSON-RPC agent over a message transport to [AgentKernel].
class AcpKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        SelectsEffort,
        ProvidesCommands,
        ReportsContext {
  AcpKernel(
    this.descriptor,
    this._context,
    this._transportFactory, {
    this._catalog,
    this._loadMcpServers,
  });

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final AcpTransportFactory _transportFactory;

  /// Local session index for this agent; null in tests that omit it.
  final AcpCatalog? _catalog;
  final AcpMcpLoader? _loadMcpServers;
  AcpMcpServers _mcp = const AcpMcpServers();
  bool _mcpClosed = false;
  AcpTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Timer? _receiveTimer;
  int _receivedInBatch = 0;
  static const _receiveBatchSize = 32;

  KernelHealth _health = KernelHealth.idle;
  String? _sessionId;
  String? _turnId;
  DateTime? _turnStarted;
  int _nextId = 0;
  int _startGeneration = 0;
  int _turnCount = 0;

  /// Open agent text/thought stream (ACP/Zed merge target).
  String? _assistantItemId;
  String? _assistantMessageId;
  bool? _assistantIsThought;
  bool _replaying = false;
  int _replaySeq = 0;
  String? _replayTurnId;
  bool _initialized = false;
  bool _starting = false;
  bool _disposed = false;
  bool _cancelling = false;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Set<String> _configRequests = {};
  final Map<String, String> _messages = {};
  final Map<String, ToolCallItem> _tools = {};
  final Set<String> _todoToolIds = {};
  final List<KernelOption> _modeOptions = [];
  List<KernelCommand> _commands = const [];

  bool _hasConfigOptions = false;
  Future<void> _configChanges = Future.value();
  late final _legacyMode = LocalChoice([], onChanged: _selectMode);
  late final _configOptions = {
    'model': AcpConfigOption(Icons.smart_toy_rounded, _selectConfigOption),
    'mode': AcpConfigOption(Icons.tune_rounded, _selectConfigOption),
    'thought_level': AcpConfigOption(
      Icons.psychology_rounded,
      _selectConfigOption,
    ),
  };

  @override
  KernelChoiceSource get model => _configOptions['model']!;

  @override
  KernelChoiceSource get mode =>
      _hasConfigOptions ? _configOptions['mode']! : _legacyMode;

  @override
  late final ModelSetting effort = AcpThoughtLevel(
    _configOptions['thought_level']!,
    _configOptions['model']!,
  );

  @override
  List<KernelCommand> get commands => _commands;

  int _contextWindow = 200000;

  @override
  int get contextWindow => _contextWindow;

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _sessionId;

  @override
  Future<void> get stopped async {
    final subscription = _subscription;
    if (subscription != null && !_disposed) await subscription.asFuture<void>();
  }

  @override
  void prepare() {
    if (_disposed || _initialized || _starting) return;
    _starting = true;
    _health = const KernelHealth(KernelHealthStatus.starting);
    // ChatSession.attach calls prepare while ChatScreen is mounting. Existing
    // session listeners must not be invalidated in the middle of that build.
    scheduleMicrotask(() {
      if (!_disposed) emitInfoChanged();
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_startGeneration;
    bool obsolete() => _disposed || generation != _startGeneration;
    try {
      // Also keep a synchronous factory failure out of the mounting frame.
      final transport = await Future<AcpTransport>.sync(
        () => _transportFactory(_context),
      );
      if (obsolete()) {
        transport.close();
        return;
      }
      _transport = QueuedAcpTransport(transport);
      _subscription = _transport!.messages.listen(
        _receiveBatched,
        onError: (Object error, StackTrace _) {
          if (!obsolete()) _fail(error);
        },
        onDone: () {
          if (!obsolete()) _fail(StateError('ACP agent process exited'));
        },
      );
      final initialized = await _request('initialize', {
        'protocolVersion': 1,
        'clientInfo': {'name': 'BaoCode', 'version': '1.0.0'},
        'clientCapabilities': <String, Object?>{},
      });
      if (obsolete()) return;
      final capabilities =
          _jsonMap(
            _jsonMap(initialized['agentCapabilities'])?['mcpCapabilities'],
          )?.cast<String, Object?>() ??
          const <String, Object?>{};
      final mcp =
          await _loadMcpServers?.call(_context, capabilities) ??
          const AcpMcpServers();
      if (obsolete() || _health.status == KernelHealthStatus.failed) {
        mcp.close();
        return;
      }
      _mcp = mcp;
      _mcpClosed = false;
      await _ensureSession();
      if (obsolete() || _health.status == KernelHealthStatus.failed) return;
      _initialized = true;
      for (final (index, warning) in _mcp.warnings.indexed) {
        emit(
          ItemUpserted(
            nextSeq,
            'acp_mcp_warning_$index',
            NoticeItem(NoticeKind.warning, warning),
          ),
        );
      }
      if (obsolete()) return;
      _starting = false;
      _health = KernelHealth.ready;
      emitInfoChanged();
    } on Object catch (error) {
      if (obsolete()) return;
      _starting = false;
      _fail(error);
    }
  }

  Future<void> _ensureSession() async {
    if (_sessionId != null) return;
    final resume = _context.resume;
    final Map<String, Object?> session;
    if (resume != null) {
      _sessionId = resume.id;
      _replaying = true;
      _closeAssistantStream();
      session = await _request('session/load', {
        'sessionId': resume.id,
        'cwd': _agentCwd(_context.cwd ?? resume.cwd),
        'mcpServers': _mcp.servers,
      });
    } else {
      session = await _request('session/new', {
        'cwd': _agentCwd(_context.cwd),
        'mcpServers': _mcp.servers,
      });
      _sessionId = session['sessionId'] as String?;
    }
    _applyModes(session['modes']);
    _setCommands(
      session['availableCommands'] ??
          session['available_commands'] ??
          session['commands'] ??
          session['slashCommands'],
    );
    // History session/update may have been queued before the load/new
    // response. Apply it now, while _replaying is still set for resume,
    // or replies are treated as a live turn and land out of order.
    _flushQueued();
    if (resume != null) _finishReplay();
    if (_sessionId == null) {
      throw StateError('ACP session returned no sessionId');
    }
    _rememberSession(title: resume?.title);
  }

  /// Keeps [sessionId] in the local catalog so the sidebar can open it
  /// again after a restart and call [session/load].
  void _rememberSession({String? title, DateTime? updatedAt}) {
    final catalog = _catalog;
    final id = _sessionId;
    final cwd = _context.cwd ?? _context.resume?.cwd;
    if (catalog == null || id == null || cwd == null || cwd.isEmpty) return;
    unawaited(
      catalog.upsert(
        SessionRecord(
          id: id,
          title: title ?? _context.resume?.title ?? '',
          updatedAt: updatedAt ?? DateTime.now().toUtc(),
          cwd: cwd,
        ),
      ),
    );
  }

  /// The directory the agent is told: a remote project's path on its host,
  /// not the `ssh://` location the app uses.
  static String _agentCwd(String? location) {
    if (location == null || location.isEmpty) return '';
    return RemoteLocation.pathOf(location);
  }

  @override
  void send(KernelTurn turn) {
    if (_disposed || turn.id == _turnId) return;
    prepare();
    unawaited(_sendWhenReady(turn));
  }

  Future<void> _sendWhenReady(KernelTurn turn) async {
    try {
      while (!_initialized &&
          !_disposed &&
          _health.status != KernelHealthStatus.failed) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!_initialized || _disposed) return;
      await _ensureSession();
      final sessionId = _sessionId!;
      _turnId = turn.id;
      _cancelling = false;
      _turnStarted = DateTime.now();
      _turnCount++;
      _closeAssistantStream();
      emit(TurnStarted(nextSeq, turn.id));
      emit(
        ItemUpserted(
          nextSeq,
          turn.id,
          UserMessageItem(text: turn.text, images: turn.images),
        ),
      );
      // /sessions replays the selected conversation through this prompt,
      // rather than through session/load.
      final loadsHistory =
          turn.text.trim().split(RegExp(r'\s+')).first == '/sessions';
      if (loadsHistory) _replaying = true;
      final result = await _request('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': turn.text},
        ],
      });
      // /sessions may queue history until the prompt result arrives.
      if (loadsHistory) {
        _flushQueued();
        _finishReplay();
      }
      if (_turnId == turn.id) {
        _endTurn(result['stopReason'] == 'cancelled');
      }
    } on Object catch (error) {
      _fail(error);
      if (_turnId == turn.id) _endTurn(false);
    }
  }

  void runCommand(String name, [String argument = '']) {
    final command = name.startsWith('/') ? name : '/$name';
    final text = argument.trim().isEmpty
        ? command
        : '$command ${argument.trim()}';
    send(KernelTurn(id: 'command_${++_nextId}', text: text));
  }

  /// Both setup and config changes report the complete state, including
  /// model-dependent reasoning choices that may have disappeared.
  void _applyConfigOptions(Object? raw) {
    if (raw is! List) return;
    _hasConfigOptions = true;
    for (final option in _configOptions.values) {
      option.replace(null);
    }
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map || item['type'] != 'select') continue;
      // Categories place the selectors. Recognize the standard ids too
      // when category is absent; never guess from a localized label.
      final category = item['category'] ?? item['id'];
      final option = _configOptions[category];
      if (option == null || !seen.add(category as String)) continue;
      option.replace(item);
    }
    emitInfoChanged();
  }

  void _selectConfigOption(String configId, String value) {
    final sessionId = _sessionId;
    if (sessionId == null || !_initialized || _disposed) return;
    final generation = _startGeneration;
    bool obsolete() => _disposed || generation != _startGeneration;
    // Serialize choices: a model response can change the thought levels.
    // Recheck the value after that response, before sending the next change.
    _configChanges = _configChanges
        .then((_) async {
          if (obsolete() || _health.status == KernelHealthStatus.failed) return;
          final option = _configOptions.values
              .where((option) => option.configId == configId)
              .firstOrNull;
          if (option == null ||
              option.selected == value ||
              !option.options.any((o) => o.id == value)) {
            return;
          }
          await _request('session/set_config_option', {
            'sessionId': sessionId,
            'configId': configId,
            'value': value,
          });
        })
        .catchError((Object error) {
          if (obsolete() || _health.status == KernelHealthStatus.failed) return;
          // A rejected setting is not a failed conversation. Keep the reported
          // choices and let the user try again or continue talking.
          emit(
            ItemUpserted(
              nextSeq,
              'acp_config_error_${++_nextId}',
              NoticeItem(
                NoticeKind.warning,
                'Could not change ACP configuration: $error',
              ),
            ),
          );
          emitInfoChanged();
        });
  }

  void _applyModes(Object? raw) {
    if (_hasConfigOptions) return;
    final Map<String, Object?> state;
    if (raw is List) {
      state = {'availableModes': raw};
    } else if (raw is Map) {
      state = raw.cast<String, Object?>();
    } else {
      return;
    }
    final modes = state['availableModes'];
    if (modes is List) {
      _modeOptions
        ..clear()
        ..addAll([
          for (final item in modes)
            if (item is Map && item['id'] is String)
              KernelOption(
                item['id'] as String,
                item['name'] as String? ?? item['id'] as String,
                Icons.tune_rounded,
                item['description'] as String? ?? 'ACP mode',
              ),
        ]);
      _legacyMode.options = List.of(_modeOptions);
    }
    final current = state['currentModeId'];
    if (current is String && current.isNotEmpty) {
      _legacyMode.reported = current;
    }
    emitInfoChanged();
  }

  void _selectMode(String modeId) {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    unawaited(
      _request('session/set_mode', {
        'sessionId': sessionId,
        'modeId': modeId,
      }).then((_) {}, onError: (Object error) => _fail(error)),
    );
  }

  void _setCommands(Object? raw) {
    if (raw is! List) return;
    _commands = [
      for (final item in raw)
        if (item is Map && item['name'] is String)
          KernelCommand(
            (item['name'] as String).replaceFirst(RegExp(r'^/'), ''),
            item['description'] as String? ?? 'ACP command',
            Icons.code_rounded,
            argumentHint: (item['input'] as Map?)?['hint'] as String? ?? '',
          ),
    ];
    emitInfoChanged();
  }

  @override
  void cancel() {
    final sessionId = _sessionId;
    if (_disposed || sessionId == null) return;
    if (_turnId == null && _permissionRpcIds.isEmpty) return;
    _cancelling = true;
    try {
      // ACP cancellation is a notification, not a request. SDK-based
      // agents dispatch it only without an id; no cancel response is due.
      _transport?.write({
        'jsonrpc': '2.0',
        'method': 'session/cancel',
        'params': {'sessionId': sessionId},
      });
      // Unblock every permission the agent is awaiting. The original
      // session/prompt response, not this notification, ends the turn.
      for (final requestId in _permissionRpcIds.keys.toList()) {
        final rpcId = _permissionRpcIds.remove(requestId)!;
        _permissionOptions.remove(requestId);
        _permissionKinds.remove(requestId);
        _commandInteractionIds.remove(requestId);
        _replyCancelled(rpcId);
        emit(InteractionResolved(nextSeq, requestId));
      }
    } on Object catch (error) {
      _fail(error);
    }
  }

  void _replyCancelled(Object rpcId) {
    _transport?.write({
      'jsonrpc': '2.0',
      'id': rpcId,
      'result': {
        'outcome': {'outcome': 'cancelled'},
      },
    });
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    final rpcId = _permissionRpcIds.remove(requestId);
    // The user may answer just as cancellation resolves the request.
    if (rpcId == null) return;
    final optionId = _permissionOptionId(requestId, answer);
    _permissionOptions.remove(requestId);
    _permissionKinds.remove(requestId);
    // `cancelled` is only for session/cancel while a permission is pending.
    // A deny must select a reject_* optionId from the agent's list.
    _transport?.write({
      'jsonrpc': '2.0',
      'id': rpcId,
      'result': {
        'outcome': optionId == null
            ? {'outcome': 'cancelled'}
            : {'outcome': 'selected', 'optionId': optionId},
      },
    });
    if (_commandInteractionIds.remove(requestId) && _turnId != null) {
      _endTurn(false);
    }
    emit(InteractionResolved(nextSeq, requestId));
  }

  /// Maps the panel's choice back to the option the agent advertised.
  String? _permissionOptionId(String requestId, InteractionAnswer answer) {
    final byLabel = _permissionOptions[requestId] ?? const {};
    final byKind = _permissionKinds[requestId] ?? const {};
    switch (answer) {
      case QuestionAnswer(:final picks, :final skipped):
        if (skipped || picks.isEmpty || picks.first.isEmpty) {
          return byKind['reject_once'] ?? byKind['reject-once'];
        }
        final label = picks.first.first;
        return byLabel[label] ?? label;
      case ApprovalAnswer(:final decision):
        return switch (decision) {
          ApprovalDecision.allowOnce =>
            byKind['allow_once'] ??
                byKind['allow-once'] ??
                byLabel['Allow once'] ??
                'allow_once',
          ApprovalDecision.allowAlways =>
            byKind['allow_always'] ??
                byKind['allow-always'] ??
                byLabel.values.firstWhere(
                  (id) => id.contains('always') && id.contains('allow'),
                  orElse: () => 'allow_always',
                ),
          ApprovalDecision.deny =>
            byKind['reject_once'] ??
                byKind['reject-once'] ??
                byKind['reject_always'] ??
                byKind['reject-always'] ??
                'reject_once',
        };
    }
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = '${++_nextId}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    if (method == 'session/new' ||
        method == 'session/load' ||
        method == 'session/set_config_option') {
      _configRequests.add(id);
    }
    _transport?.write({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    // ACP turns and startup wait on the agent. A client timeout would end a
    // still-running prompt and look like a protocol failure.
    return completer.future;
  }

  void _flushQueued() {
    final transport = _transport;
    if (transport is! QueuedAcpTransport) return;
    final pending = transport.takeQueued();
    if (pending.isEmpty) return;
    // Apply synchronously: session/load history must run while _replaying
    // is still true. A microtask would finish the replay first and then
    // treat the history as a live turn.
    if (_disposed) return;
    for (final message in pending) {
      _receive(message);
    }
  }

  /// A history replay can deliver thousands of updates in one stdout read.
  /// Pause between batches so clicks and other pages can run too. Buffer on
  /// the subscription, keeping RPC responses behind all preceding updates:
  /// session/load must not finish replay before its history has been applied.
  void _receiveBatched(Map<String, Object?> message) {
    if (_disposed) return;
    _receive(message);
    if (_disposed || ++_receivedInBatch < _receiveBatchSize) return;
    final subscription = _subscription;
    if (subscription == null) return;
    subscription.pause();
    _receiveTimer = Timer(Duration.zero, () {
      _receiveTimer = null;
      _receivedInBatch = 0;
      subscription.resume();
    });
  }

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final rawId = message['id'];
    final id = rawId?.toString();
    if (method == null && id != null) {
      final pending = _pending.remove(id);
      final config = _configRequests.remove(id);
      if (pending == null) return;
      if (message['error'] case final Map error) {
        pending.completeError(StateError('${error['message'] ?? error}'));
      } else {
        final result =
            (message['result'] as Map?)?.cast<String, Object?>() ?? const {};
        // Apply config before completing the future: a later notification in
        // the same stdout batch must not be overwritten by an await continuation.
        if (config) _applyConfigOptions(result['configOptions']);
        pending.complete(result);
      }
      return;
    }
    if (method == null) return;
    final params =
        (message['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (rawId != null && id != null) {
      // Keep the agent's JSON-RPC id type (int or string) for the reply.
      _handleServerRequest(rawId, id, method, params);
    } else if (method == 'session/update') {
      _handleUpdate(params);
    }
  }

  void _handleServerRequest(
    Object rpcId,
    String requestId,
    String method,
    Map<String, Object?> params,
  ) {
    if (method != 'session/request_permission') {
      _transport?.write({
        'jsonrpc': '2.0',
        'id': rpcId,
        'error': {'code': -32601, 'message': 'method not found: $method'},
      });
      return;
    }
    // A permission can race with session/cancel. Until prompt completes,
    // it must be cancelled as well, without opening another interaction.
    if (_cancelling) {
      _replyCancelled(rpcId);
      return;
    }
    final toolCall =
        (params['toolCall'] as Map?)?.cast<String, Object?>() ?? const {};
    final title = toolCall['title'] as String? ?? 'Permission required';
    final toolKind = toolCall['kind'] as String?;
    final isCommandChoice =
        toolKind == 'command' ||
        toolKind == 'slash_command' ||
        title.startsWith('/');
    if (isCommandChoice) _commandInteractionIds.add(requestId);
    final options = [
      for (final raw in params['options'] as List? ?? const [])
        if (raw is Map && raw['optionId'] is String)
          (
            id: raw['optionId'] as String,
            name: raw['name'] as String? ?? raw['optionId'] as String,
            kind: raw['kind'] as String?,
          ),
    ];
    _permissionRpcIds[requestId] = rpcId;
    _permissionOptions[requestId] = {
      for (final option in options) option.name: option.id,
      for (final option in options) option.id: option.id,
    };
    _permissionKinds[requestId] = {
      for (final option in options)
        if (option.kind != null) option.kind!: option.id,
    };
    // Always show the agent's own option names. ApprovalRequest would replace
    // them with localized Accept/Deny labels.
    emit(
      InteractionRequested(
        nextSeq,
        QuestionRequest(
          id: requestId,
          title: isCommandChoice ? 'Choose a command' : title,
          questions: [
            Question(
              prompt: title,
              header: isCommandChoice ? 'Command' : (toolKind ?? 'Permission'),
              options: [
                for (final option in options)
                  QuestionOption(
                    option.name,
                    description:
                        option.kind == null || option.kind == option.name
                        ? ''
                        : option.kind!,
                  ),
              ],
              allowOther: false,
            ),
          ],
        ),
      ),
    );
  }

  final Map<String, Object> _permissionRpcIds = {};
  final Map<String, Map<String, String>> _permissionOptions = {};
  final Map<String, Map<String, String>> _permissionKinds = {};
  final Set<String> _commandInteractionIds = {};

  void _beginReplayTurn() {
    if (_replayTurnId != null) _endTurn(false);
    _replayTurnId = 'acp_replay_${++_replaySeq}';
    _turnId = _replayTurnId;
    emit(TurnStarted(nextSeq, _replayTurnId!));
  }

  void _finishReplay() {
    if (_replayTurnId != null) _endTurn(false);
    _replayTurnId = null;
    _replaying = false;
    _closeAssistantStream();
  }

  void _closeAssistantStream() {
    _assistantItemId = null;
    _assistantMessageId = null;
    _assistantIsThought = null;
  }

  /// Zed/ACP: same messageId merges; either side missing messageId merges;
  /// both present and unequal starts a new message.
  bool _canMergeMessageIds(String? existing, String? incoming) {
    if (existing != null &&
        existing.isNotEmpty &&
        incoming != null &&
        incoming.isNotEmpty) {
      return existing == incoming;
    }
    return true;
  }

  void _handleUpdate(Map<String, Object?> params) {
    final session = params['sessionId'];
    if (_sessionId != null && session is String && session != _sessionId) {
      return;
    }
    final update =
        (params['update'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
      case 'agent_thought_chunk':
        final content =
            (update['content'] as Map?)?.cast<String, Object?>() ?? const {};
        final text = content['text'];
        if (text is! String || text.isEmpty) return;
        final thought = update['sessionUpdate'] == 'agent_thought_chunk';
        // ACP v1 Message ID RFD: thoughts also use messageId (optional).
        final rawId = update['messageId'] as String?;
        final messageId = rawId != null && rawId.isNotEmpty ? rawId : null;
        final merge =
            _assistantItemId != null &&
            _assistantIsThought == thought &&
            _canMergeMessageIds(_assistantMessageId, messageId);
        final String itemId;
        if (merge) {
          itemId = _assistantItemId!;
          _assistantMessageId ??= messageId;
        } else {
          // Always append in arrival order. Item ids stay unique even when
          // the protocol reuses messageId across separate assistant entries
          // (e.g. after a tool call).
          itemId =
              'acp_${thought ? 'thought' : 'message'}_${_turnCount}_${++_replaySeq}';
          _assistantItemId = itemId;
          _assistantMessageId = messageId;
          _assistantIsThought = thought;
        }
        final oldText = _messages[itemId] ?? '';
        _messages[itemId] = '$oldText$text';
        if (oldText.isEmpty) {
          emit(
            ItemUpserted(
              nextSeq,
              itemId,
              thought
                  ? ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now())
                  : const AssistantTextItem(''),
              streaming: true,
            ),
          );
        }
        emit(TextDelta(nextSeq, itemId, oldText.length, text));
      case 'available_commands_update':
        _setCommands(
          update['availableCommands'] ??
              update['available_commands'] ??
              update['commands'],
        );
      case 'config_option_update':
        _applyConfigOptions(update['configOptions']);
      case 'current_mode_update':
        _applyModes({
          'currentModeId': update['currentModeId'],
          'availableModes': update['availableModes'],
        });
      case 'usage_update':
        final usage = _contextUsage(update);
        if (usage != null) emit(UsageReported(nextSeq, usage));
      case 'tool_call':
      case 'tool_call_update':
        // A non-assistant entry ends the open stream (Zed AcpThread).
        _closeAssistantStream();
        _toolUpdate(update);
        _todosFromTool(update);
      // ACP v1 sends `plan` with top-level `entries`. Draft v2 sends
      // `plan_update` with those entries nested under `plan`. `todo_update`
      // is not in the spec; keep it so older agents still surface a list.
      case 'plan':
      case 'plan_update':
      case 'todo_update':
        _todosUpdate(_planEntries(update));
      case 'user_message_chunk':
        final content =
            (update['content'] as Map?)?.cast<String, Object?>() ?? const {};
        final text = content['text'];
        if (text is! String || text.isEmpty) return;
        // User content ends the open assistant stream.
        _closeAssistantStream();
        if (_replaying || _turnId == null || _replayTurnId != null) {
          _beginReplayTurn();
        }
        final turnId = _turnId ?? 'acp_user';
        final rawId = update['messageId'] as String?;
        final itemId = rawId != null && rawId.isNotEmpty
            ? 'acp_user_${turnId}_$rawId'
            : 'acp_user_${turnId}_${++_replaySeq}';
        final oldText = _messages[itemId] ?? '';
        _messages[itemId] = '$oldText$text';
        emit(
          ItemUpserted(
            nextSeq,
            itemId,
            UserMessageItem(text: _messages[itemId]!),
          ),
        );
      case 'session_end':
      case 'prompt_complete':
      case 'turn_complete':
        if (_turnId != null) _endTurn(false);
        break;
    }
  }

  void _toolUpdate(Map<String, Object?> update) {
    final id =
        update['toolCallId'] as String? ??
        update['id'] as String? ??
        'acp_tool';
    // ACP updates are patches: omitted fields retain the previous value.
    final previous = _tools[id];
    final title = update['title'] as String? ?? previous?.target ?? 'Tool call';
    final toolStatus = switch (update['status']) {
      'completed' || 'succeeded' || 'success' => ToolStatus.succeeded,
      'failed' || 'error' => ToolStatus.failed,
      'pending' || 'in_progress' || 'running' => ToolStatus.running,
      _ => previous?.status ?? ToolStatus.running,
    };
    final status = switch (toolStatus) {
      ToolStatus.succeeded => CommandStatus.succeeded,
      ToolStatus.failed || ToolStatus.denied => CommandStatus.failed,
      ToolStatus.running => CommandStatus.running,
    };
    final rawKind = update['kind'] as String? ?? update['toolName'] as String?;
    final kind = rawKind == null
        ? previous?.kind ?? ToolKind.other
        : _toolKind(rawKind);
    String? payload(List<String> keys, String? before) {
      for (final key in keys) {
        if (update.containsKey(key)) return _toolPayload(update[key]);
      }
      return before;
    }

    final details = ToolCallDetails(
      input: payload(const [
        'rawInput',
        'raw_input',
        'input',
      ], previous?.details?.input),
      output: payload(const [
        'rawOutput',
        'raw_output',
      ], previous?.details?.output),
      content: update.containsKey('content')
          ? _toolContent(update['content'])
          : previous?.details?.content,
    );
    final item = ToolCallItem(
      kind: kind,
      target: title,
      status: toolStatus,
      callId: id,
      tool: update['toolName'] as String? ?? previous?.tool,
      output: details.content ?? details.output,
      details: details,
    );
    _tools[id] = item;
    emit(ItemUpserted(nextSeq, id, item));
    emit(
      TasksReported(nextSeq, [
        KernelTask(
          id: id,
          description: title,
          kind: KernelTaskKind.other,
          status: status,
          startedAt: DateTime.now(),
          summary: title,
        ),
      ]),
    );
  }

  ToolKind _toolKind(String? raw) {
    final value = (raw ?? '').toLowerCase();
    if (value.contains('read')) return ToolKind.read;
    if (value.contains('grep') || value.contains('search')) {
      return ToolKind.search;
    }
    if (value.contains('todo')) return ToolKind.todo;
    if (value.contains('edit') || value.contains('write')) return ToolKind.edit;
    if (value.contains('command') || value.contains('shell')) {
      return ToolKind.command;
    }
    if (value.contains('agent')) return ToolKind.agent;
    return ToolKind.other;
  }

  /// Strings stay readable; structured payloads (including JSON strings) are
  /// formatted without interpreting them as Markdown or executable content.
  String? _toolPayload(Object? value) {
    if (value == null) return null;
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map || decoded is List) {
          return const JsonEncoder.withIndent('  ').convert(decoded);
        }
      } on FormatException {
        // Plain text is a valid tool payload too.
      }
      return value;
    }
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  String? _toolContent(Object? content) {
    if (content == null) return null;
    if (content is! List) return _toolPayload(content);
    if (content.isEmpty) return null;
    return [
      for (final block in content)
        // Standard ACP text content, plus legacy agents' bare text blocks.
        if (block is Map &&
            (block['type'] == 'content' ||
                block['type'] == 'text' ||
                block['type'] == null) &&
            _contentText(block) != null)
          _contentText(block)!
        else
          // Preserve diffs, embedded resources and unknown structured blocks.
          _toolPayload(block) ?? 'null',
    ].join('\n\n');
  }

  String? _toolDetail(Map<String, Object?> update) {
    final content = update['content'];
    if (content is List) {
      final text = content
          .whereType<Map>()
          .map(_contentText)
          .whereType<String>()
          .join();
      if (text.isNotEmpty) return text;
    }
    final raw = update['rawInput'] ?? update['raw_input'] ?? update['input'];
    return raw is String
        ? raw
        : raw == null
        ? null
        : '$raw';
  }

  /// ACP content blocks nest the text: `{type, content: {type, text}}`.
  /// Some agents put it on the block itself.
  String? _contentText(Map item) {
    final nested = item['content'];
    if (nested is Map) {
      final text = nested['text'];
      if (text is String && text.isNotEmpty) return text;
    }
    final text = item['text'];
    return text is String && text.isNotEmpty ? text : null;
  }

  Map? _jsonMap(Object? raw) {
    if (raw is Map) return raw;
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  // Some agents only expose todos in tool arguments, including history
  // replay. Papercode wraps those arguments in rawInput as a JSON string.
  void _todosFromTool(Map<String, Object?> update) {
    final input = _jsonMap(
      update['rawInput'] ?? update['raw_input'] ?? update['input'],
    );
    final name = (input?['name'] ?? update['toolName'] ?? update['title'])
        ?.toString()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z]'), '');
    final id = (update['toolCallId'] ?? update['id'])?.toString();
    final isTodo =
        name == 'todowrite' ||
        name == 'functionstodowrite' ||
        (id != null && _todoToolIds.contains(id));
    if (isTodo && id != null) _todoToolIds.add(id);
    if (isTodo && update['sessionUpdate'] == 'tool_call') {
      final args = _jsonMap(input?['arguments'] ?? input?['args']) ?? input;
      _todosUpdate(args?['todos']);
    }
    if (update['sessionUpdate'] != 'tool_call_update' ||
        update['status'] == 'failed') {
      return;
    }
    final output = _jsonMap(update['rawOutput'] ?? update['raw_output']);
    final result =
        _jsonMap(output?['content']) ?? output ?? _jsonMap(_toolDetail(update));
    if (result == null || result['ok'] == false) return;
    if (isTodo || result['ok'] == true) _todosUpdate(result['todos']);
  }

  ContextUsage? _contextUsage(Map<String, Object?> update) {
    int? asInt(Object? value) => switch (value) {
      final int n => n,
      final num n => n.round(),
      final String s => int.tryParse(s),
      _ => null,
    };
    final used =
        asInt(update['used']) ??
        asInt(update['inputTokens']) ??
        asInt(update['input_tokens']) ??
        asInt((update['usage'] as Map?)?['used']) ??
        asInt((update['usage'] as Map?)?['inputTokens']) ??
        asInt((update['usage'] as Map?)?['input_tokens']);
    final window =
        asInt(update['size']) ??
        asInt(update['contextWindow']) ??
        asInt(update['context_window']) ??
        asInt(update['window']) ??
        asInt((update['usage'] as Map?)?['size']) ??
        asInt((update['usage'] as Map?)?['contextWindow']) ??
        asInt((update['usage'] as Map?)?['context_window']) ??
        asInt((update['usage'] as Map?)?['window']);
    if (used == null || window == null || window <= 0) return null;
    _contextWindow = window;
    return ContextUsage(window: window, used: used);
  }

  Object? _planEntries(Map<String, Object?> update) {
    // ACP v1: top-level entries. v2 draft: nested under plan. Some agents
    // use items/todos, or send plan as the list itself.
    final plan = update['plan'];
    if (plan is List) return plan;
    if (plan is Map) {
      return plan['entries'] ??
          plan['items'] ??
          plan['todos'] ??
          plan['steps'] ??
          plan['tasks'];
    }
    return update['entries'] ??
        update['todos'] ??
        update['items'] ??
        update['todoItems'] ??
        update['steps'] ??
        update['tasks'];
  }

  String? _todoContent(Map item) {
    for (final key in const [
      'content',
      'title',
      'text',
      'description',
      'name',
      'task',
      'step',
      'summary',
    ]) {
      final value = item[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  void _todosUpdate(Object? raw) {
    if (raw is! List) return;
    final todos = <TodoEntry>[];
    for (final item in raw) {
      if (item is String) {
        final text = item.trim();
        if (text.isEmpty) continue;
        todos.add(TodoEntry(text, TodoStatus.pending));
        continue;
      }
      if (item is! Map) continue;
      final content = _todoContent(item);
      if (content == null) continue;
      // Spec: pending / in_progress / completed. Accept common aliases and
      // case variants from agents. v2 cancelled stays open (no cancelled UI).
      final status = switch (item['status']
          ?.toString()
          .trim()
          .toLowerCase()
          .replaceAll('-', '_')) {
        'completed' ||
        'done' ||
        'complete' ||
        'success' ||
        'succeeded' => TodoStatus.completed,
        'in_progress' ||
        'inprogress' ||
        'active' ||
        'running' ||
        'working' ||
        'current' => TodoStatus.inProgress,
        _ => TodoStatus.pending,
      };
      todos.add(
        TodoEntry(
          content,
          status,
          activeForm:
              item['activeForm'] as String? ?? item['active_form'] as String?,
        ),
      );
    }
    // Spec: each plan update replaces the whole list, including emptying it.
    emit(TodosReported(nextSeq, todos));
  }

  void _endTurn(bool interrupted) {
    final turn = _turnId;
    if (turn == null) return;
    final worked = _turnStarted == null
        ? null
        : DateTime.now().difference(_turnStarted!);
    emit(TurnEnded(nextSeq, turn, interrupted: interrupted, worked: worked));
    _turnId = null;
    _turnStarted = null;
    _cancelling = false;
    _closeAssistantStream();
  }

  void _closeMcp() {
    if (_mcpClosed) return;
    _mcpClosed = true;
    _mcp.close();
  }

  void _fail(Object error) {
    if (_disposed || _health.status == KernelHealthStatus.failed) return;
    _closeMcp();
    _health = KernelHealth(KernelHealthStatus.failed, message: '$error');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    _configRequests.clear();
    emitInfoChanged();
  }

  @override
  void restart() {
    if (_disposed) return;
    _startGeneration++;
    _receiveTimer?.cancel();
    _receiveTimer = null;
    _receivedInBatch = 0;
    for (final (index, _) in _mcp.warnings.indexed) {
      emit(ItemRemoved(nextSeq, 'acp_mcp_warning_$index'));
    }
    _transport?.close();
    _transport = null;
    _subscription?.cancel();
    _subscription = null;
    _sessionId = null;
    _hasConfigOptions = false;
    _configRequests.clear();
    _configChanges = Future.value();
    for (final option in _configOptions.values) {
      option.replace(null);
    }
    _modeOptions.clear();
    _legacyMode.options = const [];
    _legacyMode.reported = null;
    _initialized = false;
    _closeMcp();
    _mcp = const AcpMcpServers();
    _starting = false;
    _turnCount = 0;
    _cancelling = false;
    _closeAssistantStream();
    _messages.clear();
    _tools.clear();
    _todoToolIds.clear();
    _health = KernelHealth.idle;
    prepare();
  }

  @override
  void release() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _tools.clear();
    _configRequests.clear();
    _closeMcp();
    _receiveTimer?.cancel();
    _receiveTimer = null;
    _transport?.close();
    _subscription?.cancel();
    closeEvents();
  }
}

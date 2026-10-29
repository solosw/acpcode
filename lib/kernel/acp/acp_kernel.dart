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
import 'acp_terminal.dart';

/// Adapts an ACP JSON-RPC agent over a message transport to [AgentKernel].
class AcpKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        SelectsEffort,
        ProvidesCommands,
        ReportsContext,
        RunsBackgroundTasks {
  AcpKernel(
    this.descriptor,
    this._context,
    this._transportFactory, {
    this._catalog,
    this._loadMcpServers,
  }) {
    _live.add(this);
  }

  static final _live = <AcpKernel>{};

  /// Normal app exit also waits for ACP, not just the native Claude runtime.
  static Future<void> stopAll() async {
    final kernels = [..._live];
    for (final kernel in kernels) {
      kernel.dispose();
    }
    await Future.wait([
      for (final kernel in kernels)
        kernel.stopped.catchError((Object error) {
          debugPrint('Could not stop ACP agent: $error');
        }),
    ]);
  }

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
  bool _released = false;
  bool _sessionLoaded = false;
  bool _everLoaded = false;
  bool _retainedLoad = false;
  final _queuedTurns = <String>{};
  Future<void> _startTask = Future.value();
  Future<void> _stopping = Future.value();
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Set<String> _configRequests = {};
  final Map<String, String> _messages = {};
  final Map<String, ToolCallItem> _tools = {};
  final Map<String, KernelTask> _tasks = {};
  final _agents = <String, _AcpSubagent>{};
  final _toolParents = <String, String>{};
  final _childSessions = <String, _AcpChildSession>{};
  final _sessionMessages = <String, _AcpSessionMessage>{};
  AcpTerminalHost? _terminals;
  final _terminalSnapshots = <String, AcpTerminalSnapshot>{};
  final _terminalToolLinks = <String, List<String>>{};
  final _terminalToolBlocks = <String, List<Object?>>{};
  final _terminalApprovals = <String, Completer<bool>>{};
  int _terminalRequests = 0;
  int _terminalCancelEpoch = 0;
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
  Future<void> get stopped =>
      _waitForStop().timeout(const Duration(seconds: 6));

  Future<void> _waitForStop() async {
    // A launch that was cancelled before it returned must close its late
    // transport too. Merely cancelling the message stream proves no exit.
    await _startTask;
    await _stopping;
  }

  @override
  void prepare() {
    _released = false;
    _prepare();
  }

  void _prepare() {
    if (_disposed || _initialized || _starting) return;
    _starting = true;
    _health = const KernelHealth(KernelHealthStatus.starting);
    // ChatSession.attach calls prepare while ChatScreen is mounting. Existing
    // session listeners must not be invalidated in the middle of that build.
    scheduleMicrotask(() {
      if (!_disposed) emitInfoChanged();
    });
    final previous = _startTask;
    _startTask = _start(previous);
  }

  Future<void> _start(Future<void> previous) async {
    final generation = ++_startGeneration;
    bool obsolete() => _disposed || generation != _startGeneration;
    try {
      // Never overlap a replacement with a late launch or a closing process.
      await previous;
      await _stopping;
      if (obsolete()) return;
      _hasConfigOptions = false;
      // Also keep a synchronous factory failure out of the mounting frame.
      final transport = await Future<AcpTransport>.sync(
        () => _transportFactory(_context),
      );
      if (obsolete()) {
        await _closeTransport(transport);
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
      final cwd = _context.cwd ?? _context.resume?.cwd;
      if (cwd != null && cwd.isNotEmpty) {
        final host = RemoteLocation.hostOf(cwd);
        _terminals = createAcpTerminalHost([
          cwd,
          ...?_context.workspace?.call()?.folders.where(
            (folder) => RemoteLocation.hostOf(folder) == host,
          ),
        ], _terminalChanged);
      }
      final initialized = await _request('initialize', {
        'protocolVersion': 1,
        'clientInfo': {'name': 'BaoCode', 'version': '1.0.0'},
        'clientCapabilities': <String, Object?>{
          'subagents': <String, Object?>{},
          if (_terminals != null) 'terminal': true,
          // Claude ACP's compatibility extension streams child messages with
          // _meta.claudeCode.parentToolUseId instead of flattening them away.
          '_meta': {'subagent-transcript': true},
        },
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
      _releaseIfIdle();
    } on Object catch (error) {
      if (obsolete()) return;
      _starting = false;
      _fail(error);
    }
  }

  Future<void> _ensureSession() async {
    if (_sessionLoaded) return;
    final generation = _startGeneration;
    final resume = _context.resume;
    final retainedId = _sessionId ?? resume?.id;
    final Map<String, Object?> session;
    if (retainedId != null) {
      _sessionId = retainedId;
      _retainedLoad = _everLoaded;
      _replaying = !_retainedLoad;
      _closeAssistantStream();
      session = await _request('session/load', {
        'sessionId': retainedId,
        'cwd': _agentCwd(_context.cwd ?? resume?.cwd),
        'mcpServers': _mcp.servers,
      });
    } else {
      session = await _request('session/new', {
        'cwd': _agentCwd(_context.cwd),
        'mcpServers': _mcp.servers,
      });
      _sessionId = session['sessionId'] as String?;
    }
    if (_disposed || generation != _startGeneration) return;
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
    if (retainedId != null) _finishReplay();
    _retainedLoad = false;
    if (_sessionId == null) {
      throw StateError('ACP session returned no sessionId');
    }
    _sessionLoaded = true;
    _everLoaded = true;
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
    if (_disposed || turn.id == _turnId || !_queuedTurns.add(turn.id)) return;
    _prepare();
    unawaited(_sendWhenReady(turn, _startGeneration));
  }

  Future<void> _sendWhenReady(KernelTurn turn, int generation) async {
    bool obsolete() => _disposed || generation != _startGeneration;
    try {
      while (!_initialized &&
          !obsolete() &&
          _health.status != KernelHealthStatus.failed) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!_initialized || obsolete()) return;
      await _ensureSession();
      if (obsolete()) return;
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
      if (obsolete()) return;
      // /sessions may queue history until the prompt result arrives.
      if (loadsHistory) {
        _flushQueued();
        _finishReplay();
      }
      if (_turnId == turn.id) {
        _endTurn(result['stopReason'] == 'cancelled');
      }
    } on Object catch (error) {
      if (!obsolete()) _fail(error);
    } finally {
      _queuedTurns.remove(turn.id);
      _releaseIfIdle();
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
    final generation = _startGeneration;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    unawaited(
      _request('session/set_mode', {
        'sessionId': sessionId,
        'modeId': modeId,
      }).then(
        (_) {},
        onError: (Object error) {
          if (generation == _startGeneration) _fail(error);
        },
      ),
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
    if (_turnId == null &&
        _permissionRpcIds.isEmpty &&
        _terminalApprovals.isEmpty &&
        _terminalRequests == 0) {
      return;
    }
    _cancelling = true;
    _terminalCancelEpoch++;
    _cancelTerminalApprovals();
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
      _releaseIfIdle();
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
    final approval = _terminalApprovals.remove(requestId);
    if (approval != null) {
      approval.complete(
        answer is ApprovalAnswer && answer.decision != ApprovalDecision.deny,
      );
      emit(InteractionResolved(nextSeq, requestId));
      return;
    }
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
    _releaseIfIdle();
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
    try {
      final transport = _transport;
      if (transport == null) throw StateError('ACP connection closed');
      transport.write({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
      // ACP turns and startup wait on the agent, not a request timeout.
      return await completer.future;
    } finally {
      _pending.remove(id);
      _configRequests.remove(id);
    }
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

  void _linkTerminalContent(String toolId, Object? content, String? parentId) {
    if (content is! List) return;
    final session = parentId == null
        ? _sessionId
        : _childSessions.values
                  .where((child) => child.id == parentId)
                  .firstOrNull
                  ?.session ??
              _sessionId;
    final oldIds = _terminalToolLinks[toolId] ?? const <String>[];
    final ids = <String>[];
    for (final block in content) {
      if (block is! Map || block['type'] != 'terminal') continue;
      final snapshot = _terminalSnapshots[block['terminalId']];
      if (snapshot == null || snapshot.sessionId != session) continue;
      ids.add(snapshot.id);
    }
    if (ids.isEmpty) {
      _terminalToolLinks.remove(toolId);
      _terminalToolBlocks.remove(toolId);
      for (final id in oldIds) {
        _terminalChanged(_terminalSnapshots[id]!);
      }
      return;
    }
    _terminalToolLinks[toolId] = ids;
    _terminalToolBlocks[toolId] = content.toList();
    for (final id in oldIds.where((id) => !ids.contains(id))) {
      _terminalChanged(_terminalSnapshots[id]!);
    }
    for (final id in ids) {
      final synthetic = _terminalItemId(id);
      emit(ItemRemoved(nextSeq, synthetic));
      if (parentId != null) _ensureAgent(parentId).children.remove(synthetic);
      _reportTerminalTask(_terminalSnapshots[id]!);
    }
  }

  String _terminalToolContent(String toolId) => [
    for (final block in _terminalToolBlocks[toolId]!)
      if (block is Map &&
          block['type'] == 'terminal' &&
          _terminalToolLinks[toolId]!.contains(block['terminalId']))
        _terminalSnapshots[block['terminalId']]!.output
      else
        _toolContent([block]) ?? '',
  ].join('\n\n');

  void _cancelTerminalApprovals() {
    for (final entry in _terminalApprovals.entries.toList()) {
      entry.value.complete(false);
      emit(InteractionResolved(nextSeq, entry.key));
    }
    _terminalApprovals.clear();
  }

  Future<void> _terminalRequest(
    Object rpcId,
    String method,
    Map<String, Object?> params,
  ) async {
    final transport = _transport;
    final generation = _startGeneration;
    final host = _terminals;
    final cancelEpoch = _terminalCancelEpoch;
    bool cancelled() => _cancelling || cancelEpoch != _terminalCancelEpoch;
    bool current() =>
        !_disposed &&
        generation == _startGeneration &&
        identical(transport, _transport);
    _terminalRequests++;
    try {
      if (host == null) {
        throw const AcpTerminalError(
          -32601,
          'Client terminals are not available for this workspace',
        );
      }
      final session = params['sessionId'];
      if (session is! String ||
          session != _sessionId && !_childSessions.containsKey(session)) {
        throw const AcpTerminalError(-32602, 'Unknown terminal session');
      }
      Map<String, Object?> result;
      switch (method) {
        case 'terminal/create':
          if (_cancelling ||
              _replaying ||
              _retainedLoad ||
              _childSessions[session]?.legacyTerminal == true) {
            throw const AcpTerminalError(
              -32000,
              'Cannot start a terminal during replay or cancellation',
            );
          }
          final command = await host.validate(params);
          if (!current()) return;
          if (cancelled()) {
            throw const AcpTerminalError(
              -32000,
              'Terminal launch was cancelled',
            );
          }
          final requestId = 'acp_terminal_approval_${++_nextId}';
          final approval = Completer<bool>();
          _terminalApprovals[requestId] = approval;
          emit(
            InteractionRequested(
              nextSeq,
              ApprovalRequest(
                id: requestId,
                title: command.host == null
                    ? 'Run terminal command'
                    : 'Run terminal command on ${command.host}',
                toolName: 'terminal/create',
                reason: command.host == null
                    ? 'This command runs on your computer in the session workspace.'
                    : 'This command runs on ${command.host} in the remote session workspace.',
                preview: TextPreview(
                  const JsonEncoder.withIndent('  ').convert(command.input),
                ),
              ),
            ),
          );
          final allowed = await approval.future;
          if (!current()) return;
          if (!allowed || cancelled()) {
            throw const AcpTerminalError(
              -32000,
              'Terminal command was not approved',
            );
          }
          final id = await host.create(
            session,
            command,
            canStart: () =>
                current() &&
                !cancelled() &&
                _childSessions[session]?.legacyTerminal != true,
          );
          result = {'terminalId': id};
        case 'terminal/output':
          result = host.lookup(session, _terminalId(params)).result;
        case 'terminal/wait_for_exit':
          result = await host.wait(session, _terminalId(params));
        case 'terminal/kill':
          await host.kill(session, _terminalId(params));
          result = {};
        case 'terminal/release':
          await host.release(session, _terminalId(params));
          result = {};
        default:
          throw AcpTerminalError(-32601, 'method not found: $method');
      }
      if (current()) {
        transport?.write({'jsonrpc': '2.0', 'id': rpcId, 'result': result});
      }
    } on Object catch (error) {
      if (current()) {
        transport?.write({
          'jsonrpc': '2.0',
          'id': rpcId,
          'error': {
            'code': error is AcpTerminalError ? error.code : -32000,
            'message': '$error',
          },
        });
      }
    } finally {
      _terminalRequests--;
      if (!_disposed && _released) scheduleMicrotask(_releaseIfIdle);
    }
  }

  String _terminalId(Map<String, Object?> params) {
    final id = params['terminalId'];
    if (id is! String || id.isEmpty) {
      throw const AcpTerminalError(-32602, 'terminalId is required');
    }
    return id;
  }

  String _terminalItemId(String id) => 'acp_terminal_item_$id';

  void _terminalChanged(AcpTerminalSnapshot snapshot) {
    if (_disposed) return;
    final first = !_terminalSnapshots.containsKey(snapshot.id);
    _terminalSnapshots[snapshot.id] = snapshot;
    final links = _terminalToolLinks.entries
        .where((entry) => entry.value.contains(snapshot.id))
        .toList();
    if (links.isEmpty) {
      final id = _terminalItemId(snapshot.id);
      final item = _terminalItem(snapshot, id);
      final parent = _childSessions[snapshot.sessionId]?.id;
      if (parent == null) {
        if (first) _closeAssistantStream();
        emit(ItemUpserted(nextSeq, id, item));
      } else {
        if (first) _ensureAgent(parent).streamId = null;
        _ensureAgent(parent).children[id] = item;
        _publishAgent(parent);
      }
    } else {
      for (final entry in links) {
        final item = _tools[entry.key];
        if (item == null) continue;
        final parentId = _toolParents[entry.key];
        _toolUpdate({'toolCallId': entry.key}, parentId: parentId);
      }
    }
    _reportTerminalTask(snapshot);
    emit(TasksReported(nextSeq, _tasks.values.toList()));
    if (_released) scheduleMicrotask(_releaseIfIdle);
  }

  ToolCallItem _terminalItem(AcpTerminalSnapshot snapshot, String id) =>
      ToolCallItem(
        kind: ToolKind.command,
        target: snapshot.command.command,
        callId: id,
        tool: 'terminal',
        output: snapshot.output,
        status: snapshot.exitStatus == null
            ? ToolStatus.running
            : snapshot.exitStatus!['exitCode'] == 0
            ? ToolStatus.succeeded
            : ToolStatus.failed,
        details: ToolCallDetails(
          input: jsonEncode(snapshot.command.input),
          content: snapshot.output,
        ),
      );

  void _reportTerminalTask(AcpTerminalSnapshot snapshot) {
    final linked = _terminalToolLinks.entries
        .where((entry) => entry.value.contains(snapshot.id))
        .firstOrNull
        ?.key;
    final running = snapshot.exitStatus == null && !snapshot.released;
    _tasks[snapshot.id] = KernelTask(
      id: snapshot.id,
      description: snapshot.command.command,
      kind: KernelTaskKind.command,
      status: running
          ? CommandStatus.running
          : snapshot.exitStatus?['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: snapshot.startedAt,
      toolUseId: linked ?? _terminalItemId(snapshot.id),
      canStop: running && _terminals != null,
      summary: snapshot.output,
    );
  }

  @override
  void stopTask(String taskId) {
    final snapshot = _terminalSnapshots[taskId];
    final host = _terminals;
    if (snapshot == null ||
        host == null ||
        snapshot.released ||
        snapshot.exitStatus != null) {
      return;
    }
    unawaited(
      host.kill(snapshot.sessionId, taskId).catchError((Object error) {
        if (!_disposed) {
          emit(
            ItemUpserted(
              nextSeq,
              'acp_terminal_stop_$taskId',
              NoticeItem(NoticeKind.warning, 'Could not stop terminal: $error'),
            ),
          );
        }
      }),
    );
  }

  @override
  void moveToBackground(String toolUseId) {
    // Client-owned ACP terminals start asynchronously; none run in the foreground.
  }

  void _handleServerRequest(
    Object rpcId,
    String requestId,
    String method,
    Map<String, Object?> params,
  ) {
    if (method.startsWith('terminal/')) {
      unawaited(_terminalRequest(rpcId, method, params));
      return;
    }
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
    final child = _childSessions[session];
    if (_sessionId != null &&
        session is String &&
        session != _sessionId &&
        child == null) {
      // Unannounced sessions cannot establish a parent or affect this chat.
      return;
    }
    final update =
        (params['update'] as Map?)?.cast<String, Object?>() ?? const {};
    // This kernel's transcript survives an idle release. session/load still
    // restores agent context, but must not append that same history again.
    if (_retainedLoad &&
        !const {
          'available_commands_update',
          'config_option_update',
          'current_mode_update',
          'usage_update',
        }.contains(update['sessionUpdate'])) {
      return;
    }
    if (child?.legacyTerminal == true) return;
    final type = update['sessionUpdate'];
    if (type == 'subagent_update' ||
        type == 'subagent_spawned' ||
        type == 'subagent_state_update') {
      if (session is String) _subagentSessionUpdate(session, update);
      return;
    }
    if (type == 'session_message' || type == 'session_message_chunk') {
      if (session is String) _sessionMessageUpdate(session, update);
      return;
    }
    if (child != null) {
      if (child.legacyTerminal) return;
      if (type == 'state_update') {
        _childState(child, update);
        return;
      }
      if (type == 'user_message_chunk') {
        final content = update['content'];
        if (content is! Map) return;
        final rawId = update['messageId'] as String?;
        child.userMessageId =
            rawId ?? child.userMessageId ?? 'acp_child_user_${++_replaySeq}';
        _sessionMessageUpdate(session as String, {
          'sessionUpdate': 'session_message_chunk',
          'messageId': child.userMessageId,
          'senderSessionId': child.parentSession,
          'recipientSessionId': session,
          'content': content,
        });
        return;
      }
      child.userMessageId = null;
      // Tool ids are only unique within a session. Namespace them before
      // using the shared tool patch store or exposing them to the transcript.
      final toolId = update['toolCallId'] ?? update['id'];
      _agentUpdate(child.id, {
        ...update,
        if (toolId is String)
          'toolCallId': 'acp_child_tool_${jsonEncode([session, toolId])}',
      });
      return;
    }
    final meta = _jsonMap(_jsonMap(update['_meta'])?['claudeCode']);
    final toolId = update['toolCallId'] as String? ?? update['id'] as String?;
    final parentId =
        meta?['parentToolUseId'] as String? ??
        (toolId == null ? null : _toolParents[toolId]);
    if (parentId != null && parentId.isNotEmpty) {
      _agentUpdate(parentId, update);
      return;
    }
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

  void _toolUpdate(Map<String, Object?> update, {String? parentId}) {
    final id =
        update['toolCallId'] as String? ??
        update['id'] as String? ??
        'acp_tool';
    // ACP updates are patches: omitted fields retain the previous value.
    _linkTerminalContent(id, update['content'], parentId);
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
    final meta = _jsonMap(_jsonMap(update['_meta'])?['claudeCode']);
    final toolName =
        update['name'] as String? ??
        update['toolName'] as String? ??
        meta?['toolName'] as String? ??
        previous?.tool;
    final rawKind = update['kind'] as String? ?? toolName;
    var kind = rawKind == null
        ? previous?.kind ?? ToolKind.other
        : _toolKind(rawKind);
    if (kind == ToolKind.other) {
      kind = _toolKind(toolName);
    }
    String? payload(List<String> keys, String? before) {
      for (final key in keys) {
        if (update[key] != null) return _toolPayload(update[key]);
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
      content: _terminalToolLinks.containsKey(id)
          ? _terminalToolContent(id)
          : update['content'] != null
          ? _toolContent(update['content'])
          : previous?.details?.content,
    );
    final item = ToolCallItem(
      kind: kind,
      target: title,
      status: toolStatus,
      callId: id,
      tool: toolName,
      output: details.content ?? details.output,
      details: details,
    );
    _tools[id] = item;
    if (parentId != null) _toolParents[id] = parentId;
    if (kind == ToolKind.agent || _agents.containsKey(id)) {
      final agent = _ensureAgent(id, parentId: parentId);
      final input = _jsonMap(details.input);
      agent.item = agent.item.copyWith(
        description:
            input?['description'] as String? ??
            (title == 'Tool call' ? null : title),
        prompt: input?['prompt'] as String?,
        agentType: input?['subagent_type'] as String?,
        model: input?['model'] as String?,
        background: input?['run_in_background'] as bool?,
        status: status,
        result: status == CommandStatus.running ? null : item.output,
        duration: status == CommandStatus.running
            ? null
            : agent.item.duration ??
                  DateTime.now().difference(agent.item.startedAt!),
      );
      _publishAgent(id);
      return;
    }
    if (parentId != null) {
      final parent = _ensureAgent(parentId);
      parent.children[id] = item;
      parent.item = parent.item.copyWith(
        toolUses: parent.children.values.whereType<ToolCallItem>().length,
        lastTool: toolName ?? title,
        activity: title,
      );
      _publishAgent(parentId);
      return;
    }
    emit(ItemUpserted(nextSeq, id, item));
    if (_terminalToolLinks.containsKey(id)) {
      _tasks.remove(id);
      emit(TasksReported(nextSeq, _tasks.values.toList()));
      return;
    }
    _tasks[id] = KernelTask(
      id: id,
      description: title,
      kind: kind == ToolKind.command
          ? KernelTaskKind.command
          : KernelTaskKind.other,
      status: status,
      startedAt: _tasks[id]?.startedAt ?? DateTime.now(),
      toolUseId: id,
      canStop: false,
      summary: kind == ToolKind.command ? item.output : title,
    );
    emit(TasksReported(nextSeq, _tasks.values.toList()));
  }

  /// Both the current subagent RFD and the older Codex/AIR draft declare
  /// children on their parent. No tool-name heuristic participates here.
  void _subagentSessionUpdate(
    String parentSession,
    Map<String, Object?> update,
  ) {
    final standard = update['sessionUpdate'] == 'subagent_update';
    final rawId = update[standard ? 'sessionId' : 'subagentSessionId'];
    if (rawId is! String ||
        rawId.isEmpty ||
        rawId == _sessionId ||
        rawId == parentSession) {
      return;
    }
    final existing = _childSessions[rawId];
    if (existing != null && existing.parentSession != parentSession) return;
    if (update['sessionUpdate'] == 'subagent_state_update') {
      if (existing != null) _legacyChildState(existing, update['state']);
      return;
    }
    // An association is immutable. Also reject cycles before publishing a tree.
    var ancestor = _childSessions[parentSession];
    final seen = <String>{};
    while (ancestor != null && seen.add(ancestor.session)) {
      if (ancestor.session == rawId) return;
      ancestor = _childSessions[ancestor.parentSession];
    }
    final child = _childSessions.putIfAbsent(
      rawId,
      () => _AcpChildSession(
        rawId,
        parentSession,
        'acp_session_${jsonEncode(rawId)}',
      ),
    );
    _ensureAgent(child.id, parentId: _childSessions[parentSession]?.id);
    if (standard) {
      if (update.containsKey('title')) child.title = update['title'] as String?;
      if (update.containsKey('description')) {
        child.description = update['description'] as String?;
      }
      if (update.containsKey('state')) {
        _childState(child, _jsonMap(update['state']));
      } else {
        _refreshChild(child);
      }
    } else {
      if (existing == null) child.active = true;
      child.title = update['name'] as String? ?? child.title;
      final task = update['task'] as String?;
      final agent = _agents[child.id]!;
      agent.item = agent.item.copyWith(prompt: task);
      _refreshChild(child);
    }
  }

  void _refreshChild(_AcpChildSession child, {CommandStatus? status}) {
    final agent = _agents[child.id]!;
    final previous = agent.item;
    final nextStatus = status ?? previous.status;
    final running = nextStatus == CommandStatus.running;
    // Reconstruct to honor explicit metadata clears and to clear duration when
    // a standard association starts another round of foreground work.
    agent.item = AgentItem(
      id: child.id,
      description: child.title ?? child.description ?? 'Subagent',
      prompt: child.promptInTranscript ? null : previous.prompt,
      activity: child.description,
      status: nextStatus,
      startedAt: running && previous.status != CommandStatus.running
          ? DateTime.now()
          : previous.startedAt,
      duration: running
          ? null
          : previous.duration ?? DateTime.now().difference(previous.startedAt!),
      toolUses: previous.toolUses,
      lastTool: previous.lastTool,
      children: previous.children,
      background: previous.background,
    );
    _publishAgent(child.id);
    // Transport notifications can be synchronous. Do not close their stream
    // from inside its own delivery callback. Recheck idleness after the batch.
    if (!_starting && _released) scheduleMicrotask(_releaseIfIdle);
  }

  void _childState(_AcpChildSession child, Map? state) {
    child.active =
        state?['state'] == 'running' || state?['state'] == 'requires_action';
    child.userMessageId = null;
    final status = switch (state?['state']) {
      'idle' => switch (state?['stopReason']) {
        'cancelled' || 'error' || 'refusal' => CommandStatus.failed,
        _ => CommandStatus.succeeded,
      },
      // An absent, unknown or cleared snapshot is not evidence of completion.
      _ => CommandStatus.running,
    };
    _agents[child.id]!.streamId = null;
    _refreshChild(child, status: status);
  }

  void _legacyChildState(_AcpChildSession child, Object? state) {
    final status = switch (state) {
      'completed' => CommandStatus.succeeded,
      'failed' || 'cancelled' || 'disconnected' => CommandStatus.failed,
      _ => null,
    };
    if (status == null || child.legacyTerminal) return;
    child.legacyTerminal = true;
    child.active = false;
    _agents[child.id]!.streamId = null;
    _refreshChild(child, status: status);
  }

  /// Inter-session messages belong to the enclosing session's transcript.
  /// They are not a new user turn, nor a final result of the child lifetime.
  void _sessionMessageUpdate(String session, Map<String, Object?> update) {
    final messageId = update['messageId'];
    if (messageId is! String || messageId.isEmpty) return;
    final key = 'acp_session_message_${jsonEncode([session, messageId])}';
    final message = _sessionMessages.putIfAbsent(key, _AcpSessionMessage.new);
    message.sender = update['senderSessionId'] as String? ?? message.sender;
    message.recipient =
        update['recipientSessionId'] as String? ?? message.recipient;
    if (update['sessionUpdate'] == 'session_message_chunk') {
      message.content.add(update['content']);
    } else if (update.containsKey('content')) {
      message.content = (update['content'] as List?)?.toList() ?? [];
    }
    final text = [
      for (final block in message.content)
        if (block is Map)
          _contentText(block) ?? _toolPayload(block) ?? ''
        else
          _toolPayload(block) ?? '',
    ].join();
    final ChatItem item = message.sender == session
        ? AssistantTextItem(text)
        : message.recipient == session
        ? UserMessageItem(text: text)
        : NoticeItem(NoticeKind.info, text);
    final child = _childSessions[session];
    if (child == null) {
      _closeAssistantStream();
      emit(ItemUpserted(nextSeq, key, item));
    } else {
      if (child.legacyTerminal) return;
      final agent = _agents[child.id]!;
      agent.streamId = null;
      agent.children[key] = item;
      if (message.recipient == session && !child.promptInTranscript) {
        child.promptInTranscript = true;
        _refreshChild(child);
      } else {
        _publishAgent(child.id);
      }
    }
  }

  _AcpSubagent _ensureAgent(String id, {String? parentId}) {
    final agent = _agents.putIfAbsent(
      id,
      () => _AcpSubagent(
        AgentItem(id: id, description: 'Subagent', startedAt: DateTime.now()),
      ),
    );
    if (parentId != null && parentId != id && agent.parentId == null) {
      agent.parentId = parentId;
      // A child may stream before its enclosing delegation was reported.
      // Move that placeholder out of the root transcript when linked.
      emit(ItemRemoved(nextSeq, id));
    }
    return agent;
  }

  /// Each child has its own merge cursor, isolated from parallel tasks and
  /// the main assistant's open stream.
  void _agentUpdate(String id, Map<String, Object?> update) {
    if (!const {
      'agent_message_chunk',
      'agent_thought_chunk',
      'user_message_chunk',
      'tool_call',
      'tool_call_update',
    }.contains(update['sessionUpdate'])) {
      return;
    }
    final agent = _ensureAgent(id);
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
      case 'agent_thought_chunk':
        final text = _jsonMap(update['content'])?['text'];
        if (text is! String || text.isEmpty) return;
        final thought = update['sessionUpdate'] == 'agent_thought_chunk';
        final messageId = update['messageId'] as String?;
        if (agent.streamId == null ||
            agent.thought != thought ||
            !_canMergeMessageIds(agent.messageId, messageId)) {
          agent.streamId = 'acp_child_${++_replaySeq}';
          agent.messageId = messageId;
          agent.thought = thought;
        } else {
          agent.messageId ??= messageId;
        }
        final key = agent.streamId!;
        final previous = agent.children[key];
        final oldText = switch (previous) {
          AssistantTextItem() => previous.text,
          ThinkingItem() => previous.text,
          _ => '',
        };
        agent.children[key] = thought
            ? ThinkingItem(
                text: '$oldText$text',
                tokens: 0,
                startedAt: previous is ThinkingItem
                    ? previous.startedAt
                    : DateTime.now(),
              )
            : AssistantTextItem('$oldText$text');
        _publishAgent(id);
      case 'tool_call':
      case 'tool_call_update':
        agent.streamId = null;
        _toolUpdate(update, parentId: id);
      case 'user_message_chunk':
        // SubagentFeed displays the delegated prompt before its children.
        final text = _jsonMap(update['content'])?['text'];
        if (text is! String || text.isEmpty) return;
        agent.streamId = null;
        agent.prompt += text;
        agent.item = agent.item.copyWith(prompt: agent.prompt);
        _publishAgent(id);
    }
  }

  void _publishAgent(String id) {
    final visited = <String>{};
    var current = id;
    while (visited.add(current)) {
      final agent = _ensureAgent(current);
      agent.item = agent.item.copyWith(
        children: agent.children.values.toList(),
      );
      final item = agent.item;
      _tasks[current] = KernelTask(
        id: current,
        description: item.description,
        kind: KernelTaskKind.agent,
        status: item.status,
        startedAt: item.startedAt!,
        toolUseId: current,
        // ACP has no generic move-to-background operation for agent tools.
        background: true,
        canStop: false,
        summary: item.result ?? item.activity,
      );
      final parentId = agent.parentId;
      if (parentId == null) {
        emit(ItemUpserted(nextSeq, current, item));
        break;
      }
      _ensureAgent(parentId).children[current] = item;
      current = parentId;
    }
    emit(TasksReported(nextSeq, _tasks.values.toList()));
  }

  void _interruptAgents() {
    for (final child in _childSessions.values) {
      child.active = false;
    }
    for (final entry in _agents.entries.toList()) {
      final agent = entry.value;
      if (agent.item.status != CommandStatus.running) continue;
      agent.item = agent.item.copyWith(
        status: CommandStatus.failed,
        duration: DateTime.now().difference(agent.item.startedAt!),
      );
      _publishAgent(entry.key);
    }
  }

  ToolKind _toolKind(String? raw) {
    final value = (raw ?? '').toLowerCase();
    if (value.contains('read')) return ToolKind.read;
    if (value.contains('grep') || value.contains('search')) {
      return ToolKind.search;
    }
    if (value.contains('todo')) return ToolKind.todo;
    if (value.contains('edit') || value.contains('write')) return ToolKind.edit;
    if (value.contains('command') ||
        value.contains('shell') ||
        value == 'bash' ||
        value == 'execute' ||
        value == 'terminal') {
      return ToolKind.command;
    }
    if (value == 'task' || value == 'agent') {
      return ToolKind.agent;
    }
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
    if (interrupted) _interruptAgents();
    emit(TurnEnded(nextSeq, turn, interrupted: interrupted, worked: worked));
    _turnId = null;
    _turnStarted = null;
    _cancelling = false;
    _closeAssistantStream();
    if (!_starting) _releaseIfIdle();
  }

  void _closeMcp() {
    if (_mcpClosed) return;
    _mcpClosed = true;
    _mcp.close();
  }

  void _fail(Object error) {
    if (_disposed || _health.status == KernelHealthStatus.failed) return;
    _health = KernelHealth(KernelHealthStatus.failed, message: '$error');
    _endTurn(false);
    _disconnect();
    emitInfoChanged();
  }

  Future<void> _closeTransport(AcpTransport transport) {
    final closing = Future<void>.sync(transport.close);
    _stopping = Future.wait([_stopping, closing]).then((_) {});
    // Observe errors even when nobody is awaiting stopped yet. Keep the
    // original failure on _stopping so a replacement cannot overlap it.
    unawaited(
      _stopping.catchError((Object error) {
        debugPrint('Could not close ACP transport: $error');
      }),
    );
    return closing;
  }

  void _disconnect() {
    _cancelTerminalApprovals();
    final terminals = _terminals;
    _terminals = null;
    if (terminals != null) {
      final closing = Future<void>.sync(terminals.close);
      _stopping = Future.wait([_stopping, closing]).then((_) {});
      unawaited(
        _stopping.catchError((Object error) {
          debugPrint('Could not close ACP terminals: $error');
        }),
      );
    }
    _interruptAgents();
    if (_replaying && !_everLoaded) {
      // An interrupted initial load is only a partial transcript. Remove its
      // items so the next session/load can replay the complete history once.
      if (_replayTurnId != null) _endTurn(true);
      for (final id in {..._messages.keys, ..._tools.keys, ..._agents.keys}) {
        emit(ItemRemoved(nextSeq, id));
      }
      emit(TodosReported(nextSeq, const []));
      _tasks.clear();
      emit(TasksReported(nextSeq, const []));
    }
    _startGeneration++;
    _starting = false;
    _initialized = false;
    _sessionLoaded = false;
    _retainedLoad = false;
    _replaying = false;
    _replayTurnId = null;
    _receiveTimer?.cancel();
    _receiveTimer = null;
    _receivedInBatch = 0;
    final transport = _transport;
    _transport = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _closeMcp();
    _mcp = const AcpMcpServers();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('ACP connection closed'));
      }
    }
    _pending.clear();
    _configRequests.clear();
    _permissionRpcIds.clear();
    _permissionOptions.clear();
    _permissionKinds.clear();
    _commandInteractionIds.clear();
    _configChanges = Future.value();
    _closeAssistantStream();
    _messages.clear();
    // The transcript survives idle release/reconnect. Keep its child routing
    // and patch stores too: a retained session/load is deliberately not replayed.
    if (!_everLoaded) {
      _tools.clear();
      _agents.clear();
      _toolParents.clear();
      _childSessions.clear();
      _sessionMessages.clear();
    }
    _todoToolIds.clear();
    if (transport != null) {
      unawaited(_closeTransport(transport).catchError((Object _) {}));
    }
  }

  @override
  void restart() {
    if (_disposed) return;
    _endTurn(true);
    for (final (index, _) in _mcp.warnings.indexed) {
      emit(ItemRemoved(nextSeq, 'acp_mcp_warning_$index'));
    }
    _disconnect();
    _hasConfigOptions = false;
    for (final option in _configOptions.values) {
      option.replace(null);
    }
    _modeOptions.clear();
    _legacyMode.options = const [];
    _legacyMode.reported = null;
    _health = KernelHealth.idle;
    _prepare();
  }

  @override
  void release() {
    _released = true;
    _releaseIfIdle();
  }

  void _releaseIfIdle() {
    if (!_released ||
        _disposed ||
        (_turnId != null && !_replaying) ||
        _queuedTurns.isNotEmpty ||
        _childSessions.values.any((child) => child.active) ||
        _permissionRpcIds.isNotEmpty ||
        _terminalApprovals.isNotEmpty ||
        _terminalRequests != 0 ||
        (_terminals?.hasRunning ?? false) ||
        _health.status == KernelHealthStatus.failed) {
      return;
    }
    if (_transport == null && !_starting) return;
    _disconnect();
    _health = KernelHealth.idle;
    emitInfoChanged();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disconnect();
    // App exit must still find disposed sessions whose process is closing.
    unawaited(
      _waitForStop().then<void>(
        (_) => _live.remove(this),
        onError: (Object _) {
          _live.remove(this);
        },
      ),
    );
    closeEvents();
  }
}

/// An explicit parent-child association, keyed by the opaque ACP session id.
class _AcpChildSession {
  _AcpChildSession(this.session, this.parentSession, this.id);

  final String session;
  final String parentSession;
  final String id;
  String? title;
  String? description;
  bool legacyTerminal = false;
  bool active = false;
  bool promptInTranscript = false;
  String? userMessageId;
}

class _AcpSessionMessage {
  String? sender;
  String? recipient;
  List<Object?> content = [];
}

/// Mutable ACP routing state; only immutable snapshots reach the chat UI.
class _AcpSubagent {
  _AcpSubagent(this.item);

  AgentItem item;
  String? parentId;
  final children = <String, ChatItem>{};
  String prompt = '';
  String? streamId;
  String? messageId;
  bool? thought;
}

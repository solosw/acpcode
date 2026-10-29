import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:bao_pty/bao_pty.dart';
import 'package:bao_remote/client.dart';
import 'package:bao_remote/files.dart' show IdeFileNotFoundException;

import '../../remote/remote_location.dart';
import '../../remote/remote_services.dart' show RemotePtyAdapter;
import '../../remote/ssh_host.dart';
import '../claude_code/claude_environment.dart';
import 'acp_terminal_types.dart';

AcpTerminalHost? createAcpTerminalHost(
  List<String> roots,
  void Function(AcpTerminalSnapshot) onChanged,
) {
  if (roots.isEmpty) return null;
  final host = RemoteLocation.hostOf(roots.first);
  final paths = host == null ? p.context : p.posix;
  if ((host == null && !ptySupported) ||
      roots.any((r) => RemoteLocation.hostOf(r) != host) ||
      roots.any((r) => !paths.isAbsolute(RemoteLocation.pathOf(r)))) {
    return null;
  }
  return _TerminalHost(
    List.unmodifiable(roots.map(RemoteLocation.pathOf)),
    onChanged,
    host,
    paths,
  );
}

class _TerminalHost implements AcpTerminalHost {
  _TerminalHost(this.roots, this.onChanged, this.remoteHost, this.paths);
  final List<String> roots;
  final String? remoteHost;
  final p.Context paths;

  // Pin all validation and launches to one SSH connection. A replacement
  // connection must never reuse an approval made against the old server.
  Future<RemoteClient>? _connection;
  Future<RemoteClient> get _client =>
      _connection ??= SshHosts.instance[remoteHost!].ready;

  Future<String> _resolve(String path) async {
    if (remoteHost == null) return Directory(path).resolveSymbolicLinks();
    final client = await _client;
    final canonical = await client.realPath(path);
    if (await client.stat(canonical) != 'directory') {
      throw const AcpTerminalError(-32602, 'cwd must be an existing directory');
    }
    return canonical;
  }

  final void Function(AcpTerminalSnapshot) onChanged;
  final _terminals = <String, _Terminal>{};
  final _launches = <Future<String>>{};
  static int _nextId = 0;
  bool _closed = false;
  Future<void>? _closing;

  @override
  bool get hasRunning =>
      _launches.isNotEmpty ||
      _terminals.values.any((t) => !t.released && t.exitStatus == null);

  @override
  Future<AcpTerminalCommand> validate(Map<String, Object?> params) async {
    Never invalid(String message) => throw AcpTerminalError(-32602, message);
    final command = params['command'];
    final args = params['args'] ?? const [];
    final cwd = params['cwd'] ?? roots.first;
    final env = params['env'] ?? const [];
    final limit = params['outputByteLimit'] ?? 1048576;
    if (command is! String || command.isEmpty || command.contains('\u0000')) {
      invalid('command must be a non-empty executable name');
    }
    if (args is! List ||
        args.any((a) => a is! String || a.contains('\u0000'))) {
      invalid('args must contain only strings');
    }
    if (cwd is! String || !paths.isAbsolute(cwd)) {
      invalid('cwd must be absolute on the execution host');
    }
    if (env is! List) invalid('env must be a list');
    if (limit is! int || limit < 0 || limit > 8388608) {
      invalid('outputByteLimit must be between 0 and 8388608 bytes');
    }
    final environment = <String, String>{};
    for (final entry in env) {
      if (entry is! Map ||
          entry['name'] is! String ||
          entry['value'] is! String) {
        invalid('env entries require string name and value');
      }
      final name = entry['name'] as String;
      final value = entry['value'] as String;
      if (name.isEmpty ||
          name.contains('=') ||
          name.contains('\u0000') ||
          value.contains('\u0000')) {
        invalid('Invalid environment variable');
      }
      environment[name] = value;
    }
    try {
      final canonical = await _resolve(cwd);
      var inside = false;
      for (final root in roots) {
        final resolved = await _resolve(root);
        if (paths.equals(resolved, canonical) ||
            paths.isWithin(resolved, canonical)) {
          inside = true;
          break;
        }
      }
      if (!inside) {
        throw const AcpTerminalError(
          -32000,
          'cwd is outside the session workspace',
        );
      }
      return AcpTerminalCommand(
        command,
        args.cast<String>(),
        canonical,
        environment,
        limit,
        host: remoteHost,
      );
    } on IdeFileNotFoundException {
      invalid('cwd or workspace root does not exist on the execution host');
    } on FileSystemException {
      invalid('cwd or workspace root does not exist');
    }
  }

  @override
  Future<String> create(
    String sessionId,
    AcpTerminalCommand command, {
    required bool Function() canStart,
  }) {
    if (_closed) {
      throw const AcpTerminalError(-32000, 'Terminal host is closed');
    }
    final launch = _create(sessionId, command, canStart);
    _launches.add(launch);
    unawaited(
      launch.then<void>(
        (_) => _launches.remove(launch),
        onError: (Object _) {
          _launches.remove(launch);
        },
      ),
    );
    return launch;
  }

  Future<String> _create(
    String sessionId,
    AcpTerminalCommand command,
    bool Function() canStart,
  ) async {
    // Revalidate after asynchronous setup, before any process is started.
    final checked = await validate(command.input);
    if (!paths.equals(checked.cwd, command.cwd)) {
      throw const AcpTerminalError(
        -32000,
        'Working directory changed after approval',
      );
    }
    final environment = remoteHost == null
        ? {
            ...Platform.environment,
            ...await ClaudeEnvironment.of(),
            ...checked.env,
          }
        : checked.env;
    if (_closed || !canStart()) {
      throw const AcpTerminalError(-32000, 'Terminal launch was cancelled');
    }
    final Pty process;
    if (remoteHost == null) {
      process = await spawnPty(
        PtyLaunch(
          executable: checked.command,
          arguments: checked.args,
          workingDirectory: checked.cwd,
          environment: environment,
        ),
      );
    } else {
      final client = await _client;
      if (_closed || !canStart()) {
        throw const AcpTerminalError(-32000, 'Terminal launch was cancelled');
      }
      process = RemotePtyAdapter(
        await client.startPty(
          cwd: checked.cwd,
          shell: [checked.command, ...checked.args],
          shellIntegration: false,
          environment: environment,
          workspaceRoots: roots,
        ),
      );
    }
    final terminal = _Terminal(
      'acp_terminal_${++_nextId}',
      sessionId,
      checked,
      process,
      onChanged,
      posix: remoteHost != null || !Platform.isWindows,
    );
    _terminals[terminal.id] = terminal;
    if (_closed || !canStart()) {
      await terminal.release();
      throw const AcpTerminalError(-32000, 'Terminal launch was cancelled');
    }
    terminal.publish();
    return terminal.id;
  }

  _Terminal _get(String session, String id) {
    final terminal = _terminals[id];
    if (terminal == null ||
        terminal.released ||
        terminal.sessionId != session) {
      throw const AcpTerminalError(-32602, 'Unknown terminal for this session');
    }
    return terminal;
  }

  @override
  AcpTerminalSnapshot lookup(String sessionId, String id) =>
      _get(sessionId, id).snapshot;
  @override
  Future<Map<String, Object?>> wait(String sessionId, String id) async {
    final terminal = _get(sessionId, id);
    final result = await terminal.done.future;
    if (terminal.connectionLost) {
      throw const AcpTerminalError(
        -32000,
        'SSH connection lost; terminal exit status is unavailable',
      );
    }
    return result;
  }

  @override
  Future<void> kill(String sessionId, String id) => _get(sessionId, id).kill();
  @override
  Future<void> release(String sessionId, String id) =>
      _get(sessionId, id).release();
  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await Future.wait([
      for (final launch in _launches.toList())
        launch.then<void>((_) {}, onError: (Object _) {}),
    ]);
    await Future.wait([
      for (final terminal in _terminals.values) terminal.release(),
    ]);
  }
}

class _Terminal {
  _Terminal(
    this.id,
    this.sessionId,
    this.command,
    this.process,
    this.onChanged, {
    required this.posix,
  }) {
    _output = process.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => append(text, _filter), onDone: _drained.complete);
    unawaited(_finish());
  }

  final String id;
  final String sessionId;
  final AcpTerminalCommand command;
  final Pty process;
  final bool posix;
  final void Function(AcpTerminalSnapshot) onChanged;
  final startedAt = DateTime.now();
  final done = Completer<Map<String, Object?>>();
  final _drained = Completer<void>();
  final _filter = _PlainOutput();
  late final StreamSubscription<String> _output;
  String output = '';
  bool truncated = false;
  bool released = false;
  bool connectionLost = false;
  Map<String, Object?>? exitStatus;
  Timer? _notification;
  Future<void>? _killing;
  Future<void>? _releasing;

  AcpTerminalSnapshot get snapshot => AcpTerminalSnapshot(
    id: id,
    sessionId: sessionId,
    command: command,
    startedAt: startedAt,
    output: output,
    truncated: truncated,
    exitStatus: exitStatus,
    released: released,
  );

  void append(String text, _PlainOutput filter) {
    final plain = filter.add(text);
    if (plain.isEmpty) return;
    final bytes = utf8.encode('$output$plain');
    var start = bytes.length - command.outputByteLimit;
    if (start > 0) {
      truncated = true;
      while (start < bytes.length && (bytes[start] & 0xc0) == 0x80) {
        start++;
      }
      output = utf8.decode(bytes.sublist(start));
    } else {
      output = utf8.decode(bytes);
    }
    _notification ??= Timer(const Duration(milliseconds: 50), publish);
  }

  void publish() {
    _notification?.cancel();
    _notification = null;
    onChanged(snapshot);
  }

  Future<void> _finish() async {
    final code = await process.exitCode;
    // Remote notifications can settle exitCode before the decoded stream
    // has delivered its final chunk. wait_for_exit includes that chunk.
    await _drained.future;
    connectionLost = command.host != null && code == RemoteProcess.lostExitCode;
    exitStatus = connectionLost
        ? {'exitCode': null, 'signal': null}
        : posix && code < 0
        ? {
            'exitCode': null,
            'signal':
                'SIG${code == -9
                    ? 'KILL'
                    : code == -15
                    ? 'TERM'
                    : -code}',
          }
        : {'exitCode': code, 'signal': null};
    publish();
    done.complete(exitStatus!);
  }

  Future<void> kill() => _killing ??= _kill();
  Future<void> _kill() async {
    if (exitStatus != null) return;
    // Reuse the app's process-group/ConPTY cleanup rather than killing PIDs
    // discovered by a racy process-table scan.
    process.kill(PtySignal.terminate);
    try {
      await done.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(PtySignal.kill);
      await done.future.timeout(const Duration(seconds: 5));
    }
  }

  Future<void> release() => _releasing ??= _release();
  Future<void> _release() async {
    await kill();
    await _output.cancel();
    released = true;
    publish();
  }
}

/// Drop CSI, OSC, DCS and control characters, including split escape sequences.
/// Rendering process output must never trigger clipboard, input or URL actions.
class _PlainOutput {
  String state = 'text';
  bool escaped = false;
  String add(String text) {
    final out = StringBuffer();
    for (final c in text.runes) {
      if (state == 'string') {
        if (c == 7 || (escaped && c == 92)) {
          state = 'text';
          escaped = false;
        } else {
          escaped = c == 27;
        }
      } else if (state == 'escape') {
        state = c == 91
            ? 'csi'
            : [93, 80, 88, 94, 95].contains(c)
            ? 'string'
            : 'text';
      } else if (state == 'csi') {
        if (c >= 0x40 && c <= 0x7e) state = 'text';
      } else if (c == 27) {
        state = 'escape';
      } else if (c >= 0x20 && !(c >= 0x7f && c <= 0x9f) ||
          c == 10 ||
          c == 13 ||
          c == 9) {
        out.writeCharCode(c);
      }
    }
    return out.toString();
  }
}

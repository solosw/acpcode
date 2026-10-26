import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../claude_code/claude_environment.dart';
import 'acp_transport.dart';
import 'acp_process_shutdown.dart';

/// JSON-RPC over newline-delimited stdin/stdout.
class StdioAcpTransport implements AcpTransport {
  StdioAcpTransport._(this._process) {
    _subscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _readLine,
          onError: (Object error) {
            if (!_closed) _out.addError(error);
          },
          onDone: () {
            if (!_out.isClosed) unawaited(_out.close());
          },
        );
    _stderr = _process.stderr.listen((_) {}, onError: (Object _) {});
  }

  final Process _process;
  final StreamController<Map<String, Object?>> _out =
      StreamController<Map<String, Object?>>.broadcast(sync: true);
  late final StreamSubscription<String> _subscription;
  late final StreamSubscription<List<int>> _stderr;
  bool _closed = false;
  Future<void>? _closing;

  static Future<StdioAcpTransport> start(
    String command, {
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final executable = command.trim();
    if (executable.isEmpty) {
      throw const ProcessException('', [], 'ACP command is empty');
    }
    final directory = workingDirectory == null || workingDirectory.isEmpty
        ? null
        : workingDirectory;
    final env = await _environment(environment);
    final resolved = await _resolve(executable, env['PATH']);
    try {
      final process = await Process.start(
        resolved,
        arguments,
        workingDirectory: directory,
        environment: env,
        includeParentEnvironment: true,
      );
      return StdioAcpTransport._(process);
    } on ProcessException catch (error) {
      throw StateError(
        'Cannot start ACP agent "$executable". '
        'Use an absolute executable path or add its directory to PATH. $error',
      );
    }
  }

  /// The login shell's environment, so a GUI launch can find `solcode` the
  /// same way a terminal does. Explicit settings still win.
  static Future<Map<String, String>> _environment(
    Map<String, String>? extra,
  ) async {
    final login = await ClaudeEnvironment.of();
    final values = Map<String, String>.of(login);
    final inherited = values['PATH'] ?? Platform.environment['PATH'];
    final home = values['HOME'] ?? Platform.environment['HOME'];
    final paths = <String>[
      if (inherited != null && inherited.isNotEmpty) inherited,
      if (home != null && home.isNotEmpty) '$home/.local/bin',
      if (home != null && home.isNotEmpty) '$home/bin',
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ];
    values['PATH'] = paths.join(':');
    if (extra != null) values.addAll(extra);
    return values;
  }

  /// Absolute commands stay as written. Bare names are looked up on [path]
  /// so Process.start does not depend on the GUI's own PATH.
  static Future<String> _resolve(String executable, String? path) async {
    if (executable.contains('/') || path == null || path.isEmpty) {
      return executable;
    }
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      final candidate = File('$dir/$executable');
      if (candidate.existsSync()) return candidate.path;
    }
    return executable;
  }

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    _process.stdin.writeln(jsonEncode(message));
  }

  void _readLine(String line) {
    if (line.trim().isEmpty || _closed) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) _out.add(decoded.cast<String, Object?>());
    } on Object catch (error, stackTrace) {
      _out.addError(FormatException('Invalid ACP JSON: $error'), stackTrace);
    }
  }

  @override
  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    return _closing = _close();
  }

  Future<void> _close() async {
    // Do not await stdin before signalling: a non-reading peer may block it.
    unawaited(
      Future<void>.sync(_process.stdin.close).catchError((Object _) {}),
    );
    try {
      await stopAcpProcess(
        exitCode: _process.exitCode,
        kill: (force) => _process.kill(
          force ? ProcessSignal.sigkill : ProcessSignal.sigterm,
        ),
      );
    } finally {
      await Future.wait([_subscription.cancel(), _stderr.cancel()]);
      if (!_out.isClosed) unawaited(_out.close());
    }
  }
}

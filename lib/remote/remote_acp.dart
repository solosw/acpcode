// ACP agents of remote projects run on their host, the same way Claude Code
// does: the server starts the executable there, in that host's login
// environment, and the app speaks JSON-RPC over the forwarded stdio.
// Slash commands are whatever that process reports, not this machine's.

import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/client.dart';

import '../kernel/acp/acp_transport.dart';
import '../kernel/acp/acp_process_shutdown.dart';
import '../kernel/acp/acp_transport_io.dart';
import 'remote_location.dart';
import 'ssh_host.dart';

/// Starts the ACP agent named by [command] where [location] is.
///
/// A local folder starts it here. An `ssh://` project starts it on that
/// host, with [location]'s path there as the working directory. A bare
/// command is resolved on that host's login PATH.
Future<AcpTransport> startAcpAgent(
  String command, {
  List<String> arguments = const [],
  String? location,
  Map<String, String>? environment,
}) {
  final host = location == null ? null : RemoteLocation.hostOf(location);
  if (host == null) {
    return StdioAcpTransport.start(
      command,
      arguments: arguments,
      workingDirectory: location,
      environment: environment,
    );
  }
  return RemoteAcpTransport.start(
    SshHosts.instance[host],
    command,
    arguments: arguments,
    cwd: RemoteLocation.pathOf(location!),
    environment: environment,
    login: true,
  );
}

/// JSON-RPC over a process the remote server started.
class RemoteAcpTransport implements AcpTransport {
  RemoteAcpTransport._(this._process) {
    _stdout = _process.stdout
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

  /// A transport over [process], e.g. a fake under test.
  factory RemoteAcpTransport.forProcess(RemoteProcess process) =>
      RemoteAcpTransport._(process);

  static Future<RemoteAcpTransport> start(
    SshHost host,
    String command, {
    List<String> arguments = const [],
    String? cwd,
    Map<String, String>? environment,
    bool login = true,
  }) async {
    final executable = command.trim();
    if (executable.isEmpty) {
      throw StateError('ACP command is empty');
    }
    final RemoteClient client;
    try {
      client = await host.ready;
    } on SshConnectException catch (error) {
      throw StateError('Could not connect to ${host.host}: ${error.message}');
    } on Object catch (error) {
      throw StateError('Could not connect to ${host.host}: $error');
    }
    try {
      final process = await client.start(
        executable,
        arguments,
        cwd: cwd == null || cwd.isEmpty ? null : cwd,
        environment: environment,
        login: login,
      );
      return RemoteAcpTransport._(process);
    } on RpcClosed {
      throw StateError('The connection to ${host.host} was lost');
    } on Object catch (error) {
      throw StateError(
        'Cannot start ACP agent "$executable" on ${host.host}. '
        'Use a command on that host, or an absolute path there. $error',
      );
    }
  }

  final RemoteProcess _process;
  final StreamController<Map<String, Object?>> _out =
      StreamController<Map<String, Object?>>.broadcast(sync: true);
  bool _closed = false;
  Future<void>? _closing;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<List<int>> _stderr;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    _process.write(utf8.encode('${jsonEncode(message)}\n'));
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
    unawaited(Future<void>.sync(_process.closeStdin).catchError((Object _) {}));
    try {
      await stopAcpProcess(
        exitCode: _process.exitCode,
        kill: (force) => _process.kill(force: force),
      );
    } finally {
      await Future.wait([_stdout.cancel(), _stderr.cancel()]);
      if (!_out.isClosed) unawaited(_out.close());
    }
  }
}

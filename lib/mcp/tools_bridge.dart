// The app's own tools, for an agent that runs outside it: the agent's
// process starts the app as its MCP server (tools_stdio.dart), which passes
// every request back here, where the tools are (the browser's, the
// pictures').
//
// A socket of the data folder, one line per message (JSON), and a token made
// up for the run, kept in a file only the user reads: nothing on the
// network, and no other program of the machine let in.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import '../kernel/claude_code/claude_sdk_tools.dart';
import '../platform/data_dir.dart';
import 'tools_protocol.dart';

/// Serves [ClaudeSdkTools] to the processes of the app's ACP agents.
class ToolsBridge {
  ToolsBridge._();

  static final instance = ToolsBridge._();

  static final _random = Random.secure();

  /// What a process of the agents' connects to: a socket's path, or
  /// `127.0.0.1:port` on Windows; null before [start], or where it could
  /// not listen (the agents go without its tools).
  String? get address => _address;
  String? _address;

  /// The one a process of this run may open with.
  String? get token => _token;
  String? _token;

  ServerSocket? _server;
  Future<void>? _starting;

  final List<Socket> _sockets = [];

  String get folder => _folder ?? p.join(DataDirectory.current.path, 'mcp');

  /// The socket's file, where the platform has them.
  String get socketPath => p.join(_folder ?? folder, 'tools.sock');

  /// The folder [start] made its own: the data folder's as it was then,
  /// whatever it is said to be after.
  String? _folder;

  /// Listens, once a run: [address] and [token] are there after.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (_address != null) return;
    try {
      final dir = _folder = folder;
      await Directory(dir).create(recursive: true);
      if (!Platform.isWindows) await _restrict(dir, '700');
      // Bind before publishing credentials: a second app must not replace
      // the token belonging to the app that already owns this socket.
      final server = _server = Platform.isWindows
          ? await ServerSocket.bind(InternetAddress.loopbackIPv4, 0)
          : await _bindUnix();
      if (!Platform.isWindows) await _restrict(socketPath, '600');
      final token = _token = base64Url.encode(
        List<int>.generate(32, (_) => _random.nextInt(256)),
      );
      await _writeToken(token);
      _address = Platform.isWindows ? '127.0.0.1:${server.port}' : socketPath;
      final endpoint = File(p.join(dir, 'endpoint.json.part'));
      await endpoint.writeAsString(
        jsonEncode({'address': _address}),
        flush: true,
      );
      await endpoint.rename(p.join(dir, 'endpoint.json'));
      server.listen(_accept);
    } on Object catch (error) {
      // The agents are given no tools of the app's: it goes on.
      debugPrint('tools bridge: $error');
      await stop();
    }
  }

  Future<ServerSocket> _bindUnix() async {
    final path = socketPath;
    // One left by a run that ended: a running app answers on it, and is
    // left to.
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      try {
        (await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        )).destroy();
        throw StateError('another BaoCode answers on $path');
      } on SocketException {
        try {
          File(path).deleteSync();
        } on FileSystemException {
          // Bind says what it cannot.
        }
      }
    }
    return ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
  }

  /// Kept where only the user reads it.
  Future<void> _writeToken(String token) async {
    final file = File(p.join(_folder ?? folder, 'token'));
    await file.writeAsString(token, flush: true);
    if (!Platform.isWindows) await _restrict(file.path, '600');
  }

  Future<void> _restrict(String path, String mode) async {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not restrict MCP access', path);
    }
  }

  /// The environment a process of the agent's is started with, to reach the
  /// app's tools: [cwd], the project it works in.
  Map<String, String> environmentFor({String? cwd, String? session}) => {
    ToolsProtocol.addressVariable: ?address,
    ToolsProtocol.tokenVariable: ?_token,
    ToolsProtocol.cwdVariable: ?cwd,
    ToolsProtocol.sessionVariable: ?session,
  };

  int _nextConnection = 0;

  void _accept(Socket socket) {
    _sockets.add(socket);
    var authorized = false;
    String? cwd;
    String? session = 'mcp-${++_nextConnection}';
    final cancelled = Completer<void>();
    final writes = _Writes(socket);
    var initialized = false;
    final changes = ClaudeSdkTools.changes.listen((_) {
      if (authorized && initialized) {
        writes.add({
          'jsonrpc': '2.0',
          'method': 'notifications/tools/list_changed',
        });
      }
    });
    void close() {
      unawaited(changes.cancel());
      if (!cancelled.isCompleted) cancelled.complete();
      _sockets.remove(socket);
      socket.destroy();
    }

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            final Object? decoded;
            try {
              decoded = jsonDecode(line);
            } on FormatException {
              return close();
            }
            if (!authorized) {
              // The first line alone says who it is.
              final hello = switch (decoded) {
                {'baocode': final Map<String, Object?> hello} => hello,
                _ => null,
              };
              if (hello == null || _token == null || hello['token'] != _token) {
                return close();
              }
              if ((hello['cwd'] != null && hello['cwd'] is! String) ||
                  (hello['session'] != null && hello['session'] is! String)) {
                return close();
              }
              authorized = true;
              cwd = hello['cwd'] as String?;
              session = hello['session'] as String? ?? session;
              return;
            }
            if (decoded is! Map) return;
            if (decoded['method'] == 'notifications/initialized') {
              initialized = true;
            }
            // Not waited on: a tool that runs long (the browser waits on
            // the user) must not hold back the cancel that follows it.
            unawaited(
              _answer(
                decoded.cast<String, Object?>(),
                cwd,
                session,
                cancelled.future,
                writes,
              ),
            );
          },
          onError: (Object _) => close(),
          onDone: close,
        );
  }

  Future<void> _answer(
    Map<String, Object?> message,
    String? cwd,
    String? session,
    Future<void> cancelled,
    _Writes writes,
  ) async {
    final Map<String, Object?> reply;
    try {
      reply = await ClaudeSdkTools.handle(
        message,
        ClaudeSdkCall(
          cwd: cwd ?? '',
          sessionId: session,
          cancelled: cancelled,
          toolUseId: switch (message['params']) {
            {'_meta': {'claudecode/toolUseId': final String id}} => id,
            _ => null,
          },
        ),
      );
    } on Object catch (error) {
      if (message['id'] == null) return;
      writes.add({
        'jsonrpc': '2.0',
        'id': message['id'] ?? 0,
        'error': {'code': -32603, 'message': '$error'},
      });
      return;
    }
    // A notification takes no answer.
    if (message['id'] != null) writes.add(reply);
  }

  /// Lets the agents' processes go (the app is quitting).
  Future<void> stop() async {
    for (final socket in [..._sockets]) {
      socket.destroy();
    }
    _sockets.clear();
    final server = _server;
    _server = null;
    _starting = null;
    _address = null;
    _token = null;
    if (server != null) {
      await server.close();
      for (final path in [
        if (!Platform.isWindows) socketPath,
        p.join(folder, 'endpoint.json'),
        p.join(folder, 'token'),
      ]) {
        try {
          File(path).deleteSync();
        } on FileSystemException {
          // Gone.
        }
      }
    }
    _folder = null;
  }
}

/// Writes whole lines, one after the other: answers out of order still go
/// out one at a time.
class _Writes {
  _Writes(this._socket);

  final Socket _socket;
  Future<void> _queue = Future.value();
  bool _closed = false;

  void add(Map<String, Object?> message) {
    if (_closed) return;
    final line = '${jsonEncode(message)}\n';
    _queue = _queue.then((_) async {
      if (_closed) return;
      try {
        _socket.add(utf8.encode(line));
        await _socket.flush();
      } on Object {
        _closed = true;
      }
    });
  }
}

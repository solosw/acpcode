// The stdio MCP process forwards to the running app, which owns its tools.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tools_protocol.dart';

bool runsToolsStdio(List<String> arguments) =>
    arguments.contains(ToolsProtocol.flag);

String get toolsServerCommand => Platform.resolvedExecutable;

List<String> get toolsServerArguments => const [ToolsProtocol.flag];

/// A user-level registration names the data folder, never a session's token.
/// Read the running app's current endpoint each time the agent starts us.
Future<(String, String)> _endpoint(Map<String, String> environment) async {
  final address = environment[ToolsProtocol.addressVariable];
  final token = environment[ToolsProtocol.tokenVariable];
  if (address != null && token != null) return (address, token);
  final data = environment[ToolsProtocol.dataDirectoryVariable];
  if (data == null || data.isEmpty) {
    throw const FileSystemException('No running BaoCode app configured');
  }
  final folder = p.join(data, 'mcp');
  final endpoint = jsonDecode(
    await File(p.join(folder, 'endpoint.json')).readAsString(),
  );
  if (endpoint is! Map || endpoint['address'] is! String) {
    throw const FormatException('Invalid BaoCode MCP endpoint');
  }
  return (
    endpoint['address'] as String,
    (await File(p.join(folder, 'token')).readAsString()).trim(),
  );
}

/// MCP alone on stdout; failures go to stderr. App disconnect and client EOF
/// both end the process. Client EOF allows a bounded drain for quick replies;
/// longer calls are cancelled by closing their app connection.
Future<int> runToolsStdio(
  List<String> arguments, {
  Map<String, String>? environment,
  Stream<List<int>>? input,
  IOSink? output,
  IOSink? diagnostics,
  Duration drainTimeout = const Duration(seconds: 2),
}) async {
  final env = environment ?? Platform.environment;
  final out = output ?? stdout;
  final errors = diagnostics ?? stderr;
  final Socket socket;
  try {
    final (address, token) = await _endpoint(env);
    if (token.isEmpty) throw const FormatException('Missing MCP token');
    socket = await _connect(address).timeout(const Duration(seconds: 5));
    socket.add(
      utf8.encode(
        '${jsonEncode(ToolsProtocol.hello(token: token, cwd: env[ToolsProtocol.cwdVariable] ?? Directory.current.path, session: env[ToolsProtocol.sessionVariable]))}\n',
      ),
    );
    await socket.flush();
  } on Object catch (error) {
    errors.writeln('BaoCode MCP: could not reach the running app: $error');
    await errors.flush();
    return 2;
  }

  final done = Completer<int>();
  final pending = <Object>{};
  var inputEnded = false;
  Timer? drainTimer;
  void finish(int code) {
    if (!done.isCompleted) done.complete(code);
  }

  void settled() {
    if (inputEnded && pending.isEmpty) finish(0);
  }

  final answers = socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          try {
            final message = jsonDecode(line);
            if (message is! Map || message['jsonrpc'] != '2.0') {
              throw const FormatException('Invalid MCP response');
            }
            out.writeln(line);
            if (!message.containsKey('method')) pending.remove(message['id']);
            settled();
          } on Object {
            finish(3);
          }
        },
        onDone: () => finish(3),
        onError: (Object _) => finish(3),
      );
  final messages = (input ?? stdin)
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line.trim().isEmpty || done.isCompleted) return;
          final Object? decoded;
          try {
            decoded = jsonDecode(line);
          } on FormatException {
            out.writeln(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': null,
                'error': {'code': -32700, 'message': 'Parse error'},
              }),
            );
            return;
          }
          if (decoded is! Map || decoded['method'] is! String) {
            out.writeln(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': decoded is Map ? decoded['id'] : null,
                'error': {'code': -32600, 'message': 'Invalid Request'},
              }),
            );
            return;
          }
          if (decoded['id'] case final Object id) pending.add(id);
          socket.add(utf8.encode('$line\n'));
        },
        onDone: () {
          inputEnded = true;
          // Drain quick replies, but a tool waiting for connection cancellation
          // must not keep an orphaned proxy (and its app-side call) alive.
          if (pending.isNotEmpty) {
            drainTimer = Timer(drainTimeout, () => finish(3));
          }
          settled();
        },
        onError: (Object _) => finish(3),
      );
  final code = await done.future;
  drainTimer?.cancel();
  await messages.cancel();
  await answers.cancel();
  socket.destroy();
  await out.flush();
  if (code != 0) {
    errors.writeln('BaoCode MCP: the app closed the tools connection.');
    await errors.flush();
  }
  return code;
}

Future<Socket> _connect(String address) async {
  if (address.startsWith('127.0.0.1:')) {
    return Socket.connect(
      InternetAddress.loopbackIPv4,
      int.parse(address.substring('127.0.0.1:'.length)),
    );
  }
  if (!p.isAbsolute(address)) {
    throw const FormatException('The MCP endpoint must be local');
  }
  return Socket.connect(
    InternetAddress(address, type: InternetAddressType.unix),
    0,
  );
}

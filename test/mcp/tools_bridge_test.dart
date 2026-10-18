@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/mcp/tools_bridge.dart';
import 'package:baocode/mcp/tools_protocol.dart';
import 'package:baocode/mcp/tools_stdio.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory data;
  late ToolsBridge bridge;

  setUp(() async {
    data = Directory.systemTemp.createTempSync('tools-bridge-');
    DataDirectory.current = DataDirectory(data.path);
    bridge = ToolsBridge.instance;
    ClaudeSdkTools.register(
      const ClaudeSdkTool(
        name: 'echo_cwd',
        description: 'Says the working directory the call is about.',
        inputSchema: {'type': 'object'},
        run: _echoCwd,
      ),
    );
  });

  tearDown(() async {
    ClaudeSdkTools.unregister('echo_cwd');
    await bridge.stop();
    if (data.existsSync()) data.deleteSync(recursive: true);
  });

  test('the folder it binds in is the data folder it started in', () async {
    await bridge.start();
    final bound = bridge.socketPath;
    final token = File('${bridge.folder}/token');
    // The data folder said to be another after the start: the socket and
    // the token stay where they were made (main.dart sets it up first).
    DataDirectory.current = DataDirectory('${data.path}-elsewhere');
    expect(bridge.socketPath, bound);
    expect(token.existsSync(), isTrue);
    expect(File('${data.path}-elsewhere/mcp/token').existsSync(), isFalse);
  });

  test(
    'user-level endpoint discovers new credentials after app restart',
    () async {
      await bridge.start();
      final firstToken = bridge.token;
      Future<void> call() async {
        final out = _Lines();
        final code = await runToolsStdio(
          const [ToolsProtocol.flag],
          environment: {ToolsProtocol.dataDirectoryVariable: data.path},
          input: Stream.value(
            utf8.encode(
              '${jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'method': 'tools/call',
                'params': {'name': 'echo_cwd', 'arguments': {}},
              })}\n',
            ),
          ),
          output: out.sink,
        );
        expect(code, 0);
        expect(
          ((out.messages.single['result'] as Map)['content'] as List).single,
          containsPair('text', Directory.current.path),
        );
      }

      await call();
      await bridge.stop();
      await bridge.start();
      expect(bridge.token, isNot(firstToken));
      await call();
    },
  );

  test('app disconnect ends the proxy while client stdin is still open', () async {
    await bridge.start();
    final input = StreamController<List<int>>();
    final out = _Lines();
    final errors = _Lines();
    final done = runToolsStdio(
      const [ToolsProtocol.flag],
      environment: {ToolsProtocol.dataDirectoryVariable: data.path},
      input: input.stream,
      output: out.sink,
      diagnostics: errors.sink,
    );
    input.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})}\n',
      ),
    );
    for (var i = 0; i < 100 && out.lines.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(out.messages, hasLength(1));
    await bridge.stop();
    expect(await done.timeout(const Duration(seconds: 3)), 3);
    expect(errors.lines.single, contains('closed'));
    await input.close();
  });

  test('an initialized client is notified when browser tools become available', () async {
    await bridge.start();
    final socket = await _connect(bridge.address!);
    final replies = <Map<String, Object?>>[];
    final sub = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          replies.add(jsonDecode(line) as Map<String, Object?>);
        });
    socket.add(
      utf8.encode(
        '${jsonEncode(ToolsProtocol.hello(token: bridge.token!))}\n'
        '${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n',
      ),
    );
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ClaudeSdkTools.register(
      const ClaudeSdkTool(
        name: 'late_tool',
        description: 'Newly available',
        inputSchema: {'type': 'object'},
        run: _echoCwd,
      ),
    );
    addTearDown(() => ClaudeSdkTools.unregister('late_tool'));
    for (var i = 0; i < 100 && replies.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(replies, [
      containsPair('method', 'notifications/tools/list_changed'),
    ]);
    await sub.cancel();
    socket.destroy();
  });

  test('the token is kept where only the user reads it', () async {
    await bridge.start();
    expect(bridge.address, isNotNull);
    final file = File('${bridge.folder}/token');
    expect(file.readAsStringSync(), bridge.token);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x3F, 0);
    }
  });

  test('a process reaches the tools, with the project it is for', () async {
    await bridge.start();
    final out = _Lines();
    final code = await runToolsStdio(
      const [ToolsProtocol.flag],
      environment: {
        ToolsProtocol.addressVariable: bridge.address!,
        ToolsProtocol.tokenVariable: bridge.token!,
        ToolsProtocol.cwdVariable: '/projects/one',
      },
      input: Stream.value(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}})}\n'
          '${jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})}\n'
          '${jsonEncode({
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {'name': 'echo_cwd', 'arguments': {}},
          })}\n',
        ),
      ),
      output: out.sink,
    );
    expect(code, 0);
    final messages = out.messages;
    expect(messages[0], containsPair('result', isA<Map>()));
    expect((messages[1]['result']! as Map)['tools'], [
      containsPair('name', 'echo_cwd'),
    ]);
    expect(
      ((messages[2]['result']! as Map)['content']! as List).single,
      containsPair('text', '/projects/one'),
    );
  });

  test('standard MCP ping returns an empty result', () async {
    await bridge.start();
    final out = _Lines();
    final code = await runToolsStdio(
      const [ToolsProtocol.flag],
      environment: {ToolsProtocol.dataDirectoryVariable: data.path},
      input: Stream.value(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': 7, 'method': 'ping'})}\n',
        ),
      ),
      output: out.sink,
    );
    expect(code, 0);
    expect(out.messages.single, {'jsonrpc': '2.0', 'id': 7, 'result': {}});
  });

  test('EOF bounds reply draining and cancels a long running call', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'until_disconnect',
        description: 'Wait for connection cancellation',
        inputSchema: const {'type': 'object'},
        run: (_, call) async {
          started.complete();
          await call.cancelled;
          cancelled.complete();
          return 'cancelled';
        },
      ),
    );
    addTearDown(() => ClaudeSdkTools.unregister('until_disconnect'));
    await bridge.start();
    final input = StreamController<List<int>>();
    final out = _Lines();
    final errors = _Lines();
    final done = runToolsStdio(
      const [ToolsProtocol.flag],
      environment: {ToolsProtocol.dataDirectoryVariable: data.path},
      input: input.stream,
      output: out.sink,
      diagnostics: errors.sink,
      drainTimeout: const Duration(milliseconds: 50),
    );
    input.add(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 8,
          'method': 'tools/call',
          'params': {'name': 'until_disconnect', 'arguments': {}},
        })}\n',
      ),
    );
    await started.future.timeout(const Duration(seconds: 3));
    await input.close();
    expect(await done.timeout(const Duration(seconds: 3)), 3);
    await cancelled.future.timeout(const Duration(seconds: 3));
    expect(out.messages, isEmpty);
  });

  test('a process without the token is let go, answered nothing', () async {
    await bridge.start();
    final out = _Lines();
    final code = await runToolsStdio(
      const [ToolsProtocol.flag],
      environment: {
        ToolsProtocol.addressVariable: bridge.address!,
        ToolsProtocol.tokenVariable: 'not-the-token',
      },
      input: Stream.value(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})}\n',
        ),
      ),
      output: out.sink,
    );
    expect(code, 3);
    expect(out.messages, isEmpty);
  });

  test('a cancel is taken while the call it is for still waits', () async {
    final cancelled = Completer<void>();
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'wait_for_cancel',
        description: 'Waits until the agent gives it up.',
        inputSchema: const {'type': 'object'},
        run: (input, call) async {
          await call.cancelled;
          cancelled.complete();
          return 'cancelled';
        },
      ),
    );
    addTearDown(() => ClaudeSdkTools.unregister('wait_for_cancel'));
    await bridge.start();
    final answers = <Map<String, Object?>>[];
    final socket = await _connect(bridge.address!);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => answers.add(jsonDecode(line) as Map<String, Object?>),
        );
    socket.add(
      utf8.encode(
        '${jsonEncode(ToolsProtocol.hello(token: bridge.token!, session: 's1'))}\n',
      ),
    );
    socket.add(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'tools/call',
          'params': {'name': 'wait_for_cancel', 'arguments': {}},
        })}\n',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    socket.add(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': 9},
        })}\n',
      ),
    );
    await cancelled.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((answers.single['result']! as Map)['content'], [
      containsPair('text', 'cancelled'),
    ]);
    socket.destroy();
  });

  test('no app to pass the tools on to: it says so, and stops', () async {
    final out = _Lines();
    final errors = _Lines();
    final code = await runToolsStdio(
      const [ToolsProtocol.flag],
      environment: const {},
      input: const Stream.empty(),
      output: out.sink,
      diagnostics: errors.sink,
    );
    expect(code, 2);
    expect(out.lines, isEmpty);
    expect(errors.lines.single, contains('could not reach'));
  });
}

Future<String> _echoCwd(Map<String, Object?> input, ClaudeSdkCall call) async =>
    call.cwd;

Future<Socket> _connect(String address) async {
  final separator = address.lastIndexOf(':');
  final host = separator > 0 ? address.substring(0, separator) : null;
  if (host != null && !host.contains('/')) {
    return Socket.connect(host, int.parse(address.substring(separator + 1)));
  }
  return Socket.connect(
    InternetAddress(address, type: InternetAddressType.unix),
    0,
  );
}

/// The lines a process wrote.
class _Lines {
  _Lines() {
    _controller.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
  }

  final _controller = StreamController<List<int>>();
  final lines = <String>[];

  IOSink get sink => IOSink(_controller.sink);

  List<Map<String, Object?>> get messages => [
    for (final line in lines) jsonDecode(line) as Map<String, Object?>,
  ];
}

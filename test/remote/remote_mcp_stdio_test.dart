@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/server.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/mcp/tools_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

String get _dart {
  final alongside = p.join(p.dirname(Platform.resolvedExecutable), 'dart');
  return File(alongside).existsSync() ? alongside : 'dart';
}

class _Relay {
  _Relay(this.process, {bool readOutput = true}) {
    errors = process.stderr.transform(utf8.decoder).join();
    if (readOutput) {
      _output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            messages.add((jsonDecode(line) as Map).cast<String, Object?>());
          });
    }
  }

  final Process process;
  final messages = <Map<String, Object?>>[];
  late final Future<String> errors;
  StreamSubscription<String>? _output;

  static Future<_Relay> start(
    Map<String, String> environment, {
    List<String>? command,
    bool readOutput = true,
  }) async {
    final launch =
        command ?? [_dart, p.absolute('test/fixtures/remote_mcp_stdio.dart')];
    final relay = _Relay(
      await Process.start(
        launch.first,
        launch.skip(1).toList(),
        environment: environment,
      ),
      readOutput: readOutput,
    );
    addTearDown(() async {
      relay.process.kill();
      await relay.process.exitCode.timeout(const Duration(seconds: 5));
      await relay._output?.cancel();
    });
    return relay;
  }

  Future<void> send(
    String method, {
    Object? id,
    Map<String, Object?> params = const {},
  }) async {
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': ?id,
        'method': method,
        'params': params,
      }),
    );
    await process.stdin.flush();
  }

  Future<Map<String, Object?>> response(Object? id) async {
    await until(
      () => messages.any(
        (message) => message.containsKey('id') && message['id'] == id,
      ),
    );
    return messages.firstWhere(
      (message) => message.containsKey('id') && message['id'] == id,
    );
  }

  Future<void> initialize() async {
    await send(
      'initialize',
      id: 'init',
      params: {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'remote-stdio-test', 'version': '1'},
      },
    );
    expect(
      (await response('init'))['result'],
      containsPair('protocolVersion', '2025-11-25'),
    );
    await send('notifications/initialized');
  }
}

Map<String, String> _environment(ToolsHttpConnection connection) {
  final headers = connection.configuration['headers'] as Map;
  return {
    ServerMcp.urlVariable: connection.configuration['url'] as String,
    ServerMcp.tokenVariable: (headers['Authorization'] as String).substring(
      'Bearer '.length,
    ),
  };
}

String _text(Map<String, Object?> response) =>
    ((response['result'] as Map)['content'] as List).single['text'] as String;

void main() {
  late ToolsHttpServer server;
  late ToolsHttpConnection connection;

  setUp(() async {
    server = ToolsHttpServer();
    await server.start();
    connection = server.open(cwd: 'ssh://dev/project');
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'remote_mcp_context',
        description: 'The context supplied by the local app',
        inputSchema: const {'type': 'object'},
        run: (_, call) async =>
            jsonEncode({'cwd': call.cwd, 'session': call.sessionId}),
      ),
    );
  });
  tearDown(() async {
    connection.close();
    await server.stop();
    for (final name in [
      'remote_mcp_context',
      'remote_mcp_wait',
      'remote_mcp_changed',
      'remote_mcp_large',
    ]) {
      ClaudeSdkTools.unregister(name);
    }
  });

  test(
    'hello advertises the independent relay and reads older hello objects',
    () async {
      final previous = ServerMcp.selfCommand;
      ServerMcp.selfCommand = () => [
        _dart,
        p.absolute('packages/bao_remote/bin/baocode_server.dart'),
      ];
      addTearDown(() => ServerMcp.selfCommand = previous);
      final harness = await RemoteHarness.start();
      addTearDown(harness.close);
      final hello = harness.client.hello!;
      expect(hello.mcpStdioCommand, [...ServerMcp.selfCommand(), 'mcp-stdio']);
      expect(
        RemoteHello.fromJson(hello.toJson()).mcpStdioCommand,
        hello.mcpStdioCommand,
      );
      final old = hello.toJson()..remove('mcpStdioCommand');
      expect(RemoteHello.fromJson(old).mcpStdioCommand, isEmpty);
      expect(
        RemoteHello.fromJson(old).toJson(),
        isNot(contains('mcpStdioCommand')),
      );
    },
  );

  test(
    'the real bin runs a local app tool without creating server data',
    () async {
      final home = Directory.systemTemp.createTempSync('remote-mcp-home-');
      addTearDown(() => home.deleteSync(recursive: true));
      final relay = await _Relay.start(
        {..._environment(connection), 'HOME': home.path},
        command: [
          _dart,
          p.absolute('packages/bao_remote/bin/baocode_server.dart'),
          'mcp-stdio',
        ],
      );
      await relay.initialize();
      await relay.send('tools/list', id: 1);
      expect(
        ((await relay.response(1))['result'] as Map)['tools'],
        contains(containsPair('name', 'remote_mcp_context')),
      );
      await relay.send(
        'tools/call',
        id: 2,
        params: {'name': 'remote_mcp_context'},
      );
      final context = jsonDecode(_text(await relay.response(2))) as Map;
      expect(context['cwd'], 'ssh://dev/project');
      expect(context['session'], startsWith('mcp-http-'));
      await relay.process.stdin.close();
      expect(
        await relay.process.exitCode.timeout(const Duration(seconds: 5)),
        0,
      );
      expect(await relay.errors, isEmpty);
      expect(
        Directory(p.join(home.path, '.baocode-server')).existsSync(),
        isFalse,
      );
      expect(
        relay.messages.every((message) => message['jsonrpc'] == '2.0'),
        isTrue,
      );
    },
  );

  test(
    'concurrent calls allow cancellation without cancelling another id',
    () async {
      final started = <String>{};
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'remote_mcp_wait',
          description: 'Wait for this request to be cancelled',
          inputSchema: const {'type': 'object'},
          run: (input, call) async {
            final name = input['name'] as String;
            started.add(name);
            await call.cancelled;
            return name;
          },
        ),
      );
      final relay = await _Relay.start(_environment(connection));
      await relay.initialize();
      await relay.send(
        'tools/call',
        id: 10,
        params: {
          'name': 'remote_mcp_wait',
          'arguments': {'name': 'one'},
        },
      );
      await relay.send(
        'tools/call',
        id: 11,
        params: {
          'name': 'remote_mcp_wait',
          'arguments': {'name': 'two'},
        },
      );
      await until(() => started.length == 2);
      await relay.send('ping', id: 12);
      expect((await relay.response(12))['result'], isEmpty);
      await relay.send('notifications/cancelled', params: {'requestId': 10});
      expect(_text(await relay.response(10)), 'one');
      expect(relay.messages.where((message) => message['id'] == 11), isEmpty);
      await relay.send('notifications/cancelled', params: {'requestId': 11});
      expect(_text(await relay.response(11)), 'two');
      await relay.process.stdin.close();
      expect(
        await relay.process.exitCode.timeout(const Duration(seconds: 5)),
        0,
      );
      expect(await relay.errors, isEmpty);
    },
  );

  test('SSE tools/list_changed reaches stdio after initialization', () async {
    final relay = await _Relay.start(_environment(connection));
    await relay.initialize();
    await relay.send('ping', id: 1);
    await relay.response(1);
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'remote_mcp_changed',
        description: 'Appears after initialize',
        inputSchema: const {'type': 'object'},
        run: (_, _) async => 'changed',
      ),
    );
    await until(
      () => relay.messages.any(
        (message) => message['method'] == 'notifications/tools/list_changed',
      ),
    );
    await relay.send('tools/list', id: 2);
    expect(
      ((await relay.response(2))['result'] as Map)['tools'],
      contains(containsPair('name', 'remote_mcp_changed')),
    );
    await relay.process.stdin.close();
    expect(await relay.process.exitCode.timeout(const Duration(seconds: 5)), 0);
    expect(await relay.errors, isEmpty);
  });

  test('EOF drains quick replies and cancels a tool still waiting after its deadline', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'remote_mcp_wait',
        description: 'Wait for EOF cancellation',
        inputSchema: const {'type': 'object'},
        run: (_, call) async {
          started.complete();
          await call.cancelled;
          cancelled.complete();
          return 'cancelled';
        },
      ),
    );
    final relay = await _Relay.start(_environment(connection));
    await relay.initialize();
    await relay.send('ping', id: 1);
    await relay.send('tools/call', id: 2, params: {'name': 'remote_mcp_wait'});
    await started.future.timeout(const Duration(seconds: 5));
    await relay.process.stdin.close();
    expect(
      await relay.process.exitCode.timeout(const Duration(seconds: 5)),
      isNot(0),
    );
    expect((await relay.response(1))['result'], isEmpty);
    await cancelled.future.timeout(const Duration(seconds: 2));
    expect(await relay.errors, 'BaoCode MCP: the tools connection ended.\n');
  });

  test('revocation ends an idle relay whose stdin is still open', () async {
    final relay = await _Relay.start(_environment(connection));
    await relay.initialize();
    connection.close();
    expect(
      await relay.process.exitCode.timeout(const Duration(seconds: 5)),
      isNot(0),
    );
    expect(await relay.errors, 'BaoCode MCP: the tools connection ended.\n');
  });

  test(
    'app disconnect ends the relay and its outstanding HTTP requests',
    () async {
      final started = Completer<void>();
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'remote_mcp_wait',
          description: 'Wait for app disconnect',
          inputSchema: const {'type': 'object'},
          run: (_, call) async {
            started.complete();
            await call.cancelled;
            return 'cancelled';
          },
        ),
      );
      final relay = await _Relay.start(_environment(connection));
      await relay.initialize();
      await relay.send(
        'tools/call',
        id: 1,
        params: {'name': 'remote_mcp_wait'},
      );
      await started.future.timeout(const Duration(seconds: 5));
      await server.stop();
      expect(
        await relay.process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0),
      );
      expect(await relay.errors, 'BaoCode MCP: the tools connection ended.\n');
    },
  );

  test(
    'malformed input gets JSON-RPC errors without contaminating stdout',
    () async {
      final relay = await _Relay.start(_environment(connection));
      await relay.initialize();
      relay.process.stdin.writeln('{invalid json');
      await relay.process.stdin.flush();
      expect(
        (await relay.response(null))['error'],
        containsPair('code', -32700),
      );
      await relay.send('ping', id: 99);
      expect((await relay.response(99))['result'], isEmpty);
      await relay.process.stdin.close();
      expect(
        await relay.process.exitCode.timeout(const Duration(seconds: 5)),
        0,
      );
      expect(await relay.errors, isEmpty);
    },
  );

  test('unconsumed stdout cannot keep a child alive after stdin EOF', () async {
    final started = Completer<void>();
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'remote_mcp_large',
        description: 'Larger than the OS pipe buffer',
        inputSchema: const {'type': 'object'},
        run: (_, _) async {
          started.complete();
          return List.filled(2 * 1024 * 1024, 'x').join();
        },
      ),
    );
    final relay = await _Relay.start(
      _environment(connection),
      readOutput: false,
    );
    await relay.send('tools/call', id: 1, params: {'name': 'remote_mcp_large'});
    await started.future.timeout(const Duration(seconds: 5));
    await relay.process.stdin.close();
    expect(
      await relay.process.exitCode.timeout(const Duration(seconds: 5)),
      isNot(0),
    );
    await relay.process.stdout.drain<void>();
    expect(await relay.errors, 'BaoCode MCP: the tools connection ended.\n');
  });

  test('invalid endpoints and tokens fail without connection or sensitive diagnostics', () async {
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => probe.close(force: true));
    final seen = <HttpRequest>[];
    probe.listen((request) {
      seen.add(request);
      request.response.close();
    });
    final endpoint = 'http://127.0.0.1:${probe.port}/mcp';
    final secret = 'private-test-token';
    final environments = <Map<String, String>>[
      for (final url in [
        endpoint.replaceFirst('http:', 'https:'),
        endpoint.replaceFirst('127.0.0.1', 'localhost'),
        endpoint.replaceFirst('127.0.0.1', '127.0.0.2'),
        '$endpoint?secret=never-show-this',
        '$endpoint#never-show-this',
        '$endpoint/other',
        endpoint.replaceFirst('127.0.0.1', 'secret@127.0.0.1'),
      ])
        {ServerMcp.urlVariable: url, ServerMcp.tokenVariable: secret},
      {ServerMcp.urlVariable: endpoint, ServerMcp.tokenVariable: ''},
      {
        ServerMcp.urlVariable: endpoint,
        ServerMcp.tokenVariable: '$secret\r\nX-Secret: leak',
      },
    ];
    for (final env in environments) {
      final relay = await _Relay.start(env);
      expect(
        await relay.process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0),
      );
      expect(await relay.errors, 'BaoCode MCP: the tools connection ended.\n');
      expect(relay.messages, isEmpty);
    }
    expect(seen, isEmpty);
  });

  test(
    'a wrong bearer token ends the relay without echoing credentials',
    () async {
      final relay = await _Relay.start({
        ..._environment(connection),
        ServerMcp.tokenVariable: 'private-wrong-token',
      });
      expect(
        await relay.process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0),
      );
      expect(await relay.errors, 'BaoCode MCP: the tools connection ended.\n');
      expect(relay.messages, isEmpty);
    },
  );

  for (final redirectedMethod in ['GET', 'POST']) {
    test(
      '$redirectedMethod redirects never forward bearer credentials',
      () async {
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final destination = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => source.close(force: true));
        addTearDown(() => destination.close(force: true));
        final leaked = <HttpRequest>[];
        destination.listen((request) {
          leaked.add(request);
          request.response.close();
        });
        source.listen((request) async {
          final response = request.response;
          if (request.method == redirectedMethod) {
            response.statusCode = HttpStatus.temporaryRedirect;
            response.headers.set(
              'location',
              'http://127.0.0.1:${destination.port}/mcp',
            );
            await response.close();
          } else {
            response.headers.contentType = ContentType('text', 'event-stream');
            response.bufferOutput = false;
            response.write(': connected\n\n');
            await response.flush();
          }
        });
        final relay = await _Relay.start({
          ServerMcp.urlVariable: 'http://127.0.0.1:${source.port}/mcp',
          ServerMcp.tokenVariable: 'private-redirect-token',
        });
        if (redirectedMethod == 'POST') await relay.send('ping', id: 1);
        expect(
          await relay.process.exitCode.timeout(const Duration(seconds: 5)),
          isNot(0),
        );
        expect(
          await relay.errors,
          'BaoCode MCP: the tools connection ended.\n',
        );
        expect(leaked, isEmpty);
        expect(relay.messages, isEmpty);
      },
    );
  }
}

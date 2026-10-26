@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/mcp/tools_http.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  late ToolsHttpServer server;
  late HttpClient http;

  setUp(() async {
    server = ToolsHttpServer();
    http = _RealHttp().createHttpClient(null);
    await Future.wait(List.generate(8, (_) => server.start()));
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'http_context',
        description: 'Connection context',
        inputSchema: const {'type': 'object'},
        run: (_, call) async =>
            jsonEncode({'cwd': call.cwd, 'session': call.sessionId}),
      ),
    );
  });
  tearDown(() async {
    ClaudeSdkTools.unregister('http_context');
    ClaudeSdkTools.unregister('http_wait');
    ClaudeSdkTools.unregister('http_changed');
    http.close(force: true);
    await server.stop();
  });

  Future<HttpClientResponse> post(
    ToolsHttpConnection connection,
    Object message, {
    Map<String, String> headers = const {},
  }) async {
    final request = await http.postUrl(
      Uri.parse(connection.configuration['url'] as String),
    );
    final auth = connection.configuration['headers'] as Map;
    request.headers.set('Authorization', auth['Authorization'] as String);
    request.headers.set('Accept', 'application/json, text/event-stream');
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    request.write(message is String ? message : jsonEncode(message));
    return request.close();
  }

  Future<Map<String, Object?>> rpc(
    ToolsHttpConnection connection,
    String method, {
    Map<String, Object?> params = const {},
    int? id = 1,
  }) async {
    final response = await post(connection, {
      'jsonrpc': '2.0',
      'id': ?id,
      'method': method,
      'params': params,
    });
    expect(response.statusCode, id == null ? 202 : 200);
    final text = await utf8.decoder.bind(response).join();
    return text.isEmpty
        ? {}
        : (jsonDecode(text) as Map).cast<String, Object?>();
  }

  test('conversations share one URL but isolate cwd and request IDs', () async {
    final first = server.open(cwd: '/project one');
    final second = server.open(cwd: '/项目二');
    final url = server.url;
    await server.start();
    expect(server.url, url);
    expect(first.configuration['url'], second.configuration['url']);
    expect(
      first.configuration['headers'],
      isNot(second.configuration['headers']),
    );
    expect(first.configuration.containsKey('command'), isFalse);
    for (final connection in [first, second]) {
      final init = await rpc(
        connection,
        'initialize',
        params: {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'clientInfo': {'name': 'test', 'version': '1'},
        },
      );
      expect((init['result'] as Map)['protocolVersion'], '2025-06-18');
      await rpc(connection, 'notifications/initialized', id: null);
      final listed = await rpc(connection, 'tools/list');
      expect((listed['result'] as Map)['tools'], isNotEmpty);
    }
    final replies = await Future.wait([
      rpc(first, 'tools/call', params: {'name': 'http_context'}),
      rpc(second, 'tools/call', params: {'name': 'http_context'}),
    ]);
    final contexts = replies
        .map(
          (reply) => jsonDecode(
            ((reply['result'] as Map)['content'] as List).single['text']
                as String,
          ) as Map,
        )
        .toList();
    expect(contexts[0]['cwd'], '/project one');
    expect(contexts[1]['cwd'], '/项目二');
    expect(contexts[0]['session'], isNot(contexts[1]['session']));
    final auth =
        (first.configuration['headers'] as Map)['Authorization'] as String;
    expect(jsonEncode(contexts), isNot(contains(auth.substring(7))));
  });

  test('cancel and close affect only their own conversation', () async {
    final started = <String>[];
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'http_wait',
        description: 'Wait for cancellation',
        inputSchema: const {'type': 'object'},
        run: (_, call) async {
          started.add(call.cwd);
          await call.cancelled;
          return call.cwd;
        },
      ),
    );
    final first = server.open(cwd: '/one');
    final second = server.open(cwd: '/two');
    var secondDone = false;
    final waiting = [
      rpc(first, 'tools/call', params: {'name': 'http_wait'}),
      rpc(second, 'tools/call', params: {'name': 'http_wait'}).then((reply) {
        secondDone = true;
        return reply;
      }),
    ];
    for (var i = 0; started.length < 2 && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started, unorderedEquals(['/one', '/two']));
    await rpc(
      first,
      'notifications/cancelled',
      id: null,
      params: {'requestId': 1},
    );
    await waiting.first.timeout(const Duration(seconds: 2));
    expect(secondDone, isFalse);
    first.close();
    first.close();
    expect(secondDone, isFalse);
    second.close();
    await waiting.last.timeout(const Duration(seconds: 2));
    final denied = await post(first, {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'ping',
    });
    expect(denied.statusCode, 401);
    await denied.drain<void>();
  });

  test(
    'loopback service rejects browser origins, foreign hosts and tokens',
    () async {
      final connection = server.open(cwd: '/project');
      for (final headers in [
        {'Origin': 'https://attacker.example'},
        {'Origin': 'null'},
        {'Host': 'attacker.example'},
        {'Authorization': 'Bearer wrong'},
      ]) {
        final response = await post(connection, {}, headers: headers);
        expect(
          response.statusCode,
          headers.containsKey('Authorization') ? 401 : 403,
        );
        await response.drain<void>();
      }
      final request = await http.postUrl(server.url!);
      final response = await request.close();
      expect(response.statusCode, 401);
      await response.drain<void>();
    },
  );

  test('HTTP validation and protocol version negotiation', () async {
    final connection = server.open(cwd: '/project');
    final init = await rpc(
      connection,
      'initialize',
      params: {'protocolVersion': 'future'},
    );
    expect((init['result'] as Map)['protocolVersion'], '2025-11-25');
    for (final entry in [
      ('not json', -32700),
      ('[]', -32600),
      ('{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}', -32600),
    ]) {
      final response = await post(connection, entry.$1);
      final json = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect((json['error'] as Map)['code'], entry.$2);
    }
    for (final entry in [
      ({'MCP-Protocol-Version': 'invalid'}, 400),
      ({'Accept': 'application/json'}, 406),
      ({'Content-Type': 'text/plain'}, 415),
    ]) {
      final response = await post(connection, {}, headers: entry.$1);
      expect(response.statusCode, entry.$2);
      await response.drain<void>();
    }
    final tooLarge = await post(connection, 'x' * (1024 * 1024 + 1));
    expect(tooLarge.statusCode, 413);
    await tooLarge.drain<void>();
  });

  test(
    'SSE announces tool changes and reconnect retains connection context',
    () async {
      final connection = server.open(cwd: '/project');
      await rpc(connection, 'initialize');
      await rpc(connection, 'notifications/initialized', id: null);
      final request = await http.getUrl(server.url!);
      request.headers.set(
        'Authorization',
        (connection.configuration['headers'] as Map)['Authorization'] as String,
      );
      request.headers.set('Accept', 'text/event-stream');
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      final lines = StreamIterator(
        response.transform(utf8.decoder).transform(const LineSplitter()),
      );
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, ': connected');
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'http_changed',
          description: 'Added after initialization',
          inputSchema: const {'type': 'object'},
          run: (_, _) async => 'ok',
        ),
      );
      String event = '';
      while (await lines.moveNext().timeout(const Duration(seconds: 2))) {
        if (lines.current.startsWith('data:')) {
          event = lines.current.substring(5).trim();
          break;
        }
      }
      expect(
        (jsonDecode(event) as Map)['method'],
        'notifications/tools/list_changed',
      );
      await lines.cancel();
      expect((await rpc(connection, 'ping'))['result'], isEmpty);
      connection.close();
    },
  );

  test(
    'SSE serializes bursts and closes during an outstanding flush',
    () async {
      final connection = server.open(cwd: '/project');
      await rpc(connection, 'initialize');
      await rpc(connection, 'notifications/initialized', id: null);
      final request = await http.getUrl(server.url!);
      request.headers.set(
        'Authorization',
        (connection.configuration['headers'] as Map)['Authorization'] as String,
      );
      request.headers.set('Accept', 'text/event-stream');
      final response = await request.close();
      final lines = StreamIterator(
        response.transform(utf8.decoder).transform(const LineSplitter()),
      );
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, ': connected');
      for (var i = 0; i < 40; i++) {
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: 'http_changed',
            description: 'Change $i',
            inputSchema: const {'type': 'object'},
            run: (_, _) async => 'ok',
          ),
        );
        await Future<void>.value();
      }
      connection.close();
      // Buffered events drain and the stream terminates, without close/flush
      // racing or leaving the heartbeat alive. The capability is revoked too.
      var events = 0;
      while (await lines.moveNext().timeout(const Duration(seconds: 3))) {
        if (lines.current.startsWith('data:')) events++;
      }
      expect(events, greaterThan(0));
      await lines.cancel();
      final denied = await post(connection, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
      });
      expect(denied.statusCode, 401);
      await denied.drain<void>();
    },
  );

  test('server stop revokes old capabilities after restart', () async {
    final old = server.open(cwd: '/old');
    await server.stop();
    await server.start();
    final current = server.open(cwd: '/new');
    final request = await http.postUrl(server.url!);
    request.headers.set(
      'Authorization',
      (old.configuration['headers'] as Map)['Authorization'] as String,
    );
    final response = await request.close();
    expect(response.statusCode, 401);
    await response.drain<void>();
    expect((await rpc(current, 'ping'))['result'], isEmpty);
  });
}

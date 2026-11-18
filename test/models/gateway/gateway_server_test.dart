import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/models/gateway/gateway_server.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/proxy/watched_socket.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Answer = ({int status, String text});

class _Upstream {
  _Upstream(this.sockets) : server = HttpServer.listenOn(sockets);
  final WatchedServerSocket sockets;
  final HttpServer server;
  final seen =
      <({Uri url, Map<String, dynamic> body, Map<String, String> headers})>[];
  Future<void> Function(HttpRequest, Map<String, dynamic>)? reply;
  String get base => 'http://127.0.0.1:${server.port}/v1';

  static Future<_Upstream> start() async {
    final upstream = _Upstream(
      await WatchedServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    upstream.server.listen((request) async {
      try {
        final body = jsonDecode(
          await utf8.decodeStream(request),
        ) as Map<String, dynamic>;
        final headers = <String, String>{};
        request.headers.forEach(
          (key, values) => headers[key] = values.join(','),
        );
        upstream.seen.add((url: request.uri, body: body, headers: headers));
        if (upstream.reply case final reply?) {
          await reply(request, body);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_message));
          await request.response.close();
        }
      } on Object {
        /* A cancelled request may already have lost its socket. */
      }
    });
    return upstream;
  }

  Future<void> close() async {
    await server.close(force: true);
    await sockets.close();
  }
}

const _message = {
  'id': 'msg_test',
  'type': 'message',
  'role': 'assistant',
  'model': 'one',
  'content': [
    {'type': 'text', 'text': 'hello'},
  ],
  'stop_reason': 'end_turn',
  'stop_sequence': null,
  'usage': {'input_tokens': 3, 'output_tokens': 2},
};
const _chat = {
  'id': 'chat_test',
  'object': 'chat.completion',
  'model': 'one',
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': 'hello'},
      'finish_reason': 'stop',
    },
  ],
  'usage': {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': 5},
};
const _response = {
  'id': 'resp_test',
  'object': 'response',
  'status': 'completed',
  'model': 'one',
  'output': [
    {
      'id': 'item_test',
      'type': 'message',
      'status': 'completed',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': 'hello', 'annotations': []},
      ],
    },
  ],
  'usage': {'input_tokens': 3, 'output_tokens': 2, 'total_tokens': 5},
};

Map<String, dynamic> _body(
  String protocol, {
  String model = '@a/one',
  bool stream = false,
}) => switch (protocol) {
  'chat' => {
    'model': model,
    'messages': [
      {'role': 'user', 'content': 'hi'},
    ],
    'max_tokens': 128,
    'stream': stream,
  },
  'responses' => {
    'model': model,
    'input': 'hi',
    'max_output_tokens': 128,
    'stream': stream,
  },
  _ => {
    'model': model,
    'messages': [
      {'role': 'user', 'content': 'hi'},
    ],
    'max_tokens': 128,
    'stream': stream,
  },
};

String _path(String protocol) => switch (protocol) {
  'chat' => '/v1/chat/completions',
  'responses' => '/v1/responses',
  _ => '/v1/messages',
};

Future<_Answer> _ask(
  GatewayServer gateway,
  String path, {
  Map<String, dynamic>? body,
  Map<String, String> headers = const {},
  bool auth = true,
}) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      Uri.parse('${gateway.baseUrl}$path'),
    );
    if (auth) request.headers.set('authorization', 'Bearer baocode');
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final answer = await request.close();
    return (status: answer.statusCode, text: await utf8.decodeStream(answer));
  } finally {
    client.close(force: true);
  }
}

void main() {
  late _Upstream upstream;
  late ModelProviders providers;
  late GatewayServer gateway;
  late ModelProvider provider;

  setUp(() async {
    HttpOverrides.global = null;
    upstream = await _Upstream.start();
    provider = ModelProvider(
      id: 'a',
      name: 'First',
      baseUrl: upstream.base,
      models: const [ProviderModel(id: 'one')],
    );
    providers = ModelProviders.memory(providers: [provider]);
    await providers.setKey('a', 'upstream-secret');
    gateway = GatewayServer(providers: providers);
    await gateway.start(port: 0);
  });
  tearDown(() async {
    await gateway.close();
    await upstream.close();
    providers.dispose();
  });

  test(
    'aggregates enabled models, retains qualified IDs, and follows changes',
    () async {
      await providers.save(
        ModelProvider(
          id: 'b',
          name: 'Second',
          models: const [
            ProviderModel(id: 'one'),
            ProviderModel(id: 'hidden', enabled: false),
          ],
        ),
      );
      await providers.save(
        ModelProvider(
          id: 'off',
          name: 'Off',
          enabled: false,
          models: const [ProviderModel(id: 'off')],
        ),
      );
      final listed = jsonDecode((await _ask(gateway, '/v1/models')).text);
      expect(
        [for (final model in listed['data']) model['id']],
        ['@a/one', '@b/one'],
      );
      final ambiguous = await _ask(
        gateway,
        '/v1/messages',
        body: _body('anthropic', model: 'one'),
      );
      expect(ambiguous.status, 400);
      expect(ambiguous.text, contains('@upstream/model'));
      await providers.save(provider.copyWith(enabled: false));
      expect(
        (await _ask(gateway, '/v1/messages', body: _body('anthropic'))).status,
        404,
      );
      expect(upstream.seen, isEmpty);
      expect(
        (jsonDecode((await _ask(gateway, '/v1/models')).text)['data'] as List)
            .length,
        1,
      );
    },
  );

  test(
    'requires the gateway key and rejects Origin and rebinding Host',
    () async {
      expect((await _ask(gateway, '/v1/models', auth: false)).status, 401);
      expect(
        (await _ask(
          gateway,
          '/v1/models',
          headers: {'authorization': 'Bearer wrong'},
        )).status,
        401,
      );
      expect(
        (await _ask(
          gateway,
          '/v1/models',
          auth: false,
          headers: {'x-api-key': 'baocode'},
        )).status,
        200,
      );
      expect(
        (await _ask(
          gateway,
          '/v1/models',
          headers: {'origin': 'https://example.invalid'},
        )).status,
        403,
      );
      expect(
        (await _ask(
          gateway,
          '/v1/models',
          headers: {'host': 'evil.invalid:${gateway.port}'},
        )).status,
        403,
      );
      expect(
        (await _ask(
          gateway,
          '/v1/models',
          headers: {'host': 'localhost:${gateway.port}'},
        )).status,
        200,
      );
    },
  );

  for (final entry in [
    ('anthropic', ProviderProtocol.anthropic),
    ('chat', ProviderProtocol.openaiChat),
    ('responses', ProviderProtocol.openaiResponses),
  ]) {
    test(
      'native ${entry.$1} preserves payload, endpoint and upstream credentials',
      () async {
        await providers.save(
          provider.copyWith(
            protocol: entry.$2,
            headers: {'x-session': '{{CLAUDE_SESSION_ID}}'},
          ),
        );
        final body = {
          ..._body(entry.$1, model: 'one'),
          'native_option': {'keep': true},
        };
        upstream.reply = (request, body) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'native': true, 'model': body['model']}),
          );
          await request.response.close();
        };
        final answer = await _ask(
          gateway,
          '${_path(entry.$1)}?beta=true',
          body: body,
          headers: {'x-claude-code-session-id': 'session-1'},
        );
        expect(answer.status, 200);
        expect(jsonDecode(answer.text)['native'], true);
        final sent = upstream.seen.single;
        expect(sent.url.path, _path(entry.$1));
        expect(sent.url.query, 'beta=true');
        expect(sent.body, {...body, 'model': 'one'});
        expect(sent.headers['authorization'], 'Bearer upstream-secret');
        expect(sent.headers.values, isNot(contains('Bearer baocode')));
        expect(sent.headers['x-session'], 'session-1');
      },
    );
  }

  for (final target in [
    ('anthropic', ProviderProtocol.anthropic),
    ('chat', ProviderProtocol.openaiChat),
    ('responses', ProviderProtocol.openaiResponses),
  ]) {
    for (final source in [
      'anthropic',
      'chat',
      'responses',
    ].where((value) => value != target.$1)) {
      test('$source -> ${target.$1} request and nonstream answer', () async {
        await providers.save(provider.copyWith(protocol: target.$2));
        upstream.reply = (request, body) async {
          if (target.$1 == 'responses') {
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.write(
              'data: ${jsonEncode({'type': 'response.completed', 'response': _response})}$chr10$chr10',
            );
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(target.$1 == 'chat' ? _chat : _message),
            );
          }
          await request.response.close();
        };
        final answer = await _ask(gateway, _path(source), body: _body(source));
        expect(answer.status, 200, reason: answer.text);
        final decoded = jsonDecode(answer.text);
        if (source == 'anthropic') {
          expect(decoded['content'][0]['text'], 'hello');
        } else if (source == 'chat') {
          expect(decoded['choices'][0]['message']['content'], 'hello');
        } else {
          expect(decoded['output'][0]['content'][0]['text'], 'hello');
        }
        expect(upstream.seen.single.body['model'], 'one');
        expect(upstream.seen.single.url.path, _path(target.$1));
        expect(
          upstream.seen.single.headers['authorization'],
          'Bearer upstream-secret',
        );
      });
    }
  }

  test('cross-protocol stream returns incremental deltas and terminal event', () async {
    upstream.reply = (request, body) async {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      for (final event in [
        {
          'type': 'message_start',
          'message': {..._message, 'content': <Object>[], 'stop_reason': null},
        },
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'hello'},
        },
        {'type': 'content_block_stop', 'index': 0},
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 2},
        },
        {'type': 'message_stop'},
      ]) {
        request.response.write(
          'event: ${event['type']}${chr10}data: ${jsonEncode(event)}$chr10$chr10',
        );
        await request.response.flush();
      }
      await request.response.close();
    };
    for (final source in ['chat', 'responses']) {
      final answer = await _ask(
        gateway,
        _path(source),
        body: _body(source, stream: true),
      );
      expect(answer.status, 200, reason: answer.text);
      expect(answer.text, contains('hello'));
      expect(answer.text, contains('@a/one'));
      expect(
        answer.text,
        contains(source == 'chat' ? '[DONE]' : 'response.completed'),
      );
    }
  });

  for (final source in ['chat', 'responses']) {
    test(
      '$source reasoning effort keeps the real Anthropic model ID',
      () async {
        final body = {
          ..._body(source),
          if (source == 'chat')
            'reasoning_effort': 'high'
          else
            'reasoning': {'effort': 'high'},
          if (source == 'chat')
            'max_completion_tokens': 87
          else
            'max_output_tokens': 87,
          'temperature': 0.25,
          'top_p': 0.8,
        };
        final answer = await _ask(gateway, _path(source), body: body);
        expect(answer.status, 200, reason: answer.text);
        final sent = upstream.seen.single.body;
        expect(sent['model'], 'one');
        expect(sent['thinking'], {'type': 'adaptive'});
        expect(sent['output_config'], {'effort': 'high'});
        expect(sent['max_tokens'], 87);
        expect(sent['temperature'], 0.25);
        expect(sent['top_p'], 0.8);
      },
    );
  }

  test('native Anthropic thinking and output_config survive intact', () async {
    final body = {
      ..._body('anthropic'),
      'thinking': {'type': 'adaptive'},
      'output_config': {'effort': 'high'},
    };
    final answer = await _ask(gateway, '/v1/messages', body: body);
    expect(answer.status, 200);
    expect(upstream.seen.single.body, {...body, 'model': 'one'});
  });

  for (final source in ['chat', 'anthropic']) {
    test('$source token limit and sampling reach the Responses upstream', () async {
      await providers.save(
        provider.copyWith(protocol: ProviderProtocol.openaiResponses),
      );
      upstream.reply = (request, body) async {
        request.response.write(
          'data: ${jsonEncode({'type': 'response.completed', 'response': _response})}$chr10$chr10',
        );
        await request.response.close();
      };
      final body = {
        ..._body(source),
        'temperature': 0.25,
        'top_p': 0.8,
        if (source == 'chat') 'max_completion_tokens': 87 else 'max_tokens': 87,
      };
      final answer = await _ask(gateway, _path(source), body: body);
      expect(answer.status, 200, reason: answer.text);
      final sent = upstream.seen.single.body;
      expect(sent['max_output_tokens'], 87);
      expect(sent['temperature'], 0.25);
      expect(sent['top_p'], 0.8);
    });
  }

  test('Chat URL images reach the Responses upstream', () async {
    await providers.save(
      provider.copyWith(protocol: ProviderProtocol.openaiResponses),
    );
    upstream.reply = (request, body) async {
      request.response.write(
        'data: ${jsonEncode({'type': 'response.completed', 'response': _response})}$chr10$chr10',
      );
      await request.response.close();
    };
    final body = {
      ..._body('chat'),
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Describe this'},
            {
              'type': 'image_url',
              'image_url': {'url': 'https://images.example/picture.png'},
            },
          ],
        },
      ],
    };
    final answer = await _ask(gateway, '/v1/chat/completions', body: body);
    expect(answer.status, 200, reason: answer.text);
    final input = upstream.seen.single.body['input'] as List;
    final content = input.single['content'] as List;
    expect(content.where((part) => part['type'] == 'input_image').single, {
      'type': 'input_image',
      'image_url': 'https://images.example/picture.png',
      'detail': 'auto',
    });
  });

  test('native SSE bytes pass through unchanged', () async {
    const frame = 'event: custom\ndata: {"native":true}\n\n';
    upstream.reply = (request, body) async {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(frame);
      await request.response.close();
    };
    final answer = await _ask(
      gateway,
      '/v1/messages',
      body: _body('anthropic', stream: true),
    );
    expect(answer.status, 200);
    expect(answer.text, frame);
  });

  for (final source in ['anthropic', 'chat']) {
    test('disconnect cancels an active $source streaming response', () async {
      final firstBytes = Completer<void>();
      final disconnected = Completer<void>();
      upstream.reply = (request, body) async {
        unawaited(
          upstream.sockets.endOf(request)!.then((_) {
            if (!disconnected.isCompleted) disconnected.complete();
          }),
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.bufferOutput = false;
        request.response.write(
          'data: ${jsonEncode({
            'type': 'message_start',
            'message': {..._message, 'content': <Object>[]},
          })}$chr10$chr10',
        );
        await request.response.flush();
        await disconnected.future;
      };
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        gateway.port!,
      );
      final reading = socket.listen((_) {
        if (!firstBytes.isCompleted) firstBytes.complete();
      });
      final payload = jsonEncode(_body(source, stream: true));
      socket.write(
        'POST ${_path(source)} HTTP/1.1${crlf}Host: 127.0.0.1:${gateway.port}${crlf}Authorization: Bearer baocode${crlf}Content-Length: ${utf8.encode(payload).length}$crlf$crlf$payload',
      );
      await socket.flush();
      await firstBytes.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('stream headers never arrived'),
      );
      socket.destroy();
      await reading.cancel();
      await disconnected.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('upstream connection stayed open'),
      );
    });
  }

  test('model-specific protocol and endpoint overrides are honored', () async {
    await providers.save(
      provider.copyWith(
        models: [
          ProviderModel(
            id: 'one',
            protocol: ProviderProtocol.openaiChat,
            endpointUrl: '${upstream.base}/custom',
          ),
        ],
      ),
    );
    upstream.reply = (request, body) async {
      request.response.write(jsonEncode(_chat));
      await request.response.close();
    };
    final answer = await _ask(
      gateway,
      '/v1/chat/completions',
      body: _body('chat'),
    );
    expect(answer.status, 200);
    expect(upstream.seen.single.url.path, '/v1/custom');
  });

  test('cross-protocol reasoning effort reaches the real upstream', () async {
    await providers.save(
      provider.copyWith(protocol: ProviderProtocol.openaiChat),
    );
    upstream.reply = (request, body) async {
      request.response.write(jsonEncode(_chat));
      await request.response.close();
    };
    final answer = await _ask(
      gateway,
      '/v1/responses',
      body: {
        ..._body('responses'),
        'reasoning': {'effort': 'high'},
      },
    );
    expect(answer.status, 200, reason: answer.text);
    expect(upstream.seen.single.body['reasoning_effort'], 'high');
  });

  test(
    'upstream errors retain status and JSON and redirects are not followed',
    () async {
      for (final protocol in [
        ProviderProtocol.anthropic,
        ProviderProtocol.openaiChat,
      ]) {
        await providers.save(provider.copyWith(protocol: protocol));
        upstream.reply = (request, body) async {
          request.response.statusCode = 429;
          request.response.write(
            jsonEncode({
              'error': {'message': 'quota exhausted'},
            }),
          );
          await request.response.close();
        };
        final failed = await _ask(
          gateway,
          '/v1/messages',
          body: _body('anthropic'),
        );
        expect(failed.status, 429);
        expect(failed.text, contains('quota exhausted'));
        upstream.reply = (request, body) async {
          request.response.statusCode = 303;
          request.response.headers.set(
            'location',
            '${upstream.base}/credential-sink',
          );
          await request.response.close();
        };
        final count = upstream.seen.length;
        final redirected = await _ask(
          gateway,
          '/v1/messages',
          body: _body('anthropic'),
        );
        expect(redirected.status, greaterThanOrEqualTo(400));
        expect(upstream.seen.length, count + 1);
      }
    },
  );

  test(
    'network proxy handles native and translated upstreams, not local bridge',
    () async {
      await gateway.close();
      final routed = <Uri>[];
      gateway = GatewayServer(
        providers: providers,
        findProxy: (url) {
          routed.add(url);
          return 'PROXY 127.0.0.1:${upstream.server.port}';
        },
      );
      await gateway.start(port: 0);
      await providers.save(
        provider.copyWith(
          baseUrl: 'http://upstream.invalid/v1',
          protocol: ProviderProtocol.openaiChat,
        ),
      );
      upstream.reply = (request, body) async {
        request.response.write(jsonEncode(_chat));
        await request.response.close();
      };
      for (final source in ['chat', 'anthropic']) {
        final answer = await _ask(gateway, _path(source), body: _body(source));
        expect(answer.status, 200, reason: answer.text);
      }
      expect(routed, isNotEmpty);
      expect(routed.every((url) => url.host == 'upstream.invalid'), true);
    },
  );

  test('disconnecting the API client promptly cancels a pending upstream', () async {
    final entered = Completer<void>();
    final disconnected = Completer<void>();
    upstream.reply = (request, body) async {
      unawaited(
        upstream.sockets.endOf(request)!.then((_) => disconnected.complete()),
      );
      entered.complete();
      await disconnected.future;
    };
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      gateway.port!,
    );
    final payload = jsonEncode(_body('anthropic'));
    socket.write(
      'POST /v1/messages HTTP/1.1${crlf}Host: 127.0.0.1:${gateway.port}${crlf}Authorization: Bearer baocode${crlf}Content-Type: application/json${crlf}Content-Length: ${utf8.encode(payload).length}$crlf$crlf$payload',
    );
    await socket.flush();
    await entered.future.timeout(const Duration(seconds: 3));
    socket.destroy();
    await disconnected.future.timeout(const Duration(seconds: 3));
  });

  test(
    'close cancels in-flight calls and releases port; failed bind is retryable',
    () async {
      final entered = Completer<void>();
      final disconnected = Completer<void>();
      upstream.reply = (request, body) async {
        unawaited(
          upstream.sockets.endOf(request)!.then((_) => disconnected.complete()),
        );
        entered.complete();
        await disconnected.future;
      };
      final pending = _ask(
        gateway,
        '/v1/messages',
        body: _body('anthropic'),
      ).then<Object>((answer) => answer, onError: (Object error) => error);
      await entered.future.timeout(const Duration(seconds: 3));
      final oldPort = gateway.port!;
      await gateway.close();
      await disconnected.future.timeout(const Duration(seconds: 3));
      await pending.timeout(const Duration(seconds: 3));
      final busy = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        oldPort,
      );
      await expectLater(
        gateway.start(port: oldPort),
        throwsA(isA<SocketException>()),
      );
      await busy.close();
      await gateway.start(port: oldPort);
      expect((await _ask(gateway, '/v1/models')).status, 200);
    },
  );

  test(
    'unsupported cross-protocol options fail before contacting upstream',
    () async {
      final answer = await _ask(
        gateway,
        '/v1/responses',
        body: {..._body('responses'), 'previous_response_id': 'resp_old'},
      );
      expect(answer.status, 400);
      expect(upstream.seen, isEmpty);
    },
  );
}

const chr10 = '\n';
const crlf = '\r\n';

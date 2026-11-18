import 'dart:convert';

import 'package:baocode/models/gateway/gateway_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Json = Map<String, dynamic>;

Json chat(Json body) =>
    gatewayToAnthropic({'model': 'model', ...body}, GatewayProtocol.openaiChat);
Json responses(Json body) => gatewayToAnthropic({
  'model': 'model',
  ...body,
}, GatewayProtocol.openaiResponses);

List<Json> data(List<String> frames) => [
  for (final frame in frames)
    for (final line in const LineSplitter().convert(frame))
      if (line.startsWith('data:') && line.substring(5).trim() != '[DONE]')
        jsonDecode(line.substring(5)) as Json,
];

List<String> emit(GatewayStreamTranslator translator, Json event) => translator
    .convert('event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n');

Json start() => {
  'type': 'message_start',
  'message': {
    'id': 'msg_1',
    'type': 'message',
    'role': 'assistant',
    'model': 'upstream',
    'content': <dynamic>[],
    'usage': {
      'input_tokens': 12,
      'output_tokens': 0,
      'cache_read_input_tokens': 3,
    },
  },
};
Json block(int index, Json content) => {
  'type': 'content_block_start',
  'index': index,
  'content_block': content,
};
Json delta(int index, Json content) => {
  'type': 'content_block_delta',
  'index': index,
  'delta': content,
};
Json end(String reason) => {
  'type': 'message_delta',
  'delta': {'stop_reason': reason},
  'usage': {'output_tokens': 7},
};

void main() {
  group('gateway requests', () {
    test(
      'Chat system, images, reasoning, tools and results retain their roles',
      () {
        final original = <String, dynamic>{
          'stream': true,
          'max_completion_tokens': 100,
          'reasoning_effort': 'high',
          'messages': [
            {'role': 'system', 'content': 'System'},
            {
              'role': 'developer',
              'content': [
                {'type': 'text', 'text': 'Developer'},
              ],
            },
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Read image'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,YQ=='},
                },
              ],
            },
            {
              'role': 'assistant',
              'content': null,
              'reasoning_content': 'Think',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {'name': 'lookup', 'arguments': '{"x":1}'},
                },
                {
                  'id': 'call_2',
                  'type': 'function',
                  'function': {'name': 'lookup', 'arguments': '{}'},
                },
              ],
            },
            {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'one'},
            {'role': 'tool', 'tool_call_id': 'call_2', 'content': 'two'},
            {'role': 'user', 'content': 'Proceed'},
          ],
          'tools': [
            {
              'type': 'function',
              'function': {
                'name': 'lookup',
                'description': 'Find',
                'parameters': {'type': 'object'},
              },
            },
          ],
          'tool_choice': {
            'type': 'function',
            'function': {'name': 'lookup'},
          },
          'parallel_tool_calls': false,
        };
        final before = jsonEncode(original);
        final converted = chat(original);
        expect(jsonEncode(original), before);
        expect(converted['stream'], true);
        expect(converted['max_tokens'], 100);
        expect(converted['system'], [
          {'type': 'text', 'text': 'System'},
          {'type': 'text', 'text': 'Developer'},
        ]);
        final messages = converted['messages'] as List;
        expect(messages, hasLength(3));
        expect(messages[0]['content'][1]['source'], {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'YQ==',
        });
        expect(messages[1]['content'][0], {
          'type': 'thinking',
          'thinking': 'Think',
        });
        expect(messages[1]['content'][1], {
          'type': 'tool_use',
          'id': 'call_1',
          'name': 'lookup',
          'input': {'x': 1},
        });
        expect(messages[2]['content'][0]['tool_use_id'], 'call_1');
        expect(messages[2]['content'][1]['tool_use_id'], 'call_2');
        expect(messages[2]['content'][2]['text'], 'Proceed');
        expect(converted['tools'][0]['input_schema'], {'type': 'object'});
        expect(converted['tool_choice'], {
          'type': 'tool',
          'name': 'lookup',
          'disable_parallel_tool_use': true,
        });
        expect(converted['output_config'], {'effort': 'high'});
      },
    );

    test(
      'Responses instructions, tool outputs and remote images translate',
      () {
        final converted = responses({
          'instructions': 'Be concise',
          'stream': false,
          'max_output_tokens': 50,
          'reasoning': {'effort': 'medium'},
          'input': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'input_image',
                  'image_url': 'https://image.test/a.png',
                },
              ],
            },
            {
              'type': 'reasoning',
              'summary': [
                {'type': 'summary_text', 'text': 'Consider'},
              ],
            },
            {
              'type': 'function_call',
              'call_id': 'call_a',
              'name': 'lookup',
              'arguments': '{}',
            },
            {
              'type': 'function_call_output',
              'call_id': 'call_a',
              'output': [
                {'type': 'input_text', 'text': 'Found'},
              ],
            },
          ],
          'tools': [
            {
              'type': 'function',
              'name': 'lookup',
              'parameters': {'type': 'object'},
            },
          ],
          'tool_choice': 'required',
        });
        expect(converted['system'][0]['text'], 'Be concise');
        expect(converted['max_tokens'], 50);
        expect(converted['stream'], false);
        expect(converted['messages'][0]['content'][0]['source'], {
          'type': 'url',
          'url': 'https://image.test/a.png',
        });
        expect(converted['messages'][1]['content'][0]['thinking'], 'Consider');
        expect(converted['messages'][1]['content'][1]['id'], 'call_a');
        expect(
          converted['messages'][2]['content'][0]['content'][0]['text'],
          'Found',
        );
        expect(converted['tool_choice'], {'type': 'any'});
      },
    );

    test('Responses accepts plain input, preserves omitted stream and defaults max tokens', () {
      final converted = responses({'input': 'Hi'});
      expect(converted['messages'][0]['content'][0]['text'], 'Hi');
      expect(converted.containsKey('stream'), false);
      expect(converted['max_tokens'], 4096);
    });

    test(
      'unsupported sampling and strict schemas are not silently dropped',
      () {
        for (final option in [
          {'n': 2},
          {'logprobs': true},
          {'frequency_penalty': 0.5},
          {
            'tools': [
              {
                'type': 'function',
                'function': {'name': 'lookup', 'strict': true},
              },
            ],
          },
        ]) {
          expect(
            () => chat({
              'messages': [
                {'role': 'user', 'content': 'Hi'},
              ],
              ...option,
            }),
            throwsFormatException,
          );
        }
      },
    );

    test('Anthropic requests and replies keep native extensions', () {
      final native = {'model': 'm', 'native_extension': true};
      expect(gatewayToAnthropic(native, GatewayProtocol.anthropic), native);
      expect(gatewayFromAnthropic(native, GatewayProtocol.anthropic), native);
    });

    test('unsupported state and built-in tools fail rather than disappear', () {
      for (final extra in [
        {'previous_response_id': 'resp_a'},
        {'conversation': 'conversation_a'},
        {'background': true},
        {
          'tools': [
            {'type': 'web_search_preview'},
          ],
        },
        {
          'input': [
            {
              'type': 'reasoning',
              'encrypted_content': 'opaque',
              'summary': <dynamic>[],
            },
          ],
        },
        {
          'text': {
            'format': {'type': 'json_schema'},
          },
        },
      ]) {
        expect(
          () => responses({'input': 'Hi', ...extra}),
          throwsFormatException,
        );
      }
    });

    test(
      'malformed arguments, roles, content and image data fail explicitly',
      () {
        for (final message in [
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'c',
                'type': 'function',
                'function': {'name': 'x', 'arguments': 'not json'},
              },
            ],
          },
          {'role': 'function', 'content': 'result'},
          {
            'role': 'user',
            'content': [
              {'type': 'input_audio', 'input_audio': 'audio'},
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png,plain'},
              },
            ],
          },
        ]) {
          expect(
            () => chat({
              'messages': [message],
            }),
            throwsFormatException,
          );
        }
      },
    );
  });

  group('gateway complete replies', () {
    final message = <String, dynamic>{
      'id': 'msg_1',
      'model': 'provider/model',
      'stop_reason': 'tool_use',
      'content': [
        {'type': 'thinking', 'thinking': 'Let me think'},
        {'type': 'text', 'text': 'Calling'},
        {
          'type': 'tool_use',
          'id': 'call_1',
          'name': 'lookup',
          'input': {'x': 1},
        },
      ],
      'usage': {
        'input_tokens': 10,
        'cache_read_input_tokens': 5,
        'cache_creation_input_tokens': 2,
        'output_tokens': 4,
        'reasoning_tokens': 3,
      },
    };
    test('Chat retains tool identity, reasoning and cache usage', () {
      final result = gatewayFromAnthropic(message, GatewayProtocol.openaiChat);
      expect(result['model'], 'provider/model');
      final choice = result['choices'][0];
      expect(choice['finish_reason'], 'tool_calls');
      expect(choice['message']['reasoning_content'], 'Let me think');
      expect(
        choice['message']['tool_calls'][0]['function']['arguments'],
        '{"x":1}',
      );
      expect(result['usage']['prompt_tokens'], 17);
      expect(result['usage']['total_tokens'], 21);
      expect(result['usage']['prompt_tokens_details']['cached_tokens'], 5);
    });

    test(
      'Responses exposes reasoning, text and function call output items',
      () {
        final result = gatewayFromAnthropic(
          message,
          GatewayProtocol.openaiResponses,
        );
        expect(result['status'], 'completed');
        expect(result['output'][0]['type'], 'reasoning');
        expect(result['output'][1]['content'][0]['text'], 'Calling');
        expect(result['output'][2]['call_id'], 'call_1');
        expect(result['output'][2]['arguments'], '{"x":1}');
        expect(result['usage']['input_tokens'], 17);
      },
    );

    test('length limits remain incomplete and refusals keep finish reason', () {
      final limited = {...message, 'stop_reason': 'max_tokens'};
      expect(
        gatewayFromAnthropic(
          limited,
          GatewayProtocol.openaiChat,
        )['choices'][0]['finish_reason'],
        'length',
      );
      final incomplete = gatewayFromAnthropic(
        limited,
        GatewayProtocol.openaiResponses,
      );
      expect(incomplete['status'], 'incomplete');
      expect(incomplete['incomplete_details']['reason'], 'max_output_tokens');
      expect(
        gatewayFromAnthropic({
          ...message,
          'stop_reason': 'refusal',
        }, GatewayProtocol.openaiChat)['choices'][0]['finish_reason'],
        'content_filter',
      );
    });

    test('errors keep message and type in both public protocols', () {
      for (final protocol in [
        GatewayProtocol.openaiChat,
        GatewayProtocol.openaiResponses,
      ]) {
        final error = gatewayFromAnthropic({
          'type': 'error',
          'error': {'type': 'rate_limit_error', 'message': 'Retry later'},
        }, protocol);
        expect(error['error']['message'], 'Retry later');
        expect(error['error']['code'], 'rate_limit_error');
      }
    });
  });

  for (final protocol in [
    GatewayProtocol.openaiChat,
    GatewayProtocol.openaiResponses,
  ]) {
    group('$protocol stream', () {
      test('text, reasoning, tool argument fragments, stop and usage complete once', () {
        final translator = GatewayStreamTranslator(
          protocol,
          model: 'provider/public',
        );
        final frames = <String>[];
        for (final event in [
          start(),
          block(0, {'type': 'thinking', 'thinking': ''}),
          delta(0, {'type': 'thinking_delta', 'thinking': 'Think'}),
          delta(0, {'type': 'signature_delta', 'signature': 'hidden'}),
          {'type': 'content_block_stop', 'index': 0},
          block(1, {'type': 'text', 'text': 'Hi'}),
          delta(1, {'type': 'text_delta', 'text': ' there'}),
          {'type': 'content_block_stop', 'index': 1},
          block(2, {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'lookup',
            'input': <String, dynamic>{},
          }),
          delta(2, {'type': 'input_json_delta', 'partial_json': '{"x":'}),
          delta(2, {'type': 'input_json_delta', 'partial_json': '1}'}),
          {'type': 'content_block_stop', 'index': 2},
          end('tool_use'),
          {'type': 'message_stop'},
        ]) {
          frames.addAll(emit(translator, event));
        }
        expect(translator.finish(), isEmpty);
        expect(emit(translator, {'type': 'message_stop'}), isEmpty);
        final events = data(frames);
        expect(frames.join(), isNot(contains('hidden')));
        if (protocol == GatewayProtocol.openaiChat) {
          expect(
            frames.where((frame) => frame == 'data: [DONE]\n\n'),
            hasLength(1),
          );
          final chunks = events
              .where((event) => (event['choices'] as List).isNotEmpty)
              .toList();
          expect(
            chunks.every((event) => event['model'] == 'provider/public'),
            true,
          );
          expect(chunks.last['choices'][0]['finish_reason'], 'tool_calls');
          expect(
            chunks
                .where(
                  (event) =>
                      event['choices'][0]['delta']['reasoning_content'] != null,
                )
                .single['choices'][0]['delta']['reasoning_content'],
            'Think',
          );
          final tools = chunks
              .where(
                (event) => event['choices'][0]['delta']['tool_calls'] != null,
              )
              .map((event) => event['choices'][0]['delta']['tool_calls'][0])
              .toList();
          expect(tools.first['id'], 'call_1');
          expect(
            tools.map((tool) => tool['function']['arguments']).join(),
            '{"x":1}',
          );
          expect(tools.every((tool) => tool['index'] == 0), true);
          expect(events.last['usage']['prompt_tokens'], 15);
          expect(events.last['usage']['completion_tokens'], 7);
        } else {
          expect(
            events.map((event) => event['sequence_number']),
            List.generate(events.length, (index) => index),
          );
          expect(
            events.where((event) => event['type'] == 'response.completed'),
            hasLength(1),
          );
          final result = events.last['response'];
          expect(result['model'], 'provider/public');
          expect(result['output'][0]['summary'][0]['text'], 'Think');
          expect(result['output'][1]['content'][0]['text'], 'Hi there');
          expect(result['output'][2]['arguments'], '{"x":1}');
          expect(result['usage']['input_tokens'], 15);
          expect(result['usage']['output_tokens'], 7);
          final toolDeltas = events
              .where(
                (event) =>
                    event['type'] == 'response.function_call_arguments.delta',
              )
              .toList();
          expect(toolDeltas.map((event) => event['delta']).join(), '{"x":1}');
          expect(
            events.where(
              (event) => event['type'] == 'response.output_item.done',
            ),
            hasLength(3),
          );
        }
      });

      test(
        'empty and populated tool inputs at block start emit valid JSON once',
        () {
          final translator = GatewayStreamTranslator(protocol);
          final frames = <String>[];
          for (final event in [
            start(),
            block(0, {
              'type': 'tool_use',
              'id': 'a',
              'name': 'first',
              'input': <String, dynamic>{},
            }),
            {'type': 'content_block_stop', 'index': 0},
            block(1, {
              'type': 'tool_use',
              'id': 'b',
              'name': 'second',
              'input': {'x': 1},
            }),
            end('tool_use'),
            {'type': 'message_stop'},
          ]) {
            frames.addAll(emit(translator, event));
          }
          final events = data(frames);
          if (protocol == GatewayProtocol.openaiChat) {
            final tools = events
                .expand((event) => event['choices'] as List)
                .map((choice) => choice['delta']['tool_calls'])
                .whereType<List>()
                .expand((calls) => calls)
                .toList();
            expect(
              tools
                  .where((tool) => tool['index'] == 0)
                  .map((tool) => tool['function']['arguments'])
                  .join(),
              '{}',
            );
            expect(
              tools
                  .where((tool) => tool['index'] == 1)
                  .map((tool) => tool['function']['arguments'])
                  .join(),
              '{"x":1}',
            );
          } else {
            expect(events.last['response']['output'][0]['arguments'], '{}');
            expect(
              events.last['response']['output'][1]['arguments'],
              '{"x":1}',
            );
          }
        },
      );

      test(
        'EOF without stop stays incomplete and does not hide partial arguments',
        () {
          final translator = GatewayStreamTranslator(protocol);
          final frames = <String>[...emit(translator, start())];
          frames.addAll(
            emit(
              translator,
              block(0, {
                'type': 'tool_use',
                'id': 'a',
                'name': 'lookup',
                'input': <String, dynamic>{},
              }),
            ),
          );
          frames.addAll(
            emit(
              translator,
              delta(0, {'type': 'input_json_delta', 'partial_json': '{"x":'}),
            ),
          );
          frames.addAll(translator.finish());
          final events = data(frames);
          if (protocol == GatewayProtocol.openaiChat) {
            expect(
              events[events.length - 2]['choices'][0]['finish_reason'],
              'length',
            );
          } else {
            expect(events.last['type'], 'response.incomplete');
            expect(events.last['response']['output'][0]['arguments'], '{"x":');
          }
        },
      );

      test('upstream error ends with failure, never successful completion', () {
        final translator = GatewayStreamTranslator(protocol);
        final frames = emit(translator, {
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'Busy'},
        });
        expect(frames.join(), contains('Busy'));
        expect(frames.join(), isNot(contains('response.completed')));
        expect(translator.finish(), isEmpty);
        if (protocol == GatewayProtocol.openaiResponses) {
          expect(data(frames).first['type'], 'error');
          expect(data(frames).first['message'], 'Busy');
          expect(data(frames).first['code'], 'overloaded_error');
          expect(data(frames).last['type'], 'response.failed');
          expect(data(frames).last['response']['status'], 'failed');
        }
      });
    });
  }
}

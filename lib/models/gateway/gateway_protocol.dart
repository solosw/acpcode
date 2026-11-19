import 'dart:convert';

import '../proxy/translate/common.dart' show anthropicCacheCreationTokens;
import '../proxy/translate/json_value.dart';

/// The public wire format accepted by the local model gateway.
enum GatewayProtocol { anthropic, openaiChat, openaiResponses }

typedef _Json = Map<String, dynamic>;

/// Converts a stateless generation request to Anthropic's Messages format.
/// Unsupported stateful or built-in tool features fail explicitly.
Map<String, dynamic> gatewayToAnthropic(
  Map<String, dynamic> body,
  GatewayProtocol protocol,
) {
  if (protocol == GatewayProtocol.anthropic) return {...body};
  _reject(body, ['audio', 'modalities', 'prediction']);
  if ((body['n'] != null && body['n'] != 1) ||
      body['logprobs'] == true ||
      (body['frequency_penalty'] != null && body['frequency_penalty'] != 0) ||
      (body['presence_penalty'] != null && body['presence_penalty'] != 0) ||
      (body['logit_bias'] is Map && (body['logit_bias'] as Map).isNotEmpty)) {
    throw const FormatException('Sampling options cannot cross protocols');
  }
  if (protocol == GatewayProtocol.openaiResponses) {
    _reject(body, ['previous_response_id', 'conversation']);
    if (body['background'] == true) {
      throw const FormatException(
        'Background responses cannot cross protocols',
      );
    }
    if (body['text'] case final Map text when text['format'] != null) {
      final format = text['format'];
      if (format is! Map || format['type'] != 'text') {
        throw const FormatException('Structured output cannot cross protocols');
      }
    }
  } else if (body['response_format'] case final Map format) {
    if (format['type'] != 'text') {
      throw const FormatException('Structured output cannot cross protocols');
    }
  }
  final messages = <_Json>[];
  final system = <_Json>[];
  void addMessage(String role, List<_Json> content) {
    if (role == 'system' || role == 'developer') {
      if (content.any((part) => part['type'] != 'text')) {
        throw const FormatException('System content must be text');
      }
      system.addAll(content);
    } else if (role == 'user' || role == 'assistant') {
      messages.add({'role': role, 'content': content});
    } else {
      throw FormatException('Unsupported message role: $role');
    }
  }

  if (protocol == GatewayProtocol.openaiChat) {
    final input = body['messages'];
    if (input is! List) throw const FormatException('messages must be a list');
    for (final raw in input) {
      final message = _object(raw, 'message');
      final role = message['role'];
      if (role == 'tool') {
        messages.add({
          'role': 'user',
          'content': <_Json>[
            {
              'type': 'tool_result',
              'tool_use_id': _string(message['tool_call_id'], 'tool_call_id'),
              'content': _content(message['content']),
            },
          ],
        });
        continue;
      }
      final content = _content(message['content']);
      if (message['reasoning_content'] case final String reasoning
          when reasoning.isNotEmpty && role == 'assistant') {
        content.insert(0, {'type': 'thinking', 'thinking': reasoning});
      }
      if (message['tool_calls'] case final List calls) {
        if (role != 'assistant') {
          throw const FormatException('Only assistants can call tools');
        }
        for (final rawCall in calls) {
          final call = _object(rawCall, 'tool call');
          if (call['type'] != 'function') {
            throw const FormatException(
              'Only function tools can cross protocols',
            );
          }
          final function = _object(call['function'], 'function');
          content.add({
            'type': 'tool_use',
            'id': _string(call['id'], 'tool call id'),
            'name': _string(function['name'], 'function name'),
            'input': _arguments(function['arguments']),
          });
        }
      }
      addMessage(_string(role, 'role'), content);
    }
  } else {
    if (body['instructions'] case final String instructions
        when instructions.isNotEmpty) {
      system.add({'type': 'text', 'text': instructions});
    }
    final input = body['input'];
    if (input is String) {
      addMessage('user', [
        {'type': 'text', 'text': input},
      ]);
    } else if (input is List) {
      for (final raw in input) {
        final item = _object(raw, 'input item');
        switch (item['type']) {
          case null || 'message':
            addMessage(
              _string(item['role'], 'role'),
              _content(item['content']),
            );
          case 'function_call':
            addMessage('assistant', [
              {
                'type': 'tool_use',
                'id': _string(item['call_id'], 'call_id'),
                'name': _string(item['name'], 'function name'),
                'input': _arguments(item['arguments']),
              },
            ]);
          case 'function_call_output':
            addMessage('user', [
              {
                'type': 'tool_result',
                'tool_use_id': _string(item['call_id'], 'call_id'),
                'content': _content(item['output']),
              },
            ]);
          case 'reasoning':
            _reject(item, ['encrypted_content']);
            final summary = item['summary'];
            if (summary is List) {
              addMessage('assistant', [
                {
                  'type': 'thinking',
                  'thinking': summary
                      .map((part) => _object(part, 'summary')['text'] ?? '')
                      .join('\n'),
                },
              ]);
            }
          default:
            throw FormatException(
              'Unsupported Responses input: ${item['type']}',
            );
        }
      }
    } else {
      throw const FormatException('input must be text or a list');
    }
  }

  // Adjacent tool results and content belong to the same Anthropic turn.
  final merged = <_Json>[];
  for (final message in messages) {
    if (merged.isNotEmpty && merged.last['role'] == message['role']) {
      (merged.last['content'] as List).addAll(message['content'] as List);
    } else {
      merged.add(message);
    }
  }
  final result = <String, dynamic>{
    'model': body['model'],
    'messages': merged,
    if (system.isNotEmpty) 'system': system,
    'max_tokens':
        body['max_completion_tokens'] ??
        body['max_output_tokens'] ??
        body['max_tokens'] ??
        4096,
    if (body.containsKey('stream')) 'stream': body['stream'],
    for (final key in ['temperature', 'top_p', 'metadata', 'service_tier'])
      if (body.containsKey(key)) key: body[key],
  };
  if (body['stop'] case final Object stop) {
    result['stop_sequences'] = stop is List ? stop : [stop];
  }
  final effort = protocol == GatewayProtocol.openaiChat
      ? body['reasoning_effort']
      : (body['reasoning'] is Map
            ? (body['reasoning'] as Map)['effort']
            : null);
  if (effort is String) {
    result['thinking'] = {'type': effort == 'none' ? 'disabled' : 'adaptive'};
    result['output_config'] = {'effort': effort};
  }
  if (body['tools'] case final List tools) {
    result['tools'] = [
      for (final raw in tools) _tool(_object(raw, 'tool'), protocol),
    ];
  }
  if (body['tool_choice'] case final Object choice) {
    result['tool_choice'] = _toolChoice(choice, protocol);
  }
  if (body['parallel_tool_calls'] == false) {
    final choice = (result['tool_choice'] ??= {'type': 'auto'}) as Map;
    choice['disable_parallel_tool_use'] = true;
  }
  return result;
}

void _reject(_Json body, List<String> keys) {
  for (final key in keys) {
    if (body[key] != null) throw FormatException('$key cannot cross protocols');
  }
}

_Json _object(Object? value, String label) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$label must be an object');
  }
  return value;
}

String _string(Object? value, String label) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$label must be a nonempty string');
  }
  return value;
}

_Json _arguments(Object? value) {
  final parsed = value is String ? jsonDecode(value) : value;
  return {..._object(parsed, 'function arguments')};
}

List<_Json> _content(Object? value) {
  if (value == null) return [];
  if (value is String) {
    return [
      {'type': 'text', 'text': value},
    ];
  }
  if (value is! List) {
    throw const FormatException('content must be text or a list');
  }
  return [for (final raw in value) _contentPart(_object(raw, 'content part'))];
}

_Json _contentPart(_Json part) {
  switch (part['type']) {
    case 'text' || 'input_text' || 'output_text':
      return {'type': 'text', 'text': part['text'] ?? ''};
    case 'image_url' || 'input_image':
      final image = part['image_url'];
      final url = image is Map ? image['url'] : image;
      final value = _string(url, 'image URL');
      if (value.startsWith('data:')) {
        final comma = value.indexOf(',');
        if (comma < 0 || !value.substring(0, comma).endsWith(';base64')) {
          throw const FormatException('Image data must be base64');
        }
        return {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': value.substring(5, comma - 7),
            'data': value.substring(comma + 1),
          },
        };
      }
      return {
        'type': 'image',
        'source': {'type': 'url', 'url': value},
      };
    case 'refusal':
      return {'type': 'text', 'text': part['refusal'] ?? ''};
    default:
      throw FormatException('Unsupported content type: ${part['type']}');
  }
}

_Json _tool(_Json tool, GatewayProtocol protocol) {
  if (tool['type'] != 'function') {
    throw const FormatException('Only function tools can cross protocols');
  }
  final function = protocol == GatewayProtocol.openaiChat
      ? _object(tool['function'], 'function tool')
      : tool;
  if (function['strict'] == true) {
    throw const FormatException(
      'Strict function schemas cannot cross protocols',
    );
  }
  return {
    'name': _string(function['name'], 'tool name'),
    if (function['description'] != null) 'description': function['description'],
    'input_schema':
        function['parameters'] ??
        {'type': 'object', 'properties': <String, dynamic>{}},
  };
}

_Json _toolChoice(Object choice, GatewayProtocol protocol) {
  if (choice is String) {
    return {
      'type': switch (choice) {
        'auto' => 'auto',
        'none' => 'none',
        'required' => 'any',
        _ => throw FormatException('Unsupported tool choice: $choice'),
      },
    };
  }
  final object = _object(choice, 'tool choice');
  if (object['type'] != 'function') {
    throw const FormatException(
      'Only function tool choices can cross protocols',
    );
  }
  return {
    'type': 'tool',
    'name': _string(
      protocol == GatewayProtocol.openaiChat
          ? _object(object['function'], 'function choice')['name']
          : object['name'],
      'tool name',
    ),
  };
}

/// Converts a complete Anthropic message (or error) to the requested format.
Map<String, dynamic> gatewayFromAnthropic(
  Map<String, dynamic> message,
  GatewayProtocol protocol,
) {
  if (protocol == GatewayProtocol.anthropic) return {...message};
  if (message['error'] != null || message['type'] == 'error') {
    final error = message['error'];
    return {
      'error': error is Map
          ? {...error, 'param': null, 'code': error['type']}
          : {
              'message': '$error',
              'type': 'api_error',
              'param': null,
              'code': null,
            },
    };
  }
  final content = (message['content'] as List? ?? []).cast<Map>();
  final usage = _usage(
    _object(message['usage'] ?? <String, dynamic>{}, 'usage'),
    protocol,
  );
  if (protocol == GatewayProtocol.openaiChat) {
    final calls = [
      for (final block in content)
        if (block['type'] == 'tool_use') _chatTool(block),
    ];
    final reasoning = content
        .where((block) => block['type'] == 'thinking')
        .map((block) => block['thinking'] ?? '')
        .join();
    return {
      'id': message['id'],
      'object': 'chat.completion',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': message['model'],
      'choices': [
        {
          'index': 0,
          'message': {
            'role': 'assistant',
            'content': content
                .where((block) => block['type'] == 'text')
                .map((block) => block['text'] ?? '')
                .join(),
            if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
            if (calls.isNotEmpty) 'tool_calls': calls,
          },
          'finish_reason': _finishReason(
            message['stop_reason'],
            calls.isNotEmpty,
          ),
          'logprobs': null,
        },
      ],
      'usage': usage,
    };
  }
  final incomplete =
      message['stop_reason'] == 'max_tokens' ||
      message['stop_reason'] == 'pause_turn';
  return {
    'id': message['id'],
    'object': 'response',
    'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'model': message['model'],
    'status': incomplete ? 'incomplete' : 'completed',
    'error': null,
    'incomplete_details': incomplete
        ? {
            'reason': message['stop_reason'] == 'max_tokens'
                ? 'max_output_tokens'
                : 'pause_turn',
          }
        : null,
    'output': [
      for (final (index, block) in content.indexed)
        _responseItem(block, '${message['id']}_$index'),
    ],
    'usage': usage,
    'parallel_tool_calls': true,
  };
}

_Json _chatTool(Map block) => {
  'id': block['id'],
  'type': 'function',
  'function': {
    'name': block['name'],
    'arguments': jsonEncode(block['input'] ?? <String, dynamic>{}),
  },
};

String _finishReason(Object? reason, bool tools) => switch (reason) {
  'max_tokens' => 'length',
  'refusal' => 'content_filter',
  'tool_use' => 'tool_calls',
  _ => tools ? 'tool_calls' : 'stop',
};

_Json _usage(_Json usage, GatewayProtocol protocol) {
  final cached = usage['cache_read_input_tokens'] as num? ?? 0;
  final written = anthropicCacheCreationTokens(JsonValue(usage));
  final input = (usage['input_tokens'] as num? ?? 0) + cached + written;
  final output = usage['output_tokens'] as num? ?? 0;
  final reasoning =
      usage['reasoning_tokens'] ?? usage['reasoning_output_tokens'];
  return {
    (protocol == GatewayProtocol.openaiChat ? 'prompt_tokens' : 'input_tokens'):
        input,
    (protocol == GatewayProtocol.openaiChat
            ? 'completion_tokens'
            : 'output_tokens'):
        output,
    'total_tokens': input + output,
    (protocol == GatewayProtocol.openaiChat
        ? 'prompt_tokens_details'
        : 'input_tokens_details'): {
      'cached_tokens': cached,
      if (written > 0) 'cache_write_tokens': written,
    },
    if (reasoning != null)
      (protocol == GatewayProtocol.openaiChat
          ? 'completion_tokens_details'
          : 'output_tokens_details'): {
        'reasoning_tokens': reasoning,
      },
  };
}

_Json _responseItem(Map block, String id, {String status = 'completed'}) =>
    switch (block['type']) {
      'tool_use' => {
        'id': id,
        'type': 'function_call',
        'status': status,
        'call_id': block['id'],
        'name': block['name'],
        'arguments': jsonEncode(block['input'] ?? <String, dynamic>{}),
      },
      'thinking' => {
        'id': id,
        'type': 'reasoning',
        'status': status,
        'summary': [
          {'type': 'summary_text', 'text': block['thinking'] ?? ''},
        ],
      },
      'text' => {
        'id': id,
        'type': 'message',
        'status': status,
        'role': 'assistant',
        'content': [
          {
            'type': 'output_text',
            'text': block['text'] ?? '',
            'annotations': <dynamic>[],
            'logprobs': <dynamic>[],
          },
        ],
      },
      _ => throw FormatException(
        'Unsupported Anthropic output: ${block['type']}',
      ),
    };

/// Translates Anthropic SSE data lines (or complete frames) incrementally.
/// [model] is the caller's gateway model ID, kept in every public reply.
class GatewayStreamTranslator {
  GatewayStreamTranslator(this.protocol, {this.model});

  final GatewayProtocol protocol;
  final String? model;
  final int _createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final _Json _message = {
    'id': 'gateway_${DateTime.now().microsecondsSinceEpoch}',
    'type': 'message',
    'role': 'assistant',
    'model': '',
    'usage': <String, dynamic>{},
  };
  final Map<int, _GatewayBlock> _blocks = {};
  bool _started = false;
  bool _ended = false;
  int _sequence = 0;
  int _toolCount = 0;

  List<String> convert(String line) {
    if (_ended) return [];
    if (protocol == GatewayProtocol.anthropic) return [line];
    final out = <String>[];
    for (final part in const LineSplitter().convert(line)) {
      if (!part.startsWith('data:')) continue;
      final data = part.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') {
        out.addAll(finish());
        break;
      }
      final event = _object(jsonDecode(data), 'stream event');
      out.addAll(_event(event));
      if (_ended) break;
    }
    return out;
  }

  List<String> _event(_Json event) {
    final out = <String>[];
    if (event['type'] == 'ping') return out;
    if (event['type'] == 'error') {
      final error = gatewayFromAnthropic(event, protocol)['error'];
      if (protocol == GatewayProtocol.openaiChat) {
        out.add(_data({'error': error}));
        out.add('data: [DONE]\n\n');
      } else {
        out.add(
          _named('error', {
            'message': error['message'],
            'code': error['code'],
            'param': error['param'],
          }),
        );
        final failed = _response()..['status'] = 'failed';
        failed['error'] = error;
        out.add(_named('response.failed', {'response': failed}));
      }
      _ended = true;
      return out;
    }
    if (event['type'] == 'message_start') {
      _message.addAll(_object(event['message'], 'message'));
      if (model != null) _message['model'] = model;
    }
    _start(out);
    switch (event['type']) {
      case 'message_start':
        // Some Anthropic-compatible servers put initial content here.
        final content = _message['content'];
        if (content is List) {
          for (final (index, raw) in content.indexed) {
            _startBlock(index, _object(raw, 'content block'), out);
          }
        }
      case 'content_block_start':
        _startBlock(
          event['index'] as int,
          _object(event['content_block'], 'content block'),
          out,
        );
      case 'content_block_delta':
        final index = event['index'] as int;
        final delta = _object(event['delta'], 'content delta');
        final block = _blocks[index];
        if (block == null || block.done) {
          throw const FormatException('Content delta has no open block');
        }
        final text = switch (delta['type']) {
          'text_delta' => delta['text'],
          'thinking_delta' => delta['thinking'],
          'input_json_delta' => delta['partial_json'],
          'signature_delta' => null,
          _ => throw FormatException(
            'Unsupported content delta: ${delta['type']}',
          ),
        };
        if (text is String && text.isNotEmpty) _delta(block, text, out);
      case 'content_block_stop':
        final block = _blocks[event['index']];
        if (block != null) _stopBlock(block, out);
      case 'message_delta':
        final delta = _object(
          event['delta'] ?? <String, dynamic>{},
          'message delta',
        );
        _message.addAll(delta);
        if (event['usage'] case final Map<String, dynamic> usage) {
          (_message['usage'] as Map).addAll(usage);
        }
      case 'message_stop':
        out.addAll(finish());
      default:
        throw FormatException('Unsupported Anthropic event: ${event['type']}');
    }
    return out;
  }

  void _start(List<String> out) {
    if (_started) return;
    _started = true;
    if (model != null) _message['model'] = model;
    if (protocol == GatewayProtocol.openaiChat) {
      out.add(_chunk({'role': 'assistant', 'content': ''}));
    } else {
      out.add(
        _named('response.created', {
          'response': _response(status: 'in_progress'),
        }),
      );
      out.add(
        _named('response.in_progress', {
          'response': _response(status: 'in_progress'),
        }),
      );
    }
  }

  void _startBlock(int index, _Json content, List<String> out) {
    if (_blocks.containsKey(index)) {
      throw const FormatException('Repeated content block');
    }
    if (!['text', 'thinking', 'tool_use'].contains(content['type'])) {
      throw FormatException(
        'Unsupported Anthropic content: ${content['type']}',
      );
    }
    final block = _GatewayBlock(
      content,
      _blocks.length,
      '${_message['id']}_$index',
      content['type'] == 'tool_use' ? _toolCount++ : null,
    );
    _blocks[index] = block;
    final initial = switch (content['type']) {
      'text' => content['text'],
      'thinking' => content['thinking'],
      _ => null,
    };
    if (protocol == GatewayProtocol.openaiResponses) {
      final item = _item(block, status: 'in_progress');
      if (content['type'] == 'tool_use') item['arguments'] = '';
      out.add(
        _named('response.output_item.added', {
          'output_index': block.outputIndex,
          'item': item,
        }),
      );
      if (content['type'] == 'text') {
        out.add(
          _named('response.content_part.added', {
            ..._position(block),
            'part': {
              'type': 'output_text',
              'text': '',
              'annotations': <dynamic>[],
              'logprobs': <dynamic>[],
            },
          }),
        );
      } else if (content['type'] == 'thinking') {
        out.add(
          _named('response.reasoning_summary_part.added', {
            ..._position(block, reasoning: true),
            'part': {'type': 'summary_text', 'text': ''},
          }),
        );
      }
    } else if (content['type'] == 'tool_use') {
      out.add(
        _chunk({
          'tool_calls': [
            {
              'index': block.toolIndex,
              'id': content['id'],
              'type': 'function',
              'function': {'name': content['name'], 'arguments': ''},
            },
          ],
        }),
      );
    }
    if (initial is String && initial.isNotEmpty) _delta(block, initial, out);
  }

  void _delta(_GatewayBlock block, String text, List<String> out) {
    block.text.write(text);
    final type = block.content['type'];
    if (protocol == GatewayProtocol.openaiChat) {
      out.add(
        _chunk(switch (type) {
          'text' => {'content': text},
          'thinking' => {'reasoning_content': text},
          _ => {
            'tool_calls': [
              {
                'index': block.toolIndex,
                'function': {'arguments': text},
              },
            ],
          },
        }),
      );
    } else {
      out.add(
        _named(
          switch (type) {
            'text' => 'response.output_text.delta',
            'thinking' => 'response.reasoning_summary_text.delta',
            _ => 'response.function_call_arguments.delta',
          },
          {..._position(block, reasoning: type == 'thinking'), 'delta': text},
        ),
      );
    }
  }

  _Json _position(_GatewayBlock block, {bool reasoning = false}) => {
    'item_id': block.id,
    'output_index': block.outputIndex,
    if (block.content['type'] != 'tool_use')
      (reasoning ? 'summary_index' : 'content_index'): 0,
  };

  _Json _item(_GatewayBlock block, {String status = 'completed'}) {
    final content = {...block.content};
    switch (content['type']) {
      case 'text':
        content['text'] = block.text.toString();
      case 'thinking':
        content['thinking'] = block.text.toString();
      case 'tool_use':
        // Keep raw fragments on the wire; malformed/truncated JSON must not
        // be silently repaired into a different tool invocation.
        final item = _responseItem(content, block.id, status: status);
        item['arguments'] = block.text.isEmpty
            ? jsonEncode(content['input'] ?? <String, dynamic>{})
            : block.text.toString();
        return item;
    }
    return _responseItem(content, block.id, status: status);
  }

  void _stopBlock(_GatewayBlock block, List<String> out) {
    if (block.done) return;
    block.done = true;
    if (block.content['type'] == 'tool_use' && block.text.isEmpty) {
      // Empty input is {} too: OpenAI consumers must receive valid JSON.
      _delta(
        block,
        jsonEncode(block.content['input'] ?? <String, dynamic>{}),
        out,
      );
    }
    if (protocol == GatewayProtocol.openaiChat) return;
    final item = _item(block);
    final type = block.content['type'];
    if (type == 'tool_use') {
      out.add(
        _named('response.function_call_arguments.done', {
          ..._position(block),
          'arguments': item['arguments'],
        }),
      );
    } else if (type == 'text') {
      final part = (item['content'] as List).first;
      out.add(
        _named('response.output_text.done', {
          ..._position(block),
          'text': block.text.toString(),
          'logprobs': <dynamic>[],
        }),
      );
      out.add(
        _named('response.content_part.done', {
          ..._position(block),
          'part': part,
        }),
      );
    } else {
      final part = (item['summary'] as List).first;
      out.add(
        _named('response.reasoning_summary_text.done', {
          ..._position(block, reasoning: true),
          'text': block.text.toString(),
        }),
      );
      out.add(
        _named('response.reasoning_summary_part.done', {
          ..._position(block, reasoning: true),
          'part': part,
        }),
      );
    }
    out.add(
      _named('response.output_item.done', {
        'output_index': block.outputIndex,
        'item': item,
      }),
    );
  }

  /// Flushes the terminal events once. A truncated stream stays incomplete.
  List<String> finish() {
    if (_ended) return [];
    _ended = true;
    if (protocol == GatewayProtocol.anthropic) return [];
    final out = <String>[];
    _start(out);
    for (final block in _blocks.values) {
      _stopBlock(block, out);
    }
    final reason = _message['stop_reason'];
    if (protocol == GatewayProtocol.openaiChat) {
      out.add(
        _chunk(
          {},
          finish: reason == null
              ? 'length'
              : _finishReason(reason, _toolCount > 0),
        ),
      );
      out.add(
        _data({
          ..._chunkBody(),
          'choices': <dynamic>[],
          'usage': _usage(_message['usage'] as _Json, protocol),
        }),
      );
      out.add('data: [DONE]\n\n');
    } else {
      final incomplete =
          reason == null || reason == 'max_tokens' || reason == 'pause_turn';
      final response = _response(
        status: incomplete ? 'incomplete' : 'completed',
      );
      if (incomplete) {
        response['incomplete_details'] = {
          'reason': reason == 'max_tokens'
              ? 'max_output_tokens'
              : 'stream_ended',
        };
      }
      out.add(
        _named(incomplete ? 'response.incomplete' : 'response.completed', {
          'response': response,
        }),
      );
    }
    return out;
  }

  _Json _response({String status = 'completed'}) => {
    'id': _message['id'],
    'object': 'response',
    'created_at': _createdAt,
    'model': model ?? _message['model'],
    'status': status,
    'error': null,
    'incomplete_details': null,
    'output': [
      for (final block in _blocks.values)
        _item(block, status: status == 'in_progress' ? status : 'completed'),
    ],
    'usage': status == 'in_progress'
        ? null
        : _usage(_message['usage'] as _Json, protocol),
    'parallel_tool_calls': true,
  };

  _Json _chunkBody() => {
    'id': _message['id'],
    'object': 'chat.completion.chunk',
    'created': _createdAt,
    'model': model ?? _message['model'],
  };

  String _chunk(_Json delta, {String? finish}) => _data({
    ..._chunkBody(),
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': finish, 'logprobs': null},
    ],
  });

  String _named(String type, _Json event) =>
      'event: $type\ndata: ${jsonEncode({'type': type, 'sequence_number': _sequence++, ...event})}\n\n';

  String _data(_Json value) => 'data: ${jsonEncode(value)}\n\n';
}

class _GatewayBlock {
  _GatewayBlock(this.content, this.outputIndex, this.id, this.toolIndex);
  final _Json content;
  final int outputIndex;
  final String id;
  final int? toolIndex;
  final StringBuffer text = StringBuffer();
  bool done = false;
}

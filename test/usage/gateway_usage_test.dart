import 'dart:convert';

import 'package:baocode/usage/usage_capture.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:baocode/usage/usage_query.dart';
import 'package:baocode/usage/usage_record.dart';
import 'package:flutter_test/flutter_test.dart';

UsageMeter meter(String protocol) => UsageMeter(
  provider: 'relay',
  model: 'model',
  protocol: protocol,
  responseProtocol: protocol,
  source: 'gateway',
  clientAgent: 'Codex',
  info: const UsageRequestInfo(requestClass: UsageClass.main),
);

void main() {
  test('explicit client label wins; generic SDKs never imply an agent', () {
    String? detect(Map<String, String> headers) =>
        gatewayClientAgent((name) => headers[name]);
    expect(
      detect({'x-baocode-agent': ' My agent ', 'user-agent': 'opencode/1'}),
      'My agent',
    );
    expect(detect({'user-agent': 'codex_cli_rs/0.1'}), 'Codex');
    expect(detect({'user-agent': 'opencode/1'}), 'OpenCode');
    expect(detect({'user-agent': 'OpenCodeDesktop/2.0'}), 'OpenCode');
    expect(detect({'user-agent': 'MyAgent/2.0 (darwin)'}), 'MyAgent');
    expect(
      detect({'user-agent': 'undici', 'originator': 'codex_cli_rs'}),
      'Codex',
    );
    expect(
      detect({'user-agent': 'claude-cli/2.1 (external, cli)'}),
      'Claude Code',
    );
    expect(detect({'user-agent': 'OpenAI/Python 1.2'}), isNull);
    expect(detect({'anthropic-version': '2023-06-01'}), isNull);
    expect(detect({}), isNull);
    expect(detect({'x-baocode-agent': 'a' * 200})!.length, 120);
  });

  test('native SSE handles split UTF8 and reports truncated streams', () {
    final m = meter('openaiChat');
    m.answered();
    final line =
        'data: ${jsonEncode({
          'model': 'model',
          'choices': [
            {
              'index': 0,
              'delta': {'content': '你好'},
            },
          ],
        })}${String.fromCharCode(10)}';
    for (final byte in utf8.encode(line)) {
      m.bytes([byte]);
    }
    final call = m.finish(200)!;
    expect(call.failed, true);
    expect(call.firstToken, isNotNull);
    expect(call.input, 0);
    expect(call.output, 0);
    expect(call.responseBytes, utf8.encode(line).length);
    expect(m.finish(200), isNull);
  });

  test('cache details can arrive separately from token totals', () {
    final m = meter('openaiChat');
    final newline = String.fromCharCode(10);
    for (final usage in [
      {'prompt_tokens': 22, 'completion_tokens': 8},
      {
        'prompt_tokens_details': {'cached_tokens': 7},
      },
      {
        'prompt_tokens_details': {'cache_write_tokens': 2},
      },
    ]) {
      m.events('data: ${jsonEncode({'usage': usage})}$newline');
    }
    m.events('data: [DONE]$newline');
    final call = m.finish(200)!;
    expect(call.input, 13);
    expect(call.output, 8);
    expect(call.cacheRead, 7);
    expect(call.cacheWrite, 2);
  });

  test('native Responses errors and partial usage survive cancellation', () {
    final m = meter('openaiResponses');
    final response = {
      'type': 'response.failed',
      'response': {
        'model': 'model',
        'status': 'failed',
        'error': {'message': 'quota exceeded'},
        'usage': {
          'input_tokens': 14,
          'output_tokens': 6,
          'input_tokens_details': {'cached_tokens': 4},
          'output_tokens_details': {'reasoning_tokens': 2},
        },
      },
    };
    m.events('data: ${jsonEncode(response)}${String.fromCharCode(10)}');
    final call = m.finish(200)!;
    expect(call.failed, true);
    expect(call.error, 'quota exceeded');
    expect(call.input, 10);
    expect(call.cacheRead, 4);
    expect(call.output, 6);
    expect(call.reasoning, 2);
    final cancelled = meter('openaiResponses');
    cancelled.events('data: ${jsonEncode(response)}${String.fromCharCode(10)}');
    cancelled.cancel();
    final stopped = cancelled.finish(200)!;
    expect(stopped.cancelled, true);
    expect(stopped.failed, false);
    expect(stopped.output, 6);
  });

  test('native function tools and server searches count once per item', () {
    final m = meter('openaiResponses');
    for (final type in [
      'response.output_item.added',
      'response.output_item.done',
    ]) {
      for (final item in [
        {'type': 'function_call', 'id': 'fn', 'name': 'read_file'},
        {'type': 'web_search_call', 'id': 'search'},
      ]) {
        m.events(
          'data: ${jsonEncode({'type': type, 'item': item})}${String.fromCharCode(10)}',
        );
      }
      if (type == 'response.output_item.added') {
        expect(m.progress.serverTools, isEmpty);
      }
    }
    m.events(
      'data: ${jsonEncode({
        'type': 'response.completed',
        'response': {'status': 'completed'},
      })}${String.fromCharCode(10)}',
    );
    final call = m.finish(200)!;
    expect(call.toolCalls, {'read_file': 1});
    expect(call.serverTools, {'web_search': 1});
    expect(call.failed, false);
  });

  test(
    'gateway clients remain separate in persisted and filtered totals',
    () async {
      final storage = MemoryUsageStorage();
      final ledger = UsageLedger(storage)..detailed = false;
      addTearDown(ledger.dispose);
      for (final client in ['Codex', 'OpenCode']) {
        ledger.record(
          UsageCall(
            at: DateTime.now(),
            duration: const Duration(seconds: 1),
            status: 200,
            provider: 'relay',
            model: 'model',
            source: 'gateway',
            clientAgent: client,
            input: 10,
            output: 4,
          ),
        );
      }
      ledger.flush();
      final restored = UsageLedger(storage);
      addTearDown(restored.dispose);
      final calls = await restored.range();
      expect(calls, hasLength(2));
      final all = UsageSummary.of(calls, const UsageFilter());
      expect(
        all.byAgent.keys,
        containsAll(['gateway/Codex', 'gateway/OpenCode']),
      );
      final codex = UsageSummary.of(
        calls,
        const UsageFilter(agents: {'gateway/Codex'}),
      );
      expect(codex.calls, hasLength(1));
      expect(codex.calls.single.clientAgent, 'Codex');
      expect(UsageCall.decode(calls.first.encode())!.source, 'gateway');
      final legacy = UsageCall.fromJson({
        't': DateTime.now().millisecondsSinceEpoch,
        'p': 'relay',
        'm': 'model',
      })!;
      expect(legacy.source, isNull);
      expect(legacy.agentKey, '');
    },
  );
}

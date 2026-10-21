import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

const _gateway = ModelProvider(
  id: 'gw',
  name: 'Gateway',
  protocol: ProviderProtocol.openaiChat,
  baseUrl: 'https://gw.example.com/v1',
  models: [ProviderModel(id: 'gpt-5', contextWindow: 400000)],
);

/// A Claude Code kernel started, on Claude's own plan unless [settings]
/// pick a provider's model.
Future<({ClaudeCodeKernel kernel, FakeCli cli})> _started([
  Map<String, String> settings = const {},
]) async {
  late FakeCli cli;
  final kernel = ClaudeCodeKernel(
    MockKernels.claudeCode,
    KernelContext(cwd: '/p', settings: settings),
    start: (_) async => cli = FakeCli(),
    providers: ModelProviders.memory(providers: [_gateway]),
    providerEnvironment: (provider, model) async => {
      'ANTHROPIC_BASE_URL': 'http://proxy/${provider.id}',
    },
  );
  addTearDown(kernel.dispose);
  kernel.prepare();
  await pumpEventQueue();
  return (kernel: kernel, cli: cli);
}

/// The error Claude Code answers with at the limit, as it is kept.
Map<String, Object?> _limitError(String text) => {
  'type': 'assistant',
  'error': 'rate_limit',
  'parent_tool_use_id': null,
  'message': {
    'id': 'msg-limit',
    'role': 'assistant',
    'model': '<synthetic>',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  test(
    'usage limit: a rejected rate_limit_event says when it resets',
    () async {
      final (:kernel, :cli) = await _started();
      expect(kernel.usageLimitResetsAt, isNull);
      cli.push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'rejected',
          'resetsAt': 1790540400,
          'rateLimitType': 'five_hour',
          'utilization': 1.0,
        },
      });
      await pumpEventQueue();
      expect(
        kernel.usageLimitResetsAt,
        DateTime.fromMillisecondsSinceEpoch(1790540400 * 1000),
      );
    },
  );

  test('usage limit: allowed, nothing is hit', () async {
    final (:kernel, :cli) = await _started();
    cli.push({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'allowed_warning',
        'resetsAt': 1790540400,
        'rateLimitType': 'five_hour',
        'utilization': 0.9,
      },
    });
    await pumpEventQueue();
    expect(kernel.usageLimitResetsAt, isNull);
  });

  test('usage limit: read from the error Claude Code answers with', () async {
    final (:kernel, :cli) = await _started();
    cli.push(_limitError("You've hit your session limit · resets 11:59pm"));
    await pumpEventQueue();
    final at = kernel.usageLimitResetsAt!;
    expect((at.hour, at.minute), (23, 59));
    expect(at.isAfter(DateTime.now()), isTrue);
  });

  test('usage limit: the next turn clears it', () async {
    final (:kernel, :cli) = await _started();
    cli.push(_limitError("You've hit your session limit · resets 11:59pm"));
    await pumpEventQueue();
    expect(kernel.usageLimitResetsAt, isNotNull);
    kernel.send(const KernelTurn(id: 't2', text: 'go on'));
    await pumpEventQueue();
    expect(kernel.usageLimitResetsAt, isNull);
  });

  test('usage limit: a provider\'s limits are not the plan\'s', () async {
    final (:kernel, :cli) = await _started({'model': '@gw/gpt-5'});
    cli
      ..push(_limitError("You've hit your session limit · resets 11:59pm"))
      ..push({
        'type': 'rate_limit_event',
        'rate_limit_info': {'status': 'rejected', 'resetsAt': 1790540400},
      });
    await pumpEventQueue();
    expect(kernel.usageLimitResetsAt, isNull);
  });

  test('usage limit: switched to a provider\'s model, it no longer holds; '
      'back on the plan, it does again', () async {
    final (:kernel, :cli) = await _started();
    cli.push({
      'type': 'rate_limit_event',
      'rate_limit_info': {'status': 'rejected', 'resetsAt': 1790540400},
    });
    await pumpEventQueue();
    expect(kernel.usageLimitApplies, isTrue);
    expect(kernel.usageLimitResetsAt, isNotNull);

    var told = 0;
    final listening = kernel.events.listen((_) => told++);
    addTearDown(listening.cancel);
    kernel.model.select('@gw/gpt-5');
    expect(told, greaterThan(0));
    expect(kernel.usageLimitApplies, isFalse);
    expect(kernel.usageLimitResetsAt, isNull);

    kernel.model.select('default');
    expect(kernel.usageLimitApplies, isTrue);
    expect(
      kernel.usageLimitResetsAt,
      DateTime.fromMillisecondsSinceEpoch(1790540400 * 1000),
    );
  });
}

import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/widgets/turn_footer.dart';
import 'package:baocode/chat/widgets/rolling_text.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport extends MockAcpTransport {
  final incoming = StreamController<Map<String, Object?>>.broadcast(sync: true);
  Object? prompt;

  @override
  Stream<Map<String, Object?>> get messages => incoming.stream;

  void update(Map<String, Object?> update, {String session = 'session'}) {
    incoming.add({
      'method': 'session/update',
      'params': {'sessionId': session, 'update': update},
    });
  }

  void text(String text, {bool thought = false, String? messageId}) => update({
    'sessionUpdate': thought ? 'agent_thought_chunk' : 'agent_message_chunk',
    'messageId': ?messageId,
    'content': {'type': 'text', 'text': text},
  });

  void finish({bool cancelled = false}) => incoming.add({
    'id': prompt,
    'result': {'stopReason': cancelled ? 'cancelled' : 'end_turn'},
  });

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    if (method == null || method == 'session/cancel') return;
    if (method == 'session/prompt') {
      prompt = message['id'];
      return;
    }
    if (method == 'session/load') {
      update({
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'text', 'text': 'History question'},
      });
      text('History answer');
    }
    incoming.add({
      'id': message['id'],
      'result': switch (method) {
        'initialize' => {'protocolVersion': 1},
        'session/new' => {'sessionId': 'session'},
        _ => <String, Object?>{},
      },
    });
  }

  @override
  Future<void> close() async {
    await incoming.close();
    await super.close();
  }
}

class _Run {
  final transport = _Transport();
  final events = <KernelEvent>[];
  var now = DateTime.utc(2026);
  late final KernelDescriptor descriptor = KernelDescriptor(
    id: 'acp-output',
    label: 'ACP',
    icon: Icons.hub,
    description: '',
    create: (context) => AcpKernel(
      descriptor,
      context,
      (_) async => transport,
      clock: () => now,
    ),
  );
  late AcpKernel kernel;

  Future<void> start({bool resume = false}) async {
    kernel = descriptor.create(
      KernelContext(
        resume: resume
            ? SessionRecord(
                id: 'session',
                title: 'History',
                cwd: '',
                updatedAt: now,
              )
            : null,
      ),
    ) as AcpKernel;
    final subscription = kernel.events.listen(events.add);
    addTearDown(subscription.cancel);
    addTearDown(kernel.dispose);
    kernel.prepare();
    await pumpEventQueue();
    kernel.send(const KernelTurn(id: 'turn', text: 'Hello'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(transport.prompt, isNotNull);
  }

  Future<void> text(
    int milliseconds,
    String value, {
    bool thought = false,
    String? messageId,
  }) async {
    now = now.add(Duration(milliseconds: milliseconds));
    transport.text(value, thought: thought, messageId: messageId);
    await pumpEventQueue();
  }

  Future<void> finish({bool cancelled = false}) async {
    transport.finish(cancelled: cancelled);
    await pumpEventQueue();
  }

  TurnOutput get output => events.whereType<OutputReported>().last.output;
  TurnEnded get ended => events.whereType<TurnEnded>().last;
}

void main() {
  test(
    'ACP streams estimated output and retains average speed at turn end',
    () async {
      final run = _Run();
      await run.start();
      await run.text(0, 'abc');
      expect(run.output.tokens, 1);
      expect(run.output.tokensPerSecond, isNull);
      await run.text(1000, 'abc' * 100);
      expect(run.output.tokens, 101);
      expect(run.output.tokensPerSecond, closeTo(100, 1e-6));
      expect(run.output.estimated, isTrue);
      // Context-window usage describes occupancy, not this turn's tokens.
      run.transport.update({
        'sessionUpdate': 'usage_update',
        'used': 4000,
        'size': 200000,
      });
      await pumpEventQueue();
      await run.finish();
      expect(run.ended.usage!.outputTokens, 101);
      expect(run.ended.usage!.inputTokens, isNull);
      expect(run.ended.usage!.tokensPerSecond, closeTo(100, 1e-6));
      expect(run.ended.usage!.estimated, isTrue);
    },
  );

  test('ACP excludes tool waits and thoughts from timed generation', () async {
    final run = _Run();
    await run.start();
    await run.text(0, 'abc');
    await run.text(1000, 'abc' * 100);
    run.transport.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'tool',
      'title': 'Wait',
      'kind': 'read',
      'status': 'in_progress',
    });
    await pumpEventQueue();
    await run.text(30000, 'abc' * 100, thought: true);
    await run.text(30000, 'abc' * 100, thought: true);
    await run.text(30000, 'abc');
    await run.text(1000, 'abc' * 100);
    await run.finish();
    expect(run.ended.usage!.outputTokens, 402);
    expect(run.ended.usage!.tokensPerSecond, closeTo(100, 1e-6));
  });

  test(
    'ACP permission waits split timing even if message id is reused',
    () async {
      final run = _Run();
      await run.start();
      await run.text(0, 'abc', messageId: 'same');
      await run.text(1000, 'abc' * 100, messageId: 'same');
      run.transport.incoming.add({
        'id': 'permission',
        'method': 'session/request_permission',
        'params': {
          'sessionId': 'session',
          'toolCall': {'toolCallId': 'tool', 'title': 'Read', 'kind': 'read'},
          'options': [
            {'optionId': 'yes', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        },
      });
      await pumpEventQueue();
      await run.text(60000, 'abc', messageId: 'same');
      await run.text(1000, 'abc' * 100, messageId: 'same');
      await run.finish();
      expect(run.ended.usage!.outputTokens, 202);
      expect(run.ended.usage!.tokensPerSecond, closeTo(100, 1e-6));
    },
  );

  test(
    'child permissions do not split the parent output or its timing',
    () async {
      final run = _Run();
      await run.start();
      await run.text(0, 'abc', messageId: 'parent');
      await run.text(1000, 'abc' * 100, messageId: 'parent');
      run.transport.incoming.add({
        'id': 'child-permission',
        'method': 'session/request_permission',
        'params': {
          'sessionId': 'child',
          'toolCall': {'toolCallId': 'tool', 'title': 'Read', 'kind': 'read'},
          'options': [
            {'optionId': 'yes', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        },
      });
      await pumpEventQueue();
      await run.text(1000, 'abc' * 100, messageId: 'parent');
      await run.finish();
      expect(run.ended.usage!.outputTokens, 201);
      expect(run.ended.usage!.tokensPerSecond, closeTo(100, 1e-6));
      expect(
        run.events.whereType<ItemUpserted>().where(
          (event) => event.item is AssistantTextItem,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'ACP ignores child output and history when metering the current turn',
    () async {
      final run = _Run();
      await run.start(resume: true);
      expect(run.events.whereType<OutputReported>(), isEmpty);
      expect(
        run.events.whereType<TurnEnded>().every((event) => event.usage == null),
        isTrue,
      );
      run.transport.update({
        'sessionUpdate': 'subagent_update',
        'sessionId': 'child',
        'title': 'Child',
        'state': {'state': 'running'},
      });
      await pumpEventQueue();
      run.transport.update({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'abc' * 1000},
      }, session: 'child');
      await run.text(0, 'abc');
      await run.text(1000, 'abc' * 100);
      await run.finish();
      expect(run.ended.usage!.outputTokens, 101);
      expect(run.ended.usage!.tokensPerSecond, closeTo(100, 1e-6));
    },
  );

  test(
    'ACP cancellation preserves partial stats and resets the next turn',
    () async {
      final run = _Run();
      await run.start();
      await run.text(0, 'abc');
      await run.text(1000, 'abc' * 100);
      run.kernel.cancel();
      await run.finish(cancelled: true);
      expect(run.ended.interrupted, isTrue);
      expect(run.ended.usage!.outputTokens, 101);
      run.kernel.send(const KernelTurn(id: 'next', text: 'Next'));
      await pumpEventQueue();
      await run.text(0, 'abc');
      await run.finish();
      expect(run.ended.turnId, 'next');
      expect(run.ended.usage!.outputTokens, 1);
      expect(run.ended.usage!.tokensPerSecond, isNull);
    },
  );

  test('ACP short or empty responses never invent a speed', () async {
    final run = _Run();
    await run.start();
    await run.finish();
    expect(run.ended.usage, isNull);
    run.kernel.send(const KernelTurn(id: 'next', text: 'Next'));
    await pumpEventQueue();
    await run.text(0, '测试');
    await run.finish();
    expect(run.ended.usage!.outputTokens, 3);
    expect(run.ended.usage!.tokensPerSecond, isNull);
  });

  testWidgets('ACP stats reach the chat footer live and after completion', (
    tester,
  ) async {
    final run = _Run();
    final session = ChatSession(
      kernel: run.descriptor,
      kernels: [run.descriptor],
      historyCount: 0,
    );
    addTearDown(session.dispose);
    session.send(const ComposerMessage(text: 'Hello'));
    await tester.pump(const Duration(milliseconds: 50));
    run.transport.text('abc');
    await tester.pump();
    run.now = run.now.add(const Duration(seconds: 1));
    run.transport.text('abc' * 100);
    await tester.pump();
    expect(
      (session.itemAt(
        session.itemCount - 1,
      ) as LiveStatusItem).output!.tokensPerSecond,
      closeTo(100, 1e-6),
    );
    expect(
      (session.itemAt(
        session.itemCount - 1,
      ) as LiveStatusItem).output!.estimated,
      isTrue,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TurnFooter(
          live:
              (session.itemAt(session.itemCount - 1) as LiveStatusItem).output,
        ),
      ),
    );
    expect(
      tester
          .widgetList<RollingText>(find.byType(RollingText))
          .map((text) => text.text),
      contains('≈ 100.00 tok/s'),
    );
    run.transport.finish();
    await tester.pump();
    final usage = (session.itemAt(0) as UserMessageItem).usage!;
    await tester.pumpWidget(MaterialApp(home: TurnFooter(usage: usage)));
    expect(find.text('≈ 100.00 tok/s'), findsOneWidget);
    expect(usage.outputTokens, 101);
  });
}

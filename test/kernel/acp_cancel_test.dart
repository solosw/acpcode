import 'dart:async';

import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Like an ACP SDK agent, cancellation is dispatched only as a notification.
/// The prompt stays open until the test explicitly completes it.
class _Transport implements AcpTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  final written = <Map<String, Object?>>[];
  Object? _promptId;
  int prompts = 0;
  bool cancelReceived = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    switch (message['method']) {
      case 'initialize':
        _reply(message['id']!, {'protocolVersion': 1});
      case 'session/new':
        _reply(message['id']!, {'sessionId': 'session'});
      case 'session/prompt':
        _promptId = message['id'];
        prompts++;
      case 'session/cancel':
        if (!message.containsKey('id')) cancelReceived = true;
    }
  }

  void _reply(Object id, Map<String, Object?> result) =>
      _messages.add({'jsonrpc': '2.0', 'id': id, 'result': result});

  Future<void> waitForPrompt(int count) async {
    final started = Stopwatch()..start();
    while (prompts < count) {
      if (started.elapsed > const Duration(seconds: 3)) {
        throw StateError('Prompt did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void completePrompt(String stopReason) {
    _reply(_promptId!, {'stopReason': stopReason});
    _promptId = null;
  }

  void permission(Object id) => _messages.add({
    'jsonrpc': '2.0',
    'id': id,
    'method': 'session/request_permission',
    'params': {
      'sessionId': 'session',
      'toolCall': {
        'toolCallId': 'tool_$id',
        'title': 'Run tool',
        'kind': 'execute',
      },
      'options': [
        {'optionId': 'allow', 'name': 'Allow once', 'kind': 'allow_once'},
        {'optionId': 'reject', 'name': 'Reject', 'kind': 'reject_once'},
      ],
    },
  });

  void text(String text) => _messages.add({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': 'session',
      'update': {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': text},
      },
    },
  });

  @override
  Future<void> close() => _messages.close();
}

void main() {
  late _Transport transport;
  late AcpKernel kernel;
  late List<KernelEvent> events;

  setUp(() {
    transport = _Transport();
    kernel = AcpKernel(
      KernelDescriptor(
        id: 'strict-acp',
        label: 'Strict ACP',
        icon: Icons.hub,
        description: 'An agent accepting cancel notifications only',
        create: (_) => throw UnimplementedError(),
      ),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    events = [];
    final subscription = kernel.events.listen(events.add);
    addTearDown(kernel.dispose);
    addTearDown(subscription.cancel);
  });

  Future<void> start([int count = 1]) async {
    kernel.send(KernelTurn(id: 'turn-$count', text: 'work'));
    await transport.waitForPrompt(count);
  }

  test('cancel is a notification; the original prompt ends the turn', () async {
    await start();
    kernel.cancel();

    expect(transport.cancelReceived, isTrue);
    expect(transport.written.last, {
      'jsonrpc': '2.0',
      'method': 'session/cancel',
      'params': {'sessionId': 'session'},
    });
    // Do not declare a running agent stopped, or wait for a cancel response
    // that an ACP agent never sends. Final updates must still be accepted.
    expect(events.whereType<TurnEnded>(), isEmpty);
    transport.text('Finishing cancellation');
    expect(events.whereType<TextDelta>().last.text, 'Finishing cancellation');
    transport.completePrompt('cancelled');
    await pumpEventQueue();

    final ended = events.whereType<TurnEnded>().single;
    expect(ended.turnId, 'turn-1');
    expect(ended.interrupted, isTrue);
    expect(kernel.health.status, KernelHealthStatus.ready);

    await start(2);
    transport.completePrompt('end_turn');
    await pumpEventQueue();
    expect(events.whereType<TurnEnded>().last.interrupted, isFalse);
  });

  test(
    'cancel resolves all pending permissions with their original RPC ids',
    () async {
      await start();
      transport.permission(42);
      transport.permission('request-2');
      expect(events.whereType<InteractionRequested>(), hasLength(2));

      kernel.cancel();
      final replies = transport.written.where((m) => m.containsKey('result'));
      expect(replies.map((m) => m['id']), [42, 'request-2']);
      for (final reply in replies) {
        expect(reply['result'], {
          'outcome': {'outcome': 'cancelled'},
        });
      }
      expect(events.whereType<InteractionResolved>().map((e) => e.requestId), [
        '42',
        'request-2',
      ]);
      expect(events.whereType<TurnEnded>(), isEmpty);

      // A UI answer already in flight must not send a second permission reply.
      final count = transport.written.length;
      kernel.answer(
        '42',
        const QuestionAnswer([
          ['Allow once'],
        ]),
      );
      expect(transport.written, hasLength(count));
      transport.completePrompt('cancelled');
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().single.interrupted, isTrue);
    },
  );

  test(
    'permissions racing with cancel are cancelled, but the next turn works',
    () async {
      await start();
      kernel.cancel();
      transport.permission(77);
      expect(events.whereType<InteractionRequested>(), isEmpty);
      expect(transport.written.last, {
        'jsonrpc': '2.0',
        'id': 77,
        'result': {
          'outcome': {'outcome': 'cancelled'},
        },
      });
      transport.completePrompt('cancelled');
      await pumpEventQueue();

      await start(2);
      transport.permission(78);
      expect(events.whereType<InteractionRequested>().single.request.id, '78');
      kernel.answer(
        '78',
        const QuestionAnswer([
          ['Allow once'],
        ]),
      );
      expect(transport.written.last['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      transport.completePrompt('end_turn');
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().last.interrupted, isFalse);
    },
  );

  test('cancel is a no-op when no prompt or permission is pending', () async {
    kernel.prepare();
    await pumpEventQueue();
    expect(kernel.health.status, KernelHealthStatus.ready);
    final count = transport.written.length;
    kernel.cancel();
    expect(transport.written, hasLength(count));
    kernel.dispose();
    kernel.cancel();
    expect(transport.written, hasLength(count));
  });
}

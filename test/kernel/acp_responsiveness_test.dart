import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BurstTransport implements AcpTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  static const count = 256;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  void history() {
    for (var i = 0; i < count; i++) {
      _messages.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'saved',
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'messageId': 'user_$i',
            'content': {'type': 'text', 'text': 'Question $i'},
          },
        },
      });
    }
  }

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'session/load') history();
    _messages.add({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': <String, Object?>{},
    });
  }

  @override
  void close() => unawaited(_messages.close());
}

AcpKernel _kernel(_BurstTransport transport) => AcpKernel(
  KernelDescriptor(
    id: 'burst-acp',
    label: 'Burst ACP',
    icon: Icons.hub,
    description: 'Test ACP history burst',
    create: (_) => throw UnimplementedError(),
  ),
  KernelContext(
    resume: SessionRecord(
      id: 'saved',
      title: 'Saved conversation',
      cwd: '/tmp/acp-burst',
      updatedAt: DateTime.utc(2026),
    ),
  ),
  (_) async => transport,
);

void main() {
  test('ACP history yields to navigation before the load finishes', () async {
    final kernel = _kernel(_BurstTransport());
    addTearDown(kernel.dispose);
    final questions = <String>[];
    final navigation = Completer<int>();
    final ready = Completer<void>();
    final subscription = kernel.events.listen((event) {
      if (event case ItemUpserted(item: UserMessageItem(:final text))) {
        questions.add(text);
        if (questions.length == 1) {
          // A click/page-load event queued while history is arriving must get
          // an event-loop turn, not wait for the entire replay to finish.
          Timer.run(() => navigation.complete(questions.length));
        }
      }
      if (kernel.health.status == KernelHealthStatus.ready &&
          !ready.isCompleted) {
        ready.complete();
      }
    });
    addTearDown(subscription.cancel);

    kernel.prepare();
    final receivedAtNavigation = await navigation.future;
    expect(receivedAtNavigation, lessThan(_BurstTransport.count));
    await ready.future;
    expect(questions, [
      for (var i = 0; i < _BurstTransport.count; i++) 'Question $i',
    ]);
    expect(kernel.health.status, KernelHealthStatus.ready);
  });

  test('restarting during an ACP burst discards the old buffer', () async {
    var starts = 0;
    final descriptor = KernelDescriptor(
      id: 'restart-burst-acp',
      label: 'Restart burst ACP',
      icon: Icons.hub,
      description: 'Test ACP restart during history',
      create: (_) => throw UnimplementedError(),
    );
    final kernel = AcpKernel(
      descriptor,
      KernelContext(
        resume: SessionRecord(
          id: 'saved',
          title: 'Saved conversation',
          cwd: '/tmp/acp-burst',
          updatedAt: DateTime.utc(2026),
        ),
      ),
      (_) async {
        starts++;
        return _BurstTransport();
      },
    );
    addTearDown(kernel.dispose);
    var questions = 0;
    int? receivedAtRestart;
    final ready = Completer<void>();
    final subscription = kernel.events.listen((event) {
      if (event case ItemUpserted(item: UserMessageItem())) {
        questions++;
        if (questions == 1) {
          Timer.run(() {
            receivedAtRestart = questions;
            kernel.restart();
          });
        }
      }
      if (kernel.health.status == KernelHealthStatus.ready &&
          !ready.isCompleted) {
        ready.complete();
      }
    });
    addTearDown(subscription.cancel);

    kernel.prepare();
    await ready.future;
    expect(starts, 2);
    expect(receivedAtRestart, lessThan(_BurstTransport.count));
    expect(questions - receivedAtRestart!, _BurstTransport.count);
  });

  test('disposing during an ACP burst drops buffered history', () async {
    final kernel = _kernel(_BurstTransport());
    addTearDown(kernel.dispose);
    var questions = 0;
    final disposed = Completer<int>();
    final subscription = kernel.events.listen((event) {
      if (event case ItemUpserted(item: UserMessageItem())) {
        questions++;
        if (questions == 1) {
          Timer.run(() {
            kernel.dispose();
            disposed.complete(questions);
          });
        }
      }
    });
    addTearDown(subscription.cancel);

    kernel.prepare();
    final receivedAtDisposal = await disposed.future;
    expect(receivedAtDisposal, lessThan(_BurstTransport.count));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(questions, receivedAtDisposal);
  });
}

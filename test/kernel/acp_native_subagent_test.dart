import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = 'acp_mock_session';
String _id(String session) => 'acp_session_${jsonEncode(session)}';

class _Transport extends MockAcpTransport {
  _Transport({this.history = const [], this.failLoad = false}) {
    _forward = super.messages.listen(_updates.add, onDone: _updates.close);
  }

  final List<(String, Map<String, Object?>)> history;
  final bool failLoad;
  final _updates = StreamController<Map<String, Object?>>.broadcast(sync: true);
  late final StreamSubscription<Map<String, Object?>> _forward;

  @override
  Stream<Map<String, Object?>> get messages => _updates.stream;

  void update(String session, Map<String, Object?> update) => _updates.add({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'sessionId': session, 'update': update},
  });

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'session/load') {
      for (final (session, notification) in history) {
        update(session, notification);
      }
      if (failLoad) {
        _updates.add({
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': {'code': -32603, 'message': 'Interrupted history'},
        });
        return;
      }
    }
    super.write(message);
  }

  @override
  Future<void> close() async {
    await super.close();
    await _forward.cancel();
    await _updates.close();
  }
}

class _Harness {
  _Harness({
    _Transport? transport,
    _Transport? replacement,
    KernelContext context = const KernelContext(),
  }) : transport = transport ?? _Transport() {
    final descriptor = KernelDescriptor(
      id: 'generic-acp',
      label: 'Generic ACP',
      icon: Icons.hub,
      description: '',
      create: (_) => kernel,
    );
    var launches = 0;
    kernel = AcpKernel(
      descriptor,
      context,
      (_) async =>
          launches++ == 0 ? this.transport : replacement ?? this.transport,
    );
    subscription = kernel.events.listen(events.add);
    session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      historyCount: 0,
    );
    addTearDown(() async {
      session.dispose();
      kernel.dispose();
      await subscription.cancel();
      await kernel.stopped;
    });
  }

  final _Transport transport;
  final events = <KernelEvent>[];
  late final AcpKernel kernel;
  late final ChatSession session;
  late final StreamSubscription<KernelEvent> subscription;

  Future<void> start() async {
    kernel.prepare();
    await pumpEventQueue();
  }

  void spawn(String child, {String parent = _root, bool legacy = false}) =>
      transport.update(parent, {
        if (legacy) ...{
          'sessionUpdate': 'subagent_spawned',
          'subagentSessionId': child,
          'name': 'Agent $child',
          'task': 'Investigate $child',
          'capabilities': {},
        } else ...{
          'sessionUpdate': 'subagent_update',
          'sessionId': child,
          'title': 'Agent $child',
          'description': 'Role $child',
          'state': {'state': 'running'},
          'capabilities': {'cancel': {}},
        },
      });

  void text(String child, String text, {bool thought = false}) =>
      transport.update(child, {
        'sessionUpdate': thought
            ? 'agent_thought_chunk'
            : 'agent_message_chunk',
        'messageId': 'same-message',
        'content': {'type': 'text', 'text': text},
      });

  List<KernelTask> get tasks => events.whereType<TasksReported>().last.tasks;
  AgentItem agent(String child) =>
      session.agentOf(tasks.firstWhere((t) => t.id == _id(child)))!.agent;
}

void main() {
  test(
    'an interrupted initial native replay removes partial cards before retry',
    () async {
      final history = <(String, Map<String, Object?>)>[
        (
          _root,
          {
            'sessionUpdate': 'subagent_update',
            'sessionId': 'a',
            'title': 'Replay child',
            'state': {'state': 'running'},
          },
        ),
        (
          'a',
          {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'complete answer'},
          },
        ),
        (
          _root,
          {
            'sessionUpdate': 'subagent_update',
            'sessionId': 'a',
            'state': {'state': 'idle', 'stopReason': 'end_turn'},
          },
        ),
      ];
      final h = _Harness(
        transport: _Transport(history: history, failLoad: true),
        replacement: _Transport(history: history),
        context: KernelContext(
          resume: SessionRecord(
            id: _root,
            title: 'Replay',
            cwd: '/tmp',
            updatedAt: DateTime.utc(2026),
          ),
        ),
      );
      await h.start();
      expect(h.kernel.health.status, KernelHealthStatus.failed);
      expect(h.tasks, isEmpty);
      expect(
        h.events.whereType<ItemRemoved>().any((e) => e.id == _id('a')),
        isTrue,
      );
      h.kernel.restart();
      await pumpEventQueue();
      expect(h.kernel.health.status, KernelHealthStatus.ready);
      expect(h.tasks, hasLength(1));
      expect(
        h.agent('a').children.whereType<AssistantTextItem>().single.text,
        'complete answer',
      );
      expect(h.agent('a').status, CommandStatus.succeeded);
    },
  );

  test('native child user chunks preserve separate rounds without duplicating the legacy task', () async {
    final h = _Harness();
    await h.start();
    h.spawn('a', legacy: true);
    for (final text in ['First ', 'request']) {
      h.transport.update('a', {
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'text', 'text': text},
      });
    }
    h.text('a', 'first answer');
    h.transport.update('a', {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': 'Second request'},
    });
    h.text('a', 'second answer');
    await pumpEventQueue();
    final feed = SubagentFeed(h.session, [_id('a')]);
    addTearDown(feed.dispose);
    expect(feed.agent!.prompt, isNull);
    expect(
      feed.agent!.children.whereType<UserMessageItem>().map((i) => i.text),
      ['First request', 'Second request'],
    );
    expect(feed.agent!.children.map((i) => i.runtimeType), [
      UserMessageItem,
      AssistantTextItem,
      UserMessageItem,
      AssistantTextItem,
    ]);
  });

  test('active native children survive view release until their foreground work ends', () async {
    final h = _Harness();
    await h.start();
    h.spawn('a');
    h.text('a', 'kept');
    h.kernel.release();
    await pumpEventQueue();
    expect(h.kernel.health.status, KernelHealthStatus.ready);
    h.transport.update(_root, {
      'sessionUpdate': 'subagent_update',
      'sessionId': 'a',
      'state': {'state': 'idle', 'stopReason': 'end_turn'},
    });
    await pumpEventQueue();
    expect(h.kernel.health.status, KernelHealthStatus.idle);
    expect(h.agent('a').status, CommandStatus.succeeded);
  });

  test('retained load skips duplicate history but retains live child routing and tool patches', () async {
    final replacement = _Transport(
      history: [
        (
          _root,
          {
            'sessionUpdate': 'subagent_update',
            'sessionId': 'a',
            'title': 'Duplicate',
          },
        ),
        (
          'a',
          {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'duplicate'},
          },
        ),
      ],
    );
    final h = _Harness(replacement: replacement);
    await h.start();
    h.spawn('a');
    h.text('a', 'kept');
    h.transport.update('a', {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'read',
      'kind': 'read',
      'title': 'Read original',
      'rawInput': {'path': 'original'},
    });
    h.transport.update(_root, {
      'sessionUpdate': 'subagent_update',
      'sessionId': 'a',
      'state': {'state': 'idle', 'stopReason': 'end_turn'},
    });
    h.kernel.release();
    await h.kernel.stopped;
    h.kernel.prepare();
    await pumpEventQueue();
    replacement.update(_root, {
      'sessionUpdate': 'subagent_update',
      'sessionId': 'a',
      'state': {'state': 'running'},
    });
    replacement.update('a', {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'read',
      'status': 'completed',
      'rawOutput': 'after reconnect',
    });
    replacement.update('a', {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'new'},
    });
    await pumpEventQueue();
    expect(h.tasks, hasLength(1));
    expect(h.agent('a').description, 'Agent a');
    expect(
      h.agent('a').children.whereType<AssistantTextItem>().map((i) => i.text),
      ['kept', 'new'],
    );
    final tool = h.agent('a').children.whereType<ToolCallItem>().single;
    expect(tool.target, 'Read original');
    expect(tool.details!.input, contains('original'));
    expect(tool.output, 'after reconnect');
  });

  test(
    'generic ACP declares subagents and displays only announced child sessions',
    () async {
      final h = _Harness();
      await h.start();
      final init = h.transport.written.firstWhere(
        (m) => m['method'] == 'initialize',
      );
      expect(
        ((init['params'] as Map)['clientCapabilities'] as Map)['subagents'],
        isEmpty,
      );
      h.text('unannounced', 'must not appear');
      h.spawn('child');
      h.text('child', 'answer');
      await pumpEventQueue();
      expect(h.tasks, hasLength(1));
      expect(h.tasks.single.kind, KernelTaskKind.agent);
      expect(h.tasks.single.canStop, isFalse);
      expect(h.agent('child').description, 'Agent child');
      expect(h.agent('child').prompt, isNull); // Role is not an instruction.
      expect(
        h.agent('child').children.whereType<AssistantTextItem>().single.text,
        'answer',
      );
      expect(h.events.whereType<TextDelta>(), isEmpty);
    },
  );

  test(
    'native ACP preserves root and parallel child streams and scopes tool ids',
    () async {
      final h = _Harness();
      await h.start();
      h.spawn('a');
      h.spawn('b');
      h.text(_root, 'main ');
      h.text('a', 'a ');
      h.text('b', 'b ');
      for (final session in [_root, 'a', 'b']) {
        h.transport.update(session, {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'read',
          'name': 'Read',
          'kind': 'read',
          'title': 'Read $session',
          'rawInput': {'path': session},
        });
      }
      h.transport.update('a', {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'read',
        'status': 'completed',
        'rawOutput': 'a source',
      });
      h.text('a', 'after tool');
      h.text('b', 'thinking', thought: true);
      h.transport.update('b', {
        'sessionUpdate': 'plan',
        'entries': [
          {'content': 'child plan'},
        ],
      });
      h.transport.update('b', {
        'sessionUpdate': 'usage_update',
        'used': 12,
        'size': 100,
      });
      h.text(_root, 'main after tool');
      await pumpEventQueue();
      final a = h.agent('a').children.whereType<ToolCallItem>().single;
      final b = h.agent('b').children.whereType<ToolCallItem>().single;
      expect(a.status, ToolStatus.succeeded);
      expect(a.output, 'a source');
      expect(b.status, ToolStatus.running);
      expect(b.output, isNull);
      expect(a.callId, isNot(b.callId));
      expect(
        h.agent('a').children.whereType<AssistantTextItem>().map((i) => i.text),
        ['a ', 'after tool'],
      );
      expect(
        h.agent('b').children.whereType<ThinkingItem>().single.text,
        'thinking',
      );
      expect(h.events.whereType<TextDelta>().map((e) => e.text), [
        'main ',
        'main after tool',
      ]);
      expect(h.events.whereType<TodosReported>(), isEmpty);
      expect(h.events.whereType<UsageReported>(), isEmpty);
      expect(h.tasks.map((t) => t.id).toSet(), {_id('a'), _id('b'), 'read'});
    },
  );

  test('native ACP resolves nested task navigation and rejects invalid associations', () async {
    final h = _Harness();
    await h.start();
    h.spawn('outer');
    h.spawn('inner', parent: 'outer');
    h.spawn(_root, parent: 'inner'); // Cycle/root alias.
    h.spawn('outer', parent: 'inner'); // Cycle/reparent.
    h.spawn('inner'); // Immutable parent.
    h.spawn('orphan', parent: 'unknown');
    h.text('inner', 'nested answer');
    await pumpEventQueue();
    final task = h.tasks.firstWhere((t) => t.id == _id('inner'));
    expect(h.session.agentOf(task)?.path, [_id('outer'), _id('inner')]);
    expect(h.tasks, hasLength(2));
    final feed = SubagentFeed(h.session, [_id('outer'), _id('inner')]);
    addTearDown(feed.dispose);
    expect(feed.itemAt(0), isA<AssistantTextItem>());
    expect((feed.itemAt(0) as AssistantTextItem).text, 'nested answer');
    expect(
      h.events.whereType<ItemUpserted>().any((e) => e.id == _id('inner')),
      isFalse,
    );
  });

  test(
    'standard metadata patches preserve omissions and honor explicit clears',
    () async {
      final h = _Harness();
      await h.start();
      h.spawn('a');
      await pumpEventQueue();
      final started = h.agent('a').startedAt;
      h.transport.update(_root, {
        'sessionUpdate': 'subagent_update',
        'sessionId': 'a',
      });
      await pumpEventQueue();
      expect(h.agent('a').description, 'Agent a');
      h.transport.update(_root, {
        'sessionUpdate': 'subagent_update',
        'sessionId': 'a',
        'title': null,
      });
      await pumpEventQueue();
      expect(h.agent('a').description, 'Role a');
      h.transport.update(_root, {
        'sessionUpdate': 'subagent_update',
        'sessionId': 'a',
        'description': null,
        'capabilities': null,
      });
      await pumpEventQueue();
      expect(h.agent('a').description, 'Subagent');
      expect(h.agent('a').activity, isNull);
      expect(h.agent('a').startedAt, started);
      expect(h.tasks.single.canStop, isFalse);
    },
  );

  test(
    'standard foreground state can become idle and run again in the same card',
    () async {
      final h = _Harness();
      await h.start();
      h.spawn('a');
      h.text('a', 'first');
      h.transport.update(_root, {
        'sessionUpdate': 'subagent_update',
        'sessionId': 'a',
        'state': {'state': 'idle', 'stopReason': 'end_turn'},
      });
      await pumpEventQueue();
      expect(h.agent('a').status, CommandStatus.succeeded);
      expect(h.agent('a').duration, isNotNull);
      h.transport.update(_root, {
        'sessionUpdate': 'subagent_update',
        'sessionId': 'a',
        'state': {'state': 'running'},
      });
      h.text('a', 'second');
      await pumpEventQueue();
      expect(h.agent('a').status, CommandStatus.running);
      expect(h.agent('a').duration, isNull);
      expect(
        h.agent('a').children.whereType<AssistantTextItem>().map((i) => i.text),
        ['first', 'second'],
      );
      expect(h.tasks, hasLength(1));
      for (final state in [
        null,
        {'state': 'unknown'},
        {'state': '_future'},
      ]) {
        h.transport.update(_root, {
          'sessionUpdate': 'subagent_update',
          'sessionId': 'a',
          'state': state,
        });
        await pumpEventQueue();
        expect(h.agent('a').status, CommandStatus.running);
      }
      h.transport.update('a', {
        'sessionUpdate': 'state_update',
        'state': 'idle',
        'stopReason': 'error',
      });
      await pumpEventQueue();
      expect(h.agent('a').status, CommandStatus.failed);
    },
  );

  for (final state in ['completed', 'failed', 'cancelled', 'disconnected']) {
    test('Codex 2.2.2 legacy child lifecycle: $state', () async {
      final h = _Harness();
      await h.start();
      h.spawn('codex', legacy: true);
      h.text('codex', 'result');
      h.transport.update(_root, {
        'sessionUpdate': 'subagent_state_update',
        'subagentSessionId': 'codex',
        'state': state,
      });
      h.text('codex', 'late');
      await pumpEventQueue();
      expect(h.agent('codex').prompt, 'Investigate codex');
      expect(
        h.agent('codex').status,
        state == 'completed' ? CommandStatus.succeeded : CommandStatus.failed,
      );
      expect(
        h.agent('codex').children.whereType<AssistantTextItem>().single.text,
        'result',
      );
      final feed = SubagentFeed(h.session, [_id('codex')]);
      addTearDown(feed.dispose);
      expect(feed.isStreaming, isFalse);
      h.spawn('codex:generation:2', legacy: true);
      h.text('codex:generation:2', 'resumed');
      await pumpEventQueue();
      expect(h.tasks, hasLength(2));
      expect(h.agent('codex:generation:2').status, CommandStatus.running);
    });
  }

  test(
    'standard session messages patch and stream within their own transcript',
    () async {
      final h = _Harness();
      await h.start();
      h.spawn('a');
      h.transport.update('a', {
        'sessionUpdate': 'session_message',
        'messageId': 'm',
        'senderSessionId': _root,
        'recipientSessionId': 'a',
        'content': [
          {'type': 'text', 'text': 'Instruction'},
        ],
      });
      h.transport.update('a', {
        'sessionUpdate': 'session_message_chunk',
        'messageId': 'm',
        'content': {'type': 'text', 'text': 'more'},
      });
      await pumpEventQueue();
      expect(
        h.agent('a').children.whereType<UserMessageItem>().single.text,
        'Instructionmore',
      );
      h.transport.update('a', {
        'sessionUpdate': 'session_message',
        'messageId': 'm',
        'senderSessionId': null,
      });
      await pumpEventQueue();
      expect(
        h.agent('a').children.whereType<UserMessageItem>().single.text,
        'Instructionmore',
      );
      h.transport.update('a', {
        'sessionUpdate': 'session_message',
        'messageId': 'm',
        'content': [],
      });
      await pumpEventQueue();
      expect(
        h.agent('a').children.whereType<UserMessageItem>().single.text,
        '',
      );
      h.transport.update('a', {
        'sessionUpdate': 'session_message_chunk',
        'messageId': 'reply',
        'senderSessionId': 'a',
        'recipientSessionId': _root,
        'content': {'type': 'text', 'text': 'Report'},
      });
      h.transport.update(_root, {
        'sessionUpdate': 'session_message',
        'messageId': 'm',
        'senderSessionId': _root,
        'recipientSessionId': 'a',
        'content': [
          {'type': 'text', 'text': 'Root outgoing'},
        ],
      });
      await pumpEventQueue();
      expect(
        h.agent('a').children.whereType<AssistantTextItem>().single.text,
        'Report',
      );
      expect(h.agent('a').status, CommandStatus.running);
      expect(h.agent('a').result, isNull);
      expect(
        h.events
            .whereType<ItemUpserted>()
            .where((e) => e.item is AssistantTextItem)
            .map((e) => (e.item as AssistantTextItem).text),
        ['Root outgoing'],
      );
      expect(h.events.whereType<TurnStarted>(), isEmpty);
    },
  );

  test(
    'native subagent history replays cards, child messages and completion',
    () async {
      final h = _Harness(
        transport: _Transport(
          history: [
            (
              _root,
              {
                'sessionUpdate': 'subagent_spawned',
                'subagentSessionId': 'history-child',
                'name': 'History',
                'task': 'Historical prompt',
                'capabilities': {},
              },
            ),
            (
              'history-child',
              {
                'sessionUpdate': 'agent_message_chunk',
                'content': {'type': 'text', 'text': 'Historical answer'},
              },
            ),
            (
              _root,
              {
                'sessionUpdate': 'subagent_state_update',
                'subagentSessionId': 'history-child',
                'state': 'completed',
              },
            ),
          ],
        ),
        context: KernelContext(
          resume: SessionRecord(
            id: _root,
            title: 'History',
            cwd: '/tmp',
            updatedAt: DateTime.utc(2026),
          ),
        ),
      );
      await h.start();
      final feed = SubagentFeed(h.session, [_id('history-child')]);
      addTearDown(feed.dispose);
      expect(feed.isStreaming, isFalse);
      expect(feed.itemCount, 2);
      expect((feed.itemAt(0) as UserMessageItem).text, 'Historical prompt');
      expect((feed.itemAt(1) as AssistantTextItem).text, 'Historical answer');
      expect(h.tasks.single.status, CommandStatus.succeeded);
    },
  );

  test(
    'disconnect closes nested native tasks without losing their dialogue',
    () async {
      final h = _Harness();
      await h.start();
      h.spawn('a');
      h.spawn('b', parent: 'a');
      h.text('b', 'kept');
      await h.transport.close();
      await pumpEventQueue();
      expect(h.tasks.every((t) => t.status == CommandStatus.failed), isTrue);
      expect(
        h.agent('b').children.whereType<AssistantTextItem>().single.text,
        'kept',
      );
    },
  );
}

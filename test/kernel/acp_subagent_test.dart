import 'dart:async';

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

class _Harness {
  _Harness({
    MockAcpTransport? transport,
    KernelContext context = const KernelContext(),
  }) : transport = transport ?? MockAcpTransport() {
    final descriptor = KernelDescriptor(
      id: 'acp-subagent-test',
      label: 'ACP',
      icon: Icons.hub,
      description: 'ACP subagent test',
      create: (_) => kernel,
    );
    kernel = AcpKernel(descriptor, context, (_) async => this.transport);
    subscription = kernel.events.listen(events.add);
    session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      historyCount: 0,
    );
    addTearDown(() async {
      session.dispose();
      await subscription.cancel();
      kernel.dispose();
    });
  }

  final MockAcpTransport transport;
  final events = <KernelEvent>[];
  late final AcpKernel kernel;
  late final ChatSession session;
  late final StreamSubscription<KernelEvent> subscription;

  Future<void> start() async {
    kernel.prepare();
    await pumpEventQueue();
  }

  void notify(Map<String, Object?> update, {String? parent}) {
    transport.notify({
      ...update,
      if (parent != null)
        '_meta': {
          'claudeCode': {'parentToolUseId': parent},
        },
    });
  }

  void task(String id, {String? parent, String name = 'Task'}) => notify({
    'sessionUpdate': 'tool_call',
    'toolCallId': id,
    'kind': 'other',
    'name': name,
    'title': 'Delegate $id',
    'status': 'in_progress',
    'rawInput': {
      'description': 'Inspect $id',
      'prompt': 'Read $id',
      'subagent_type': 'Explore',
    },
  }, parent: parent);

  void text(
    String text, {
    String? parent,
    String? messageId,
    bool thought = false,
  }) => notify({
    'sessionUpdate': thought ? 'agent_thought_chunk' : 'agent_message_chunk',
    'content': {'type': 'text', 'text': text},
    'messageId': ?messageId,
  }, parent: parent);

  AgentItem agent(String id) =>
      events
              .whereType<ItemUpserted>()
              .lastWhere((event) => event.id == id && event.item is AgentItem)
              .item
          as AgentItem;

  List<KernelTask> get tasks => events.whereType<TasksReported>().last.tasks;
}

class _ReplayTransport extends MockAcpTransport {
  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'session/load') {
      notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'history-task',
        'name': 'Task',
        'rawInput': {'prompt': 'Historical prompt'},
      });
      notify({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'Historical child answer'},
        '_meta': {
          'claudeCode': {'parentToolUseId': 'history-task'},
        },
      });
      notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'history-task',
        'status': 'completed',
        'rawOutput': 'Historical report',
      });
    }
    super.write(message);
  }
}

class _HoldingTransport extends MockAcpTransport {
  Map<String, Object?>? prompt;

  @override
  Stream<Map<String, Object?>> get messages => super.messages.map((message) {
    if (prompt != null &&
        message['id'] == prompt!['id'] &&
        message.containsKey('result')) {
      return {
        ...message,
        'result': {'stopReason': 'cancelled'},
      };
    }
    return message;
  });

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == 'session/prompt') {
      prompt = message;
      return;
    }
    super.write(message);
  }

  void finish() => super.write(prompt!);
}

void main() {
  test(
    'ACP replayed child prompt chunks do not duplicate delegation input',
    () async {
      final h = _Harness();
      await h.start();
      h.task('a');
      for (final text in ['Read ', 'a']) {
        h.notify({
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': text},
        }, parent: 'a');
      }
      expect(h.agent('a').prompt, 'Read a');
    },
  );

  test(
    'ACP late parent links move child placeholders out of the root feed',
    () async {
      final h = _Harness();
      await h.start();
      h.text('early nested text', parent: 'inner');
      h.task('outer');
      h.task('inner', parent: 'outer');
      await pumpEventQueue();
      final task = h.tasks.firstWhere((task) => task.id == 'inner');
      expect(h.session.agentOf(task)?.path, ['outer', 'inner']);
      final roots = [
        for (var i = 0; i < h.session.itemCount; i++) h.session.itemAt(i),
      ].whereType<AgentItem>();
      expect(roots.map((a) => a.id), ['outer']);
      expect(
        roots.single.children
            .whereType<AgentItem>()
            .single
            .children
            .whereType<AssistantTextItem>()
            .single
            .text,
        'early nested text',
      );
    },
  );

  test('ACP replay keeps child dialogue within its historical task', () async {
    final h = _Harness(
      transport: _ReplayTransport(),
      context: KernelContext(
        resume: SessionRecord(
          id: 'acp_mock_session',
          title: 'Earlier',
          cwd: '/tmp/project',
          updatedAt: DateTime.utc(2026),
        ),
      ),
    );
    await h.start();
    final task = h.tasks.single;
    expect(task.kind, KernelTaskKind.agent);
    expect(task.status, CommandStatus.succeeded);
    expect(h.session.agentOf(task)?.path, ['history-task']);
    final feed = SubagentFeed(h.session, ['history-task']);
    addTearDown(feed.dispose);
    expect(feed.isStreaming, isFalse);
    expect(feed.itemCount, 3);
    expect((feed.itemAt(0) as UserMessageItem).text, 'Historical prompt');
    expect(
      (feed.itemAt(1) as AssistantTextItem).text,
      'Historical child answer',
    );
    expect((feed.itemAt(2) as AssistantTextItem).text, 'Historical report');
    expect(
      h.events.whereType<TextDelta>().any(
        (e) => e.text == 'Historical child answer',
      ),
      isFalse,
    );
  });

  test(
    'ACP cancelling the parent ends child tasks after prompt acknowledgement',
    () async {
      final transport = _HoldingTransport();
      final h = _Harness(transport: transport);
      await h.start();
      h.kernel.send(const KernelTurn(id: 'cancel-parent', text: 'delegate'));
      await pumpEventQueue();
      h.task('outer');
      h.task('inner', parent: 'outer');
      h.kernel.cancel();
      expect(h.agent('outer').status, CommandStatus.running);
      transport.finish();
      await pumpEventQueue();
      expect(h.agent('outer').status, CommandStatus.failed);
      expect(
        h.agent('outer').children.whereType<AgentItem>().single.status,
        CommandStatus.failed,
      );
      expect(h.tasks.every((t) => t.status == CommandStatus.failed), isTrue);
      expect(h.events.whereType<TurnEnded>().last.interrupted, isTrue);
    },
  );

  test(
    'ACP does not infer child lifecycles from spawn or control calls',
    () async {
      final h = _Harness();
      await h.start();
      for (final name in ['wait_agent', 'close_agent', 'spawn_agent']) {
        h.notify({
          'sessionUpdate': 'tool_call',
          'toolCallId': name,
          'name': name,
          'kind': 'other',
        });
      }
      expect(h.tasks.every((t) => t.kind == KernelTaskKind.other), isTrue);
      expect(
        h.events.whereType<ItemUpserted>().where((e) => e.item is AgentItem),
        isEmpty,
      );
    },
  );

  test(
    'ACP advertises child transcripts and maps delegation names to agent cards',
    () async {
      final h = _Harness();
      await h.start();
      final initialize = h.transport.written.firstWhere(
        (m) => m['method'] == 'initialize',
      );
      final params = initialize['params'] as Map;
      expect(params['clientCapabilities'], {
        'subagents': <String, Object?>{},
        '_meta': {'subagent-transcript': true},
      });

      for (final name in ['Task', 'Agent']) {
        h.task(name, name: name);
        final item = h.agent(name);
        expect(item.id, name);
        expect(item.description, 'Inspect $name');
        expect(item.prompt, 'Read $name');
        expect(item.agentType, 'Explore');
        expect(item.status, CommandStatus.running);
      }
      expect(h.tasks, hasLength(2));
      expect(
        h.tasks.every(
          (task) => task.kind == KernelTaskKind.agent && !task.canStop,
        ),
        isTrue,
      );
      expect(h.kernel, isA<RunsBackgroundTasks>());
      expect(h.tasks.every((task) => !task.canStop), isTrue);
    },
  );

  test(
    'ACP Claude tool metadata and null patches retain task prompt and result',
    () async {
      final h = _Harness();
      await h.start();
      h.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'task',
        'kind': 'other',
        'title': 'Explore files',
        '_meta': {
          'claudeCode': {'toolName': 'Task'},
        },
        'rawInput': {'prompt': 'Read the source', 'description': 'Explore'},
      });
      final initial = h.agent('task');
      h.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'task',
        'status': 'completed',
        'rawInput': null,
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'Found it'},
          },
        ],
      });
      h.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'task',
        'rawOutput': null,
      });
      final completed = h.agent('task');
      expect(completed.prompt, 'Read the source');
      expect(completed.description, 'Explore');
      expect(completed.startedAt, initial.startedAt);
      expect(completed.status, CommandStatus.succeeded);
      expect(completed.result, 'Found it');
      expect(completed.duration, isNotNull);
      expect(h.tasks.single.status, CommandStatus.succeeded);
      expect(
        h.events
            .whereType<ItemUpserted>()
            .where((e) => e.id == 'task')
            .every((e) => e.item is AgentItem),
        isTrue,
      );
    },
  );

  test(
    'ACP parallel child streams are isolated from root text and plans',
    () async {
      final h = _Harness();
      await h.start();
      h.task('a');
      h.task('b');
      h.text('main ', messageId: 'main');
      h.text('alpha ', parent: 'a', messageId: 'shared');
      h.text('beta ', parent: 'b', messageId: 'shared');
      h.text('continued', messageId: 'main');
      h.text('done', parent: 'a', messageId: 'shared');
      h.text('thinking', parent: 'b', messageId: 'shared', thought: true);
      h.notify({
        'sessionUpdate': 'plan',
        'entries': [
          {'content': 'Child plan', 'status': 'pending'},
        ],
      }, parent: 'a');
      h.notify({
        'sessionUpdate': 'usage_update',
        'used': 10,
        'size': 100,
      }, parent: 'a');

      expect(
        h.agent('a').children.whereType<AssistantTextItem>().single.text,
        'alpha done',
      );
      expect(
        h.agent('b').children.whereType<AssistantTextItem>().single.text,
        'beta ',
      );
      expect(
        h.agent('b').children.whereType<ThinkingItem>().single.text,
        'thinking',
      );
      final root = h.events.whereType<TextDelta>().toList();
      expect(root.map((e) => e.id).toSet(), hasLength(1));
      expect(root.map((e) => e.text).join(), 'main continued');
      expect(h.events.whereType<TodosReported>(), isEmpty);
      expect(h.events.whereType<UsageReported>(), isEmpty);
      expect(h.tasks, hasLength(2));
    },
  );

  test(
    'ACP nested agent tasks open existing SubagentFeed and patch child tools',
    () async {
      final h = _Harness();
      await h.start();
      h.task('outer');
      h.task('inner', parent: 'outer', name: 'Agent');
      h.text('Inspecting', parent: 'inner');
      h.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'read',
        'name': 'Read',
        'kind': 'read',
        'title': 'Read lib/main.dart',
        'rawInput': {'path': 'lib/main.dart'},
      }, parent: 'inner');
      // Some adapters omit parent metadata on later patches.
      h.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'read',
        'status': 'completed',
        'rawOutput': 'source',
      });
      h.text('Finished', parent: 'inner');
      await pumpEventQueue();
      final task = h.tasks.firstWhere((t) => t.id == 'inner');
      expect(h.session.agentOf(task)?.path, ['outer', 'inner']);
      final feed = SubagentFeed(h.session, ['outer', 'inner']);
      addTearDown(feed.dispose);
      expect(feed.agent?.prompt, 'Read inner');
      expect(feed.isStreaming, isTrue);
      expect(feed.itemAt(0), isA<UserMessageItem>());
      final child = feed.agent!.children.whereType<ToolCallItem>().single;
      expect(child.target, 'Read lib/main.dart');
      expect(child.status, ToolStatus.succeeded);
      expect(child.details?.input, contains('lib/main.dart'));
      expect(child.output, 'source');
      expect(feed.agent!.toolUses, 1);
      expect(
        feed.agent!.children.whereType<AssistantTextItem>().map((e) => e.text),
        ['Inspecting', 'Finished'],
      );
      expect(h.tasks.map((t) => t.id).toSet(), {'outer', 'inner'});
      expect(
        h.events.whereType<ItemUpserted>().any(
          (e) => e.id == 'read' || e.id == 'inner',
        ),
        isFalse,
      );

      h.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'inner',
        'status': 'completed',
        'rawOutput': 'Nested report',
      });
      await pumpEventQueue();
      expect(feed.isStreaming, isFalse);
      expect(feed.agent!.status, CommandStatus.succeeded);
      expect(
        (feed.itemAt(feed.itemCount - 1) as AssistantTextItem).text,
        'Nested report',
      );
    },
  );

  test(
    'ACP late delegation details preserve already streamed child messages',
    () async {
      final h = _Harness();
      await h.start();
      h.text('early', parent: 'late');
      final initial = h.agent('late');
      h.task('late');
      expect(h.agent('late').startedAt, initial.startedAt);
      expect(h.agent('late').prompt, 'Read late');
      expect(
        h.agent('late').children.whereType<AssistantTextItem>().single.text,
        'early',
      );
      expect(h.tasks, hasLength(1));
    },
  );

  test('ACP failure is reflected in cards and tasks; disconnect ends running children', () async {
    final h = _Harness();
    await h.start();
    h.task('failed');
    h.task('running');
    h.notify({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'failed',
      'status': 'failed',
      'rawOutput': 'Cannot read file',
    });
    await h.transport.close();
    await pumpEventQueue();
    expect(h.agent('failed').result, 'Cannot read file');
    expect(h.agent('failed').status, CommandStatus.failed);
    expect(h.agent('running').status, CommandStatus.failed);
    expect(h.tasks.every((t) => t.status == CommandStatus.failed), isTrue);
    expect(h.kernel.health.status, KernelHealthStatus.failed);
  });
}

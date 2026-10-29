import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/mock_acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';

class _TrackingTransport extends MockAcpTransport {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  KernelDescriptor descriptor() => KernelDescriptor(
    id: 'mock-acp',
    label: 'Mock ACP',
    icon: Icons.hub,
    description: 'Test ACP agent',
    create: (_) => throw UnimplementedError(),
  );

  test('ACP prepare defers notifications and starts only once', () async {
    final transport = MockAcpTransport();
    var starts = 0;
    final kernel = AcpKernel(descriptor(), const KernelContext(), (_) async {
      starts++;
      return transport;
    });
    addTearDown(kernel.dispose);
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);
    addTearDown(subscription.cancel);

    kernel.prepare();
    kernel.prepare();
    expect(kernel.health.status, KernelHealthStatus.starting);
    expect(events, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    expect(events.first, isA<KernelInfoChanged>());
    expect(kernel.health.status, KernelHealthStatus.ready);
  });

  test(
    'a synchronous ACP factory failure is reported asynchronously',
    () async {
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(),
        (_) => throw StateError('Agent could not start'),
      );
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final subscription = kernel.events.listen(events.add);
      addTearDown(subscription.cancel);

      kernel.prepare();
      expect(events, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(kernel.health.message, contains('Agent could not start'));
      expect(events, isNotEmpty);
    },
  );

  test('disposing during ACP startup closes the late transport', () async {
    final transport = _TrackingTransport();
    final pending = Completer<_TrackingTransport>();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(),
      (_) => pending.future,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);
    addTearDown(subscription.cancel);

    kernel.prepare();
    await pumpEventQueue();
    expect(events.single, isA<KernelInfoChanged>());
    events.clear();
    kernel.dispose();
    pending.complete(transport);
    await kernel.stopped;
    expect(transport.closed, isTrue);
    expect(transport.written, isEmpty);
    expect(events, isEmpty);
  });

  test('ACP initializes a session and streams an assistant message', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(kernel.commands.map((command) => command.name), ['splash']);
    expect(kernel.mode.options.map((option) => option.id), ['plan', 'bypass']);
    expect(kernel.mode.selected, 'plan');

    kernel.send(const KernelTurn(id: 'turn-1', text: 'hello'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(kernel.sessionId, 'acp_mock_session');
    expect(kernel.commands.single.name, 'splash');
    expect(kernel.mode.options.map((option) => option.id), ['plan', 'bypass']);
    kernel.mode.select('bypass');
    expect(
      transport.written.any(
        (message) => message['method'] == 'session/set_mode',
      ),
      isTrue,
    );
    expect(
      transport.written.map((message) => message['method']),
      containsAll(<Object?>['initialize', 'session/new', 'session/prompt']),
    );
    expect(events.whereType<TurnStarted>().single.turnId, 'turn-1');
    final user = events.whereType<ItemUpserted>().singleWhere(
      (event) => event.id == 'turn-1',
    );
    expect(user.item, isA<UserMessageItem>());
    expect((user.item as UserMessageItem).text, 'hello');
    expect(events.whereType<TextDelta>().single.text, 'Echo: hello');
    expect(
      events
          .whereType<ItemUpserted>()
          .where((event) {
            return event.item is AssistantTextItem;
          })
          .single
          .id,
      'acp_message_1_1',
    );

    kernel.send(const KernelTurn(id: 'turn-2', text: 'again'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      events
          .whereType<ItemUpserted>()
          .where((event) {
            return event.item is AssistantTextItem &&
                event.id.startsWith('acp_message_2_');
          })
          .single
          .id,
      'acp_message_2_2',
    );
    expect(
      events
          .whereType<ItemUpserted>()
          .where((event) => event.id == 'turn-2')
          .single
          .item,
      isA<UserMessageItem>(),
    );
    expect(events.whereType<UsageReported>().first.usage.used, 4200);
    expect(events.whereType<UsageReported>().first.usage.window, 200000);
    expect(kernel.contextWindow, 200000);
    expect(events.whereType<TurnEnded>().map((event) => event.turnId), [
      'turn-1',
      'turn-2',
    ]);

    await subscription.cancel();
    kernel.dispose();
  });

  test('ACP session/load replays history as separate turns', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      KernelContext(
        cwd: '/tmp/project',
        resume: SessionRecord(
          id: 'sess_history',
          title: 'Earlier',
          updatedAt: DateTime.utc(2026, 10, 9),
          cwd: '/tmp/project',
        ),
      ),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      transport.written.any((message) => message['method'] == 'session/load'),
      isTrue,
    );
    expect(
      transport.written.any((message) => message['method'] == 'session/new'),
      isFalse,
    );
    final users = events
        .whereType<ItemUpserted>()
        .where((event) => event.item is UserMessageItem)
        .map((event) => (event.item as UserMessageItem).text)
        .toList();
    final answers = events
        .whereType<ItemUpserted>()
        .where((event) => event.item is AssistantTextItem)
        .map((event) => event.id)
        .toList();
    expect(users, ['first question', 'second question']);
    expect(answers, hasLength(2));
    expect(answers.first, isNot(answers.last));
    expect(events.whereType<TurnStarted>().length, 2);

    await subscription.cancel();
    kernel.dispose();
  });

  test(
    'ACP permission shows agent option names and keeps JSON-RPC id',
    () async {
      final transport = MockAcpTransport();
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(cwd: '/tmp/project'),
        (_) async => transport,
      );
      final events = <KernelEvent>[];
      final subscription = kernel.events.listen(events.add);

      kernel.send(const KernelTurn(id: 'turn-perm', text: 'need-permission'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final requested = events.whereType<InteractionRequested>().single;
      expect(requested.request, isA<QuestionRequest>());
      final question = requested.request as QuestionRequest;
      expect(question.title, 'Run ls');
      expect(question.questions.single.options.map((o) => o.label), [
        'Allow once',
        'Allow always',
        'Reject',
      ]);

      kernel.answer(
        question.id,
        const QuestionAnswer([
          ['Allow once'],
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final reply = transport.written.lastWhere(
        (message) => message.containsKey('result') && message['id'] == 42,
      );
      expect(reply['id'], 42);
      expect(reply['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'opt_allow'},
      });
      expect(
        events.whereType<InteractionResolved>().single.requestId,
        question.id,
      );

      await subscription.cancel();
      kernel.dispose();
    },
  );

  test('ACP skip maps to reject_once option instead of cancelled', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.send(const KernelTurn(id: 'turn-deny', text: 'need-permission'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final question =
        events.whereType<InteractionRequested>().single.request
            as QuestionRequest;

    kernel.answer(question.id, const QuestionAnswer([], skipped: true));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final reply = transport.written.lastWhere(
      (message) => message.containsKey('result') && message['id'] == 42,
    );
    expect(reply['result'], {
      'outcome': {'outcome': 'selected', 'optionId': 'opt_reject'},
    });

    await subscription.cancel();
    kernel.dispose();
  });

  test('ACP plan session updates replace the todo list', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // ACP v1: sessionUpdate "plan", entries at the top level.
    transport.notify({
      'sessionUpdate': 'plan',
      'entries': [
        {
          'content': 'Analyze the existing codebase structure',
          'priority': 'high',
          'status': 'pending',
        },
        {
          'content': 'Create unit tests',
          'priority': 'medium',
          'status': 'in_progress',
        },
      ],
    });
    // ACP v2 draft: sessionUpdate "plan_update", entries under plan.
    // A later update replaces the whole list, including cancelled.
    transport.notify({
      'sessionUpdate': 'plan_update',
      'plan': {
        'type': 'items',
        'planId': 'plan-1',
        'entries': [
          {
            'content': 'Analyze the existing codebase structure',
            'priority': 'high',
            'status': 'completed',
          },
          {
            'content': 'Create unit tests',
            'priority': 'medium',
            'status': 'cancelled',
          },
        ],
      },
    });

    // Papercode sends sessionUpdate "todo_update" with id'd todos, not plan.
    transport.notify({
      'sessionUpdate': 'todo_update',
      'todos': [
        {
          'id': '1',
          'content': 'Analyze the existing codebase structure',
          'status': 'pending',
          'priority': 'high',
        },
        {
          'id': '2',
          'content': 'Create unit tests',
          'status': 'in_progress',
          'activeForm': 'Writing tests',
        },
      ],
    });

    final reports = events.whereType<TodosReported>().toList();
    expect(reports, hasLength(3));
    expect(reports.first.todos.map((todo) => todo.status), [
      TodoStatus.pending,
      TodoStatus.inProgress,
    ]);
    expect(reports[1].todos.map((todo) => (todo.content, todo.status)), [
      ('Analyze the existing codebase structure', TodoStatus.completed),
      ('Create unit tests', TodoStatus.pending),
    ]);
    expect(reports.last.todos.map((todo) => (todo.content, todo.status)), [
      ('Analyze the existing codebase structure', TodoStatus.pending),
      ('Create unit tests', TodoStatus.inProgress),
    ]);
    expect(reports.last.todos.last.activeForm, 'Writing tests');

    // Papercode wraps the todo_write result as nested ACP content. The text
    // is JSON `{ok, todos}` and history replay may not send todo_update.
    transport.notify({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'todo_write',
      'kind': 'other',
      'title': '更新待办',
      'status': 'completed',
      'content': [
        {
          'type': 'content',
          'content': {
            'type': 'text',
            'text': '{"ok":true,"todos":[{"id":"1","content":"Wire ACP","status":"in_progress","activeForm":"Wiring ACP"}],"message":"todos updated: 1 total"}',
          },
        },
      ],
    });
    expect(
      events.whereType<TodosReported>().last.todos.single.content,
      'Wire ACP',
    );
    expect(
      events.whereType<TodosReported>().last.todos.single.status,
      TodoStatus.inProgress,
    );
    expect(
      events.whereType<TodosReported>().last.todos.single.activeForm,
      'Wiring ACP',
    );

    await subscription.cancel();
    kernel.dispose();
  });

  test(
    'ACP command tasks retain parallel calls, output and patch state',
    () async {
      final transport = MockAcpTransport();
      final kernel = AcpKernel(
        descriptor(),
        const KernelContext(),
        (_) async => transport,
      );
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final subscription = kernel.events.listen(events.add);
      addTearDown(subscription.cancel);
      kernel.prepare();
      await pumpEventQueue();

      for (final kind in ['execute', 'Bash', 'shell', 'command', 'terminal']) {
        transport.notify({
          'sessionUpdate': 'tool_call',
          'toolCallId': kind,
          'title': 'Run $kind',
          'kind': kind,
          'status': 'in_progress',
          'rawInput': {'command': 'echo $kind'},
        });
      }
      transport.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'named',
        'title': 'Named Bash tool',
        'kind': 'other',
        'toolName': 'Bash',
      });
      final initial = events.whereType<TasksReported>().last.tasks;
      expect(initial, hasLength(6));
      for (final task in initial) {
        expect(task.kind, KernelTaskKind.command);
        expect(task.toolUseId, task.id);
        expect(task.background, isTrue);
        expect(task.canStop, isFalse);
        expect(task.copyWith(status: CommandStatus.succeeded).canStop, isFalse);
      }
      expect(kernel, isNot(isA<RunsBackgroundTasks>()));

      transport.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'execute',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'first output'},
          },
        ],
      });
      transport.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'execute',
        'status': 'completed',
      });
      transport.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'Bash',
        'status': 'failed',
        'rawOutput': 'command failed',
      });
      transport.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'read',
        'title': 'Read a file',
        'kind': 'read',
      });
      final tasks = events.whereType<TasksReported>().last.tasks;
      expect(tasks, hasLength(7));
      expect(tasks.first.startedAt, initial.first.startedAt);
      expect(tasks.first.kind, KernelTaskKind.command);
      expect(tasks.first.status, CommandStatus.succeeded);
      expect(tasks.first.summary, 'first output');
      expect(tasks[1].status, CommandStatus.failed);
      expect(tasks[1].summary, 'command failed');
      expect(tasks.last.kind, KernelTaskKind.other);
    },
  );

  test('ACP plan variants with items/description still become todos', () async {
    final transport = MockAcpTransport();
    final kernel = AcpKernel(
      descriptor(),
      const KernelContext(cwd: '/tmp/project'),
      (_) async => transport,
    );
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);

    kernel.prepare();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Some agents nest under plan.items and use description / TitleCase status.
    transport.notify({
      'sessionUpdate': 'plan',
      'plan': {
        'items': [
          {
            'description': 'Inspect ACP plan updates',
            'priority': 'high',
            'status': 'InProgress',
          },
          {'title': 'Show TodoPanel above composer', 'status': 'PENDING'},
        ],
      },
    });
    // plan as a bare list of strings.
    transport.notify({
      'sessionUpdate': 'plan',
      'plan': ['First step', 'Second step'],
    });

    final reports = events.whereType<TodosReported>().toList();
    expect(reports, hasLength(2));
    expect(reports.first.todos.map((todo) => (todo.content, todo.status)), [
      ('Inspect ACP plan updates', TodoStatus.inProgress),
      ('Show TodoPanel above composer', TodoStatus.pending),
    ]);
    expect(reports.last.todos.map((todo) => todo.content), [
      'First step',
      'Second step',
    ]);

    await subscription.cancel();
    kernel.dispose();
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/agent_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/agent_step.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/panels/todo_panel.dart';
import 'package:baocode/chat/widgets/step_header.dart';
import 'package:baocode/chat/widgets/tool_call_row.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements AcpTransport {
  _Transport({this.fixture});

  final List<Map<String, Object?>>? fixture;

  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  void update(Map<String, Object?> update, {String sessionId = 'session'}) =>
      _messages.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'sessionId': sessionId, 'update': update},
      });

  void text(String kind, String text, {String? messageId}) => update({
    'sessionUpdate': kind,
    'content': {'type': 'text', 'text': text},
    'messageId': ?messageId,
  });

  void history() {
    if (fixture case final messages?) {
      for (final message in messages) {
        _messages.add(message);
      }
      return;
    }
    text('user_message_chunk', 'First question', messageId: 'hist_user_0');
    text(
      'agent_thought_chunk',
      'Thought about the first answer',
      messageId: 'hist_agent_1',
    );
    text('agent_message_chunk', 'First answer', messageId: 'hist_agent_1');
    update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'todo',
      'kind': 'other',
      'rawInput': {
        'name': 'todo_write',
        'arguments': jsonEncode({
          'todos': [
            {'id': 'a', 'content': 'Replay task', 'status': 'pending'},
          ],
        }),
      },
    });
    text('agent_message_chunk', 'Follow-up answer', messageId: 'hist_agent_1');
    text('user_message_chunk', 'Second question', messageId: 'hist_user_3');
    text(
      'agent_thought_chunk',
      'Thought about the second answer',
      messageId: 'hist_agent_4',
    );
    text('agent_message_chunk', 'Second answer', messageId: 'hist_agent_4');
  }

  @override
  void write(Map<String, Object?> message) {
    final method = message['method'];
    if (method == 'session/load' || method == 'session/prompt') history();
    _messages.add({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': switch (method) {
        'initialize' => {'protocolVersion': 1},
        'session/new' => {'sessionId': 'session'},
        'session/prompt' => {'stopReason': 'end_turn'},
        _ => <String, Object?>{},
      },
    });
  }

  @override
  Future<void> close() => _messages.close();
}

Future<ChatSession> _pump(
  WidgetTester tester,
  _Transport transport, {
  bool resume = false,
  bool listenAboveChat = false,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: 'acp-test',
    label: 'ACP test',
    icon: Icons.hub,
    description: '',
    create: (context) => AcpKernel(descriptor, context, (_) async => transport),
  );
  final session = ChatSession(
    kernel: descriptor,
    kernels: [descriptor],
    historyCount: 0,
    kernelContext: KernelContext(
      resume: resume
          ? SessionRecord(
              id: 'session',
              title: 'History',
              updatedAt: DateTime.utc(2026),
              cwd: '',
            )
          : null,
    ),
  );
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: listenAboveChat
          ? ListenableBuilder(
              listenable: session,
              builder: (context, child) => ChatScreen(session: session),
            )
          : ChatScreen(session: session),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  return session;
}

ToolCallItem _tool(ChatSession session, String id) => [
  for (var i = 0; i < session.itemCount; i++)
    if (session.itemAt(i) case final ToolCallItem tool when tool.callId == id)
      tool,
].single;

String _pretty(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

void main() {
  for (final legacy in [false, true]) {
    testWidgets(
      'native ACP card opens child session and returns (legacy: $legacy)',
      (tester) async {
        final transport = _Transport();
        final session = await _pump(tester, transport);
        transport.update(
          legacy
              ? {
                  'sessionUpdate': 'subagent_spawned',
                  'subagentSessionId': 'child',
                  'name': 'Investigate tests',
                  'task': 'Find failing tests',
                  'capabilities': {},
                }
              : {
                  'sessionUpdate': 'subagent_update',
                  'sessionId': 'child',
                  'title': 'Investigate tests',
                  'description': 'Test investigator',
                  'state': {'state': 'running'},
                },
        );
        transport.update({
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': 'Child conversation'},
        }, sessionId: 'child');
        await tester.pump();
        final card = tester.widget<AgentStep>(find.byType(AgentStep));
        expect(card.item.description, 'Investigate tests');
        expect(card.onStop, isNull);
        await tester.tap(find.byType(AgentStep));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(SubagentHeader), findsOneWidget);
        expect(session.openAgents, [card.item.id]);
        expect(
          find.text('Child conversation', findRichText: true),
          findsOneWidget,
        );
        if (legacy) {
          expect(
            find.text('Find failing tests', findRichText: true),
            findsOneWidget,
          );
        }
        transport.update(
          legacy
              ? {
                  'sessionUpdate': 'subagent_state_update',
                  'subagentSessionId': 'child',
                  'state': 'completed',
                }
              : {
                  'sessionUpdate': 'subagent_update',
                  'sessionId': 'child',
                  'state': {'state': 'idle', 'stopReason': 'end_turn'},
                },
        );
        await tester.pump();
        await tester.tap(
          find.descendant(
            of: find.byType(SubagentHeader),
            matching: find.text('Conversation'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(session.openAgents, isEmpty);
        expect(
          tester.widget<AgentStep>(find.byType(AgentStep)).item.status,
          CommandStatus.succeeded,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'ACP delegation card opens its live child conversation and returns',
    (tester) async {
      final transport = _Transport();
      final session = await _pump(tester, transport);
      transport.update({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'explore',
        'name': 'Task',
        'kind': 'other',
        'title': 'Explore source',
        'rawInput': {
          'description': 'Inspect project',
          'prompt': 'Find the entry point',
        },
      });
      transport.update({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'Reading the source'},
        '_meta': {
          'claudeCode': {'parentToolUseId': 'explore'},
        },
      });
      await tester.pump();
      expect(find.byType(AgentStep), findsOneWidget);
      final card = tester.widget<AgentStep>(find.byType(AgentStep));
      expect(card.item.description, 'Inspect project');
      expect(card.onStop, isNull);
      expect(card.onMoveToBackground, isNull);
      await tester.tap(find.byType(AgentStep));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SubagentHeader), findsOneWidget);
      expect(session.openAgents, ['explore']);
      expect(
        find.textContaining('Find the entry point', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('Reading the source', findRichText: true),
        findsOneWidget,
      );

      transport.update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'explore',
        'status': 'completed',
        'rawOutput': 'Entry point found',
      });
      await tester.pump();
      expect(
        find.textContaining('Entry point found', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SubagentHeader),
          matching: find.text('Conversation'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(session.openAgents, isEmpty);
      expect(find.byType(SubagentHeader), findsNothing);
      expect(find.byType(AgentStep), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ACP tool expands input and output, retaining details across patches',
    (tester) async {
      final transport = _Transport();
      final session = await _pump(tester, transport);
      const input = {'command': 'printf hello', 'cwd': '/project with spaces'};
      transport.update({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'run',
        'title': 'Inspect project',
        'kind': 'execute',
        'status': 'pending',
        'rawInput': input,
      });
      await tester.pump();
      final row = find.byType(ToolCallRow);
      final header = find.descendant(
        of: row,
        matching: find.byType(StepHeader),
      );
      expect(row, findsOneWidget);
      expect(find.text(_pretty(input)), findsNothing);
      expect(_tool(session, 'run').detail, isNull);
      await tester.tap(header);
      await tester.pump();
      expect(find.text('Input'), findsOneWidget);
      expect(find.text(_pretty(input)), findsOneWidget);
      expect(find.text('Waiting for output'), findsOneWidget);
      const output = {'stdout': 'hello', 'exitCode': 0};
      transport.update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'run',
        'status': 'completed',
        'rawOutput': output,
      });
      await tester.pump();
      expect(_tool(session, 'run').target, 'Inspect project');
      expect(_tool(session, 'run').details?.input, _pretty(input));
      expect(_tool(session, 'run').details?.output, _pretty(output));
      expect(find.text(_pretty(output)), findsOneWidget);
      transport.update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'run',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'Command completed'},
          },
        ],
      });
      await tester.pump();
      expect(_tool(session, 'run').status, ToolStatus.succeeded);
      expect(find.text(_pretty(input)), findsOneWidget);
      expect(find.text(_pretty(output)), findsOneWidget);
      expect(find.text('Returned content'), findsOneWidget);
      expect(find.text('Command completed'), findsOneWidget);
      await tester.tap(header);
      await tester.pump();
      expect(find.text(_pretty(input)), findsNothing);
      expect(find.text(_pretty(output)), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ACP content output preserves block boundaries and structured blocks',
    (tester) async {
      final transport = _Transport();
      final session = await _pump(tester, transport);
      const diff = {
        'type': 'diff',
        'path': '/project/a.dart',
        'oldText': 'before',
        'newText': 'after',
      };
      const resource = {
        'type': 'content',
        'content': {
          'type': 'resource',
          'resource': {
            'uri': 'file:///project/result.txt',
            'mimeType': 'text/plain',
            'text': 'Resource body',
          },
        },
      };
      const input = {'path': '/project/a.dart'};
      transport.update({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'edit',
        'kind': 'edit',
        'title': 'Update source',
        'raw_input': jsonEncode(input),
      });
      transport.update({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'edit',
        'status': 'completed',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'First block'},
          },
          {'type': 'text', 'text': 'Second block'},
          diff,
          resource,
        ],
      });
      await tester.pump();
      final content = [
        'First block',
        'Second block',
        _pretty(diff),
        _pretty(resource),
      ].join(String.fromCharCodes([10, 10]));
      final tool = _tool(session, 'edit');
      expect(tool.kind, ToolKind.edit);
      expect(tool.details?.input, _pretty(input));
      expect(tool.details?.content, content);
      expect(tool.output, content);
      await tester.tap(
        find.descendant(
          of: find.byType(ToolCallRow),
          matching: find.byType(StepHeader),
        ),
      );
      await tester.pump();
      expect(find.text('Output'), findsOneWidget);
      expect(find.text(content), findsOneWidget);
      expect(find.byType(SelectableText), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('ACP missing payloads and failed calls remain expandable', (
    tester,
  ) async {
    final transport = _Transport();
    final session = await _pump(tester, transport);
    transport.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'missing',
      'title': 'Unavailable details',
    });
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ToolCallRow),
        matching: find.byType(StepHeader),
      ),
    );
    await tester.pump();
    expect(
      find.text('The agent did not provide input details.'),
      findsOneWidget,
    );
    expect(find.text('Waiting for output'), findsOneWidget);
    transport.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'missing',
      'status': 'failed',
      'input': <String, Object?>{},
      'raw_output': 'Permission denied',
    });
    await tester.pump();
    expect(_tool(session, 'missing').status, ToolStatus.failed);
    expect(find.text('{}'), findsOneWidget);
    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.text('Waiting for output'), findsNothing);
    transport.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'missing',
      'rawInput': null,
      'rawOutput': null,
      'content': [],
    });
    await tester.pump();
    expect(_tool(session, 'missing').status, ToolStatus.failed);
    // ACP null fields are no-op patches, not requests to erase payloads.
    expect(find.text('{}'), findsOneWidget);
    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.text('Output unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ACP replayed tool details expand like live calls', (
    tester,
  ) async {
    const input = {'path': '/project/历史.txt'};
    final transport = _Transport(
      fixture: [
        for (final update in <Map<String, Object?>>[
          {
            'sessionUpdate': 'tool_call',
            'toolCallId': 'history-tool',
            'title': 'Read history file',
            'kind': 'read',
            'rawInput': input,
          },
          {
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 'history-tool',
            'status': 'completed',
            'rawOutput': '历史输出',
          },
        ])
          {
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': {'sessionId': 'session', 'update': update},
          },
      ],
    );
    final session = await _pump(tester, transport, resume: true);
    final tool = _tool(session, 'history-tool');
    expect(tool.target, 'Read history file');
    expect(tool.kind, ToolKind.read);
    expect(tool.status, ToolStatus.succeeded);
    expect(tool.details?.input, _pretty(input));
    expect(find.text('历史输出'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(ToolCallRow),
        matching: find.byType(StepHeader),
      ),
    );
    await tester.pump();
    expect(find.text(_pretty(input)), findsOneWidget);
    expect(find.text('历史输出'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ACP can mount below an existing session listener', (
    tester,
  ) async {
    await _pump(tester, _Transport(), listenAboveChat: true);
    expect(tester.takeException(), isNull);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('actual solcode replay preserves every reply in arrival order', (
    tester,
  ) async {
    final messages = (jsonDecode(
      File('test/kernel/acp_history_fixture.json').readAsStringSync(),
    ) as List).map((item) => (item as Map).cast<String, Object?>()).toList();
    // Use the test session id without changing the notification contents.
    for (final message in messages) {
      (message['params'] as Map)['sessionId'] = 'session';
    }
    final session = await _pump(
      tester,
      _Transport(fixture: messages),
      resume: true,
    );
    final expected = [
      for (final message in messages)
        if ((message['params'] as Map)['update'] case final Map update)
          if (update['sessionUpdate'] == 'user_message_chunk' ||
              update['sessionUpdate'] == 'agent_message_chunk')
            (update['content'] as Map)['text'],
    ];
    final actual = [
      for (var i = 0; i < session.itemCount; i++)
        switch (session.itemAt(i)) {
          UserMessageItem(:final text) => text,
          AssistantTextItem(:final text) => text,
          _ => null,
        },
    ].whereType<String>().toList();
    expect(actual, expected);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('todo tool arguments update the mounted chat panel', (
    tester,
  ) async {
    final transport = _Transport();
    final session = await _pump(tester, transport);
    transport.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'todo-1',
      'kind': 'other',
      'rawInput': {
        'name': 'TodoWrite',
        'arguments': jsonEncode({
          'todos': [
            {
              'id': '1',
              'content': 'Check panel',
              'status': 'in_progress',
              'activeForm': 'Checking panel',
            },
          ],
        }),
      },
    });
    await tester.pump();
    expect(session.todos.single.status, TodoStatus.inProgress);
    expect(find.byType(TodoPanel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TodoPanel),
        matching: find.text('Checking panel'),
      ),
      findsOneWidget,
    );

    transport.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'todo-1',
      'status': 'completed',
      'rawOutput': {
        'ok': true,
        'todos': [
          {'id': '1', 'content': 'Check panel', 'status': 'completed'},
        ],
      },
    });
    await tester.pump();
    expect(session.todos.single.status, TodoStatus.completed);
    expect(find.byType(TodoPanel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TodoPanel),
        matching: find.text('Check panel'),
      ),
      findsOneWidget,
    );

    transport.update({'sessionUpdate': 'todo_update', 'todos': <Object?>[]});
    await tester.pump();
    expect(find.byType(TodoPanel), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ACP plan session update mounts TodoPanel above composer', (
    tester,
  ) async {
    final transport = _Transport();
    final session = await _pump(tester, transport);
    expect(find.byType(TodoPanel), findsNothing);

    transport.update({
      'sessionUpdate': 'plan',
      'entries': [
        {
          'content': 'Analyze the existing codebase structure',
          'priority': 'high',
          'status': 'pending',
        },
        {
          'content': 'Identify components that need refactoring',
          'priority': 'high',
          'status': 'in_progress',
        },
      ],
    });
    await tester.pump();

    expect(session.todos, hasLength(2));
    expect(find.byType(TodoPanel), findsOneWidget);
    expect(
      find.text('Analyze the existing codebase structure'),
      findsOneWidget,
    );
    expect(
      find.text('Identify components that need refactoring'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('assistant text after a tool stays after the tool', (
    tester,
  ) async {
    final transport = _Transport();
    final session = await _pump(tester, transport);
    transport.text('agent_message_chunk', 'Before ');
    transport.text('agent_message_chunk', 'tool');
    transport.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'read-1',
      'title': 'Read file',
      'kind': 'read',
    });
    transport.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'read-1',
      'status': 'completed',
    });
    transport.text('agent_message_chunk', 'After ');
    transport.text('agent_message_chunk', 'tool');
    await tester.pump();
    final items = [
      for (var i = 0; i < session.itemCount; i++) session.itemAt(i),
    ];
    expect(items, hasLength(3));
    expect((items[0] as AssistantTextItem).text, 'Before tool');
    expect(items[1], isA<ToolCallItem>());
    expect((items[2] as AssistantTextItem).text, 'After tool');
    expect(session.todos, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final resume in [false, true]) {
    testWidgets(
      'history keeps replies separate via ${resume ? 'session/load' : '/sessions'}',
      (tester) async {
        final session = await _pump(tester, _Transport(), resume: resume);
        if (!resume) {
          session.send(const ComposerMessage(text: '/sessions'));
          await tester.pump(const Duration(milliseconds: 50));
        }
        final items = [
          for (var i = 0; i < session.itemCount; i++) session.itemAt(i),
        ];
        expect(items.whereType<AssistantTextItem>().map((item) => item.text), [
          'First answer',
          'Follow-up answer',
          'Second answer',
        ]);
        final messages = items
            .where(
              (item) => item is UserMessageItem || item is AssistantTextItem,
            )
            .map(
              (item) => switch (item) {
                UserMessageItem(:final text) => text,
                AssistantTextItem(:final text) => text,
                _ => '',
              },
            )
            .toList();
        expect(
          messages,
          containsAllInOrder([
            'First question',
            'First answer',
            'Follow-up answer',
            'Second question',
            'Second answer',
          ]),
        );
        // ACP/Zed: render in arrival order. Thought and message share a
        // messageId but are different kinds, so they stay separate items.
        final firstAnswer = items.indexWhere(
          (item) => item is AssistantTextItem && item.text == 'First answer',
        );
        final firstThought = items.indexWhere(
          (item) =>
              item is ThinkingItem &&
              item.text == 'Thought about the first answer',
        );
        final followUp = items.indexWhere(
          (item) =>
              item is AssistantTextItem && item.text == 'Follow-up answer',
        );
        final secondQuestion = items.indexWhere(
          (item) => item is UserMessageItem && item.text == 'Second question',
        );
        expect(firstAnswer, greaterThanOrEqualTo(0));
        expect(firstThought, greaterThanOrEqualTo(0));
        expect(firstThought, lessThan(firstAnswer));
        expect(followUp, greaterThan(firstAnswer));
        expect(secondQuestion, greaterThan(followUp));
        expect(session.isStreaming, isFalse);
        expect(find.byType(TodoPanel), findsOneWidget);
        expect(find.text('First answer'), findsOneWidget);
        expect(find.text('Follow-up answer'), findsOneWidget);
        expect(find.text('Second answer'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

import 'dart:async';
import 'dart:io';

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

const _session = 'acp_mock_session';
Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out awaiting terminal event');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Transport extends MockAcpTransport {
  _Transport() {
    _subscription = super.messages.listen(
      _messages.add,
      onDone: _messages.close,
    );
  }
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  late final StreamSubscription<Map<String, Object?>> _subscription;
  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  void request(Object id, String method, Map<String, Object?> params) =>
      _messages.add({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
  void update(String session, Map<String, Object?> update) => _messages.add({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'sessionId': session, 'update': update},
  });
  @override
  Future<void> close() async {
    await super.close();
    await _subscription.cancel();
    await _messages.close();
  }
}

class _Harness {
  _Harness(this.root, {String? cwd}) {
    final descriptor = KernelDescriptor(
      id: 'term-test',
      label: 'ACP',
      icon: Icons.hub,
      description: '',
      create: (_) => kernel,
    );
    kernel = AcpKernel(
      descriptor,
      KernelContext(cwd: cwd ?? root.path),
      (_) async => transport,
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
  final Directory root;
  final transport = _Transport();
  final events = <KernelEvent>[];
  late final AcpKernel kernel;
  late final ChatSession session;
  late final StreamSubscription<KernelEvent> subscription;
  int _next = 1000;
  Future<void> start() async {
    kernel.prepare();
    await pumpEventQueue();
  }

  Object request(
    String method,
    Map<String, Object?> params, {
    String session = _session,
  }) {
    final id = _next++;
    transport.request(id, method, {'sessionId': session, ...params});
    return id;
  }

  Future<Map<String, Object?>> response(Object id) async {
    await _until(() => transport.written.any((m) => m['id'] == id));
    return transport.written.firstWhere((m) => m['id'] == id);
  }

  Future<String> create(
    String script, {
    String session = _session,
    Map<String, Object?> extra = const {},
  }) async {
    final before = events.whereType<InteractionRequested>().length;
    final id = request('terminal/create', {
      'command': '/bin/sh',
      'args': ['-c', script],
      ...extra,
    }, session: session);
    await _until(
      () => events.whereType<InteractionRequested>().length > before,
    );
    kernel.answer(
      events.whereType<InteractionRequested>().last.request.id,
      const ApprovalAnswer(ApprovalDecision.allowOnce),
    );
    final result = await response(id);
    expect(result['error'], isNull, reason: '$result');
    return (result['result'] as Map)['terminalId'] as String;
  }

  List<KernelTask> get tasks => events.whereType<TasksReported>().last.tasks;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('baocode-acp-terminal-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
  });

  test(
    'terminal creation preserves assistant ordering in root and child feeds',
    () async {
      final h = _Harness(root);
      await h.start();
      void text(String session, String value) => h.transport.update(session, {
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'm',
        'content': {'type': 'text', 'text': value},
      });
      text(_session, 'before');
      final rootTerminal = await h.create('sleep 0.1');
      text(_session, 'after');
      h.transport.notify({
        'sessionUpdate': 'subagent_update',
        'sessionId': 'child',
        'state': {'state': 'running'},
      });
      text('child', 'child before');
      await h.create('sleep 0.1', session: 'child');
      text('child', 'child after');
      await pumpEventQueue();
      final roots = [
        for (var i = 0; i < h.session.itemCount; i++) h.session.itemAt(i),
      ];
      expect(roots.whereType<AssistantTextItem>().map((i) => i.text), [
        'before',
        'after',
      ]);
      expect(roots.indexWhere((i) => i is ToolCallItem), 1);
      final childTask = h.tasks.firstWhere(
        (t) => t.kind == KernelTaskKind.agent,
      );
      final agent = h.session.agentOf(childTask)!.agent;
      expect(agent.children.map((i) => i.runtimeType), [
        AssistantTextItem,
        ToolCallItem,
        AssistantTextItem,
      ]);
      await h.response(
        h.request('terminal/wait_for_exit', {'terminalId': rootTerminal}),
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'cancellation after approval cannot launch a command on the next turn',
    () async {
      final h = _Harness(root);
      await h.start();
      final request = h.request('terminal/create', {
        'command': '/bin/sh',
        'args': ['-c', 'echo should-not-run'],
      });
      await _until(() => h.events.whereType<InteractionRequested>().isNotEmpty);
      final approval = h.events
          .whereType<InteractionRequested>()
          .last
          .request
          .id;
      h.kernel.answer(
        approval,
        const ApprovalAnswer(ApprovalDecision.allowOnce),
      );
      h.kernel.cancel();
      h.kernel.send(const KernelTurn(id: 'next-turn', text: 'new request'));
      expect((await h.response(request))['error'], isNotNull);
      expect(
        h.transport.written.where(
          (m) =>
              m['result'] is Map &&
              (m['result'] as Map).containsKey('terminalId'),
        ),
        isEmpty,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'literal command args and explicit env are passed without an extra shell',
    () async {
      final h = _Harness(root);
      await h.start();
      final marker = File('${root.path}/not-created');
      final literal = await h.create(
        '',
        extra: {
          'command': '/bin/echo',
          'args': ['\$(touch "${marker.path}")'],
        },
      );
      await h.response(
        h.request('terminal/wait_for_exit', {'terminalId': literal}),
      );
      expect(await marker.exists(), isFalse);
      final result =
          (await h.response(
                h.request('terminal/output', {'terminalId': literal}),
              ))['result']
              as Map;
      expect(result['output'], contains(r'$(touch'));
      final env = await h.create(
        r'printf "%s" "$ACP_TEST_ENV"',
        extra: {
          'env': [
            {'name': 'ACP_TEST_ENV', 'value': 'explicit-value'},
          ],
        },
      );
      await h.response(
        h.request('terminal/wait_for_exit', {'terminalId': env}),
      );
      final output =
          (await h.response(
                h.request('terminal/output', {'terminalId': env}),
              ))['result']
              as Map;
      expect(output['output'], 'explicit-value');
    },
    skip: Platform.isWindows,
  );

  test(
    'approved missing executable fails without leaving a running task',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = h.request('terminal/create', {
        'command': '${root.path}/not-an-executable',
      });
      await _until(() => h.events.whereType<InteractionRequested>().isNotEmpty);
      h.kernel.answer(
        h.events.whereType<InteractionRequested>().last.request.id,
        const ApprovalAnswer(ApprovalDecision.allowOnce),
      );
      expect((await h.response(id))['error'], isNotNull);
      expect(h.events.whereType<TasksReported>(), isEmpty);
    },
  );

  test(
    'released running command ends pending waits and preserves final display',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create('printf retained; sleep 30');
      final waiting = h.request('terminal/wait_for_exit', {'terminalId': id});
      expect(
        (await h.response(
          h.request('terminal/release', {'terminalId': id}),
        ))['result'],
        isEmpty,
      );
      expect((await h.response(waiting))['result'], isNotNull);
      expect(h.tasks.single.status, CommandStatus.failed);
      expect(h.tasks.single.summary, contains('retained'));
      expect(h.session.stopOf(h.tasks.single.toolUseId), isNull);
    },
    skip: Platform.isWindows,
  );

  test(
    'terminal stays alive beyond the prompt response and supports UI stop',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create('sleep 30');
      h.kernel.send(
        const KernelTurn(id: 'turn', text: 'continue while the command runs'),
      );
      await pumpEventQueue();
      expect(h.events.whereType<TurnEnded>(), isNotEmpty);
      final task = h.tasks.firstWhere((task) => task.id == id);
      expect(task.status, CommandStatus.running);
      expect(h.session.moveToBackgroundOf(task.toolUseId), isNull);
      expect(h.session.stopOf(task.toolUseId), isNotNull);
      h.session.stopOf(task.toolUseId)!();
      await h.response(h.request('terminal/wait_for_exit', {'terminalId': id}));
      expect(
        h.tasks.firstWhere((task) => task.id == id).status,
        CommandStatus.failed,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'Claude metadata can attach a root-owned terminal inside a child feed',
    () async {
      final h = _Harness(root);
      await h.start();
      h.transport.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'delegate',
        'name': 'Task',
        'rawInput': {'description': 'Explore'},
      });
      final id = await h.create('printf child-output');
      h.transport.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'child-shell',
        'kind': 'execute',
        'content': [
          {'type': 'terminal', 'terminalId': id},
        ],
        '_meta': {
          'claudeCode': {'parentToolUseId': 'delegate'},
        },
      });
      await h.response(h.request('terminal/wait_for_exit', {'terminalId': id}));
      await pumpEventQueue();
      final feed = SubagentFeed(h.session, ['delegate']);
      addTearDown(feed.dispose);
      expect(
        feed.agent!.children.whereType<ToolCallItem>().single.output,
        'child-output',
      );
      expect(
        h.tasks.firstWhere((task) => task.id == id).toolUseId,
        'child-shell',
      );
      final roots = [
        for (var i = 0; i < h.session.itemCount; i++) h.session.itemAt(i),
      ];
      expect(roots.whereType<ToolCallItem>(), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test(
    'replacing a terminal block detaches it without losing terminal history',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create('printf kept');
      h.transport.notify({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'tool',
        'kind': 'execute',
        'content': [
          {'type': 'terminal', 'terminalId': id},
        ],
      });
      await h.response(h.request('terminal/wait_for_exit', {'terminalId': id}));
      h.transport.notify({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool',
        'status': 'completed',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'summary'},
          },
        ],
      });
      await pumpEventQueue();
      expect(
        h.tasks.firstWhere((task) => task.id == id).toolUseId,
        'acp_terminal_item_$id',
      );
      final roots = [
        for (var i = 0; i < h.session.itemCount; i++) h.session.itemAt(i),
      ].whereType<ToolCallItem>();
      expect(
        roots.map((item) => item.output),
        containsAll(['kept', 'summary']),
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'a shell ignoring TERM is escalated to KILL with an exit signal',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create(
        'trap "" TERM; printf ready; while :; do sleep 1; done',
      );
      await _until(() => h.tasks.single.summary!.contains('ready'));
      await h.response(h.request('terminal/kill', {'terminalId': id}));
      final wait =
          (await h.response(
                h.request('terminal/wait_for_exit', {'terminalId': id}),
              ))['result']
              as Map;
      expect(wait['signal'], 'SIGKILL');
      expect(wait['exitCode'], isNull);
    },
    skip: Platform.isWindows,
  );

  test('local and remote terminal capabilities are declared', () async {
    final h = _Harness(root);
    await h.start();
    final init = h.transport.written.firstWhere(
      (m) => m['method'] == 'initialize',
    );
    expect(
      ((init['params'] as Map)['clientCapabilities'] as Map)['terminal'],
      isTrue,
    );
    final remote = _Harness(root, cwd: 'ssh://host/tmp/project');
    await remote.start();
    final remoteInit = remote.transport.written.firstWhere(
      (m) => m['method'] == 'initialize',
    );
    expect(
      ((remoteInit['params'] as Map)['clientCapabilities'] as Map)['terminal'],
      isTrue,
    );
  });

  test('create is asynchronous, captures both pipes, and waits for complete output', () async {
    final h = _Harness(root);
    await h.start();
    final id = await h.create(
      'printf early; sleep 0.2; printf late; printf error >&2; exit 7',
    );
    expect(h.tasks.single.status, CommandStatus.running);
    expect(h.tasks.single.canStop, isTrue);
    final output = await h.response(
      h.request('terminal/output', {'terminalId': id}),
    );
    expect((output['result'] as Map)['exitStatus'], isNull);
    final wait = await h.response(
      h.request('terminal/wait_for_exit', {'terminalId': id}),
    );
    expect((wait['result'] as Map)['exitCode'], 7);
    final finalOutput =
        (await h.response(
              h.request('terminal/output', {'terminalId': id}),
            ))['result']
            as Map;
    expect(finalOutput['output'], contains('early'));
    expect(finalOutput['output'], contains('late'));
    expect(finalOutput['output'], contains('error'));
    expect(finalOutput['truncated'], isFalse);
    expect(h.tasks.single.status, CommandStatus.failed);
    expect(h.tasks.single.canStop, isFalse);
  }, skip: Platform.isWindows);

  test(
    'approval includes args cwd env; denial never creates a process',
    () async {
      final h = _Harness(root);
      await h.start();
      final marker = File('${root.path}/denied');
      final request = h.request('terminal/create', {
        'command': '/bin/sh',
        'args': ['-c', 'touch "${marker.path}"'],
        'env': [
          {'name': 'TEST', 'value': 'visible'},
        ],
      });
      await _until(() => h.events.whereType<InteractionRequested>().isNotEmpty);
      final approval =
          h.events.whereType<InteractionRequested>().last.request
              as ApprovalRequest;
      expect((approval.preview as TextPreview).text, contains('visible'));
      expect((approval.preview as TextPreview).text, contains(root.path));
      expect(approval.alwaysAllowLabel, isNull);
      h.kernel.answer(approval.id, const ApprovalAnswer(ApprovalDecision.deny));
      expect((await h.response(request))['error'], isNotNull);
      expect(await marker.exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test(
    'cancel resolves pending local approvals and ignores late answers',
    () async {
      final h = _Harness(root);
      await h.start();
      final request = h.request('terminal/create', {
        'command': '/bin/sh',
        'args': ['-c', 'echo never'],
      });
      await _until(() => h.events.whereType<InteractionRequested>().isNotEmpty);
      final approval = h.events
          .whereType<InteractionRequested>()
          .last
          .request
          .id;
      h.kernel.cancel();
      h.kernel.answer(
        approval,
        const ApprovalAnswer(ApprovalDecision.allowOnce),
      );
      expect((await h.response(request))['error'], isNotNull);
      expect(h.events.whereType<InteractionResolved>(), hasLength(1));
      expect(h.events.whereType<TasksReported>(), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test('invalid session, paths, env and limits fail before approval', () async {
    final h = _Harness(root);
    await h.start();
    for (final params in <Map<String, Object?>>[
      {'command': 'echo', 'cwd': '/'},
      {'command': 'echo', 'cwd': 'relative'},
      {'command': ''},
      {
        'command': 'echo',
        'args': [1],
      },
      {
        'command': 'echo',
        'env': [
          {'name': 'BAD=NAME', 'value': 'x'},
        ],
      },
      {'command': 'echo', 'outputByteLimit': -1},
    ]) {
      expect(
        (await h.response(h.request('terminal/create', params)))['error'],
        isNotNull,
      );
    }
    expect(
      (await h.response(
        h.request('terminal/create', {
          'command': 'echo',
        }, session: 'unannounced'),
      ))['error'],
      isNotNull,
    );
    expect(h.events.whereType<InteractionRequested>(), isEmpty);
  });

  test('symlink cwd cannot escape workspace roots', () async {
    final outside = await Directory.systemTemp.createTemp('baocode-outside-');
    addTearDown(() => outside.delete(recursive: true));
    final link = Link('${root.path}/escape');
    await link.create(outside.path);
    final h = _Harness(root);
    await h.start();
    expect(
      (await h.response(
        h.request('terminal/create', {'command': 'echo', 'cwd': link.path}),
      ))['error'],
      isNotNull,
    );
    expect(h.events.whereType<InteractionRequested>(), isEmpty);
  }, skip: Platform.isWindows);

  test(
    'output truncation keeps UTF8 valid; a zero-byte limit retains no text',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create('printf "你好世界"', extra: {'outputByteLimit': 5});
      await h.response(h.request('terminal/wait_for_exit', {'terminalId': id}));
      final result =
          (await h.response(
                h.request('terminal/output', {'terminalId': id}),
              ))['result']
              as Map;
      expect(result['output'], '界');
      expect(result['truncated'], isTrue);
      final empty = await h.create(
        'printf nonempty',
        extra: {'outputByteLimit': 0},
      );
      await h.response(
        h.request('terminal/wait_for_exit', {'terminalId': empty}),
      );
      final zero =
          (await h.response(
                h.request('terminal/output', {'terminalId': empty}),
              ))['result']
              as Map;
      expect(zero['output'], '');
      expect(zero['truncated'], isTrue);
    },
    skip: Platform.isWindows,
  );

  test(
    'control sequences are neutralized including OSC split across writes',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create(
        r"printf '\033]52;c;'; sleep 0.1; printf 'clipboard\007safe\033[31mred\033[0m'",
      );
      await h.response(h.request('terminal/wait_for_exit', {'terminalId': id}));
      final result =
          (await h.response(
                h.request('terminal/output', {'terminalId': id}),
              ))['result']
              as Map;
      expect(result['output'], 'safered');
      expect(h.tasks.single.summary, 'safered');
    },
    skip: Platform.isWindows,
  );

  test('kill retains output; release invalidates ids and resolves concurrent waiters', () async {
    final h = _Harness(root);
    await h.start();
    final id = await h.create('printf running; sleep 30');
    final wait1 = h.request('terminal/wait_for_exit', {'terminalId': id});
    final wait2 = h.request('terminal/wait_for_exit', {'terminalId': id});
    expect(
      (await h.response(
        h.request('terminal/kill', {'terminalId': id}),
      ))['result'],
      isEmpty,
    );
    expect(
      (await h.response(wait1))['result'],
      (await h.response(wait2))['result'],
    );
    expect(
      (await h.response(
        h.request('terminal/output', {'terminalId': id}),
      ))['error'],
      isNull,
    );
    expect(
      (await h.response(
        h.request('terminal/release', {'terminalId': id}),
      ))['result'],
      isEmpty,
    );
    expect(
      (await h.response(
        h.request('terminal/output', {'terminalId': id}),
      ))['error'],
      isNotNull,
    );
    expect(h.tasks.single.status, CommandStatus.failed);
  }, skip: Platform.isWindows);

  test('terminal content links tools without duplicate tasks and keeps released output', () async {
    final h = _Harness(root);
    await h.start();
    final id = await h.create('printf live; sleep 0.1; printf final');
    h.transport.notify({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'shell',
      'kind': 'execute',
      'title': 'Run tests',
      'content': [
        {'type': 'terminal', 'terminalId': id},
      ],
    });
    await pumpEventQueue();
    expect(h.tasks, hasLength(1));
    expect(h.tasks.single.toolUseId, 'shell');
    await h.response(h.request('terminal/wait_for_exit', {'terminalId': id}));
    await h.response(h.request('terminal/release', {'terminalId': id}));
    await pumpEventQueue();
    final tool =
        h.events
                .whereType<ItemUpserted>()
                .lastWhere((e) => e.id == 'shell')
                .item
            as ToolCallItem;
    expect(tool.details!.content, 'livefinal');
    expect(tool.output, 'livefinal');
    expect(
      h.events.whereType<ItemRemoved>().any(
        (e) => e.id == 'acp_terminal_item_$id',
      ),
      isTrue,
    );
    expect(h.tasks, hasLength(1));
    expect(h.tasks.single.summary, 'livefinal');
  }, skip: Platform.isWindows);

  test(
    'parallel child terminals are isolated, nested and independently stoppable',
    () async {
      final h = _Harness(root);
      await h.start();
      for (final session in ['a', 'b']) {
        h.transport.notify({
          'sessionUpdate': 'subagent_update',
          'sessionId': session,
          'state': {'state': 'running'},
        });
      }
      final a = await h.create('printf a; sleep 30', session: 'a');
      final b = await h.create('printf b; sleep 30', session: 'b');
      expect(
        (await h.response(
          h.request('terminal/output', {'terminalId': a}, session: 'b'),
        ))['error'],
        isNotNull,
      );
      h.transport.update('a', {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'same-tool',
        'kind': 'execute',
        'content': [
          {'type': 'terminal', 'terminalId': a},
        ],
      });
      h.transport.update('b', {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'same-tool',
        'kind': 'execute',
        'content': [
          {'type': 'terminal', 'terminalId': b},
        ],
      });
      await pumpEventQueue();
      h.kernel.stopTask(a);
      await h.response(
        h.request('terminal/wait_for_exit', {'terminalId': a}, session: 'a'),
      );
      await pumpEventQueue();
      expect(h.tasks.firstWhere((t) => t.id == a).status, CommandStatus.failed);
      expect(
        h.tasks.firstWhere((t) => t.id == b).status,
        CommandStatus.running,
      );
      final agentTask = h.tasks.firstWhere(
        (t) => t.kind == KernelTaskKind.agent,
      );
      final feed = SubagentFeed(h.session, h.session.agentOf(agentTask)!.path);
      addTearDown(feed.dispose);
      expect(feed.agent!.children.whereType<ToolCallItem>(), hasLength(1));
      expect(h.session.stopOf(agentTask.toolUseId), isNull);
    },
    skip: Platform.isWindows,
  );

  test(
    'active terminal keeps released kernel alive; exit permits idle disconnect',
    () async {
      final h = _Harness(root);
      await h.start();
      final id = await h.create('sleep 0.2; echo done');
      h.kernel.release();
      await pumpEventQueue();
      expect(h.kernel.health.status, KernelHealthStatus.ready);
      await _until(
        () =>
            h.tasks.any((t) => t.id == id && t.status != CommandStatus.running),
      );
      await pumpEventQueue();
      expect(h.kernel.health.status, KernelHealthStatus.idle);
      expect(h.tasks.single.summary, contains('done'));
    },
    skip: Platform.isWindows,
  );

  test(
    'dispose waits for cleanup and cannot launch pending approvals',
    () async {
      final h = _Harness(root);
      await h.start();
      await h.create('sleep 30');
      h.request('terminal/create', {
        'command': '/bin/sh',
        'args': ['-c', 'sleep 30'],
      });
      await _until(
        () => h.events.whereType<InteractionRequested>().length == 2,
      );
      h.kernel.dispose();
      await h.kernel.stopped;
      expect(
        h.transport.written.where(
          (m) =>
              m['result'] is Map &&
              (m['result'] as Map).containsKey('terminalId'),
        ),
        hasLength(1),
      );
    },
    skip: Platform.isWindows,
  );
}

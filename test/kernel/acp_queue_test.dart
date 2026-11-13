import 'dart:async';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_controller.dart';
import 'package:baocode/chat/panels/queue_panel.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/keybindings/keybinding_service.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> _modelConfigs(String model) => [
  {
    'id': 'agent-model',
    'name': 'Model',
    'category': 'model',
    'type': 'select',
    'currentValue': model,
    'options': [
      for (final value in ['a', 'b', 'c']) {'value': value, 'name': value},
    ],
  },
];

/// Prompts and configuration changes wait for explicit test responses.
class _Transport implements AcpTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  final written = <Map<String, Object?>>[];
  List<Map<String, Object?>>? configOptions;
  bool closed = false;

  List<Map<String, Object?>> get prompts => written
      .where((message) => message['method'] == 'session/prompt')
      .toList();

  List<String> get texts => [
    for (final message in prompts)
      (((message['params'] as Map)['prompt'] as List).first as Map)['text']
          as String,
  ];

  List<Map<String, Object?>> get configChanges => written
      .where((message) => message['method'] == 'session/set_config_option')
      .toList();

  int get cancellations =>
      written.where((message) => message['method'] == 'session/cancel').length;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    switch (message['method']) {
      case 'initialize':
        reply(message['id']!, {'protocolVersion': 1});
      case 'session/new':
      case 'session/load':
        reply(message['id']!, {
          'sessionId': 'session',
          if (configOptions != null) 'configOptions': configOptions,
        });
    }
  }

  void reply(Object id, Map<String, Object?> result) =>
      _messages.add({'jsonrpc': '2.0', 'id': id, 'result': result});

  void complete(int index, {String reason = 'end_turn'}) =>
      reply(prompts[index]['id']!, {'stopReason': reason});

  void completeConfig(int index) {
    final request = configChanges[index];
    final params = request['params'] as Map;
    configOptions = [
      for (final option in configOptions!)
        if (option['id'] == params['configId'])
          {...option, 'currentValue': params['value']}
        else
          option,
    ];
    reply(request['id']!, {'configOptions': configOptions});
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

  Future<void> waitForPrompts(int count) async {
    final elapsed = Stopwatch()..start();
    while (prompts.length < count) {
      if (elapsed.elapsed > const Duration(seconds: 3)) {
        throw StateError('Prompt did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void update(String kind, [String? text]) => _messages.add({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': 'session',
      'update': {
        'sessionUpdate': kind,
        if (text != null) 'content': {'type': 'text', 'text': text},
      },
    },
  });

  void failPrompt(int index) => _messages.add({
    'jsonrpc': '2.0',
    'id': prompts[index]['id'],
    'error': {'code': -32603, 'message': 'Agent failed'},
  });

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _messages.close();
  }
}

void main() {
  late _Transport transport;
  late AcpKernel kernel;
  late KernelDescriptor descriptor;
  late List<KernelEvent> events;
  late Transcript transcript;
  Future<AcpTransport> Function()? launch;

  setUp(() {
    launch = null;
    transport = _Transport();
    descriptor = KernelDescriptor(
      id: 'queued-acp',
      label: 'Queued ACP',
      icon: Icons.hub,
      description: 'A test ACP agent with held prompt responses',
      create: (_) => kernel,
    );
    kernel = AcpKernel(
      descriptor,
      const KernelContext(),
      (_) => launch?.call() ?? Future.value(transport),
    );
    events = [];
    transcript = Transcript();
    final subscription = kernel.events.listen((event) {
      events.add(event);
      transcript.apply(event);
    });
    addTearDown(subscription.cancel);
    addTearDown(() async {
      kernel.dispose();
      await kernel.stopped;
    });
  });

  void send(String id, {bool now = false}) =>
      kernel.send(KernelTurn(id: id, text: id, now: now));

  List<String> queued() => transcript.queued.map((entry) => entry.$1).toList();

  test(
    'a prompt waits for configuration appended while it is waiting',
    () async {
      transport.configOptions = _modelConfigs('a');
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(kernel.model.selected, 'a');

      kernel.model.select('b');
      send('first');
      await pumpEventQueue();
      expect(transport.configChanges.single['params'], {
        'sessionId': 'session',
        'configId': 'agent-model',
        'value': 'b',
      });
      expect(transport.prompts, isEmpty);

      // The prompt is already awaiting A when B is appended to the chain.
      kernel.model.select('c');
      await pumpEventQueue();
      expect(transport.configChanges, hasLength(1));
      transport.completeConfig(0);
      await pumpEventQueue();
      expect(transport.configChanges, hasLength(2));
      expect(transport.configChanges[1]['params'], {
        'sessionId': 'session',
        'configId': 'agent-model',
        'value': 'c',
      });
      expect(kernel.model.selected, 'b');
      expect(transport.prompts, isEmpty);
      expect(events.whereType<TurnStarted>(), isEmpty);

      transport.completeConfig(1);
      await transport.waitForPrompts(1);
      expect(kernel.model.selected, 'c');
      expect(transport.texts, ['first']);
      transport.complete(0);
      await pumpEventQueue();
    },
  );

  test('ACP queues messages and sends one prompt at a time', () async {
    send('first');
    await transport.waitForPrompts(1);
    transport.update('agent_message_chunk', 'First answer');
    send('second');
    send('third');
    await pumpEventQueue();

    expect(queued(), ['second', 'third']);
    expect(transport.texts, ['first']);
    expect(events.whereType<TurnStarted>().map((event) => event.turnId), [
      'first',
    ]);

    transport.complete(0);
    await pumpEventQueue();
    expect(transport.texts, ['first', 'second']);
    expect(queued(), ['third']);
    expect(transcript.activeTurn, 'second');
    transport.complete(1);
    await pumpEventQueue();
    expect(transport.texts, ['first', 'second', 'third']);
    expect(queued(), isEmpty);
    transport.complete(2);
    await pumpEventQueue();
    expect(transcript.activeTurn, isNull);
    expect(transport.cancellations, 0);
    expect(events.whereType<TurnEnded>().map((event) => event.turnId), [
      'first',
      'second',
      'third',
    ]);
  });

  test(
    'queued messages can be withdrawn and reordered without remote requests',
    () async {
      send('first');
      await transport.waitForPrompts(1);
      send('second');
      send('third');
      send('fourth');
      final queue = kernel as QueuesMessages;
      queue.moveQueued('fourth', 0);
      expect(queued(), ['fourth', 'second', 'third']);
      expect(await queue.cancelQueued('second'), isTrue);
      expect(await queue.cancelQueued('first'), isFalse);
      expect(await queue.cancelQueued('missing'), isFalse);
      expect(queued(), ['fourth', 'third']);
      queue.moveQueued('fourth', 100);
      expect(queued(), ['third', 'fourth']);
      expect(transport.texts, ['first']);
      transport.complete(0);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'third']);
      transport.complete(1);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'third', 'fourth']);
    },
  );

  test(
    'send now waits for cancel completion before taking the selected message',
    () async {
      send('first');
      await transport.waitForPrompts(1);
      send('second');
      send('third');
      (kernel as QueuesMessages).sendQueuedNow('third');
      expect(queued(), ['third', 'second']);
      expect(transport.cancellations, 1);
      await pumpEventQueue();
      expect(transport.texts, ['first']);
      transport.update('turn_complete');
      await pumpEventQueue();
      // A notification must not finish the turn or clear cancellation.
      expect(transport.texts, ['first']);
      expect(events.whereType<TurnEnded>(), isEmpty);
      expect(transcript.activeTurn, 'first');
      transport.permission('late-permission');
      await pumpEventQueue();
      expect(
        transport.written.singleWhere(
          (message) => message['id'] == 'late-permission',
        )['result'],
        {
          'outcome': {'outcome': 'cancelled'},
        },
      );
      expect(events.whereType<TurnEnded>(), isEmpty);
      expect(transport.texts, ['first']);

      transport.complete(0, reason: 'cancelled');
      await pumpEventQueue();
      final ended = events.whereType<TurnEnded>().single;
      expect(ended.turnId, 'first');
      expect(ended.interrupted, isTrue);
      expect(transport.texts, ['first', 'third']);
      expect(queued(), ['second']);
      transport.complete(1);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'third', 'second']);
    },
  );

  test(
    'reordering a send-now target does not cancel the next prompt',
    () async {
      send('first');
      await transport.waitForPrompts(1);
      send('second');
      send('third');
      final queue = kernel as QueuesMessages;
      queue.sendQueuedNow('third');
      expect(queued(), ['third', 'second']);
      expect(transport.cancellations, 1);

      queue.moveQueued('third', 1);
      expect(queued(), ['second', 'third']);
      await pumpEventQueue();
      expect(transport.texts, ['first']);
      expect(events.whereType<TurnEnded>(), isEmpty);

      transport.complete(0, reason: 'cancelled');
      await transport.waitForPrompts(2);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'second']);
      expect(queued(), ['third']);
      expect(transport.cancellations, 1);
      expect(transcript.activeTurn, 'second');
      expect(
        events.whereType<TurnEnded>().map(
          (event) => (event.turnId, event.interrupted),
        ),
        [('first', true)],
      );

      transport.complete(1);
      await transport.waitForPrompts(3);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'second', 'third']);
      expect(transport.cancellations, 1);
      expect(queued(), isEmpty);
      expect(transcript.activeTurn, 'third');
      expect(
        events.whereType<TurnEnded>().map(
          (event) => (event.turnId, event.interrupted),
        ),
        [('first', true), ('second', false)],
      );
      transport.complete(2);
      await pumpEventQueue();
    },
  );

  test('messages queue during startup and an early send-now interrupts after prompt', () async {
    final starting = Completer<AcpTransport>();
    launch = () => starting.future;
    send('first');
    send('second');
    send('third', now: true);
    expect(queued(), ['third', 'second']);
    expect(transport.written, isEmpty);
    starting.complete(transport);
    await transport.waitForPrompts(1);
    expect(transport.texts, ['first']);
    expect(transport.cancellations, 1);
    transport.complete(0, reason: 'cancelled');
    await pumpEventQueue();
    expect(transport.texts, ['first', 'third']);
  });

  test(
    'duplicate turn ids are ignored during startup, queueing and completion',
    () async {
      final starting = Completer<AcpTransport>();
      launch = () => starting.future;
      send('first');
      send('first');
      send('second');
      send('second');
      expect(queued(), ['second']);
      expect(transport.written, isEmpty);

      starting.complete(transport);
      await transport.waitForPrompts(1);
      send('first');
      send('second');
      await pumpEventQueue();
      expect(transport.texts, ['first']);
      expect(queued(), ['second']);

      transport.complete(0);
      await transport.waitForPrompts(2);
      send('first');
      send('second');
      await pumpEventQueue();
      expect(transport.texts, ['first', 'second']);
      expect(queued(), isEmpty);
      transport.complete(1);
      await pumpEventQueue();

      send('first');
      send('second');
      await pumpEventQueue();
      expect(transport.texts, ['first', 'second']);
      expect(queued(), isEmpty);
      expect(transport.cancellations, 0);
      expect(events.whereType<TurnStarted>().map((event) => event.turnId), [
        'first',
        'second',
      ]);
      expect(events.whereType<TurnEnded>().map((event) => event.turnId), [
        'first',
        'second',
      ]);
    },
  );

  test(
    'ChatSession allows sending while ACP is working and edits queued text',
    () async {
      final session = ChatSession(kernel: descriptor, historyCount: 0);
      addTearDown(session.dispose);
      session.send(const ComposerMessage(text: 'first'));
      await transport.waitForPrompts(1);
      expect(session.isStreaming, isTrue);
      expect(session.canQueue, isTrue);
      expect(session.canSend, isTrue);
      session.send(const ComposerMessage(text: 'second'));
      session.send(const ComposerMessage(text: 'third'));
      final second = session.queued.first.$1;
      expect(session.queued.map((entry) => entry.$2.text), ['second', 'third']);
      await session.editQueued(second);
      expect(session.draft.pendingMessage?.text, 'second');
      expect(session.queued.single.$2.text, 'third');
      transport.complete(0);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'third']);
      expect(session.queued, isEmpty);
    },
  );

  test(
    'ChatSession takes back a queued turn awaiting configuration for editing',
    () async {
      transport.configOptions = _modelConfigs('a');
      final session = ChatSession(kernel: descriptor, historyCount: 0);
      addTearDown(session.dispose);
      session.send(const ComposerMessage(text: 'first'));
      await transport.waitForPrompts(1);
      session.send(const ComposerMessage(text: 'second'));
      session.send(const ComposerMessage(text: 'third'));
      final second = session.queued.first.$1;
      kernel.model.select('b');
      await pumpEventQueue();
      expect(transport.configChanges, hasLength(1));

      transport.complete(0);
      await pumpEventQueue();
      expect(transport.texts, ['first']);
      expect(transcript.activeTurn, isNull);
      expect(session.queued.map((entry) => entry.$2.text), ['second', 'third']);

      await session.editQueued(second);
      expect(session.draft.pendingMessage?.text, 'second');
      expect(session.queued.map((entry) => entry.$2.text), ['third']);
      expect(transport.texts, ['first']);
      expect(transport.cancellations, 0);

      transport.completeConfig(0);
      await transport.waitForPrompts(2);
      await pumpEventQueue();
      expect(transport.texts, ['first', 'third']);
      expect(session.queued, isEmpty);
      expect(transport.cancellations, 0);

      session.send(const ComposerMessage(text: 'second edited'));
      expect(session.queued.single.$2.text, 'second edited');
      transport.complete(1);
      await transport.waitForPrompts(3);
      expect(transport.texts, ['first', 'third', 'second edited']);
      expect(session.queued, isEmpty);
      transport.complete(2);
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>(), hasLength(3));
    },
  );

  test(
    'ChatSession queues slash commands and forwards send-now priority',
    () async {
      final session = ChatSession(kernel: descriptor, historyCount: 0);
      addTearDown(session.dispose);
      session.send(const ComposerMessage(text: 'first'));
      await transport.waitForPrompts(1);
      final first = events.whereType<TurnStarted>().single.turnId;

      session.send(const ComposerMessage(text: '/help'));
      expect(session.queued.single.$2.text, '/help');
      expect(transport.texts, ['first']);
      expect(transport.cancellations, 0);

      session.send(const ComposerMessage(text: '/compact'), now: true);
      await pumpEventQueue();
      expect(session.queued.map((entry) => entry.$2.text), [
        '/compact',
        '/help',
      ]);
      expect(transport.texts, ['first']);
      expect(transport.cancellations, 1);
      expect(events.whereType<TurnEnded>(), isEmpty);

      transport.complete(0, reason: 'cancelled');
      await transport.waitForPrompts(2);
      await pumpEventQueue();
      expect(transport.texts, ['first', '/compact']);
      expect(session.queued.single.$2.text, '/help');
      expect(transport.cancellations, 1);
      final ended = events.whereType<TurnEnded>().single;
      expect(ended.turnId, first);
      expect(ended.interrupted, isTrue);

      transport.complete(1);
      await transport.waitForPrompts(3);
      expect(transport.texts, ['first', '/compact', '/help']);
      expect(session.queued, isEmpty);
      expect(transport.cancellations, 1);
      transport.complete(2);
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>(), hasLength(3));
    },
  );

  testWidgets('composer Enter queues an ACP message and shows QueuePanel', (
    tester,
  ) async {
    final previousKeys = KeybindingService.instance;
    KeybindingService.instance = KeybindingService();
    addTearDown(() => KeybindingService.instance = previousKeys);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Create the kernel's initial futures in the widget test's fake clock.
    late final KernelDescriptor uiDescriptor;
    uiDescriptor = KernelDescriptor(
      id: 'queued-acp-ui',
      label: 'Queued ACP',
      icon: Icons.hub,
      description: 'An ACP agent for the real chat composer',
      create: (_) => AcpKernel(
        uiDescriptor,
        const KernelContext(),
        (_) async => transport,
      ),
    );
    final session = ChatSession(kernel: uiDescriptor, historyCount: 0);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatScreen(session: session),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        transport.written.map((message) => message['method']),
        contains('session/new'),
      );
      final composer =
          tester.widget<MarkdownEditor>(find.byType(MarkdownEditor)).controller
              as ComposerController;

      Future<void> enter(String text) async {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pump();
        expect(composer.shownText, text);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 20));
      }

      await enter('first');
      expect(transport.texts, ['first']);
      expect(session.isStreaming, isTrue);
      expect(session.canSend, isTrue);
      expect(session.canQueue, isTrue);
      expect(composer.shownText, isEmpty);
      expect(find.byType(QueuePanel), findsNothing);

      await enter('second');
      expect(transport.texts, ['first']);
      expect(transport.cancellations, 0);
      expect(session.queued.single.$2.text, 'second');
      expect(composer.shownText, isEmpty);
      expect(find.byType(QueuePanel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(QueuePanel),
          matching: find.text('second'),
        ),
        findsOneWidget,
      );

      transport.complete(0);
      await tester.pump(const Duration(milliseconds: 20));
      expect(transport.texts, ['first', 'second']);
      expect(session.queued, isEmpty);
      expect(find.byType(QueuePanel), findsNothing);
      expect(transport.cancellations, 0);
      transport.complete(1);
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.isStreaming, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
    }
  });

  test(
    'a failed prompt clears pending messages and never starts another prompt',
    () async {
      send('first');
      await transport.waitForPrompts(1);
      send('second');
      send('third');
      transport.failPrompt(0);
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(transport.texts, ['first']);
      expect(queued(), isEmpty);
      expect(transport.closed, isTrue);
    },
  );

  test(
    'release waits for the entire queue before closing the idle transport',
    () async {
      send('first');
      await transport.waitForPrompts(1);
      send('second');
      kernel.release();
      transport.complete(0);
      await pumpEventQueue();
      expect(transport.closed, isFalse);
      expect(transport.texts, ['first', 'second']);
      transport.complete(1);
      await pumpEventQueue();
      expect(transport.closed, isTrue);
      expect(kernel.health.status, KernelHealthStatus.idle);
    },
  );

  test(
    'restart removes a queued turn already waiting for configuration',
    () async {
      transport.configOptions = _modelConfigs('a');
      send('first');
      await transport.waitForPrompts(1);
      send('second');
      kernel.model.select('b');
      await pumpEventQueue();
      expect(transport.configChanges, hasLength(1));
      expect(queued(), ['second']);

      transport.complete(0);
      await pumpEventQueue();
      expect(transport.texts, ['first']);
      expect(queued(), ['second']);
      expect(transcript.activeTurn, isNull);
      expect(events.whereType<TurnEnded>().single.turnId, 'first');
      final old = transport;
      transport = _Transport();
      kernel.restart();
      await pumpEventQueue();
      expect(old.closed, isTrue);
      expect(old.texts, ['first']);
      expect(queued(), isEmpty);
      expect(transcript.activeTurn, isNull);

      send('replacement');
      await transport.waitForPrompts(1);
      expect(transport.texts, ['replacement']);
      expect(queued(), isEmpty);
      transport.complete(0);
      await pumpEventQueue();
    },
  );

  test('restart cannot let an obsolete prompt release a new queue', () async {
    send('first');
    await transport.waitForPrompts(1);
    send('old queued');
    final old = transport;
    kernel.restart();
    transport = _Transport();
    send('replacement');
    send('new queued');
    await transport.waitForPrompts(1);
    expect(old.closed, isTrue);
    expect(old.texts, ['first']);
    expect(transport.texts, ['replacement']);
    expect(queued(), ['new queued']);
    transport.complete(0);
    await pumpEventQueue();
    expect(transport.texts, ['replacement', 'new queued']);
  });

  test('disposing does not send waiting messages', () async {
    send('first');
    await transport.waitForPrompts(1);
    send('second');
    kernel.dispose();
    await kernel.stopped;
    expect(transport.texts, ['first']);
    expect(transport.closed, isTrue);
  });
}

import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _select(
  String category,
  String current,
  List<String> values, {
  String? id,
}) => {
  'id': id ?? 'agent-$category',
  'name': 'Agent $category',
  'category': category,
  'type': 'select',
  'currentValue': current,
  'options': [
    for (final value in values) {'value': value, 'name': value},
  ],
};

List<Map<String, Object?>> _configs({String model = 'Model A'}) => [
  _select('mode', 'Ask', ['Ask', 'Code', 'Plan']),
  _select('model', model, ['Model A', 'Model B']),
  _select('thought_level', 'Low', ['Low', 'Medium', 'High']),
];

class _Transport implements AcpTransport {
  _Transport({this.configs});

  List<Map<String, Object?>>? configs;
  List<Map<String, Object?>>? afterSetup;
  bool automatic = true;
  final written = <Map<String, Object?>>[];
  final _out = StreamController<Map<String, Object?>>.broadcast(sync: true);

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  List<Map<String, Object?>> get changes =>
      written.where((m) => m['method'] == 'session/set_config_option').toList();

  void reply(Map<String, Object?> request, Map<String, Object?> result) =>
      _out.add({'jsonrpc': '2.0', 'id': request['id'], 'result': result});

  void report(List<Map<String, Object?>> next) {
    configs = next;
    update({'sessionUpdate': 'config_option_update', 'configOptions': next});
  }

  void update(Map<String, Object?> update) => _out.add({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'sessionId': 'session', 'update': update},
  });

  void accept(Map<String, Object?> request, List<Map<String, Object?>> next) {
    configs = next;
    reply(request, {'configOptions': next});
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final params = message['params'] as Map? ?? const {};
    switch (message['method']) {
      case 'initialize':
        reply(message, {'protocolVersion': 1});
      case 'session/new':
      case 'session/load':
        reply(message, {
          if (message['method'] == 'session/new') 'sessionId': 'session',
          if (configs != null) 'configOptions': configs,
          'modes': {
            'currentModeId': 'legacy',
            'availableModes': [
              {'id': 'legacy', 'name': 'Legacy mode'},
            ],
          },
        });
        if (afterSetup case final next?) report(next);
      case 'session/set_config_option':
        if (!automatic) return;
        accept(message, [
          for (final option in configs ?? <Map<String, Object?>>[])
            if (option['id'] == params['configId'])
              {...option, 'currentValue': params['value']}
            else
              option,
        ]);
      case 'session/set_mode':
        reply(message, {});
      case 'session/prompt':
        reply(message, {'stopReason': 'end_turn'});
    }
  }

  @override
  Future<void> close() => _out.close();
}

KernelDescriptor _descriptor(AcpTransport Function() transport) {
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: 'acp-config-test',
    label: 'ACP Config Test',
    icon: Icons.hub,
    description: '',
    create: (context) =>
        AcpKernel(descriptor, context, (_) async => transport()),
  );
  return descriptor;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

Future<AcpKernel> _start(_Transport transport, {bool resume = false}) async {
  final kernel = _descriptor(() => transport).create(
    KernelContext(
      cwd: '/tmp/project',
      resume: resume
          ? SessionRecord(
              id: 'session',
              title: 'Saved',
              cwd: '/tmp/project',
              updatedAt: DateTime.utc(2026),
            )
          : null,
    ),
  ) as AcpKernel;
  addTearDown(kernel.dispose);
  kernel.prepare();
  await _settle();
  expect(kernel.health.status, KernelHealthStatus.ready);
  return kernel;
}

Future<ChatSession> _pump(WidgetTester tester, _Transport transport) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final descriptor = _descriptor(() => transport);
  final session = ChatSession(
    kernel: descriptor,
    kernels: [descriptor],
    historyCount: 0,
  );
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: ChatScreen(session: session),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  return session;
}

void main() {
  for (final resume in [false, true]) {
    test(
      'config categories from session ${resume ? 'load' : 'new'} supersede legacy modes',
      () async {
        final transport = _Transport(configs: _configs());
        final kernel = await _start(transport, resume: resume);
        expect(kernel.model.options.map((o) => o.id), ['Model A', 'Model B']);
        expect(kernel.model.selected, 'Model A');
        expect(kernel.mode.options.map((o) => o.id), ['Ask', 'Code', 'Plan']);
        expect(kernel.effort.optionsFor('Model A').map((o) => o.id), [
          'Low',
          'Medium',
          'High',
        ]);
        expect(kernel.effort.optionsFor('Model B'), isEmpty);
        kernel.mode.select('Code');
        kernel.model.select('Model B');
        await _settle();
        kernel.effort.select('Model B', 'High');
        await _settle();
        expect(transport.changes.map((m) => m['params']), [
          {'sessionId': 'session', 'configId': 'agent-mode', 'value': 'Code'},
          {
            'sessionId': 'session',
            'configId': 'agent-model',
            'value': 'Model B',
          },
          {
            'sessionId': 'session',
            'configId': 'agent-thought_level',
            'value': 'High',
          },
        ]);
        expect(
          transport.written.any((m) => m['method'] == 'session/set_mode'),
          isFalse,
        );
        expect(kernel.mode.selected, 'Code');
        expect(kernel.model.selected, 'Model B');
        expect(kernel.effort.selected, 'High');
      },
    );
  }

  test(
    'grouped values, duplicate categories and absent categories are handled',
    () async {
      final model = _select('model', 'b', []);
      model['options'] = [
        {
          'group': 'provider',
          'name': 'Provider',
          'options': [
            {'value': 'a', 'name': 'Alpha', 'description': 'Fast'},
            {'value': 'b', 'name': 'Beta'},
          ],
        },
      ];
      final thought = _select('thought_level', 'Low', [
        'Low',
        'High',
      ], id: 'thought_level')..remove('category');
      final transport = _Transport(
        configs: [
          model,
          _select('model', 'wrong', ['wrong']),
          thought,
          _select('_custom', 'x', ['x'], id: 'mode'),
          {
            'id': 'unsupported',
            'category': 'mode',
            'type': 'boolean',
            'currentValue': true,
          },
        ],
      );
      final kernel = await _start(transport);
      expect(kernel.model.options.map((o) => o.label), ['Alpha', 'Beta']);
      expect(kernel.model.options.first.group?.label, 'Provider');
      expect(kernel.model.options.first.description, 'Fast');
      expect(kernel.model.selected, 'b');
      expect(kernel.effort.selected, 'Low');
      expect(kernel.mode.options, isEmpty);
      kernel.model.select('invented');
      kernel.effort.select('b', 'invented');
      await _settle();
      expect(transport.changes, isEmpty);
    },
  );

  test(
    'selection waits for acknowledgment and applies all dependent changes',
    () async {
      final transport = _Transport(configs: _configs())..automatic = false;
      final kernel = await _start(transport);
      kernel.model.select('Model B');
      await _settle();
      expect(kernel.model.selected, 'Model A');
      transport.accept(transport.changes.single, [
        _select('model', 'Model B', ['Model A', 'Model B']),
        _select('thought_level', 'Balanced', ['Balanced', 'Deep']),
      ]);
      await _settle();
      expect(kernel.model.selected, 'Model B');
      expect(kernel.mode.options, isEmpty);
      expect(kernel.effort.optionsFor('Model B').map((o) => o.id), [
        'Balanced',
        'Deep',
      ]);
      expect(kernel.effort.selected, 'Balanced');
    },
  );

  test('agent notifications replace all config, clear removed selectors, ignore old modes', () async {
    final transport = _Transport(configs: _configs());
    final kernel = await _start(transport);
    transport.report([
      _select('mode', 'Plan', ['Plan', 'Code']),
    ]);
    await _settle();
    expect(kernel.mode.selected, 'Plan');
    expect(kernel.model.options, isEmpty);
    expect(kernel.effort.optionsFor(''), isEmpty);
    transport.update({
      'sessionUpdate': 'current_mode_update',
      'currentModeId': 'legacy',
    });
    await _settle();
    expect(kernel.mode.selected, 'Plan');
    transport.report([]);
    await _settle();
    expect(kernel.mode.options, isEmpty);
  });

  test('a rejected config keeps the conversation ready and the old value, and can retry', () async {
    final transport = _Transport(configs: _configs())..automatic = false;
    final kernel = await _start(transport);
    final events = <KernelEvent>[];
    final subscription = kernel.events.listen(events.add);
    addTearDown(subscription.cancel);
    kernel.model.select('Model B');
    await _settle();
    transport._out.add({
      'jsonrpc': '2.0',
      'id': transport.changes.single['id'],
      'error': {'code': -32602, 'message': 'Model unavailable'},
    });
    await _settle();
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(kernel.model.selected, 'Model A');
    expect(
      events.whereType<ItemUpserted>().any((e) => e.item is NoticeItem),
      isTrue,
    );
    transport.automatic = true;
    kernel.model.select('Model B');
    await _settle();
    expect(kernel.model.selected, 'Model B');
  });

  test(
    'queued reasoning choice is revalidated after a model response',
    () async {
      final transport = _Transport(configs: _configs())..automatic = false;
      final kernel = await _start(transport);
      kernel.model.select('Model B');
      kernel.effort.select('Model A', 'High');
      await _settle();
      expect(transport.changes, hasLength(1));
      transport.accept(transport.changes.single, [
        _select('model', 'Model B', ['Model A', 'Model B']),
        _select('thought_level', 'Balanced', ['Balanced', 'Deep']),
      ]);
      await _settle();
      expect(transport.changes, hasLength(1));
      expect(kernel.effort.selected, 'Balanced');
    },
  );

  for (final notificationFirst in [false, true]) {
    test(
      'config response and notification keep wire order ($notificationFirst)',
      () async {
        final transport = _Transport(configs: _configs())..automatic = false;
        final kernel = await _start(transport);
        kernel.model.select('Model B');
        await _settle();
        final response = _configs(model: 'Model B');
        final notification = [
          _select('mode', 'Plan', ['Plan', 'Code']),
        ];
        if (notificationFirst) transport.report(notification);
        transport.accept(transport.changes.single, response);
        if (!notificationFirst) transport.report(notification);
        await _settle();
        expect(kernel.model.selected, notificationFirst ? 'Model B' : null);
        expect(kernel.mode.selected, notificationFirst ? 'Ask' : 'Plan');
      },
    );
  }

  for (final resume in [false, true]) {
    test(
      'notification immediately after session setup wins ($resume)',
      () async {
        final transport = _Transport(configs: _configs())
          ..afterSetup = [
            _select('mode', 'Plan', ['Plan', 'Code']),
          ];
        final kernel = await _start(transport, resume: resume);
        expect(kernel.mode.selected, 'Plan');
        expect(kernel.model.options, isEmpty);
      },
    );
  }

  test('disposed kernels do not send queued configuration changes', () async {
    final transport = _Transport(configs: _configs())..automatic = false;
    final kernel = await _start(transport);
    kernel.model.select('Model B');
    kernel.mode.select('Code');
    kernel.dispose();
    await _settle();
    expect(transport.changes, isEmpty);
  });

  test('agents without configOptions retain the legacy mode API', () async {
    final transport = _Transport();
    final kernel = await _start(transport);
    transport.update({
      'sessionUpdate': 'current_mode_update',
      'currentModeId': 'legacy',
      'availableModes': [
        {'id': 'legacy', 'name': 'Legacy mode'},
        {'id': 'old-code', 'name': 'Old Code'},
      ],
    });
    await _settle();
    kernel.mode.select('old-code');
    await _settle();
    expect(transport.written.last['method'], 'session/set_mode');
    expect(kernel.model.options, isEmpty);
    expect(kernel.effort.optionsFor(''), isEmpty);
  });

  test(
    'restart drops old configuration and can reconnect to a legacy agent',
    () async {
      var transport = _Transport(configs: _configs())..automatic = false;
      final descriptor = _descriptor(() => transport);
      final kernel = descriptor.create(const KernelContext()) as AcpKernel;
      addTearDown(kernel.dispose);
      kernel.prepare();
      await _settle();
      expect(kernel.model.options, isNotEmpty);
      kernel.model.select('Model B');
      await _settle();
      expect(transport.changes, hasLength(1));
      kernel.mode.select('Code');
      final oldTransport = transport;
      transport = _Transport();
      kernel.restart();
      expect(kernel.model.options, isEmpty);
      expect(kernel.effort.optionsFor(''), isEmpty);
      await _settle();
      expect(kernel.mode.selected, 'legacy');
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(oldTransport.changes, hasLength(1));
      expect(transport.changes, isEmpty);
    },
  );

  testWidgets('ACP config drives model, mode and reasoning menus', (
    tester,
  ) async {
    final transport = _Transport(configs: _configs());
    final session = await _pump(tester, transport);
    expect(session.models?.selected.id, 'Model A');
    expect(find.text('Model A · Low'), findsOneWidget);
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();
    expect(session.modes?.selected.id, 'Code');
    await tester.tap(find.text('Model A · Low'));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Model A').last));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(session.selected(KernelChoiceKind.effort), 'High');
    expect(find.text('Model A · High'), findsOneWidget);
    await tester.tap(find.text('Model A · High'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model B'));
    await tester.pumpAndSettle();
    expect(session.models?.selected.id, 'Model B');
    expect(transport.changes, hasLength(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reasoning-only agents show their selector without inventing a model',
    (tester) async {
      final transport = _Transport(
        configs: [
          _select('thought_level', 'Low', ['Low', 'High']),
        ],
      );
      final session = await _pump(tester, transport);
      expect(session.models, isNull);
      expect(session.modes, isNull);
      expect(find.byType(ComposerPicker), findsOneWidget);
      await tester.tap(find.text('Low'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      expect(session.selected(KernelChoiceKind.effort), 'High');
      expect(find.text('High'), findsOneWidget);
      transport.report([
        _select('thought_level', 'Max', ['Low', 'High', 'Max']),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Max'), findsOneWidget);
      transport.report([]);
      await tester.pumpAndSettle();
      expect(find.byType(ComposerPicker), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

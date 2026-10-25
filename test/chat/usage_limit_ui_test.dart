import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/panels/limit_reset_panel.dart';
import 'package:baocode/chat/resume_after_reset.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/chat/composer/session_model_picker.dart';
import 'package:baocode/ide/ide_switch.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

const _gateway = ModelProvider(
  id: 'gw',
  name: 'Gateway',
  protocol: ProviderProtocol.openaiChat,
  baseUrl: 'https://gw.example.com/v1',
  models: [ProviderModel(id: 'gpt-5', contextWindow: 400000)],
);

/// The error Claude Code answers with at the limit.
Map<String, Object?> _limitError(String text) => {
  'type': 'assistant',
  'error': 'rate_limit',
  'parent_tool_use_id': null,
  'message': {
    'id': 'msg-limit',
    'role': 'assistant',
    'model': '<synthetic>',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  late ResumeAfterReset resumes;
  // The setting, as settings.json has it.
  late ValueNotifier<bool> setting;

  setUp(() {
    final before = ResumeAfterReset.current;
    setting = ValueNotifier(true);
    ResumeAfterResetSetting.current = () => setting.value;
    ResumeAfterResetSetting.changes = setting;
    ResumeAfterResetSetting.write = (on) => setting.value = on;
    resumes = ResumeAfterReset.current = ResumeAfterReset();
    addTearDown(() {
      ResumeAfterReset.current = before;
      ResumeAfterResetSetting.current = () => false;
      ResumeAfterResetSetting.changes = null;
      ResumeAfterResetSetting.write = null;
      resumes.dispose();
      setting.dispose();
    });
  });

  /// A Claude Code session on a CLI the test speaks for, its session
  /// named, a message sent; on [settings]' model.
  Future<({ChatSession session, FakeCli cli})> pumpSession(
    WidgetTester tester, {
    Map<String, String> settings = const {},
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cli = FakeCli();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (_) async => cli,
        providers: ModelProviders.memory(providers: [_gateway]),
        providerEnvironment: (provider, model) async => {
          'ANTHROPIC_BASE_URL': 'http://proxy/${provider.id}',
        },
      ),
    );
    final session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      kernelContext: KernelContext(cwd: '/tmp/project', settings: settings),
      historyCount: 0,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: ChatScreen(title: 'Fix the tests', session: session),
      ),
    );
    await tester.pump();
    session.send(const ComposerMessage(text: 'fix the tests'));
    await tester.pump(const Duration(milliseconds: 100));
    cli.push({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'session-1',
      'cwd': '/tmp/project',
    });
    await tester.pump(const Duration(milliseconds: 100));
    return (session: session, cli: cli);
  }

  /// The turn ends at the limit, which resets in an hour; listed, as the
  /// workspace lists it.
  Future<DateTime> hitLimit(WidgetTester tester, FakeCli cli) async {
    final at = DateTime.now().add(const Duration(hours: 1));
    final seconds = at.millisecondsSinceEpoch ~/ 1000;
    cli
      ..push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'rejected',
          'resetsAt': seconds,
          'rateLimitType': 'five_hour',
        },
      })
      ..push(_limitError("You've hit your session limit · resets 11pm"))
      ..push({
        'type': 'result',
        'subtype': 'success',
        'is_error': true,
        'result': "You've hit your session limit · resets 11pm",
      });
    await tester.pump(const Duration(milliseconds: 100));
    final resetsAt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    resumes.hit(sessionId: 'session-1', resetsAt: resetsAt);
    await tester.pump();
    return resetsAt;
  }

  testWidgets('usage limit, the setting on: says when it goes on, nothing '
      'asked', (tester) async {
    final (:session, :cli) = await pumpSession(tester);
    expect(find.byType(LimitResetPanel), findsNothing);
    final at = await hitLimit(tester, cli);
    expect(session.usageLimitResetsAt, at);
    expect(find.byType(LimitResetPanel), findsOneWidget);
    expect(find.textContaining('continues automatically'), findsOneWidget);
    // Turned off: nothing shown, nothing to go on.
    setting.value = false;
    await tester.pump();
    expect(find.byType(LimitResetPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    // Its timer: listed till the limit resets.
    resumes.dispose();
  });

  testWidgets('usage limit, the setting off: nothing shown', (tester) async {
    setting.value = false;
    final (session: _, :cli) = await pumpSession(tester);
    await hitLimit(tester, cli);
    expect(find.byType(LimitResetPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    resumes.dispose();
  });

  testWidgets('usage limit: only warned, nothing shown', (tester) async {
    final (session: _, :cli) = await pumpSession(tester);
    cli
      ..push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'allowed_warning',
          'resetsAt': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          'rateLimitType': 'five_hour',
          'utilization': 0.9,
        },
      })
      ..push({'type': 'result', 'subtype': 'success', 'is_error': false});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LimitResetPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('usage limit: on a provider, none', (tester) async {
    final (:session, :cli) = await pumpSession(
      tester,
      settings: {'model': '@gw/gpt-5'},
    );
    await hitLimit(tester, cli);
    expect(session.usageLimitResetsAt, isNull);
    expect(find.byType(LimitResetPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    resumes.dispose();
  });

  testWidgets('the model picker: its switch beside Claude\'s own models, '
      'not a provider\'s', (tester) async {
    setting.value = false;
    final (:session, :cli) = await pumpSession(tester);
    cli.push({'type': 'result', 'subtype': 'success', 'is_error': false});
    // The menu opens, its submenu follows the pointer, over a moment.
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await settle();
    final models = session.models!.options;
    final own = models.firstWhere((model) => !model.id.startsWith('@'));
    expect(session.continuesAfterLimit(own.id), isTrue);
    expect(session.continuesAfterLimit('@gw/gpt-5'), isFalse);

    await tester.tap(find.byType(SessionModelPicker));
    await settle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text(own.label).last));
    await settle();
    final toggle = find.text('Continue After Limit Reset');
    expect(toggle, findsOneWidget);
    final switches = find.byType(IdeSwitch);
    expect(tester.widget<IdeSwitch>(switches.last).value, isFalse);
    await tester.tap(toggle);
    await settle();
    expect(setting.value, isTrue);
    // The menu stays open, the switch on.
    expect(toggle, findsOneWidget);
    expect(tester.widget<IdeSwitch>(switches.last).value, isTrue);

    final gateway = models.firstWhere((model) => model.id == '@gw/gpt-5');
    await mouse.moveTo(tester.getCenter(find.text(gateway.label).last));
    await settle();
    expect(find.text('Continue After Limit Reset'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

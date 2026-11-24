import 'dart:io';

import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/kernel/acp/acp_agent.dart';
import 'package:baocode/kernel/acp_agents.dart';
import 'package:baocode/settings/pages/agent_customization_copy.dart';
import 'package:baocode/settings/pages/agents_page.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late String config;
  late String target;
  late CustomizationStore store;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('baocode-copy-widget-');
    final root = temporary.resolveSymbolicLinksSync();
    config = p.join(root, '.claude');
    target = p.join(root, 'agent', 'rules');
    store = CustomizationStore(configDir: config, homeDir: root);
    final file = File(p.join(config, 'rules', 'test', 'policy.md'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('Rule');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<void> pumpCopy(
    WidgetTester tester, {
    bool enabled = true,
    String? directory,
  }) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentCustomizationCopy(
            agent: AcpAgentConfig(
              id: 'test',
              label: 'Test',
              command: 'agent',
              rulesDirectory: directory ?? target,
            ),
            store: store,
            enabled: enabled,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> actAndWait(
    WidgetTester tester,
    Future<void> Function() action,
    bool Function() done,
  ) async {
    await tester.runAsync(() async {
      await action();
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (done()) return;
      }
      fail('The copy UI did not finish the requested operation');
    });
    await tester.pumpAndSettle();
  }

  testWidgets('preview and cancel never write; confirmation copies', (
    tester,
  ) async {
    await pumpCopy(tester);
    expect(Directory(target).existsSync(), isFalse);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Preview rules copy')),
      () => find.text('Copy user rules').evaluate().isNotEmpty,
    );
    expect(Directory(target).existsSync(), isFalse);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Cancel')),
      () =>
          tester
              .widget<IdeButton>(
                find.widgetWithText(IdeButton, 'Preview rules copy'),
              )
              .onPressed !=
          null,
    );
    expect(Directory(target).existsSync(), isFalse);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Preview rules copy')),
      () => find.text('Copy user rules').evaluate().isNotEmpty,
    );
    await actAndWait(
      tester,
      () => tester.tap(find.text('Copy')),
      () => find
          .textContaining('Copied user rules to this machine.')
          .evaluate()
          .isNotEmpty,
    );
    expect(
      File(p.join(target, 'test', 'policy.md')).readAsStringSync(),
      'Rule',
    );
  });

  testWidgets('existing files show conflicts and disable confirmation', (
    tester,
  ) async {
    final existing = File(p.join(target, 'test', 'policy.md'));
    existing.parent.createSync(recursive: true);
    existing.writeAsStringSync('Existing');
    await pumpCopy(tester);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Preview rules copy')),
      () => find.text('Copy user rules').evaluate().isNotEmpty,
    );
    expect(find.textContaining('conflict: test'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Copy'))
          .onPressed,
      isNull,
    );
    expect(existing.readAsStringSync(), 'Existing');
    await actAndWait(
      tester,
      () => tester.tap(find.text('Cancel')),
      () =>
          tester
              .widget<IdeButton>(
                find.widgetWithText(IdeButton, 'Preview rules copy'),
              )
              .onPressed !=
          null,
    );
  });

  testWidgets('unsaved settings and blank destinations disable preview', (
    tester,
  ) async {
    await pumpCopy(tester, enabled: false);
    expect(
      tester
          .widget<IdeButton>(
            find.widgetWithText(IdeButton, 'Preview rules copy'),
          )
          .onPressed,
      isNull,
    );
    await pumpCopy(tester, directory: '');
    expect(
      tester
          .widget<IdeButton>(
            find.widgetWithText(IdeButton, 'Preview rules copy'),
          )
          .onPressed,
      isNull,
    );
    expect(Directory(target).existsSync(), isFalse);
  });

  testWidgets(
    'saves copy directories without splitting existing spaced arguments',
    (tester) async {
      final settings = UserSettings(p.join(temporary.path, 'settings.json'));
      final agents = AcpAgents(settings);
      addTearDown(() {
        agents.dispose();
        settings.dispose();
      });
      await tester.runAsync(
        () => agents.add(
          const AcpAgentConfig(
            id: 'test',
            label: 'Test',
            command: '',
            hostConfigurations: {
              'dev': AcpAgentConfig(
                id: 'test',
                label: 'Test',
                command: 'agent',
                arguments: ['--profile', 'profile with spaces'],
              ),
            },
          ),
        ),
      );
      tester.view.physicalSize = const Size(1100, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentsSettingsPage(agents: agents, customizations: store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsNothing);
      await tester.tap(find.text('Edit agent'));
      await tester.pumpAndSettle();
      final inputs = find.byType(EditableText);
      expect(inputs, findsNWidgets(5));
      await tester.enterText(inputs.at(4), target);
      await tester.ensureVisible(find.text('Save'));
      await actAndWait(
        tester,
        () => tester.tap(find.text('Save')),
        () => agents.agents.single.forHost('dev').rulesDirectory == target,
      );
      expect(agents.agents.single.forHost('dev').arguments, [
        '--profile',
        'profile with spaces',
      ]);
      expect(agents.agents.single.forHost('dev').rulesDirectory, target);
      expect(Directory(target).existsSync(), isFalse); // Saving isn't copying.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

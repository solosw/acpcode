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
    target = p.join(root, 'agent', 'skills');
    store = CustomizationStore(configDir: config, homeDir: root);
    final file = File(p.join(config, 'skills', 'test', 'SKILL.md'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('Skill');
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
              skillsDirectory: directory ?? target,
            ),
            store: store,
            hosts: const ['dev'],
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
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.value, ''); // Never implicitly copy onto an SSH host.
    await actAndWait(
      tester,
      () => tester.tap(find.text('Preview skills copy')),
      () => find.text('Copy user skills').evaluate().isNotEmpty,
    );
    expect(Directory(target).existsSync(), isFalse);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Cancel')),
      () =>
          tester
              .widget<IdeButton>(
                find.widgetWithText(IdeButton, 'Preview skills copy'),
              )
              .onPressed !=
          null,
    );
    expect(Directory(target).existsSync(), isFalse);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Preview skills copy')),
      () => find.text('Copy user skills').evaluate().isNotEmpty,
    );
    await actAndWait(
      tester,
      () => tester.tap(find.text('Copy')),
      () => find
          .textContaining('Copied user skills on this machine.')
          .evaluate()
          .isNotEmpty,
    );
    expect(
      File(p.join(target, 'test', 'SKILL.md')).readAsStringSync(),
      'Skill',
    );
  });

  testWidgets('existing files show conflicts and disable confirmation', (
    tester,
  ) async {
    final existing = File(p.join(target, 'test', 'SKILL.md'));
    existing.parent.createSync(recursive: true);
    existing.writeAsStringSync('Existing');
    await pumpCopy(tester);
    await actAndWait(
      tester,
      () => tester.tap(find.text('Preview skills copy')),
      () => find.text('Copy user skills').evaluate().isNotEmpty,
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
                find.widgetWithText(IdeButton, 'Preview skills copy'),
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
            find.widgetWithText(IdeButton, 'Preview skills copy'),
          )
          .onPressed,
      isNull,
    );
    await pumpCopy(tester, directory: '');
    expect(
      tester
          .widget<IdeButton>(
            find.widgetWithText(IdeButton, 'Preview skills copy'),
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
            command: 'agent',
            arguments: ['--profile', 'profile with spaces'],
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
      final inputs = find.byType(EditableText);
      expect(inputs, findsNWidgets(6));
      await tester.enterText(inputs.at(4), target);
      await tester.enterText(
        inputs.at(5),
        p.join(temporary.path, 'agent', 'rules'),
      );
      await tester.ensureVisible(find.text('Save'));
      await actAndWait(
        tester,
        () => tester.tap(find.text('Save')),
        () => agents.agents.single.skillsDirectory == target,
      );
      expect(agents.agents.single.arguments, [
        '--profile',
        'profile with spaces',
      ]);
      expect(
        agents.agents.single.rulesDirectory,
        p.join(temporary.path, 'agent', 'rules'),
      );
      expect(Directory(target).existsSync(), isFalse); // Saving isn't copying.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

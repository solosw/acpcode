import 'dart:io';

import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/chat_defaults.dart';
import 'package:baocode/settings/pages/chat_defaults_card.dart';
import 'package:baocode/settings/pages/settings_dropdown.dart';
import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends UserSettings {
  _Settings() : super('unused');

  @override
  final Map<String, Object?> values = {};

  @override
  Future<void> update(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    notifyListeners();
  }
}

void main() {
  late _Settings settings;

  setUp(() {
    settings = _Settings();
    addTearDown(settings.dispose);
  });

  Workspace workspace({PreferenceStore? preferences}) {
    final value = Workspace(
      projects: const [Project('Project', '/tmp/project')],
      kernels: MockKernels.all,
      userSettings: settings,
      preferences: preferences,
    );
    addTearDown(value.dispose);
    return value;
  }

  test('missing and malformed defaults follow the previous choices', () {
    expect(ChatDefaults.agent(settings), isNull);
    expect(ChatDefaults.modes(settings), isEmpty);
    settings.values.addAll({
      ChatDefaults.agentKey: 42,
      ChatDefaults.modesKey: {'claude-code': '', 'codex': 42, 1: 'plan'},
    });
    expect(ChatDefaults.agent(settings), isNull);
    expect(ChatDefaults.modes(settings), isEmpty);
    expect(workspace().preferredKernel.id, 'claude-code');
  });

  test(
    'configured defaults override last choices and preserve approvals',
    () async {
      settings.values.addAll({
        ChatDefaults.agentKey: 'claude-code',
        ChatDefaults.modesKey: {'claude-code': 'ask'},
      });
      final value = workspace(
        preferences: MemoryPreferenceStore({
          'kernel': 'codex',
          'settings': {'mode': 'plan', 'permission': 'acceptEdits'},
        }),
      );
      await value.load();
      final session = value.selected.session;
      expect(value.selected.kernel.id, 'claude-code');
      expect(session.modes!.selected.id, 'ask');
      expect(session.permissions!.selected.id, 'acceptEdits');
    },
  );

  test(
    'changing defaults creates a new empty chat without changing the old one',
    () async {
      final value = workspace();
      final original = value.create();
      expect(original.session.modes!.selected.id, 'agent');
      await settings.update(ChatDefaults.modesKey, {'claude-code': 'plan'});
      final next = value.create();
      expect(next, isNot(same(original)));
      expect(next.session.modes!.selected.id, 'plan');
      expect(original.session.modes!.selected.id, 'agent');
      expect(value.create(), same(next));
      await settings.update(ChatDefaults.agentKey, 'codex');
      expect(value.create().kernel.id, 'codex');
      expect(original.kernel.id, 'claude-code');
    },
  );

  test('IDE and phone new chats use the configured defaults', () async {
    final value = workspace();
    final original = value.newIdeChat('/tmp/project');
    await settings.update(ChatDefaults.modesKey, {'claude-code': 'ask'});
    final ide = value.newIdeChat('/tmp/project');
    expect(ide, isNot(same(original)));
    expect(ide.session.modes!.selected.id, 'ask');
    expect(
      value.startAgent(value.projects.first).session.modes!.selected.id,
      'ask',
    );
  });

  test('removed agents fall back to an available descriptor', () async {
    final value = workspace(
      preferences: MemoryPreferenceStore({'kernel': 'codex'}),
    );
    await value.load();
    await settings.update(ChatDefaults.agentKey, 'removed-agent');
    expect(value.preferredKernel.id, 'codex');
    value.refreshKernels([MockKernels.claudeCode]);
    expect(value.preferredKernel.id, 'claude-code');
    expect(value.create().kernel.id, 'claude-code');
  });

  test('explicit task settings take precedence over chat defaults', () async {
    settings.values.addAll({
      ChatDefaults.agentKey: 'codex',
      ChatDefaults.modesKey: {'claude-code': 'ask'},
    });
    final thread = await workspace().scheduledAgent(
      location: '/tmp/project',
      kernelId: 'claude-code',
      settings: {'mode': 'plan'},
    );
    expect(thread.kernel.id, 'claude-code');
    expect(thread.session.modes!.selected.id, 'plan');
  });

  test(
    'defaults are persisted and read again from the settings file',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'bao-chat-defaults-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final first = UserSettings('${directory.path}/settings.json');
      final second = UserSettings(first.path);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.load();
      await first.update(ChatDefaults.agentKey, 'claude-code');
      await first.update(ChatDefaults.modesKey, {'claude-code': 'ask'});
      await second.load();
      expect(ChatDefaults.agent(second), 'claude-code');
      expect(ChatDefaults.modes(second), {'claude-code': 'ask'});
    },
  );

  testWidgets('settings pick an agent and mode, or return to last used', (
    tester,
  ) async {
    final value = workspace();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatDefaultsCard(settings: settings, workspace: value),
        ),
      ),
    );
    final l10n = englishLocalizations;
    Finder dropdown(String label) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is SettingsRow && widget.label == label,
      ),
      matching: find.byType(SettingsDropdown),
    );
    await tester.tap(dropdown(l10n.generalSettingsDefaultAgent));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code'));
    await tester.pumpAndSettle();
    expect(settings[ChatDefaults.agentKey], 'claude-code');
    await tester.tap(dropdown(l10n.generalSettingsDefaultMode));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(ChatDefaults.modes(settings), {'claude-code': 'ask'});
    expect(find.text('Ask'), findsOneWidget);
    await tester.tap(dropdown(l10n.generalSettingsDefaultMode));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.generalSettingsLastUsed).last);
    await tester.pumpAndSettle();
    expect(settings[ChatDefaults.modesKey], isNull);
    await tester.tap(dropdown(l10n.generalSettingsDefaultAgent));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.generalSettingsLastUsed).last);
    await tester.pumpAndSettle();
    expect(settings[ChatDefaults.agentKey], isNull);
  });
}

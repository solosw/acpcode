import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/kernel/acp/acp_agent.dart';
import 'package:baocode/kernel/acp_agents.dart';
import 'package:baocode/kernel/acp_registry.dart';
import 'package:baocode/settings/pages/agent_edit_dialog.dart';
import 'package:baocode/settings/pages/agent_registry_picker.dart';
import 'package:baocode/settings/pages/agents_page.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _entry = AcpRegistryEntry(
  id: 'codex-acp',
  name: 'Codex',
  description: 'Coding agent',
  version: '2.5.0',
  distribution: {
    'npx': {'package': '@agentclientprotocol/codex-acp@2.5.0'},
  },
);

class _Registry extends AcpRegistry {
  int loads = 0;
  int installs = 0;
  bool failLoad = false;
  bool failInstall = false;
  AcpRegistryEntry? lastInstalled;
  AcpRegistryEntry offered = _entry;
  String targetPlatform = 'darwin-aarch64';
  Completer<AcpAgentConfig>? pending;
  void Function(AcpInstallPlan, int?, int?)? reportProgress;

  @override
  String get platform => targetPlatform;

  @override
  Future<List<AcpRegistryEntry>> load() async {
    loads++;
    if (failLoad) throw StateError('Registry unavailable');
    return [
      offered,
      const AcpRegistryEntry(
        id: 'unsupported',
        name: 'Other Agent',
        description: 'Unavailable',
        version: '1.0',
        distribution: {},
      ),
    ];
  }

  @override
  Future<AcpAgentConfig> cache(
    AcpRegistryEntry entry, {
    void Function(AcpInstallPlan, int?, int?)? onProgress,
  }) async {
    installs++;
    lastInstalled = entry;
    reportProgress = onProgress;
    if (failInstall) throw StateError('npm is missing');
    return pending?.future ??
        AcpAgentConfig(
          id: entry.id,
          label: entry.name,
          command: '',
          registry: entry,
        );
  }
}

Finder _input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);
Finder _button(String label) => find.widgetWithText(IdeButton, label).last;

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.pump();
  await tester.ensureVisible(_button(label));
  await tester.tap(_button(label));
  await tester.pumpAndSettle();
}

void main() {
  late Directory temporary;
  late UserSettings settings;
  late AcpAgents agents;
  late _Registry registry;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('baocode-agent-dialog-');
    settings = UserSettings(p.join(temporary.path, 'settings.json'));
    agents = AcpAgents(settings);
    registry = _Registry();
  });
  tearDown(() {
    agents.dispose();
    settings.dispose();
    temporary.deleteSync(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    List<String> hosts = const [],
    String initialHost = '',
    Future<String?> Function(BuildContext, String)? pickRemoteDirectory,
  }) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentsSettingsPage(
            agents: agents,
            registry: registry,
            hosts: hosts,
            initialHost: initialHost,
            pickRemoteDirectory: pickRemoteDirectory ?? (_, _) async => null,
            customizations: CustomizationStore(
              configDir: p.join(temporary.path, '.claude'),
              homeDir: temporary.path,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(_button('Save'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 30));
        if (find.byType(AgentEditDialog).evaluate().isEmpty) return;
      }
      fail('Agent was not saved');
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'list only; add and cancel do not create placeholder configuration',
    (tester) async {
      await pumpPage(tester);
      expect(find.byType(EditableText), findsNothing);
      await _tap(tester, 'Add agent');
      expect(find.byType(AgentEditDialog), findsOneWidget);
      expect(agents.agents, isEmpty);
      await tester.enterText(_input('agent-name'), 'Discard me');
      await _tap(tester, 'Cancel');
      expect(agents.agents, isEmpty);
      expect(find.byType(EditableText), findsNothing);
      expect(registry.loads, 0);
    },
  );

  testWidgets('validates manual configuration without a server selector', (
    tester,
  ) async {
    final choices = [p.join(temporary.path, 'my rules'), null];
    var picks = 0;
    await pumpPage(
      tester,
      hosts: ['dev', 'prod'],
      pickRemoteDirectory: (_, host) async {
        expect(host, 'dev');
        return choices[picks++];
      },
    );
    await _tap(tester, 'Add agent');
    await _tap(tester, 'Save');
    expect(find.text('Name and command are required.'), findsOneWidget);
    await tester.enterText(_input('agent-name'), 'Example');
    await tester.enterText(_input('agent-command'), 'example');
    await tester.enterText(_input('agent-arguments'), '[1]');
    await _tap(tester, 'Save');
    expect(
      find.text('Arguments must be a JSON array of strings.'),
      findsOneWidget,
    );
    await tester.enterText(
      _input('agent-arguments'),
      ' ["--profile", "profile with spaces"] ',
    );
    await tester.enterText(_input('agent-environment'), 'INVALID');
    await _tap(tester, 'Save');
    expect(
      find.text('Use KEY=value on each non-empty environment line.'),
      findsOneWidget,
    );
    await tester.enterText(
      _input('agent-environment'),
      'KEY=hello world\nTOKEN=a=b',
    );
    expect(_input('agent-skills'), findsNothing);
    final button = find.byKey(const ValueKey('agent-rules-browse'));
    for (var i = 0; i < choices.length; i++) {
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(picks, 2);
    expect(find.byKey(const ValueKey('agent-server')), findsNothing);
    await save(tester);
    final config = agents.agents.single;
    final agent = config.forHost('dev');
    expect(agent.arguments, ['--profile', 'profile with spaces']);
    expect(agent.environment, {'KEY': 'hello world', 'TOKEN': 'a=b'});
    expect(agent.skillsDirectory, isEmpty);
    expect(agent.rulesDirectory, choices.first);
    expect(config.hostScoped, isTrue);
    expect(agent.command, 'example');
    expect(() => config.forHost('prod'), throwsStateError);
    expect(() => config.forHost(null), throwsStateError);
    expect(find.byType(EditableText), findsNothing);
    expect(registry.installs, 0);
  });

  testWidgets(
    'edit preserves id; cancel preserves saved values; delete needs confirmation',
    (tester) async {
      await tester.runAsync(
        () => agents.add(
          const AcpAgentConfig(
            id: 'original',
            label: 'Original',
            command: 'agent',
            description: 'Description',
          ),
        ),
      );
      await pumpPage(tester);
      expect(find.byType(EditableText), findsNothing);
      await _tap(tester, 'Edit agent');
      await tester.enterText(_input('agent-name'), 'Discarded');
      await _tap(tester, 'Cancel');
      expect(agents.agents.single.label, 'Original');
      await _tap(tester, 'Edit agent');
      await tester.enterText(_input('agent-name'), 'Renamed');
      await save(tester);
      expect(agents.agents.single.id, 'original');
      expect(agents.agents.single.description, 'Description');
      expect(agents.agents.single.label, 'Renamed');
      await _tap(tester, 'Delete');
      await _tap(tester, 'Cancel');
      expect(agents.agents, hasLength(1));
      await _tap(tester, 'Delete');
      await tester.runAsync(() async {
        await tester.tap(_button('Delete'));
        for (var i = 0; i < 100 && agents.agents.isNotEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(agents.agents, isEmpty);
    },
  );

  testWidgets(
    'registry searches and previews; cancel installs nothing; explicit installation fills form',
    (tester) async {
      await pumpPage(tester);
      await _tap(tester, 'Add agent');
      await _tap(tester, 'ACP Registry');
      expect(registry.loads, 1);
      expect(registry.installs, 0);
      final search = find.descendant(
        of: find.byType(AgentRegistryPicker),
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, 'Codex');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('registry-unsupported')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('registry-codex-acp')));
      await tester.pumpAndSettle();
      await _tap(tester, 'Install and configure');
      expect(
        find.textContaining('may run package installation scripts'),
        findsOneWidget,
      );
      await _tap(tester, 'Cancel');
      expect(registry.installs, 0);
      expect(agents.agents, isEmpty);
      await _tap(tester, 'Install and configure');
      await _tap(tester, 'Install and configure');
      expect(registry.installs, 1);
      expect(_input('agent-command'), findsNothing);
      expect(agents.agents, isEmpty); // Installation does not implicitly save.
      await save(tester);
      expect(agents.agents.single.label, 'Codex');
      expect(agents.agents.single.registry?.id, _entry.id);
    },
  );

  testWidgets(
    'editing offers the matching registry update and saves it explicitly',
    (tester) async {
      await tester.runAsync(
        () => agents.add(
          const AcpAgentConfig(
            id: 'my-codex',
            label: 'My Codex',
            command: '',
            hostScoped: true,
            rulesDirectory: '/rules',
            registry: _entry,
          ),
        ),
      );
      await pumpPage(tester);
      await _tap(tester, 'Edit agent');
      await _tap(tester, 'Update agent');
      expect(find.textContaining('has no newer package'), findsOneWidget);
      await _tap(tester, 'Download current version');
      await _tap(tester, 'Download current version');
      expect(registry.lastInstalled?.version, '2.5.0');
      await save(tester);
      expect(agents.agents.single.registry?.version, '2.5.0');
      expect(agents.agents.single.registryImported, isFalse);
      registry.installs = 0;

      registry.offered = const AcpRegistryEntry(
        id: 'codex-acp',
        name: 'Codex',
        description: 'Coding agent',
        version: '2.6.0',
        distribution: {
          'npx': {'package': '@agentclientprotocol/codex-acp@2.6.0'},
        },
      );
      await _tap(tester, 'Edit agent');
      await _tap(tester, 'Update agent');
      expect(find.text('Codex · 2.5.0 → 2.6.0'), findsOneWidget);
      await _tap(tester, 'Update agent');
      await _tap(tester, 'Cancel');
      expect(registry.installs, 0);
      await _tap(tester, 'Update agent');
      await _tap(tester, 'Update agent');
      expect(registry.lastInstalled?.version, '2.6.0');
      expect(agents.agents.single.registry?.version, '2.5.0');
      await save(tester);
      final saved = agents.agents.single;
      expect(saved.registry?.version, '2.6.0');
      expect(saved.id, 'my-codex');
      expect(saved.label, 'My Codex');
      expect(saved.rulesDirectory, '/rules');
      expect(saved.hostScoped, isTrue);
    },
  );

  testWidgets('legacy imports missing from the catalog open saved JSON', (
    tester,
  ) async {
    const entry = AcpRegistryEntry(
      id: 'legacy-import',
      name: 'Legacy Import',
      description: '',
      version: '1.0.0',
      distribution: {
        'npx': {'package': 'legacy-import@1.0.0'},
      },
    );
    await tester.runAsync(
      () => agents.add(
        const AcpAgentConfig(
          id: 'legacy-import',
          label: 'Legacy Import',
          command: '',
          registry: entry,
        ),
      ),
    );
    expect(agents.agents.single.registryImported, isFalse);
    await pumpPage(tester);
    await _tap(tester, 'Edit agent');
    await _tap(tester, 'Update agent');
    expect(registry.loads, 1);
    final field = tester.widget<EditableText>(_input('registry-json'));
    expect(jsonDecode(field.controller.text), entry.toJson());
    await _tap(tester, 'Preview entries');
    await _tap(tester, 'Update agent');
    await _tap(tester, 'Update agent');
    await save(tester);
    expect(agents.agents.single.registryImported, isTrue);
  });

  testWidgets(
    'registry failures can retry and unsupported distributions cannot install',
    (tester) async {
      registry.failLoad = true;
      await pumpPage(tester);
      await _tap(tester, 'Add agent');
      await _tap(tester, 'ACP Registry');
      expect(
        find.textContaining('Could not load the ACP Registry'),
        findsOneWidget,
      );
      registry.failLoad = false;
      await _tap(tester, 'Retry');
      expect(registry.loads, 2);
      await tester.tap(find.byKey(const ValueKey('registry-unsupported')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<IdeButton>(_button('Install and configure')).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('registry-codex-acp')));
      await tester.pumpAndSettle();
      registry.failInstall = true;
      await _tap(tester, 'Install and configure');
      await _tap(tester, 'Install and configure');
      expect(find.textContaining('Installation failed.'), findsOneWidget);
      expect(agents.agents, isEmpty);
      registry.failInstall = false;
      await _tap(tester, 'Install and configure');
      await _tap(tester, 'Install and configure');
      expect(registry.installs, 2);
      expect(_input('agent-name'), findsOneWidget);
    },
  );

  testWidgets('manual form and registry fit a smaller desktop window', (
    tester,
  ) async {
    await pumpPage(tester, hosts: ['dev']);
    tester.view.physicalSize = const Size(520, 680);
    await tester.pumpAndSettle();
    await _tap(tester, 'Add agent');
    final rules = find.byKey(const ValueKey('agent-rules-browse'));
    await tester.ensureVisible(rules);
    expect(tester.takeException(), isNull);
    await _tap(tester, 'ACP Registry');
    await tester.tap(find.byKey(const ValueKey('registry-codex-acp')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Cancel');
  });

  testWidgets('editing preserves legacy host configurations and skills', (
    tester,
  ) async {
    await tester.runAsync(
      () => agents.add(
        const AcpAgentConfig(
          id: 'legacy',
          label: 'SSH Agent',
          command: '',
          skillsDirectory: '/local/old-skills',
          hostScoped: true,
          hostConfigurations: {
            'dev': AcpAgentConfig(
              id: 'legacy',
              label: 'SSH Agent',
              command: '/srv/bin/agent',
              arguments: ['--profile', 'dev build'],
              environment: {'TOKEN': 'remote-only'},
              skillsDirectory: '/srv/skills',
              rulesDirectory: '/srv/rules',
            ),
          },
        ),
      ),
    );
    await pumpPage(tester, hosts: ['dev'], initialHost: 'dev');
    await _tap(tester, 'Edit agent');
    expect(find.byKey(const ValueKey('agent-server')), findsNothing);
    expect(find.text('This machine'), findsNothing);
    expect(find.text('Preview skills copy'), findsNothing);
    expect(
      tester.widget<EditableText>(_input('agent-command')).controller.text,
      '/srv/bin/agent',
    );
    await tester.enterText(_input('agent-name'), 'Renamed');
    await save(tester);
    final saved = agents.agents.single;
    expect(saved.id, 'legacy');
    expect(saved.label, 'Renamed');
    expect(saved.hostScoped, isTrue);
    expect(saved.skillsDirectory, '/local/old-skills');
    final remote = saved.forHost('dev');
    expect(remote.command, '/srv/bin/agent');
    expect(remote.arguments, ['--profile', 'dev build']);
    expect(remote.environment, {'TOKEN': 'remote-only'});
    expect(remote.skillsDirectory, '/srv/skills');
    expect(remote.rulesDirectory, '/srv/rules');
    expect(() => saved.forHost('other'), throwsStateError);
  });

  testWidgets('registry templates switch recipes without losing drafts', (
    tester,
  ) async {
    await pumpPage(tester);
    await _tap(tester, 'Add agent');
    await _tap(tester, 'ACP Registry');
    await _tap(tester, 'Enter registry JSON');
    final input = _input('registry-json');
    String text() => tester.widget<EditableText>(input).controller.text;
    Map distribution() => (jsonDecode(text()) as Map)['distribution'] as Map;

    expect(distribution(), contains('npx'));
    await _tap(tester, 'uv template');
    expect(distribution()['uvx']['package'], '<python-package>==1.0.0');
    const draft = '{"id": "draft"}';
    await tester.enterText(input, draft);
    await _tap(tester, 'Executable archive template');
    await _tap(tester, 'Cancel');
    expect(text(), draft);
    await _tap(tester, 'Executable archive template');
    await _tap(tester, 'Replace draft');
    final builds = distribution()['binary'] as Map;
    expect(builds['linux-x86_64']['archive'], contains('.tar.gz'));
    expect(builds['windows-x86_64']['cmd'], './my-agent.exe');
    await _tap(tester, 'npm template');
    expect(distribution(), contains('npx'));
    expect(registry.installs, 0);
  });

  testWidgets('JSON import recovers from errors and works offline', (
    tester,
  ) async {
    registry.failLoad = true;
    await pumpPage(tester, hosts: ['dev']);
    await _tap(tester, 'Add agent');
    await _tap(tester, 'ACP Registry');
    await _tap(tester, 'Enter registry JSON');
    final json = _input('registry-json');
    final template = tester.widget<EditableText>(json).controller.text;
    expect(jsonDecode(template), contains('distribution'));
    expect(template, contains('<npm-package>'));
    await _tap(tester, 'Preview entries');
    expect(registry.installs, 0);
    await tester.enterText(json, '{');
    await _tap(tester, 'Browse official registry');
    await _tap(tester, 'Enter registry JSON');
    expect(tester.widget<EditableText>(json).controller.text, '{');
    await _tap(tester, 'Preview entries');
    expect(
      find.textContaining('Could not read the registry JSON.'),
      findsOneWidget,
    );
    expect(registry.installs, 0);

    const entry = {
      'id': 'typed-agent',
      'name': 'Typed Agent',
      'version': '1.0.0',
      'distribution': {
        'npx': {'package': 'typed-agent@1.0.0'},
      },
    };
    await tester.enterText(json, jsonEncode(entry));
    await _tap(tester, 'Preview entries');
    expect(
      find.textContaining('Could not read the registry JSON.'),
      findsNothing,
    );
    expect(find.textContaining('typed-agent@1.0.0'), findsAtLeastNWidgets(1));
    await tester.enterText(json, jsonEncode([entry]));
    await tester.pump();
    expect(
      find.widgetWithText(IdeButton, 'Install and configure'),
      findsNothing,
    );
    await _tap(tester, 'Preview entries');
    await _tap(tester, 'Install and configure');
    await _tap(tester, 'Install and configure');
    expect(registry.installs, 1);
    expect(registry.lastInstalled?.id, 'typed-agent');
    expect(find.byKey(const ValueKey('agent-server')), findsNothing);
    expect(_input('agent-command'), findsNothing);
    await save(tester);
    expect(agents.agents.single.label, 'Typed Agent');
    expect(agents.agents.single.registry?.id, 'typed-agent');
    final remote = agents.agents.single.forHost('dev');
    expect(remote.registry?.id, 'typed-agent');
    expect(agents.agents.single.hostConfigurations, isEmpty);
  });

  testWidgets('registry document lets users select a remote-only binary', (
    tester,
  ) async {
    await pumpPage(tester);
    await _tap(tester, 'Add agent');
    await _tap(tester, 'ACP Registry');
    await _tap(tester, 'Enter registry JSON');
    await tester.enterText(
      _input('registry-json'),
      jsonEncode({
        'agents': [
          {
            'id': 'another',
            'name': 'Another Agent',
            'version': '1.0.0',
            'distribution': {
              'npx': {'package': 'another@1.0.0'},
            },
          },
          {
            'id': 'remote-binary',
            'name': 'Remote Binary',
            'version': '1.0.0',
            'distribution': {
              'binary': {
                'linux-x86_64': {
                  'archive': 'https://example.com/remote-linux.tar.gz',
                  'cmd': './remote',
                },
                'windows-x86_64': {
                  'archive': 'https://example.com/remote-windows.zip',
                  'cmd': './remote.exe',
                },
              },
            },
          },
        ],
      }),
    );
    await _tap(tester, 'Preview entries');
    expect(
      find.widgetWithText(IdeButton, 'Install and configure'),
      findsNothing,
    );
    final tile = find.byKey(const ValueKey('registry-remote-binary'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(
      find.text('Source: https://example.com/remote-linux.tar.gz'),
      findsOneWidget,
    );
    expect(
      find.text('Source: https://example.com/remote-windows.zip'),
      findsOneWidget,
    );
    registry.pending = Completer<AcpAgentConfig>();
    await _tap(tester, 'Install and configure');
    await tester.tap(_button('Install and configure'));
    await tester.pump();
    final entry = registry.lastInstalled!;
    expect(entry.id, 'remote-binary');
    registry.reportProgress!(entry.binaryPlans.first, 50, 100);
    await tester.pump();
    expect(
      find.textContaining('Downloading package · linux-x86_64 · 1/2 · 50%'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    registry.reportProgress!(entry.binaryPlans.last, 1 << 20, null);
    await tester.pump();
    expect(
      find.textContaining('windows-x86_64 · 2/2 · 1.0 MiB'),
      findsOneWidget,
    );
    registry.reportProgress!(entry.binaryPlans.last, null, null);
    await tester.pump();
    expect(find.textContaining('Saving package'), findsOneWidget);
    registry.pending!.complete(
      AcpAgentConfig(
        id: entry.id,
        label: entry.name,
        command: '',
        registry: entry,
      ),
    );
    await tester.pumpAndSettle();
    await save(tester);
    expect(agents.agents.single.command, isEmpty);
    expect(agents.agents.single.registry?.id, 'remote-binary');
    expect(agents.agents.single.registryImported, isTrue);
    final loads = registry.loads;
    registry.failLoad = true;
    await _tap(tester, 'Edit agent');
    await tester.enterText(_input('agent-name'), 'Remote Renamed');
    await _tap(tester, 'Update agent');
    expect(registry.loads, loads);
    final input = _input('registry-json');
    final savedJson = tester.widget<EditableText>(input).controller.text;
    expect(jsonDecode(savedJson), entry.toJson());
    await tester.enterText(input, jsonEncode(_entry.toJson()));
    await _tap(tester, 'Preview entries');
    expect(
      find.textContaining('must include the agent being updated'),
      findsOneWidget,
    );
    final next = jsonDecode(savedJson) as Map;
    next['version'] = '2.0.0';
    next['distribution']['binary']['linux-x86_64']['cmd'] = 'remote';
    await tester.enterText(input, jsonEncode(next));
    await _tap(tester, 'Preview entries');
    registry.pending = null;
    await _tap(tester, 'Update agent');
    await _tap(tester, 'Update agent');
    expect(agents.agents.single.registry?.version, '1.0.0');
    await save(tester);
    expect(agents.agents.single.label, 'Remote Renamed');
    final updated = agents.agents.single.registry!;
    expect(updated.id, 'remote-binary');
    expect(updated.version, '2.0.0');
    expect(updated.binaryPlanFor('linux-x86_64')?.command, 'remote');
    final disk = jsonDecode(
      File(p.join(temporary.path, 'settings.json')).readAsStringSync(),
    ) as Map;
    final stored = (disk[AcpAgents.settingKey] as List).single as Map;
    expect(stored['registryImported'], isTrue);
    expect(stored['registry'], next);
    await _tap(tester, 'Edit agent');
    await _tap(tester, 'Update agent');
    expect(registry.loads, loads);
    expect(
      jsonDecode(tester.widget<EditableText>(input).controller.text),
      next,
    );
  });

  testWidgets('installation cannot be dismissed while it is running', (
    tester,
  ) async {
    registry.pending = Completer<AcpAgentConfig>();
    await pumpPage(tester);
    await _tap(tester, 'Add agent');
    await _tap(tester, 'ACP Registry');
    await tester.tap(find.byKey(const ValueKey('registry-codex-acp')));
    await tester.pumpAndSettle();
    await _tap(tester, 'Install and configure');
    await tester.tap(_button('Install and configure'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<IdeButton>(_button('Cancel')).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(AgentEditDialog), findsOneWidget);
    registry.pending!.complete(
      const AcpAgentConfig(id: 'test', label: 'Test', command: 'test'),
    );
    await tester.pumpAndSettle();
    expect(_input('agent-name'), findsOneWidget);
  });
}

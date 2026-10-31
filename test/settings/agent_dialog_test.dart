import 'dart:async';
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
import 'package:flutter/services.dart';
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
  String launchCommand = 'npx';
  String targetPlatform = 'darwin-aarch64';
  Completer<AcpAgentConfig>? pending;

  @override
  String get platform => targetPlatform;

  @override
  Future<List<AcpRegistryEntry>> load() async {
    loads++;
    if (failLoad) throw StateError('Registry unavailable');
    return [
      _entry,
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
  Future<AcpAgentConfig> install(AcpRegistryEntry entry) async {
    installs++;
    if (failInstall) throw StateError('npm is missing');
    return pending?.future ??
        AcpAgentConfig(
          id: 'codex-acp',
          label: 'Codex',
          command: launchCommand,
          arguments: ['-y', '@agentclientprotocol/codex-acp@2.5.0'],
        );
  }
}

Finder _input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);
Finder _button(String label) => find.widgetWithText(IdeButton, label).last;

Future<void> _tap(WidgetTester tester, String label) async {
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
    Future<String?> Function()? pickDirectory,
    List<String> hosts = const [],
    String initialHost = '',
    Future<AcpRegistry> Function(String, AcpRegistry, bool)? connectRegistry,
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
            pickDirectory: pickDirectory,
            hosts: hosts,
            initialHost: initialHost,
            connectRegistry: connectRegistry ?? (_, _, _) async => registry,
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

  testWidgets(
    'validates form and saves arguments, environment and native folder picks',
    (tester) async {
      final choices = <String?>[
        p.join(temporary.path, 'my skills'),
        null,
        p.join(temporary.path, 'my rules'),
      ];
      var picks = 0;
      await pumpPage(tester, pickDirectory: () async => choices[picks++]);
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
      for (final key in ['agent-skills', 'agent-skills', 'agent-rules']) {
        final button = find.byKey(ValueKey('$key-browse'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }
      expect(picks, 3);
      expect(
        tester.widget<EditableText>(_input('agent-skills')).controller.text,
        choices[0],
      );
      await save(tester);
      final agent = agents.agents.single;
      expect(agent.arguments, ['--profile', 'profile with spaces']);
      expect(agent.environment, {'KEY': 'hello world', 'TOKEN': 'a=b'});
      expect(agent.skillsDirectory, choices[0]);
      expect(agent.rulesDirectory, choices[2]);
      expect(find.byType(EditableText), findsNothing);
      expect(registry.installs, 0);
    },
  );

  testWidgets('default folder button invokes desktop native picker channel', (
    tester,
  ) async {
    final methods = <String>[];
    const channel = MethodChannel('baocode/window');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      methods.add(call.method);
      return '/chosen/skills';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pumpPage(tester);
    await _tap(tester, 'Add agent');
    final button = find.byKey(const ValueKey('agent-skills-browse'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(methods, ['pickDirectory']);
    expect(
      tester.widget<EditableText>(_input('agent-skills')).controller.text,
      '/chosen/skills',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
      expect(
        tester.widget<EditableText>(_input('agent-command')).controller.text,
        'npx',
      );
      expect(
        tester.widget<EditableText>(_input('agent-arguments')).controller.text,
        '["-y","@agentclientprotocol/codex-acp@2.5.0"]',
      );
      expect(agents.agents, isEmpty); // Installation does not implicitly save.
      await save(tester);
      expect(agents.agents.single.label, 'Codex');
    },
  );

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
    await pumpPage(tester);
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

  testWidgets(
    'remote install targets its host and selected network without altering local config',
    (tester) async {
      await tester.runAsync(
        () => agents.add(
          const AcpAgentConfig(
            id: 'existing',
            label: 'Existing',
            command: '/local/agent',
            environment: {'TOKEN': 'local-only'},
            hostScoped: true,
          ),
        ),
      );
      final remote = _Registry()
        ..launchCommand = '/srv/bin/agent'
        ..targetPlatform = 'linux-aarch64';
      final choices = <bool>[];
      await pumpPage(
        tester,
        hosts: ['dev'],
        connectRegistry: (host, local, network) async {
          expect(host, 'dev');
          choices.add(network);
          return remote;
        },
      );
      tester.view.physicalSize = const Size(520, 680);
      await tester.pumpAndSettle();
      await _tap(tester, 'Edit agent');
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('agent-target')),
          )
          .onChanged!('dev');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_input('agent-command')).controller.text,
        isEmpty,
      );
      expect(
        tester
            .widget<EditableText>(_input('agent-environment'))
            .controller
            .text,
        isEmpty,
      );
      await _tap(tester, 'ACP Registry');
      expect(tester.takeException(), isNull);
      tester
          .widget<DropdownButton<bool>>(
            find.byKey(const ValueKey('agent-install-network')),
          )
          .onChanged!(false);
      await tester.pumpAndSettle();
      final item = find.byKey(const ValueKey('registry-codex-acp'));
      await tester.ensureVisible(item);
      await tester.tap(item);
      await tester.pumpAndSettle();
      await _tap(tester, 'Install and configure');
      expect(
        find.textContaining('Configuration / installation target: dev'),
        findsOneWidget,
      );
      expect(find.textContaining('Use server network'), findsWidgets);
      await _tap(tester, 'Cancel');
      expect(remote.installs, 0);
      await _tap(tester, 'Install and configure');
      await _tap(tester, 'Install and configure');
      expect(remote.installs, 1);
      expect(registry.installs, 0);
      expect(choices.last, isFalse);
      expect(
        tester.widget<EditableText>(_input('agent-command')).controller.text,
        '/srv/bin/agent',
      );
      expect(tester.takeException(), isNull);
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('agent-target')),
          )
          .onChanged!('');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_input('agent-command')).controller.text,
        '/local/agent',
      );
      expect(
        tester
            .widget<EditableText>(_input('agent-environment'))
            .controller
            .text,
        'TOKEN=local-only',
      );
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('agent-target')),
          )
          .onChanged!('dev');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_input('agent-command')).controller.text,
        '/srv/bin/agent',
      );
      await save(tester);
      final saved = agents.agents.single;
      expect(saved.id, 'existing');
      expect(saved.command, '/local/agent');
      expect(saved.environment, {'TOKEN': 'local-only'});
      expect(saved.forHost('dev').command, '/srv/bin/agent');
      expect(saved.forHost('dev').environment, isEmpty);
      expect(() => saved.forHost('other'), throwsStateError);
    },
  );

  testWidgets(
    'remote folders never invoke native local picker; cancellation keeps path',
    (tester) async {
      var nativeCalls = 0;
      var remoteCalls = 0;
      await pumpPage(
        tester,
        hosts: ['dev'],
        initialHost: 'dev',
        pickDirectory: () async {
          nativeCalls++;
          return '/wrong-host';
        },
        pickRemoteDirectory: (_, host) async {
          expect(host, 'dev');
          remoteCalls++;
          return remoteCalls == 1 ? '/srv/skills' : null;
        },
      );
      await _tap(tester, 'Add agent');
      await tester.enterText(_input('agent-name'), 'Remote only');
      await tester.enterText(_input('agent-command'), '/srv/agent');
      final skills = find.byKey(const ValueKey('agent-skills-browse'));
      await tester.ensureVisible(skills);
      await tester.tap(skills);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_input('agent-skills')).controller.text,
        '/srv/skills',
      );
      await tester.enterText(_input('agent-rules'), '/srv/existing-rules');
      final rules = find.byKey(const ValueKey('agent-rules-browse'));
      await tester.ensureVisible(rules);
      await tester.tap(rules);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_input('agent-rules')).controller.text,
        '/srv/existing-rules',
      );
      expect(nativeCalls, 0);
      await save(tester);
      final saved = agents.agents.single;
      expect(saved.command, isEmpty);
      expect(saved.forHost('dev').rulesDirectory, '/srv/existing-rules');
      expect(() => saved.forHost(null), throwsStateError);
    },
  );

  testWidgets(
    'SSH connection failure can retry and never invokes local installer',
    (tester) async {
      var failConnection = true;
      await pumpPage(
        tester,
        hosts: ['dev'],
        initialHost: 'dev',
        connectRegistry: (_, _, _) async {
          if (failConnection) throw StateError('SSH connection lost');
          return registry;
        },
      );
      await _tap(tester, 'Add agent');
      await _tap(tester, 'ACP Registry');
      expect(find.textContaining('SSH connection lost'), findsOneWidget);
      expect(registry.installs, 0);
      failConnection = false;
      await _tap(tester, 'Retry');
      expect(find.byKey(const ValueKey('registry-codex-acp')), findsOneWidget);
      await _tap(tester, 'Cancel');
      expect(agents.agents, isEmpty);
    },
  );

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

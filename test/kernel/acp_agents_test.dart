import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/acp/acp_agent.dart';
import 'package:baocode/kernel/acp_agents.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late UserSettings settings;
  late AcpAgents agents;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('baocode-agent-settings-');
    settings = UserSettings(p.join(temporary.path, 'settings.json'));
    agents = AcpAgents(settings);
  });
  tearDown(() {
    agents.dispose();
    settings.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('stores and reads multiple ACP agent configurations', () async {
    final first = const AcpAgentConfig(
      id: 'claude-acp',
      label: 'Claude ACP',
      command: 'claude',
      arguments: ['--acp'],
      environment: {'MODE': 'test'},
      skillsDirectory: '~/agent/skills',
      rulesDirectory: '~/agent/rules',
    );
    final second = const AcpAgentConfig(
      id: 'codex-acp',
      label: 'Codex ACP',
      command: 'codex',
    );
    await agents.save([first, second]);
    expect(agents.agents.map((agent) => agent.id), ['claude-acp', 'codex-acp']);
    expect(agents.agents.first.arguments, ['--acp']);
    expect(agents.agents.first.environment['MODE'], 'test');
    expect(agents.agents.first.skillsDirectory, '~/agent/skills');
    expect(agents.agents.first.rulesDirectory, '~/agent/rules');
    expect(agents.agents.last.skillsDirectory, isEmpty);
    expect(agents.agents.last.rulesDirectory, isEmpty);
    await settings.load();
    expect(agents.agents.first.rulesDirectory, '~/agent/rules');
    await agents.remove(first.id);
    expect(agents.agents.map((agent) => agent.id), ['codex-acp']);
  });

  test(
    'host configurations persist and never reuse local credentials',
    () async {
      await agents.add(
        const AcpAgentConfig(
          id: 'scoped',
          label: 'Scoped',
          command: '/local/agent',
          hostScoped: true,
          environment: {'TOKEN': 'local-only'},
          hostConfigurations: {
            'dev': AcpAgentConfig(
              id: 'scoped',
              label: 'Scoped',
              command: '/remote/agent',
              arguments: ['with spaces'],
              environment: {'TOKEN': 'remote-only'},
              skillsDirectory: '/remote/skills',
            ),
          },
        ),
      );
      await settings.load();
      final agent = agents.agents.single;
      expect(agent.forHost(null).environment, {'TOKEN': 'local-only'});
      expect(agent.forHost('dev').command, '/remote/agent');
      expect(agent.forHost('dev').arguments, ['with spaces']);
      expect(agent.forHost('dev').environment, {'TOKEN': 'remote-only'});
      expect(agent.forHost('dev').skillsDirectory, '/remote/skills');
      expect(() => agent.forHost('other'), throwsStateError);
      expect(agent.hostScoped, isTrue);
    },
  );

  test(
    'remote-only and legacy entries have explicit, different resolution',
    () {
      const legacy = AcpAgentConfig(
        id: 'legacy',
        label: 'Legacy',
        command: 'agent',
      );
      expect(legacy.forHost('dev'), same(legacy));
      const remote = AcpAgentConfig(
        id: 'remote',
        label: 'Remote',
        command: '',
        hostScoped: true,
        hostConfigurations: {
          'dev': AcpAgentConfig(
            id: 'remote',
            label: 'Remote',
            command: 'agent',
          ),
        },
      );
      expect(remote.forHost('dev').command, 'agent');
      expect(() => remote.forHost(null), throwsStateError);
      expect(() => remote.forHost('other'), throwsStateError);
    },
  );

  test(
    'legacy and malformed customization fields default to disabled',
    () async {
      await settings.update(AcpAgents.settingKey, [
        {'id': 'old', 'label': 'Old', 'command': 'agent'},
        {'id': 'invalid', 'skillsDirectory': 42, 'rulesDirectory': false},
      ]);
      for (final agent in agents.agents) {
        expect(agent.skillsDirectory, isEmpty);
        expect(agent.rulesDirectory, isEmpty);
      }
      await agents.save(agents.agents);
      for (final json in settings[AcpAgents.settingKey] as List) {
        expect((json as Map).containsKey('skillsDirectory'), isFalse);
        expect(json.containsKey('rulesDirectory'), isFalse);
      }
    },
  );
}

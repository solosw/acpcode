import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/customize/customization_disk.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/kernel/acp/acp_kernel.dart';
import 'package:baocode/kernel/acp/acp_skills.dart';
import 'package:baocode/kernel/acp/acp_skills_io.dart';
import 'package:baocode/kernel/acp/acp_system_prompt.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeAcpTransport implements AcpTransport {
  _FakeAcpTransport({
    this.agentCapabilities = const {},
    this.initialCommands = const [],
  });

  final Map<String, Object?> agentCapabilities;
  final List<Map<String, Object?>> initialCommands;
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast(sync: true);
  final List<Map<String, Object?>> written = [];

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  void emitUpdate(Map<String, Object?> update) {
    _out.add({
      'jsonrpc': '2.0',
      'method': 'session/update',
      'params': {'sessionId': 'sess_1', 'update': update},
    });
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    final id = message['id'];
    switch (method) {
      case 'initialize':
        _respond(id, {
          'protocolVersion': 1,
          'agentInfo': {'name': 'fake-acp'},
          if (agentCapabilities.isNotEmpty)
            'agentCapabilities': agentCapabilities,
        });
      case 'session/new':
        _respond(id, {
          'sessionId': 'sess_1',
          if (initialCommands.isNotEmpty) 'availableCommands': initialCommands,
        });
      case 'session/load':
        _respond(id, {
          if (initialCommands.isNotEmpty) 'availableCommands': initialCommands,
        });
      case 'session/prompt':
        _respond(id, {'sessionId': 'sess_1', 'stopReason': 'end_turn'});
    }
  }

  void _respond(Object? id, Map<String, Object?> result) {
    if (id == null) return;
    _out.add({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

class _MemoryDisk implements CustomizationDisk {
  _MemoryDisk(this.files);

  final Map<String, String> files;

  @override
  bool get isLocal => false;

  @override
  p.Context get paths => p.posix;

  @override
  Future<String> configDir() async => '/home/dev/.claude';

  @override
  Future<String?> homeDir() async => '/home/dev';

  @override
  Future<String?> read(String path) async => files[path];

  @override
  Future<void> write(String path, String text) async => files[path] = text;

  @override
  Future<void> delete(String path) async => files.remove(path);

  @override
  Future<bool?> isDirectory(String path) async {
    if (files.containsKey(path)) return false;
    final prefix = path.endsWith('/') ? path : '$path/';
    if (files.keys.any((k) => k.startsWith(prefix))) return true;
    return null;
  }

  @override
  Future<List<({String path, bool directory})>> children(String path) async {
    final prefix = path.endsWith('/') ? path : '$path/';
    final seen = <String, bool>{};
    for (final key in files.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        seen[key] = false;
      } else {
        seen['$prefix${rest.substring(0, slash)}'] = true;
      }
    }
    return [
      for (final entry in seen.entries)
        (path: entry.key, directory: entry.value),
    ];
  }
}

KernelDescriptor _descriptor() => KernelDescriptor(
  id: 'acp-test',
  label: 'ACP Test',
  icon: Icons.hub_rounded,
  description: 'Test',
  create: (_) => throw UnimplementedError(),
);

void main() {
  group('AcpSystemPromptCapabilities & resolveAcpSystemPrompt', () {
    test('parses v1 and v2 systemPrompt capability shapes', () {
      expect(AcpSystemPromptCapabilities.parse(null).supported, isFalse);
      expect(
        AcpSystemPromptCapabilities.parse({'sessionCapabilities': {}}).supported,
        isFalse,
      );

      final v1Append = AcpSystemPromptCapabilities.parse({
        'sessionCapabilities': {'systemPrompt': <String, Object?>{}},
      });
      expect(v1Append.supported, isTrue);
      expect(v1Append.override, isFalse);

      final v1Override = AcpSystemPromptCapabilities.parse({
        'sessionCapabilities': {
          'systemPrompt': {
            'mode': {'override': <String, Object?>{}},
          },
        },
      });
      expect(v1Override.supported, isTrue);
      expect(v1Override.override, isTrue);

      final v2Override = AcpSystemPromptCapabilities.parse({
        'sessionCapabilities': <String, Object?>{},
        'session': {
          'systemPrompt': {
            'mode': {'override': <String, Object?>{}},
          },
        },
      });
      expect(v2Override.supported, isTrue);
      expect(v2Override.override, isTrue);
    });

    test('never emits empty content when custom prompt text is blank', () {
      const caps = AcpSystemPromptCapabilities(supported: true, override: true);
      for (final mode in CoreSystemPromptMode.values) {
        final resolved = resolveAcpSystemPrompt(
          capabilities: caps,
          corePrompt: CoreSystemPrompt(mode: mode, text: '   '),
        );
        expect(resolved.param, isNull);
        expect(resolved.warnings, isEmpty);
      }
    });
  });

  group('AcpKernel systemPrompt integration', () {
    test('stays silent and omits systemPrompt on v1 agent with default setting', () async {
      final transport = _FakeAcpTransport();
      final kernel = AcpKernel(
        _descriptor(),
        const KernelContext(cwd: '/tmp/project'),
        (_) async => transport,
        systemPrompt: () => const CoreSystemPrompt(),
      );
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sessionNew = transport.written.singleWhere(
        (m) => m['method'] == 'session/new',
      );
      expect((sessionNew['params'] as Map).containsKey('systemPrompt'), isFalse);
      expect(
        events.whereType<ItemUpserted>().where((e) => e.item is NoticeItem),
        isEmpty,
      );
      await sub.cancel();
      kernel.dispose();
      await kernel.stopped;
    });

    for (final resume in [false, true]) {
      test(
        'sends append systemPrompt on session/${resume ? "load" : "new"} when supported',
        () async {
          final transport = _FakeAcpTransport(
            agentCapabilities: {
              'sessionCapabilities': {'systemPrompt': <String, Object?>{}},
            },
          );
          final kernel = AcpKernel(
            _descriptor(),
            KernelContext(
              cwd: '/tmp/project',
              resume: resume
                  ? SessionRecord(
                      id: 'saved_1',
                      title: 'Saved',
                      cwd: '/tmp/project',
                      updatedAt: DateTime.utc(2026),
                    )
                  : null,
              workspace: () => const KernelWorkspace(
                folders: [],
                instructions: 'Workspace extra note.',
              ),
            ),
            (_) async => transport,
            systemPrompt: () => const CoreSystemPrompt(
              mode: CoreSystemPromptMode.append,
              text: 'Always reply in Chinese.',
            ),
          );
          kernel.prepare();
          await Future<void>.delayed(const Duration(milliseconds: 20));

          final req = transport.written.singleWhere(
            (m) => m['method'] == (resume ? 'session/load' : 'session/new'),
          );
          expect((req['params'] as Map)['systemPrompt'], {
            'mode': 'append',
            'content': [
              {
                'type': 'text',
                'text': 'Always reply in Chinese.\n\nWorkspace extra note.',
              },
            ],
          });
          kernel.dispose();
          await kernel.stopped;
        },
      );
    }

    test('sends override systemPrompt when agent advertises mode.override', () async {
      final transport = _FakeAcpTransport(
        agentCapabilities: {
          'sessionCapabilities': {
            'systemPrompt': {
              'mode': {'override': <String, Object?>{}},
            },
          },
        },
      );
      final kernel = AcpKernel(
        _descriptor(),
        const KernelContext(cwd: '/tmp/project'),
        (_) async => transport,
        systemPrompt: () => const CoreSystemPrompt(
          mode: CoreSystemPromptMode.replace,
          text: 'Custom full core instructions.',
        ),
      );
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final req = transport.written.singleWhere(
        (m) => m['method'] == 'session/new',
      );
      expect((req['params'] as Map)['systemPrompt'], {
        'mode': 'override',
        'content': [
          {'type': 'text', 'text': 'Custom full core instructions.'},
        ],
      });
      expect(
        events.whereType<ItemUpserted>().where((e) => e.item is NoticeItem),
        isEmpty,
      );
      await sub.cancel();
      kernel.dispose();
      await kernel.stopped;
    });

    test('warns and refuses illegal override when agent only supports append', () async {
      final transport = _FakeAcpTransport(
        agentCapabilities: {
          'sessionCapabilities': {'systemPrompt': <String, Object?>{}},
        },
      );
      final kernel = AcpKernel(
        _descriptor(),
        KernelContext(
          cwd: '/tmp/project',
          workspace: () => const KernelWorkspace(
            folders: [],
            instructions: 'Repo note',
          ),
        ),
        (_) async => transport,
        systemPrompt: () => const CoreSystemPrompt(
          mode: CoreSystemPromptMode.replace,
          text: 'Replace prompt',
        ),
      );
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final req = transport.written.singleWhere(
        (m) => m['method'] == 'session/new',
      );
      expect((req['params'] as Map)['systemPrompt'], {
        'mode': 'append',
        'content': [
          {'type': 'text', 'text': 'Repo note'},
        ],
      });
      final notices = events
          .whereType<ItemUpserted>()
          .map((e) => e.item)
          .whereType<NoticeItem>()
          .toList();
      expect(notices, hasLength(1));
      expect(notices.single.text, contains('override'));
      await sub.cancel();
      kernel.dispose();
      await kernel.stopped;
    });

    test('warns and omits systemPrompt when v1 agent lacks capability', () async {
      final transport = _FakeAcpTransport();
      final kernel = AcpKernel(
        _descriptor(),
        const KernelContext(cwd: '/tmp/project'),
        (_) async => transport,
        systemPrompt: () => const CoreSystemPrompt(
          mode: CoreSystemPromptMode.append,
          text: 'Be concise.',
        ),
      );
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final req = transport.written.singleWhere(
        (m) => m['method'] == 'session/new',
      );
      expect((req['params'] as Map).containsKey('systemPrompt'), isFalse);
      final notices = events
          .whereType<ItemUpserted>()
          .map((e) => e.item)
          .whereType<NoticeItem>()
          .toList();
      expect(notices, hasLength(1));
      expect(notices.single.text, contains('systemPrompt'));
      await sub.cancel();
      kernel.dispose();
      await kernel.stopped;
    });

    test('workspace ownPrompt bypasses CoreSystemPrompt', () async {
      final transport = _FakeAcpTransport(
        agentCapabilities: {
          'session': {
            'systemPrompt': {
              'mode': {'override': <String, Object?>{}},
            },
          },
        },
      );
      final kernel = AcpKernel(
        _descriptor(),
        KernelContext(
          cwd: '/tmp/project',
          workspace: () => const KernelWorkspace(
            folders: [],
            instructions: 'Bot persona only.',
            ownPrompt: true,
          ),
        ),
        (_) async => transport,
        systemPrompt: () => const CoreSystemPrompt(
          mode: CoreSystemPromptMode.append,
          text: 'Must be ignored for bots',
        ),
      );
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final req = transport.written.singleWhere(
        (m) => m['method'] == 'session/new',
      );
      expect((req['params'] as Map)['systemPrompt'], {
        'mode': 'override',
        'content': [
          {'type': 'text', 'text': 'Bot persona only.'},
        ],
      });
      kernel.dispose();
      await kernel.stopped;
    });
  });

  group('AcpSkill expansion & store loading', () {
    test('expands placeholders, CLAUDE_SKILL_DIR, and fallback arguments', () {
      final skill = AcpSkill.fromMarkdown(
        fallbackName: 'deploy',
        path: '/home/u/.claude/skills/deploy/SKILL.md',
        baseDir: '/home/u/.claude/skills/deploy',
        markdown: '''---
name: deploy-app
description: Deploy the app
argument-hint: <env> <tag>
---
Run \${CLAUDE_SKILL_DIR}/run.sh for \$1 with \$2 (all: \$ARGUMENTS).''',
      );
      expect(skill.name, 'deploy-app');
      expect(skill.argumentHint, '<env> <tag>');
      expect(skill.modelInvocable, isTrue);
      expect(skill.userInvocable, isTrue);

      final prompt = skill.toPromptText('prod "v1.2.3"');
      expect(
        prompt,
        contains('Base directory for this skill: /home/u/.claude/skills/deploy'),
      );
      expect(
        prompt,
        contains(
          'Run /home/u/.claude/skills/deploy/run.sh for prod with v1.2.3 (all: prod "v1.2.3").',
        ),
      );

      final plain = AcpSkill.fromMarkdown(
        fallbackName: 'review',
        path: '/p/.claude/skills/review/SKILL.md',
        baseDir: '/p/.claude/skills/review',
        markdown: 'Check the diff carefully.',
      );
      expect(
        plain.expand('src/main.dart'),
        'Check the diff carefully.\n\nARGUMENTS: src/main.dart',
      );
    });

    test('loads skills from CustomizationStore with project precedence and switches', () async {
      final root = Directory.systemTemp.createTempSync('baocode_acp_skills_');
      addTearDown(() => root.deleteSync(recursive: true));
      final configDir = p.join(root.path, 'claude');
      final projectDir = p.join(root.path, 'repo');

      void writeSkill(String base, String folder, String content) {
        final dir = Directory(p.join(base, 'skills', folder))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'SKILL.md')).writeAsStringSync(content);
      }

      writeSkill(configDir, 'shared', '''---
name: shared
description: User shared skill
---
User body''');
      writeSkill(p.join(projectDir, '.claude'), 'shared', '''---
name: shared
description: Project shared skill
---
Project body''');
      writeSkill(configDir, 'disabled-one', '''---
name: disabled-one
description: Should be hidden
---
Hidden''');
      writeSkill(configDir, 'manual-only', '''---
name: manual-only
description: Manual skill
disable-model-invocation: true
---
Manual body''');

      final store = CustomizationStore(configDir: configDir, homeDir: root.path);
      final loaded = await loadAcpSkillsFromStore(
        store,
        project: projectDir,
        switches: const ExtensionSwitches(disabledSkills: {'disabled-one'}),
      );
      expect(loaded.skills.map((s) => s.name), ['manual-only', 'shared']);
      expect(loaded.byName('shared')!.body, 'Project body');
      expect(loaded.byName('manual-only')!.modelInvocable, isFalse);
      final section = loaded.systemPromptSection();
      expect(section, contains('shared'));
      expect(section, isNot(contains('manual-only')));
    });

    test('loads POSIX remote skills through CustomizationDisk without local IO', () async {
      final disk = _MemoryDisk({
        '/home/dev/.claude/skills/remote-deploy/SKILL.md': '''---
name: remote-deploy
description: Deploy on remote host
---
Run \${CLAUDE_SKILL_DIR}/deploy.sh''',
        '/srv/app/.claude/skills/repo-check/SKILL.md': '''---
name: repo-check
description: Repo checks
---
Run repo checks.''',
      });
      final store = CustomizationStore(
        configDir: '/home/dev/.claude',
        homeDir: '/home/dev',
        disk: disk,
      );
      final loaded = await loadAcpSkillsFromStore(
        store,
        project: '/srv/app',
      );
      expect(loaded.skills.map((s) => s.name), ['remote-deploy', 'repo-check']);
      final remoteDeploy = loaded.byName('remote-deploy')!;
      expect(remoteDeploy.path, '/home/dev/.claude/skills/remote-deploy/SKILL.md');
      expect(remoteDeploy.baseDir, '/home/dev/.claude/skills/remote-deploy');
      expect(
        remoteDeploy.expand(''),
        'Run /home/dev/.claude/skills/remote-deploy/deploy.sh',
      );
    });
  });

  group('AcpKernel skills protocol & BaoCode skills integration', () {
    test('uses structured skill blocks when agent advertises v2 skill prompt capability', () async {
      final transport = _FakeAcpTransport(
        agentCapabilities: {
          'session': {
            'prompt': {
              'skill': {'inline': <String, Object?>{}},
            },
          },
        },
        initialCommands: [
          {
            'type': 'skill',
            'name': 'pdf',
            'description': 'Work with PDF files',
            'path': '/skills/pdf/SKILL.md',
          },
          {
            'type': 'command',
            'name': 'compact',
            'description': 'Compact context',
          },
        ],
      );
      final kernel = AcpKernel(
        _descriptor(),
        const KernelContext(cwd: '/tmp/project'),
        (_) async => transport,
      );
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final pdfCmd = kernel.commands.singleWhere((c) => c.name == 'pdf');
      expect(pdfCmd.isSkill, isTrue);
      expect(pdfCmd.filePath, '/skills/pdf/SKILL.md');
      expect(kernel.commands.singleWhere((c) => c.name == 'compact').isSkill, isFalse);

      // Leading skill invocation with arguments.
      kernel.send(const KernelTurn(id: 't1', text: '/pdf extract tables'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final p1 = transport.written.where((m) => m['method'] == 'session/prompt').first;
      expect((p1['params'] as Map)['prompt'], [
        {'type': 'skill', 'name': 'pdf'},
        {'type': 'text', 'text': 'extract tables'},
      ]);
      // User message item keeps the original /pdf command text.
      final user1 = events.whereType<ItemUpserted>().singleWhere((e) => e.id == 't1');
      expect((user1.item as UserMessageItem).text, '/pdf extract tables');

      // Inline skill reference when inline capability is advertised.
      kernel.send(const KernelTurn(id: 't2', text: 'Please use /pdf to parse this'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final p2 = transport.written.where((m) => m['method'] == 'session/prompt').last;
      expect((p2['params'] as Map)['prompt'], [
        {'type': 'text', 'text': 'Please use '},
        {'type': 'skill', 'name': 'pdf'},
        {'type': 'text', 'text': ' to parse this'},
      ]);

      await sub.cancel();
      kernel.dispose();
      await kernel.stopped;
    });

    test('falls back to plain text for agent skills on v1 agents without skill prompt capability', () async {
      final transport = _FakeAcpTransport(
        initialCommands: [
          {
            'type': 'skill',
            'name': 'pdf',
            'description': 'Work with PDF files',
          },
        ],
      );
      final kernel = AcpKernel(
        _descriptor(),
        const KernelContext(cwd: '/tmp/project'),
        (_) async => transport,
      );
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      kernel.send(const KernelTurn(id: 't1', text: '/pdf summary'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final p1 = transport.written.singleWhere((m) => m['method'] == 'session/prompt');
      expect((p1['params'] as Map)['prompt'], [
        {'type': 'text', 'text': '/pdf summary'},
      ]);
      kernel.dispose();
      await kernel.stopped;
    });

    test('merges BaoCode skills, survives command updates, injects catalog, and expands on invoke (v1 compatible)', () async {
      final transport = _FakeAcpTransport(
        agentCapabilities: {
          'sessionCapabilities': {'systemPrompt': <String, Object?>{}},
        },
        initialCommands: [
          {'name': 'agent-only', 'description': 'Native command'},
        ],
      );
      final skills = AcpSkills(
        skills: [
          const AcpSkill(
            name: 'verify-app',
            description: 'Verify app behavior',
            path: '/repo/.claude/skills/verify-app/SKILL.md',
            baseDir: '/repo/.claude/skills/verify-app',
            body: 'Run checks on \$1 in \${CLAUDE_SKILL_DIR}.',
            argumentHint: '<target>',
          ),
          const AcpSkill(
            name: 'hidden-user',
            description: 'Model only skill',
            path: '/repo/.claude/skills/hidden-user/SKILL.md',
            baseDir: '/repo/.claude/skills/hidden-user',
            body: 'Internal steps.',
            userInvocable: false,
          ),
        ],
      );
      final kernel = AcpKernel(
        _descriptor(),
        const KernelContext(cwd: '/repo'),
        (_) async => transport,
        loadSkills: (_) async => skills,
      );
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      kernel.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // BaoCode skills catalog injected via systemPrompt append.
      final sessionNew = transport.written.singleWhere(
        (m) => m['method'] == 'session/new',
      );
      final sp = (sessionNew['params'] as Map)['systemPrompt'] as Map;
      expect(sp['mode'], 'append');
      final spText = ((sp['content'] as List).first as Map)['text'] as String;
      expect(spText, contains('verify-app'));
      expect(spText, contains('/repo/.claude/skills/verify-app/SKILL.md'));
      expect(spText, contains('hidden-user'));

      // Commands include agent command + userInvocable BaoCode skill (not userInvocable: false).
      expect(kernel.commands.map((c) => c.name), ['agent-only', 'verify-app']);
      expect(
        kernel.commands.singleWhere((c) => c.name == 'verify-app').filePath,
        '/repo/.claude/skills/verify-app/SKILL.md',
      );

      // Later available_commands_update replaces agent commands but keeps BaoCode skills.
      transport.emitUpdate({
        'sessionUpdate': 'available_commands_update',
        'availableCommands': [
          {'name': 'plan', 'description': 'Plan work'},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(kernel.commands.map((c) => c.name), ['plan', 'verify-app']);

      // Invoking BaoCode skill expands SKILL.md into standard text block.
      kernel.send(const KernelTurn(id: 't1', text: '/verify-app checkout'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final p1 = transport.written.singleWhere((m) => m['method'] == 'session/prompt');
      final blocks = (p1['params'] as Map)['prompt'] as List;
      expect(blocks, hasLength(1));
      expect((blocks.first as Map)['type'], 'text');
      final sentText = (blocks.first as Map)['text'] as String;
      expect(sentText, contains('Base directory for this skill: /repo/.claude/skills/verify-app'));
      expect(sentText, contains('Run checks on checkout in /repo/.claude/skills/verify-app.'));

      // Chat UI still displays the original /verify-app command text.
      final userItem = events.whereType<ItemUpserted>().singleWhere((e) => e.id == 't1');
      expect((userItem.item as UserMessageItem).text, '/verify-app checkout');

      await sub.cancel();
      kernel.dispose();
      await kernel.stopped;
    });
  });
}

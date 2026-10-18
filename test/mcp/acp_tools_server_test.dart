@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/mcp/tools_protocol.dart';
import 'package:baocode/mcp/tools_registration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String home;
  late String config;
  late CustomizationStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('user-tools-mcp-');
    home = temp.path;
    config = p.join(home, '.claude');
    store = CustomizationStore(configDir: config, homeDir: home);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<UserMcpRegistration> register({String? command}) =>
      registerBaocodeTools(
        store: store,
        command: command ?? Platform.resolvedExecutable,
        dataDirectory: p.join(home, 'data'),
      );

  test(
    'registration is user-scoped and ACP loads it in every project',
    () async {
      expect(await register(), UserMcpRegistration.registered);
      final items = await store.list(CustomizationKind.mcps);
      expect(items.single.scope, CustomizationScope.user);
      expect(items.single.path, p.join(home, '.claude.json'));
      for (final name in ['one', 'two']) {
        final project = Directory(p.join(home, name))..createSync();
        final loaded = await loadAcpMcpServers(
          KernelContext(cwd: project.path),
          const {},
          environment: {'HOME': home, 'CLAUDE_CONFIG_DIR': config},
        );
        expect(loaded.warnings, isEmpty);
        final server = loaded.servers.single;
        expect(server['name'], 'baocode');
        expect(server['command'], Platform.resolvedExecutable);
        expect(server['args'], [ToolsProtocol.flag]);
        expect(server['env'], [
          {
            'name': ToolsProtocol.dataDirectoryVariable,
            'value': p.join(home, 'data'),
          },
        ]);
        expect(File(p.join(project.path, '.mcp.json')).existsSync(), isFalse);
      }
    },
  );

  test('custom config directory owns its user registration', () async {
    config = p.join(home, 'custom claude');
    store = CustomizationStore(configDir: config, homeDir: home);
    await register();
    expect(File(p.join(config, '.claude.json')).existsSync(), isTrue);
    expect(File(p.join(home, '.claude.json')).existsSync(), isFalse);
  });

  test(
    'preserves user state and other servers; registration is idempotent',
    () async {
      final file = File(p.join(home, '.claude.json'));
      final original = {
        'theme': 'dark',
        'projects': {
          '/project': {'trusted': true},
        },
        'mcpServers': {
          'other': {'command': 'other-tool'},
        },
      };
      file.writeAsStringSync(jsonEncode(original));
      await register();
      final text = file.readAsStringSync();
      final saved = jsonDecode(text) as Map;
      expect(saved['theme'], original['theme']);
      expect(saved['projects'], original['projects']);
      expect((saved['mcpServers'] as Map)['other'], {'command': 'other-tool'});
      expect(await register(), UserMcpRegistration.unchanged);
      expect(file.readAsStringSync(), text);
    },
  );

  test('does not replace a user-owned server named baocode', () async {
    final file = File(p.join(home, '.claude.json'));
    const original = '{"mcpServers":{"baocode":{"command":"my-server"}}}';
    file.writeAsStringSync(original);
    expect(await register(), UserMcpRegistration.conflict);
    expect(file.readAsStringSync(), original);
  });

  test('updates a managed executable path after the app moves', () async {
    await register(command: '/old/BaoCode');
    expect(
      await register(command: '/new/BaoCode'),
      UserMcpRegistration.registered,
    );
    final saved = (await store.list(CustomizationKind.mcps)).single.server!;
    expect(saved['command'], '/new/BaoCode');
    expect(saved['env'], {
      ToolsProtocol.dataDirectoryVariable: p.join(home, 'data'),
    });
  });

  test('managed updates preserve extra fields and environment', () async {
    await register(command: '/old/BaoCode');
    final file = File(p.join(home, '.claude.json'));
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    final managed = (saved['mcpServers'] as Map)['baocode'] as Map;
    managed['timeout'] = 120;
    (managed['env'] as Map)['EXTRA_SETTING'] = 'keep';
    file.writeAsStringSync(jsonEncode(saved));

    await register(command: '/new/BaoCode');
    final updated = (await store.list(CustomizationKind.mcps)).single.server!;
    expect(updated['command'], '/new/BaoCode');
    expect(updated['timeout'], 120);
    expect(updated['env'], {
      ToolsProtocol.dataDirectoryVariable: p.join(home, 'data'),
      'EXTRA_SETTING': 'keep',
    });
  });

  test(
    'atomic registration preserves permissions and a config symlink',
    () async {
      final target = File(p.join(home, 'actual-config.json'))
        ..writeAsStringSync('{"theme":"dark"}');
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['640', target.path]);
        expect(result.exitCode, 0);
        await Link(p.join(home, '.claude.json')).create(target.path);
        await register();
        expect(
          await FileSystemEntity.isLink(p.join(home, '.claude.json')),
          isTrue,
        );
        expect(target.statSync().mode & 0x1ff, 0x1a0);
        final saved = jsonDecode(target.readAsStringSync()) as Map;
        expect(saved['theme'], 'dark');
        expect((saved['mcpServers'] as Map).containsKey('baocode'), isTrue);
        expect(
          Directory(home).listSync().where(
            (item) => p.basename(item.path).startsWith('.mcp-config-'),
          ),
          isEmpty,
        );
      }
    },
  );

  test('a dangling config symlink is not replaced', () async {
    final path = p.join(home, '.claude.json');
    final target = p.join(home, 'missing.json');
    await Link(path).create(target);
    await expectLater(register(), throwsA(isA<FileSystemException>()));
    expect(await FileSystemEntity.isLink(path), isTrue);
    expect(await Link(path).target(), target);
  }, skip: Platform.isWindows);

  test('concurrent user registrations retain both servers', () async {
    await Future.wait([
      register(),
      CustomizationStore(configDir: config, homeDir: home).registerUserMcp(
        'other',
        {'command': 'other-tool'},
        isManaged: (_) => false,
      ),
    ]);
    final names = (await store.list(CustomizationKind.mcps))
        .map((item) => item.name);
    expect(names, unorderedEquals(['baocode', 'other']));
  });

  for (final invalid in ['{broken', '[]', '{"mcpServers":null}']) {
    test('invalid user configuration is not overwritten: $invalid', () async {
      final file = File(p.join(home, '.claude.json'))
        ..writeAsStringSync(invalid);
      await expectLater(register(), throwsFormatException);
      expect(file.readAsStringSync(), invalid);
    });
  }
}

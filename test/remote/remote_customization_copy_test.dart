@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:baocode/customize/customization_directory_copy.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/remote/remote_customization_disk.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

void main() {
  late Directory temporary;
  late String root;
  late String config;
  late String target;
  late SshHost host;
  late MemoryConnector connector;
  late CustomizationDirectoryCopy copier;

  void write(String path, String text) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('baocode-remote-copy-');
    root = temporary.resolveSymbolicLinksSync();
    config = p.join(root, 'remote home', '.claude');
    // Quotes, spaces and metacharacters must remain literal path characters.
    target = p.join(root, "agent ' ; \$(false)", 'skills');
    connector = MemoryConnector(p.join(root, 'server'));
    host = SshHost('dev', connect: connector.call);
    copier = CustomizationDirectoryCopy(
      CustomizationStore(
        configDir: config,
        homeDir: p.dirname(config),
        disk: RemoteCustomizationDisk(host),
      ),
    );
  });
  tearDown(() {
    host.close();
    temporary.deleteSync(recursive: true);
  });

  test(
    'remote binary and executable skills copy, update and conflict',
    () async {
      final source = p.join(config, 'skills', 'test', 'SKILL.md');
      write(source, 'Remote skill');
      final asset = File(
        p.join(config, 'skills', 'test', 'assets', 'data.bin'),
      );
      asset.parent.createSync(recursive: true);
      asset.writeAsBytesSync([0, 255, 128]);
      final script = p.join(config, 'skills', 'test', 'scripts', 'run.sh');
      write(script, '#!/bin/sh\nexit 0\n');
      expect((await Process.run('chmod', ['700', script])).exitCode, 0);

      final plan = await copier.preview(CustomizationKind.skills, target);
      expect(Directory(target).existsSync(), isFalse);
      await copier.apply(plan);
      expect(
        File(p.join(target, 'test', 'SKILL.md')).readAsStringSync(),
        'Remote skill',
      );
      expect(
        File(p.join(target, 'test', 'assets', 'data.bin')).readAsBytesSync(),
        [0, 255, 128],
      );
      expect(
        File(p.join(target, 'test', 'scripts', 'run.sh')).statSync().mode &
            0x40,
        isNot(0),
      );
      expect(
        (await copier.preview(CustomizationKind.skills, target)).hasChanges,
        isFalse,
      );
      write(source, 'Updated remote skill');
      await copier.apply(
        await copier.preview(CustomizationKind.skills, target),
      );
      expect(
        File(p.join(target, 'test', 'SKILL.md')).readAsStringSync(),
        'Updated remote skill',
      );
      write(p.join(target, 'test', 'SKILL.md'), 'External');
      expect(
        (await copier.preview(CustomizationKind.skills, target)).hasConflicts,
        isTrue,
      );
    },
  );

  test('remote rules and tilde use the selected host store', () async {
    write(p.join(config, 'CLAUDE.md'), 'Remote global rule');
    write(p.join(config, 'rules', 'nested', 'style.md'), 'Remote style');
    final plan = await copier.preview(CustomizationKind.rules, '~/agent/rules');
    expect(plan.targetRoot, p.join(p.dirname(config), 'agent', 'rules'));
    await copier.apply(plan);
    expect(
      File(p.join(plan.targetRoot, 'CLAUDE.md')).readAsStringSync(),
      'Remote global rule',
    );
    expect(
      File(p.join(plan.targetRoot, 'nested', 'style.md')).readAsStringSync(),
      'Remote style',
    );
  });

  test(
    'remote links are refused; connection failure never falls back to local',
    () async {
      write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Remote skill');
      Link(p.join(config, 'skills', 'test', 'loop')).createSync(config);
      await expectLater(
        copier.preview(CustomizationKind.skills, target),
        throwsStateError,
      );
      expect(Directory(target).existsSync(), isFalse);
      host.close();
      connector.failure = StateError('Host unavailable');
      host = SshHost('unavailable', connect: connector.call);
      copier = CustomizationDirectoryCopy(
        CustomizationStore(
          configDir: config,
          disk: RemoteCustomizationDisk(host),
        ),
      );
      await expectLater(
        copier.preview(CustomizationKind.skills, target),
        throwsA(isA<Object>()),
      );
      expect(Directory(target).existsSync(), isFalse);
    },
  );
}

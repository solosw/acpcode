import 'dart:convert';
import 'dart:io';

import 'package:baocode/customize/customization_directory_copy.dart';
import 'package:baocode/customize/customization_disk.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FailOnceCopyDisk implements CustomizationCopyDisk {
  _FailOnceCopyDisk(this.delegate);
  final CustomizationCopyDisk delegate;
  bool fail = true;

  @override
  bool get isLocal => delegate.isLocal;
  @override
  p.Context get paths => delegate.paths;
  @override
  Future<String> configDir() => delegate.configDir();
  @override
  Future<String?> homeDir() => delegate.homeDir();
  @override
  Future<String?> read(String path) => delegate.read(path);
  @override
  Future<List<({String path, bool directory})>> children(String directory) =>
      delegate.children(directory);
  @override
  Future<bool?> isDirectory(String path) => delegate.isDirectory(path);
  @override
  Future<void> write(String path, String text) => delegate.write(path, text);
  @override
  Future<void> delete(String path) => delegate.delete(path);
  @override
  Future<CustomizationFileInfo?> inspect(String path) => delegate.inspect(path);
  @override
  Future<List<String>> copyEntries(String directory) =>
      delegate.copyEntries(directory);
  @override
  Future<String> resolveCopyPath(String path) => delegate.resolveCopyPath(path);
  @override
  Future<List<int>> readCopyBytes(String path) => delegate.readCopyBytes(path);
  @override
  Future<void> createCopyDirectory(String path) =>
      delegate.createCopyDirectory(path);
  @override
  Future<void> writeCopyBytes(
    String path,
    List<int> bytes, {
    required bool executable,
  }) {
    if (fail && p.basename(path) == 'b.md') {
      fail = false;
      throw StateError('Simulated write failure');
    }
    return delegate.writeCopyBytes(path, bytes, executable: executable);
  }
}

void main() {
  late Directory temporary;
  late String root;
  late String config;
  late String target;
  late CustomizationDirectoryCopy copier;

  void write(String path, String text) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('baocode-copy-test-');
    root = temporary.resolveSymbolicLinksSync();
    config = p.join(root, '.claude');
    target = p.join(root, 'agent skills');
    copier = CustomizationDirectoryCopy(
      CustomizationStore(configDir: config, homeDir: root),
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<CustomizationCopyPlan> skills() =>
      copier.preview(CustomizationKind.skills, target);
  Future<CustomizationCopyPlan> rules() =>
      copier.preview(CustomizationKind.rules, target);

  test('preview is read-only; copies complete user skill resources', () async {
    write(p.join(config, 'skills', 'pdf', 'SKILL.md'), 'PDF');
    write(p.join(config, 'skills', 'pdf', 'references', 'guide.md'), 'Guide');
    write(p.join(config, 'skills', 'pdf', '.private'), 'Hidden resource');
    final bytes = [0, 255, 128, 10];
    final image = File(p.join(config, 'skills', 'pdf', 'assets', 'image.bin'));
    image.parent.createSync(recursive: true);
    image.writeAsBytesSync(bytes);
    Directory(p.join(config, 'skills', 'pdf', 'empty')).createSync();
    write(
      p.join(config, 'skills', 'synced', 'a', 'cloud', 'SKILL.md'),
      'Cloud',
    );
    write(p.join(config, 'skills', 'not-a-skill', 'readme.md'), 'Not a skill');
    write(p.join(config, 'plugins', 'skills', 'plugin', 'SKILL.md'), 'Plugin');
    write(
      p.join(root, 'project', '.claude', 'skills', 'local', 'SKILL.md'),
      'Local',
    );

    final plan = await skills();
    expect(plan.hasChanges, isTrue);
    expect(Directory(target).existsSync(), isFalse);
    await copier.apply(plan);
    expect(File(p.join(target, 'pdf', 'SKILL.md')).readAsStringSync(), 'PDF');
    expect(
      File(p.join(target, 'pdf', 'assets', 'image.bin')).readAsBytesSync(),
      bytes,
    );
    expect(
      File(p.join(target, 'pdf', '.private')).readAsStringSync(),
      'Hidden resource',
    );
    expect(Directory(p.join(target, 'pdf', 'empty')).existsSync(), isTrue);
    expect(Directory(p.join(target, 'synced')).existsSync(), isFalse);
    expect(Directory(p.join(target, 'not-a-skill')).existsSync(), isFalse);
    expect((await skills()).hasChanges, isFalse);
    expect((await skills()).hasConflicts, isFalse);
  });

  test('updates managed files; retains deleted sources as stale', () async {
    final source = p.join(config, 'skills', 'test', 'SKILL.md');
    write(source, 'Before');
    await copier.apply(await skills());
    write(source, 'After');
    final update = await skills();
    expect(update.count(CustomizationCopyAction.update), 1);
    await copier.apply(update);
    final copied = File(p.join(target, 'test', 'SKILL.md'));
    expect(copied.readAsStringSync(), 'After');
    File(source).deleteSync();
    final stale = await skills();
    expect(stale.count(CustomizationCopyAction.stale), 1);
    await copier.apply(stale);
    expect(copied.readAsStringSync(), 'After');
  });

  test(
    'never adopts or overwrites existing files, even identical ones',
    () async {
      write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Same');
      write(p.join(target, 'test', 'SKILL.md'), 'Same');
      final plan = await skills();
      expect(plan.hasConflicts, isTrue);
      await expectLater(copier.apply(plan), throwsStateError);
      expect(
        File(p.join(target, CustomizationDirectoryCopy.manifestName))
            .existsSync(),
        isFalse,
      );
    },
  );

  test('external modifications conflict, blocking the entire copy', () async {
    write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Source');
    await copier.apply(await skills());
    write(p.join(target, 'test', 'SKILL.md'), 'External');
    write(p.join(config, 'skills', 'new', 'SKILL.md'), 'New');
    final plan = await skills();
    expect(plan.hasConflicts, isTrue);
    await expectLater(copier.apply(plan), throwsStateError);
    expect(
      File(p.join(target, 'test', 'SKILL.md')).readAsStringSync(),
      'External',
    );
    expect(Directory(p.join(target, 'new')).existsSync(), isFalse);
  });

  test('source changes after confirmation require a fresh preview', () async {
    final source = p.join(config, 'skills', 'test', 'SKILL.md');
    write(source, 'Before');
    final plan = await skills();
    write(source, 'Changed');
    await expectLater(copier.apply(plan), throwsStateError);
    expect(Directory(target).existsSync(), isFalse);
  });

  test(
    'target and manifest changes after preview require a fresh preview',
    () async {
      write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Source');
      final plan = await skills();
      write(p.join(target, 'test', 'SKILL.md'), 'Unexpected');
      await expectLater(copier.apply(plan), throwsStateError);
      File(p.join(target, 'test', 'SKILL.md')).deleteSync();
      await copier.apply(await skills());
      final next = await skills();
      final manifest = File(
        p.join(target, CustomizationDirectoryCopy.manifestName),
      );
      manifest.writeAsStringSync('${manifest.readAsStringSync()}\n');
      await expectLater(copier.apply(next), throwsStateError);
    },
  );

  test(
    'rules retain bytes, front matter and resources; include user CLAUDE.md',
    () async {
      const conditional =
          '---\npaths: ["lib/**"]\n---\nKeep this conditional.\n';
      write(p.join(config, 'rules', 'nested', 'style.md'), conditional);
      write(p.join(config, 'rules', 'nested', 'reference.txt'), 'Reference');
      write(p.join(config, 'CLAUDE.md'), '@rules/nested/style.md\nGlobal rule');
      final plan = await rules();
      await copier.apply(plan);
      expect(
        File(p.join(target, 'nested', 'style.md')).readAsStringSync(),
        conditional,
      );
      expect(
        File(p.join(target, 'nested', 'reference.txt')).readAsStringSync(),
        'Reference',
      );
      expect(
        File(p.join(target, 'CLAUDE.md')).readAsStringSync(),
        '@rules/nested/style.md\nGlobal rule',
      );
      expect((await rules()).hasChanges, isFalse);
    },
  );

  test(
    'duplicate rule names are rejected rather than silently merged',
    () async {
      write(p.join(config, 'CLAUDE.md'), 'Global');
      write(p.join(config, 'rules', 'CLAUDE.md'), 'Other');
      await expectLater(rules(), throwsStateError);
      expect(Directory(target).existsSync(), isFalse);
    },
  );

  test('empty sources do not create a target', () async {
    final plan = await skills();
    expect(plan.entries, isEmpty);
    await copier.apply(plan);
    expect(Directory(target).existsSync(), isFalse);
  });

  test(
    'rejects relative paths, overlapping roots and reserved source names',
    () async {
      await expectLater(
        copier.preview(CustomizationKind.skills, 'relative'),
        throwsArgumentError,
      );
      for (final path in [config, p.join(config, 'skills'), root]) {
        await expectLater(
          copier.preview(CustomizationKind.skills, path),
          throwsStateError,
        );
      }
      write(
        p.join(config, 'rules', CustomizationDirectoryCopy.manifestName),
        '{}',
      );
      await expectLater(rules(), throwsStateError);
    },
  );

  test('tilde resolves against the selected host home', () async {
    write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Source');
    final plan = await copier.preview(
      CustomizationKind.skills,
      '~/agent/skills',
    );
    expect(plan.targetRoot, p.join(root, 'agent', 'skills'));
  });

  test('malformed, foreign and escaping manifests fail closed', () async {
    final manifest = p.join(target, CustomizationDirectoryCopy.manifestName);
    write(manifest, 'invalid JSON');
    await expectLater(skills(), throwsFormatException);
    write(
      manifest,
      jsonEncode({
        'version': 1,
        'source': '/elsewhere',
        'kind': 'skills',
        'files': {},
      }),
    );
    await expectLater(skills(), throwsStateError);
    write(
      manifest,
      jsonEncode({
        'version': 1,
        'source': config,
        'kind': 'skills',
        'files': {'../outside': 'hash'},
      }),
    );
    await expectLater(skills(), throwsStateError);
  });

  test(
    'a failed copy checkpoints completed files and can resume safely',
    () async {
      write(p.join(config, 'rules', 'a.md'), 'A');
      write(p.join(config, 'rules', 'b.md'), 'B');
      final disk = _FailOnceCopyDisk(
        CustomizationDisk.local! as CustomizationCopyDisk,
      );
      copier = CustomizationDirectoryCopy(
        CustomizationStore(configDir: config, homeDir: root, disk: disk),
      );
      await expectLater(copier.apply(await rules()), throwsStateError);
      expect(File(p.join(target, 'a.md')).readAsStringSync(), 'A');
      expect(File(p.join(target, 'b.md')).existsSync(), isFalse);
      final resumed = await rules();
      expect(resumed.hasConflicts, isFalse);
      expect(resumed.count(CustomizationCopyAction.unchanged), 1);
      await copier.apply(resumed);
      expect(File(p.join(target, 'b.md')).readAsStringSync(), 'B');
    },
  );

  test(
    'concurrent copies to the same target reject the stale preview',
    () async {
      write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Skill');
      final first = await skills();
      final second = await skills();
      final running = copier.apply(first);
      final stale = expectLater(copier.apply(second), throwsStateError);
      await running;
      await stale;
      expect(
        File(p.join(target, 'test', 'SKILL.md')).readAsStringSync(),
        'Skill',
      );
      expect((await skills()).hasConflicts, isFalse);
    },
  );

  test('directories named SKILL.md are not considered user skills', () async {
    Directory(p.join(config, 'skills', 'invalid', 'SKILL.md'))
        .createSync(recursive: true);
    expect((await skills()).entries, isEmpty);
  });

  if (!Platform.isWindows) {
    test(
      'executable resources remain executable; mode changes conflict',
      () async {
        write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Skill');
        final script = p.join(config, 'skills', 'test', 'scripts', 'run.sh');
        write(script, '#!/bin/sh\nexit 0\n');
        expect((await Process.run('chmod', ['700', script])).exitCode, 0);
        await copier.apply(await skills());
        final copied = p.join(target, 'test', 'scripts', 'run.sh');
        expect(File(copied).statSync().mode & 0x40, isNot(0));
        expect((await Process.run('chmod', ['600', copied])).exitCode, 0);
        expect((await skills()).hasConflicts, isTrue);
      },
    );

    test('rejects source links, including cycles, before writing', () async {
      write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Skill');
      Link(p.join(config, 'skills', 'test', 'loop')).createSync(config);
      await expectLater(skills(), throwsStateError);
      expect(Directory(target).existsSync(), isFalse);
    });

    test(
      'target directory links and linked ancestors cannot redirect copies',
      () async {
        write(p.join(config, 'skills', 'test', 'SKILL.md'), 'Skill');
        Directory(target).createSync();
        final outside = Directory(p.join(root, 'outside'))..createSync();
        Link(p.join(target, 'test')).createSync(outside.path);
        final plan = await skills();
        expect(plan.hasConflicts, isTrue);
        await expectLater(copier.apply(plan), throwsStateError);
        expect(outside.listSync(), isEmpty);
        Link(p.join(root, 'alias')).createSync(config);
        await expectLater(
          copier.preview(
            CustomizationKind.skills,
            p.join(root, 'alias', 'nested'),
          ),
          throwsStateError,
        );
      },
    );
  }
}

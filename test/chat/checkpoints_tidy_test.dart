@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/review/review_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final hasGit = () {
    try {
      return Process.runSync('git', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  late Directory temp;
  late String root;
  late String checkpoints;
  final long = DateTime.now().subtract(const Duration(days: 60));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode_tidy_');
    final resolved = await temp.resolveSymbolicLinks();
    root = p.join(resolved, 'project');
    checkpoints = p.join(resolved, 'checkpoints');
    await Directory(root).create();
    await File(p.join(root, 'a.txt')).writeAsString('a\n');
  });

  tearDown(() => temp.delete(recursive: true));

  Future<String> git(String gitDir, List<String> arguments) async {
    final result = await Process.run(
      'git',
      ['--git-dir=$gitDir', ...arguments],
      environment: {
        'GIT_AUTHOR_NAME': 'test',
        'GIT_AUTHOR_EMAIL': 'test@localhost',
        'GIT_COMMITTER_NAME': 'test',
        'GIT_COMMITTER_EMAIL': 'test@localhost',
        'GIT_COMMITTER_DATE': '${long.millisecondsSinceEpoch ~/ 1000} +0000',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return '${result.stdout}'.trim();
  }

  /// Session [name]'s changes, saved [long] ago.
  Future<void> saveLongAgo(String gitDir, String name) async {
    final tree = await git(gitDir, ['mktree']);
    final commit = await git(gitDir, ['commit-tree', '-m', 'old', tree]);
    await git(gitDir, ['update-ref', 'refs/baocode/sessions/$name', commit]);
  }

  Future<List<String>> sessions(String gitDir) async => (await git(gitDir, [
    'for-each-ref',
    '--format=%(refname:lstrip=3)',
    'refs/baocode/sessions/',
  ])).split('\n').where((line) => line.isNotEmpty).toList();

  test('drops the sessions not saved for a month, keeps the others, and runs '
      'once a day', () async {
    final store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    await store.snapshot();
    await store.save('recent', 'data', blobs: const []);
    await saveLongAgo(store.gitDir, 'old');
    expect(await sessions(store.gitDir), ['old', 'recent']);

    await GitReviewStore.tidy(checkpoints);
    expect(await sessions(store.gitDir), ['recent']);
    expect(await store.load('recent'), 'data');
    expect(await store.load('old'), isNull);

    // Not again the same day.
    await saveLongAgo(store.gitDir, 'older');
    await GitReviewStore.tidy(checkpoints);
    expect(await sessions(store.gitDir), ['older', 'recent']);
    await GitReviewStore.tidy(
      checkpoints,
      now: DateTime.now().add(const Duration(days: 1, minutes: 1)),
    );
    expect(await sessions(store.gitDir), ['recent']);
  }, skip: !hasGit);

  test("deletes a repository with no session left that nothing used for a "
      "month, but not one open, nor one an agent snapshots in", () async {
    final open = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    await open.snapshot();
    await saveLongAgo(open.gitDir, 'old');
    await File(p.join(open.gitDir, 'index')).setLastModified(long);

    Future<String> repository(String name) async {
      final gitDir = p.join(checkpoints, name);
      await git(gitDir, ['init', '-q', '--bare', '--template=', gitDir]);
      await saveLongAgo(gitDir, 'old');
      return gitDir;
    }

    final unused = await repository('gone-0000000000000000');
    await File(p.join(unused, 'index')).writeAsString('');
    await File(p.join(unused, 'index')).setLastModified(long);
    // Snapshots taken, not saved yet.
    final working = await repository('working-0000000000000000');
    await File(p.join(working, 'index')).writeAsString('');

    await GitReviewStore.tidy(checkpoints);
    expect(Directory(unused).existsSync(), isFalse);
    expect(Directory(working).existsSync(), isTrue);
    expect(await sessions(working), isEmpty);
    expect(Directory(open.gitDir).existsSync(), isTrue);
    expect(await sessions(open.gitDir), isEmpty);
    // Still at work.
    await File(p.join(root, 'a.txt')).writeAsString('b\n');
    expect(await open.snapshot(), isNotEmpty);
  }, skip: !hasGit);

  /// Makes the loose objects of [gitDir] [long] old, as if written then.
  Future<void> age(String gitDir) async {
    await for (final entry in Directory(
      p.join(gitDir, 'objects'),
    ).list(recursive: true)) {
      if (entry is File) await entry.setLastModified(long);
    }
  }

  Future<bool> has(String gitDir, String oid) async =>
      (await Process.run('git', [
        '--git-dir=$gitDir',
        'cat-file',
        '-e',
        oid,
      ])).exitCode ==
      0;

  test('collects the snapshots, but for the latest and what the sessions '
      'keep', () async {
    final store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    final file = File(p.join(root, 'a.txt'));
    await file.writeAsString('first\n');
    final first = await store.snapshot();
    final gone = (await store.current('a.txt'))!;
    await file.writeAsString('second\n');
    await store.snapshot();
    final kept = (await store.store(
      Uint8List.fromList('kept\n'.codeUnits),
      mode: '100644',
    ));
    await store.save('s', 'data', blobs: [kept]);
    await file.writeAsString('latest\n');
    final latest = (await store.current('a.txt'))!;
    await store.snapshot();
    await age(store.gitDir);

    await GitReviewStore.tidy(checkpoints);
    expect(await has(store.gitDir, gone.oid), isFalse);
    expect(await has(store.gitDir, first!), isFalse);
    expect(await has(store.gitDir, kept.oid), isTrue);
    expect(await has(store.gitDir, latest.oid), isTrue);
    // And snapshots go on from there.
    await file.writeAsString('next\n');
    expect(await store.snapshot(), isNotNull);
  }, skip: !hasGit);

  test(
    'deletes what is not a repository: the folders of another build',
    () async {
      final folder = Directory(
        p.join(checkpoints, 'project-0000000000000000', 's'),
      )..createSync(recursive: true);
      File(p.join(folder.path, 'review.json')).writeAsStringSync('{}');
      await GitReviewStore.tidy(checkpoints);
      expect(folder.parent.existsSync(), isFalse);
    },
    skip: !hasGit,
  );

  test('takes the place of a folder of another build when opened', () async {
    final store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    await Directory(store.gitDir).delete(recursive: true);
    Directory(p.join(store.gitDir, 's')).createSync(recursive: true);
    final reopened = (await GitReviewStore.open(
      root,
      checkpoints: checkpoints,
    ))!;
    expect(await reopened.snapshot(), isNotNull);
    expect(Directory(p.join(reopened.gitDir, 's')).existsSync(), isFalse);
  }, skip: !hasGit);

  test('clearing leaves only what the conversations open keep', () async {
    final open = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    await open.snapshot();
    final kept = await open.store(
      Uint8List.fromList('kept\n'.codeUnits),
      mode: '100644',
    );
    await open.save('held', 'data', blobs: [kept]);
    await saveLongAgo(open.gitDir, 'closed');
    final other = p.join(checkpoints, 'other-0000000000000000');
    await git(other, ['init', '-q', '--bare', '--template=', other]);
    await saveLongAgo(other, 'old');
    expect(await GitReviewStore.sizeOf(checkpoints), greaterThan(0));

    await GitReviewStore.clear(checkpoints);
    expect(Directory(other).existsSync(), isFalse);
    expect(await sessions(open.gitDir), ['held']);
    expect(await open.load('held'), 'data');
    expect(await has(open.gitDir, kept.oid), isTrue);
    await File(p.join(root, 'a.txt')).writeAsString('b\n');
    expect(await open.snapshot(), isNotNull);
  }, skip: !hasGit);

  test('a missing folder is left be', () async {
    await GitReviewStore.tidy(p.join(temp.path, 'none'));
    expect(Directory(p.join(temp.path, 'none')).existsSync(), isFalse);
  });
}

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show LocalReviewStore;
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

/// The actual v1 layout: a bare repository, session JSON in a commit
/// message, and its snapshot tree plus base/after blobs kept by that commit.
class _LegacyCheckpoint {
  _LegacyCheckpoint(this.folder, this.root);
  final String folder;
  final String root;

  Future<String> git(List<String> arguments, {String? input}) async {
    final process = await Process.start(
      'git',
      ['--git-dir=$folder', ...arguments],
      environment: {
        'GIT_AUTHOR_NAME': 'baocode',
        'GIT_AUTHOR_EMAIL': 'baocode@localhost',
        'GIT_COMMITTER_NAME': 'baocode',
        'GIT_COMMITTER_EMAIL': 'baocode@localhost',
      },
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    if (input != null) process.stdin.write(input);
    await process.stdin.close();
    final code = await process.exitCode;
    final error = await errors;
    if (code != 0) throw StateError('git $arguments: $error');
    return (await output).trimRight();
  }

  Future<ReviewBlob> blob(String text, {String mode = '100644'}) async =>
      ReviewBlob(
        mode,
        await git(['hash-object', '-w', '--stdin'], input: text),
      );

  void write(String path, String text) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  Future<
    ({ReviewBlob base, ReviewBlob after, ReviewBlob unrelated, String commit})
  >
  seed(String session) async {
    final base = await blob('before\n');
    final after = await blob('after\n');
    final deleted = await blob('deleted\n');
    final added = await blob('created\n');
    final unrelated = await blob(
      'unchanged project contents, not a pending edit\n',
    );
    final snapshot = await git(
      ['mktree'],
      input:
          '100644 blob ${after.oid}\tedit.txt\n'
          '100644 blob ${added.oid}\tnew.txt\n'
          '100644 blob ${unrelated.oid}\tunrelated.txt\n',
    );
    final blobs = [base, after, deleted, added];
    final saved = await git(
      ['mktree'],
      input:
          '040000 tree $snapshot\tt0\n'
          '${[for (final (index, blob) in blobs.indexed) '100644 blob ${blob.oid}\tb$index\n'].join()}',
    );
    Map<String, Object?> entry(ReviewBlob? base, ReviewBlob? after) => {
      'base': base?.toJson(),
      'after': after?.toJson(),
      'current': after?.toJson(),
      'reported': false,
      'shared': false,
      'conflict': false,
    };
    final data = jsonEncode({
      'version': 1,
      'snapshot': snapshot,
      'entries': {
        'edit.txt': entry(base, after),
        'new.txt': entry(null, added),
        'deleted.txt': entry(deleted, null),
        'not-pending.txt': entry(unrelated, unrelated),
      },
      'unseen': [
        {'path': p.join(root, 'unknown.txt'), 'added': 2, 'removed': 1},
      ],
    });
    final commit = await git([
      'commit-tree',
      '--no-gpg-sign',
      '-F',
      '-',
      saved,
    ], input: data);
    await git(['update-ref', 'refs/baocode/sessions/$session', commit]);
    write('edit.txt', 'after\n');
    write('new.txt', 'created\n');
    write('unknown.txt', 'untracked edit\n');
    write('unrelated.txt', 'unchanged project contents, not a pending edit\n');
    return (base: base, after: after, unrelated: unrelated, commit: commit);
  }
}

void main() {
  for (final remote in [false, true]) {
    group(remote ? 'remote legacy review' : 'local legacy review', () {
      late Directory temp;
      late String root;
      late String checkpoints;
      late _LegacyCheckpoint legacy;
      RemoteHarness? harness;
      const session = 'legacy-session';

      setUp(() async {
        temp = await Directory.systemTemp.createTemp('legacy-review-');
        root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
        if (remote) {
          harness = await RemoteHarness.start();
          checkpoints = p.join(harness!.dataDir.path, 'checkpoints');
        } else {
          checkpoints = p.join(temp.path, 'checkpoints');
        }
        final store = (await LocalReviewStore.open(
          root,
          checkpoints: checkpoints,
        ))!;
        legacy = _LegacyCheckpoint(store.folder, root);
        await legacy.git(['init', '-q', '--bare', '--template=', store.folder]);
      });

      tearDown(() async {
        await harness?.close();
        harness = null;
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });

      Future<ReviewStore> open() async => remote
          ? (await harness!.client.openReview(root))!
          : (await LocalReviewStore.open(root, checkpoints: checkpoints))!;

      test(
        'rehashes only pending files and preserves originals and Undo',
        () async {
          final old = await legacy.seed(session);
          // Migration must also work once Git has packed the checkpoint.
          await legacy.git(['gc', '--prune=now']);
          // Opening the new store and its periodic cleanup must not delete v1.
          final store = await open();
          await LocalReviewStore.tidy(
            checkpoints,
            every: Duration.zero,
            now: DateTime.now().add(const Duration(days: 365)),
          );
          final review = await ChangeReview.resume(store, session);
          addTearDown(review.dispose);
          expect(review.failure, isNull);
          expect(review.changes, hasLength(4));
          final edited = p.join(root, 'edit.txt');
          expect(await review.original(edited)!(), 'before\n');
          expect(await review.original(p.join(root, 'new.txt'))!(), isEmpty);
          expect(
            await review.original(p.join(root, 'deleted.txt'))!(),
            'deleted\n',
          );
          expect(
            review.changes
                .singleWhere((change) => change.path.endsWith('unknown.txt'))
                .tracked,
            isFalse,
          );
          final data = jsonDecode((await store.load(session))!) as Map;
          expect(data['version'], 2);
          expect(data.containsKey('snapshot'), isFalse);
          final base = ReviewBlob.fromJson(
            (data['entries'] as Map)['edit.txt']['base'],
          )!;
          expect(base.oid, isNot(old.base.oid));
          expect(utf8.decode(await store.read(session, base)), 'before\n');
          final directory = Directory(
            p.join(legacy.folder, 'sessions-v2', session, 'blobs'),
          );
          final imported = directory
              .listSync()
              .map((file) => p.basename(file.path))
              .toSet();
          expect(imported, hasLength(4));
          final unrelated = await LocalReviewStore.open(
            root,
            checkpoints: checkpoints,
          );
          final unrelatedBlob = await unrelated!.current('unrelated.txt');
          expect(imported, isNot(contains(unrelatedBlob!.oid)));
          expect(
            await legacy.git(['rev-parse', 'refs/baocode/sessions/$session']),
            old.commit,
          );
          await review.undoAll();
          expect(File(edited).readAsStringSync(), 'before\n');
          expect(
            File(p.join(root, 'deleted.txt')).readAsStringSync(),
            'deleted\n',
          );
          expect(File(p.join(root, 'new.txt')).existsSync(), isFalse);
          await review.keepAll(); // Also accept the legacy unseen edit.
          expect(await store.load(session), isNull);
          final reopened = await ChangeReview.resume(await open(), session);
          addTearDown(reopened.dispose);
          expect(reopened.failure, isNull);
          expect(
            reopened.changes,
            isEmpty,
          ); // The retained ref must not revive.
        },
      );

      test(
        'failed migration preserves the source and can be retried',
        () async {
          final old = await legacy.seed(session);
          final object = File(
            p.join(
              legacy.folder,
              'objects',
              old.after.oid.substring(0, 2),
              old.after.oid.substring(2),
            ),
          );
          final bytes = await object.readAsBytes();
          await object.delete();
          final store = await open();
          await expectLater(
            store.load(session),
            throwsA(isA<ReviewUnavailable>()),
          );
          expect(
            File(p.join(legacy.folder, 'sessions-v2', session, 'review.json'))
                .existsSync(),
            isFalse,
          );
          expect(
            File(p.join(legacy.folder, '.migrated-$session')).existsSync(),
            isFalse,
          );
          expect(
            await legacy.git(['rev-parse', 'refs/baocode/sessions/$session']),
            old.commit,
          );
          await LocalReviewStore.tidy(
            checkpoints,
            every: Duration.zero,
            now: DateTime.now().add(const Duration(days: 365)),
          );
          expect(File(p.join(legacy.folder, 'HEAD')).existsSync(), isTrue);
          final failed = await ChangeReview.resume(store, session);
          addTearDown(failed.dispose);
          expect(failed.failure, isNotNull);
          await failed
              .keepAll(); // A failed review cannot overwrite its source.
          expect(
            File(p.join(legacy.folder, '.migrated-$session')).existsSync(),
            isFalse,
          );
          await object.writeAsBytes(bytes);
          final recovered = await ChangeReview.resume(await open(), session);
          addTearDown(recovered.dispose);
          expect(recovered.failure, isNull);
          expect(
            await recovered.original(p.join(root, 'edit.txt'))!(),
            'before\n',
          );
          await recovered.undoAll();
          expect(File(p.join(root, 'edit.txt')).readAsStringSync(), 'before\n');
        },
      );

      test(
        'a missing commit is a migration failure, not an empty review',
        () async {
          final old = await legacy.seed(session);
          final object = File(
            p.join(
              legacy.folder,
              'objects',
              old.commit.substring(0, 2),
              old.commit.substring(2),
            ),
          );
          final bytes = await object.readAsBytes();
          await object.delete();
          final store = await open();
          await expectLater(
            store.load(session),
            throwsA(isA<ReviewUnavailable>()),
          );
          expect(
            File(p.join(legacy.folder, 'refs', 'baocode', 'sessions', session))
                .readAsStringSync()
                .trim(),
            old.commit,
          );
          expect(
            File(p.join(legacy.folder, '.migrated-$session')).existsSync(),
            isFalse,
          );
          await object.writeAsBytes(bytes);
          final review = await ChangeReview.resume(store, session);
          addTearDown(review.dispose);
          expect(review.failure, isNull);
          expect(
            await review.original(p.join(root, 'edit.txt'))!(),
            'before\n',
          );
        },
      );

      test(
        'migrating one session leaves unopened sessions recoverable',
        () async {
          await legacy.seed(session);
          await legacy.seed('unopened');
          final store = await open();
          final first = await ChangeReview.resume(store, session);
          addTearDown(first.dispose);
          expect(first.failure, isNull);
          await first.keepAll();
          await LocalReviewStore.tidy(
            checkpoints,
            every: Duration.zero,
            now: DateTime.now().add(const Duration(days: 365)),
          );
          final second = await ChangeReview.resume(await open(), 'unopened');
          addTearDown(second.dispose);
          expect(second.failure, isNull);
          expect(
            await second.original(p.join(root, 'edit.txt'))!(),
            'before\n',
          );
          await second.undoAll();
          expect(File(p.join(root, 'edit.txt')).readAsStringSync(), 'before\n');
          expect(await store.load(session), isNull);
        },
      );

      test(
        'a legacy session named objects cannot overwrite its repository',
        () async {
          final old = await legacy.seed('objects');
          final store = await open();
          final review = await ChangeReview.resume(store, 'objects');
          addTearDown(review.dispose);
          expect(review.failure, isNull);
          await review.keepAll();
          expect(
            await legacy.git(['cat-file', 'blob', old.base.oid]),
            'before',
          );
          expect(await store.load('objects'), isNull);
        },
      );
    });
  }
}

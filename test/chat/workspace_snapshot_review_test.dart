@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bao_remote/local.dart' show BlobReviewStore;
import 'package:bao_remote/src/review/git_review_store.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  for (final remote in [false, true]) {
    group(remote ? 'SSH workspace snapshots' : 'local workspace snapshots', () {
      late Directory temp;
      late String root;
      late ReviewStore store;
      late String checkpoints;
      late ChangeReview review;
      RemoteHarness? harness;

      String at(String name) => p.join(root, name);
      void write(String name, String text) {
        final file = File(at(name));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(text);
      }

      String read(String name) => File(at(name)).readAsStringSync();

      setUp(() async {
        temp = Directory.systemTemp.createTempSync('workspace-snapshot-');
        root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
        if (remote) {
          harness = await RemoteHarness.start();
          store = (await harness!.client.openReview())!;
          checkpoints = p.join(harness!.dataDir.path, 'checkpoints');
        } else {
          checkpoints = p.join(temp.path, 'checkpoints');
          store = BlobReviewStore.open(checkpoints);
        }
        review = ChangeReview(store, root: root)..session = 'snapshot-session';
      });
      tearDown(() async {
        await review.discard();
        review.dispose();
        await harness?.close();
        harness = null;
        temp.deleteSync(recursive: true);
      });

      test('discovers modifications, creations and deletions without any kernel events or project Git repository', () async {
        write('edit.txt', 'before\n');
        write('delete.txt', 'deleted content\n');
        await review.begin();
        write('edit.txt', 'after\n');
        write('new.txt', 'created\n');
        File(at('delete.txt')).deleteSync();
        await review.observe();
        expect(review.failure, isNull);
        expect(review.changes.map((change) => change.path).toSet(), {
          at('edit.txt'),
          at('delete.txt'),
          at('new.txt'),
        });
        expect(review.changes.every((change) => change.tracked), isTrue);
        expect(await review.original(at('edit.txt'))!(), 'before\n');
        await review.undoAll();
        expect(read('edit.txt'), 'before\n');
        expect(read('delete.txt'), 'deleted content\n');
        expect(File(at('new.txt')).existsSync(), isFalse);
        await review.observe();
        expect(
          review.changes,
          isEmpty,
          reason: 'Undo itself must not be rediscovered',
        );
      });

      test(
        'Keep stays kept but a later shell write starts from the kept content',
        () async {
          write('file.txt', 'before\n');
          await review.begin();
          write('file.txt', 'kept\n');
          await review.observe();
          await review.keepAll();
          await review.observe();
          expect(review.changes, isEmpty);
          write('file.txt', 'later\n');
          await review.observe();
          expect(await review.original(at('file.txt'))!(), 'kept\n');
          await review.undoAll();
          expect(read('file.txt'), 'kept\n');
        },
      );

      test('intervening user writes are rebased rather than undone in the next turn', () async {
        const initial = 'agent=0\nline1\nline2\nline3\nline4\nuser=0\n';
        write('file.txt', initial);
        await review.begin();
        write('file.txt', initial.replaceFirst('agent=0', 'agent=1'));
        await review.observe();
        write('file.txt', read('file.txt').replaceFirst('user=0', 'user=1'));
        await review.begin();
        write('file.txt', read('file.txt').replaceFirst('agent=1', 'agent=2'));
        await review.observe();
        await review.undoAll();
        expect(read('file.txt'), initial.replaceFirst('user=0', 'user=1'));
      });

      test('ignored files and generated dependencies are not attributed to a conversation', () async {
        write('.gitignore', 'ignored.txt\n');
        write('ignored.txt', 'before\n');
        write('node_modules/package.js', 'before\n');
        write('source.txt', 'before\n');
        await review.begin();
        write('ignored.txt', 'after\n');
        write('node_modules/package.js', 'after\n');
        write('source.txt', 'after\n');
        await review.observe();
        expect(review.changes.map((change) => change.path), [at('source.txt')]);
        expect(review.failure, isNull);
      });

      test(
        'unignoring existing user files never turns them into agent creations',
        () async {
          write('.gitignore', 'notes/\n');
          write('notes/user.txt', 'existing user notes\n');
          await review.begin();
          write('.gitignore', '');
          await review.observe();
          final newlyVisible = review.changes.singleWhere(
            (change) => change.path.endsWith('user.txt'),
          );
          expect(newlyVisible.tracked, isFalse);
          await review.undoAll();
          expect(read('notes/user.txt'), 'existing user notes\n');
          expect(review.failure, isNull);
        },
      );

      test('private snapshots preserve the project Git index and existing unstaged changes', () async {
        write('file.txt', 'staged\n');
        for (final args in [
          ['init', '-q', '--template=', root],
          ['-C', root, 'add', 'file.txt'],
        ]) {
          final result = await Process.run('git', args);
          expect(result.exitCode, 0, reason: result.stderr.toString());
        }
        final index = File(at('.git/index')).readAsBytesSync();
        final head = File(at('.git/HEAD')).readAsStringSync();
        write('file.txt', 'unstaged before the turn\n');
        await review.begin();
        write('file.txt', 'agent write\n');
        await review.observe();
        await review.undoAll();
        expect(read('file.txt'), 'unstaged before the turn\n');
        expect(File(at('.git/index')).readAsBytesSync(), index);
        expect(File(at('.git/HEAD')).readAsStringSync(), head);
        expect(review.failure, isNull);
      });

      test(
        'clearing checkpoints preserves the active snapshot baseline',
        () async {
          write('file.txt', 'before\n');
          await review.begin();
          if (!remote) {
            await BlobReviewStore.clear((store as BlobReviewStore).checkpoints);
          }
          write('file.txt', 'after\n');
          await review.observe();
          expect(await review.original(at('file.txt'))!(), 'before\n');
          expect(review.failure, isNull);
        },
      );

      if (!remote) {
        test(
          'a timed-out observation preserves earlier changes and later turns',
          () async {
            write('first.txt', 'before\n');
            write('later.txt', 'original\n');
            await review.begin();
            write('first.txt', 'first edit\n');
            await review.observe();
            final run = GitReviewStore.run;
            addTearDown(() => GitReviewStore.run = run);
            GitReviewStore.run =
                (
                  executable,
                  arguments, {
                  required workingDirectory,
                  environment = const {},
                  input,
                  required timeout,
                }) async =>
                    (exitCode: -1, stdout: Uint8List(0), stderr: 'timed out');
            write('later.txt', 'second edit\n');
            await review.observe();
            expect(review.failure, isNull);
            expect(review.changes.map((change) => change.path), [
              at('first.txt'),
            ]);
            GitReviewStore.run = run;
            await review.observe();
            await review.look();
            expect(review.changes.map((change) => change.path).toSet(), {
              at('first.txt'),
              at('later.txt'),
            });
            await review.begin();
            write('later.txt', 'third edit\n');
            await review.observe();
            await review.undoAll();
            expect(read('first.txt'), 'before\n');
            expect(read('later.txt'), 'original\n');
            expect(review.failure, isNull);
          },
        );

        test(
          'snapshot limits recover without claiming writes in the gap',
          () async {
            final maxBytes = GitReviewStore.maxBytes;
            final delay = GitReviewStore.oversizedRetryDelay;
            addTearDown(() {
              GitReviewStore.maxBytes = maxBytes;
              GitReviewStore.oversizedRetryDelay = delay;
            });
            write('file.txt', 'before\n');
            await review.begin();
            write('file.txt', 'first edit\n');
            await review.observe();
            write('generated.txt', 'generated output exceeds test limit\n');
            GitReviewStore.maxBytes = 1;
            await review.observe();
            expect(review.failure, isNull);
            expect(review.changes.map((change) => change.path), [
              at('file.txt'),
            ]);
            write('gap.txt', 'user content in the gap\n');
            File(at('generated.txt')).deleteSync();
            GitReviewStore.maxBytes = maxBytes;
            GitReviewStore.oversizedRetryDelay = Duration.zero;
            await review.observe();
            expect(review.changes.map((change) => change.path), [
              at('file.txt'),
            ]);
            write('file.txt', 'later edit\n');
            write('new.txt', 'new agent output\n');
            await review.observe();
            await review.look();
            expect(review.failure, isNull);
            expect(review.changes.map((change) => change.path).toSet(), {
              at('file.txt'),
              at('new.txt'),
            });
            await review.undoAll();
            expect(read('file.txt'), 'before\n');
            expect(File(at('new.txt')).existsSync(), isFalse);
            expect(read('gap.txt'), 'user content in the gap\n');
          },
        );
      }

      File scanObject(String tree) {
        final repository = Directory(p.join(checkpoints, 'snapshots'))
            .listSync()
            .whereType<Directory>()
            .singleWhere(
              (folder) => File(p.join(folder.path, 'HEAD')).existsSync(),
            );
        final object = File(
          p.join(
            repository.path,
            'objects',
            tree.substring(0, 2),
            tree.substring(2),
          ),
        );
        expect(object.existsSync(), isTrue);
        return object;
      }

      test('a collected old scan tree rebaselines without losing explicit edits', () async {
        final snapshots = store as ReviewSnapshots;
        write('explicit.txt', 'explicit before\n');
        write('gap-deleted.txt', 'user file before gap\n');
        write('later.txt', 'later before\n');
        final baseline = (await snapshots.snapshot(root))!;
        await review.begin();
        await review.before(at('explicit.txt'));
        write('explicit.txt', 'explicit after\n');
        await review.after(at('explicit.txt'));
        // Another conversation advances latest while this conversation is idle.
        write('gap-created.txt', 'user file during gap\n');
        File(at('gap-deleted.txt')).deleteSync();
        final advanced = (await snapshots.snapshot(root))!;
        expect(advanced.tree, isNot(baseline.tree));
        scanObject(baseline.tree).deleteSync();

        await review.observe();
        expect(review.failure, isNull);
        expect(review.changes.map((change) => change.path), [
          at('explicit.txt'),
        ]);
        expect(
          await review.original(at('explicit.txt'))!(),
          'explicit before\n',
        );
        // Nothing from the unobserved interval is guessed as a creation/deletion.
        expect(review.changes.every((change) => change.tracked), isTrue);
        write('later.txt', 'later after\n');
        write('new-agent.txt', 'agent creation\n');
        await review.observe();
        expect(review.failure, isNull);
        expect(review.changes.map((change) => change.path).toSet(), {
          at('explicit.txt'),
          at('later.txt'),
          at('new-agent.txt'),
        });
        await review.undoAll();
        expect(read('explicit.txt'), 'explicit before\n');
        expect(read('later.txt'), 'later before\n');
        expect(File(at('new-agent.txt')).existsSync(), isFalse);
        expect(read('gap-created.txt'), 'user file during gap\n');
        expect(File(at('gap-deleted.txt')).existsSync(), isFalse);
      });

      test(
        'a corrupt old scan tree is not treated as a collected baseline',
        () async {
          final snapshots = store as ReviewSnapshots;
          write('file.txt', 'before\n');
          final baseline = (await snapshots.snapshot(root))!;
          await review.begin();
          write('file.txt', 'after\n');
          final advanced = (await snapshots.snapshot(root))!;
          expect(advanced.tree, isNot(baseline.tree));
          final object = scanObject(baseline.tree)..deleteSync();
          object.writeAsStringSync('corrupt object');
          await review.observe();
          expect(review.failure, isNotNull);
          expect(review.changes, isEmpty);
        },
      );

      test('one conversation snapshots each workspace folder', () async {
        final other = Directory(p.join(temp.path, 'other'))..createSync();
        final file = File(p.join(other.path, 'file.txt'))
          ..writeAsStringSync('other before\n');
        write('file.txt', 'before\n');
        await review.begin(
          roots: [root, other.path, root, p.join(root, 'nested')],
        );
        write('file.txt', 'after\n');
        file.writeAsStringSync('other after\n');
        await review.observe();
        expect(review.changes.map((change) => change.path).toSet(), {
          at('file.txt'),
          file.path,
        });
        await review.undoAll();
        expect(read('file.txt'), 'before\n');
        expect(file.readAsStringSync(), 'other before\n');
        expect(review.failure, isNull);
      });

      test(
        'snapshot changes retain originals and Undo across conversation resume',
        () async {
          write('file.txt', 'before\n');
          await review.begin();
          write('file.txt', 'after\n');
          await review.observe();
          final resumed = await ChangeReview.resume(
            store,
            'snapshot-session',
            root: root,
          );
          addTearDown(resumed.dispose);
          expect(await resumed.original(at('file.txt'))!(), 'before\n');
          await resumed.undoAll();
          expect(read('file.txt'), 'before\n');
        },
      );
    });
  }
}

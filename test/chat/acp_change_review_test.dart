@TestOn('vm')
library;

import 'dart:io';

import 'package:bao_remote/local.dart' show LocalReviewStore;
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  for (final remote in [false, true]) {
    group(remote ? 'remote ACP discovery' : 'local ACP discovery', () {
      late Directory temp;
      late String root;
      late ReviewStore store;
      late ChangeReview review;
      RemoteHarness? harness;

      void write(String path, String text) {
        final file = File(p.join(root, path));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(text);
      }

      String read(String path) => File(p.join(root, path)).readAsStringSync();

      setUp(() async {
        temp = Directory.systemTemp.createTempSync('acp-review-');
        root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
        if (remote) {
          harness = await RemoteHarness.start();
          store = (await harness!.client.openReview(root))!;
        } else {
          store = (await LocalReviewStore.open(
            root,
            checkpoints: p.join(temp.path, 'checkpoints'),
          ))!;
        }
        review = ChangeReview(store)..session = 'acp';
      });

      tearDown(() async {
        review.dispose();
        // Dispose also drops the transient scan baseline, after queued work.
        await review.discard();
        await harness?.close();
        harness = null;
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });

      test('shell edits, creations and deletions can be undone', () async {
        write('edit.txt', 'before\n');
        write('delete.txt', 'delete me\n');
        await review.begin();
        write('edit.txt', 'after\n');
        write('new.txt', 'created\n');
        File(p.join(root, 'delete.txt')).deleteSync();
        // No FileEdited events: these edits came from a shell.
        await review.observe();
        expect(review.failure, isNull);
        expect(review.changes, hasLength(3));
        expect(review.changes.every((change) => change.tracked), isTrue);
        expect(await review.original(p.join(root, 'edit.txt'))!(), 'before\n');
        await review.undoAll();
        expect(read('edit.txt'), 'before\n');
        expect(read('delete.txt'), 'delete me\n');
        expect(File(p.join(root, 'new.txt')).existsSync(), isFalse);
        await review.observe();
        expect(review.changes, isEmpty);
      });

      test('Keep preserves the scan baseline for a later shell edit', () async {
        write('file.txt', 'before\n');
        await review.begin();
        write('file.txt', 'kept\n');
        await review.observe();
        await review.keepAll();
        await review.observe();
        expect(review.changes, isEmpty);
        write('file.txt', 'later\n');
        await review.observe();
        expect(await review.original(p.join(root, 'file.txt'))!(), 'kept\n');
        await review.undoAll();
        expect(read('file.txt'), 'kept\n');
      });

      test(
        'between-turn user edits and editor undo are not rediscovered',
        () async {
          write('file.txt', 'before\n');
          await review.begin();
          write('file.txt', 'agent\n');
          await review.observe();
          await review.keepAll();
          write('file.txt', 'user\n');
          await review.begin();
          await review.observe();
          expect(review.changes, isEmpty);
          write('file.txt', 'agent again\n');
          await review.observe();
          write('file.txt', 'user\n');
          await review.settle([p.join(root, 'file.txt')]);
          await review.observe();
          expect(review.changes, isEmpty);
        },
      );

      test('ignores build files and visits nested repositories', () async {
        write('.gitignore', 'ignored.txt\n');
        write('ignored.txt', 'ignored\n');
        write('node_modules/dependency.js', 'generated\n');
        write('nested/a.txt', 'before\n');
        final git = await Process.run('git', [
          'init',
          '-q',
          '--template=',
          p.join(root, 'nested'),
        ]);
        expect(git.exitCode, 0);
        await review.begin();
        write('ignored.txt', 'changed\n');
        write('node_modules/dependency.js', 'changed\n');
        write('nested/a.txt', 'after\n');
        await review.observe();
        expect(review.failure, isNull);
        expect(review.changes.map((change) => change.path), [
          p.join(root, 'nested/a.txt'),
        ]);
        await review.undoAll();
        expect(read('nested/a.txt'), 'before\n');
      });

      if (!remote) {
        test('checkpoints inside the project are never rediscovered', () async {
          review.dispose();
          store = (await LocalReviewStore.open(
            root,
            checkpoints: p.join(root, '.checkpoints'),
          ))!;
          review = ChangeReview(store)..session = 'inside';
          write('file.txt', 'before\n');
          await review.begin();
          write('file.txt', 'after\n');
          await review.observe();
          expect(review.failure, isNull);
          expect(review.changes.map((change) => change.path), [
            p.join(root, 'file.txt'),
          ]);
          await review.keepAll();
          await review.observe();
          expect(review.failure, isNull);
          expect(review.changes, isEmpty);
        });
      }

      test(
        'a file that grows too large is not mistaken for a deletion',
        () async {
          final beforeLimit = LocalReviewStore.maxFileBytes;
          addTearDown(() => LocalReviewStore.maxFileBytes = beforeLimit);
          LocalReviewStore.maxFileBytes = 32;
          write('file.txt', 'small\n');
          await review.begin();
          write('file.txt', 'x' * 40);
          await review.observe();
          expect(review.failure, isNull);
          expect(review.changes.single.tracked, isFalse);
          await review.undoAll();
          expect(read('file.txt'), 'x' * 40);
          await review.keepAll();
          await review.observe();
          expect(review.changes, isEmpty);
        },
      );
    });
  }
}

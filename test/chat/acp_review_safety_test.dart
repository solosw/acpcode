@TestOn('vm')
library;

import 'dart:io';

import 'package:bao_remote/local.dart' show GitReviewStore;
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  for (final remote in [false, true]) {
    group(remote ? 'remote ACP review safety' : 'local ACP review safety', () {
      late Directory temp;
      late String root;
      late ChangeReview review;
      late ReviewStore store;
      RemoteHarness? harness;

      void write(String name, String text) =>
          File(p.join(root, name)).writeAsStringSync(text);
      String read(String name) => File(p.join(root, name)).readAsStringSync();

      setUp(() async {
        temp = Directory.systemTemp.createTempSync('acp-review-safety-');
        root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
        if (remote) {
          harness = await RemoteHarness.start();
          store = (await harness!.client.openReview(root))!;
        } else {
          store = (await GitReviewStore.open(
            root,
            checkpoints: p.join(temp.path, 'checkpoints'),
          ))!;
        }
        review = ChangeReview(store)..session = 'safety';
      });

      tearDown(() async {
        review.dispose();
        await review.discard();
        await harness?.close();
        harness = null;
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });

      test('Undo after two turns preserves intervening user edits', () async {
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
        expect(review.failure, isNull);
      });

      test(
        'conflicting user edits stay protected across scan and resume',
        () async {
          write('file.txt', 'initial\n');
          await review.begin();
          write('file.txt', 'first agent\n');
          await review.observe();
          write('file.txt', 'user\n');
          await review.begin();
          expect(review.changes.single.conflict, isTrue);
          write('file.txt', 'second agent\n');
          await review.observe();
          expect(review.changes.single.conflict, isTrue);
          await review.undoAll();
          expect(read('file.txt'), 'second agent\n');
          final resumed = await ChangeReview.resume(store, 'safety');
          addTearDown(resumed.dispose);
          await resumed.undoAll();
          expect(read('file.txt'), 'second agent\n');
          expect(resumed.changes.single.conflict, isTrue);
          expect(resumed.failure, isNull);
        },
      );

      test(
        'a user-edited agent creation is never deleted by a later Undo',
        () async {
          await review.begin();
          write('file.txt', 'agent=1\nuser=0\n');
          await review.observe();
          write('file.txt', 'agent=1\nuser=1\n');
          await review.begin();
          write('file.txt', 'agent=2\nuser=1\n');
          await review.observe();
          await review.undoAll();
          expect(read('file.txt'), 'agent=2\nuser=1\n');
          expect(review.changes.single.conflict, isTrue);
          expect(review.failure, isNull);
        },
      );

      test(
        'unignoring a directory never makes Undo delete existing children',
        () async {
          Directory(p.join(root, 'notes')).createSync();
          write('.gitignore', 'notes/\n');
          write('notes/user.txt', 'existing user notes\n');
          await review.begin();
          write('.gitignore', '');
          await review.observe();
          expect(
            review.changes
                .singleWhere((change) => change.path.endsWith('user.txt'))
                .tracked,
            isFalse,
          );
          await review.undoAll();
          expect(read('notes/user.txt'), 'existing user notes\n');
          expect(review.failure, isNull);
        },
      );

      test('unignoring an existing file never makes Undo delete it', () async {
        write('.gitignore', 'notes.txt\n');
        write('notes.txt', 'existing user notes\n');
        await review.begin();
        write('.gitignore', '');
        await review.observe();
        await review.undoAll();
        expect(File(p.join(root, 'notes.txt')).existsSync(), isTrue);
        expect(read('notes.txt'), 'existing user notes\n');
        expect(review.failure, isNull);
      });
    });
  }
}

@TestOn('vm')
library;

import 'dart:io';

import 'package:bao_remote/local.dart' show BlobReviewStore;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  for (final remote in [false, true]) {
    group(remote ? 'remote ACP ledger' : 'local ACP ledger', () {
      late Directory temp;
      late String root;
      late ChangeReview review;
      RemoteHarness? harness;
      var seq = 0;

      String at(String name) => p.join(root, name);
      void write(String name, String text) {
        final file = File(at(name));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(text);
      }

      Future<void> edit(String name, String? text) async {
        final file = File(at(name));
        final original = file.existsSync() ? file.readAsStringSync() : null;
        if (text == null) {
          file.deleteSync();
        } else {
          write(name, text);
        }
        review.reportEdit(
          FileEdited(
            ++seq,
            FileChange(
              path: at(name),
              added: text == null ? 0 : 1,
              removed: original == null ? 0 : 1,
            ),
            original: OriginalText(original),
            after: text == null ? FileSnapshot(null) : FileSnapshot.text(text),
          ),
        );
        await review.look();
      }

      setUp(() async {
        temp = Directory.systemTemp.createTempSync('acp-ledger-');
        root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
        final ReviewStore store;
        if (remote) {
          harness = await RemoteHarness.start();
          store = (await harness!.client.openReview())!;
        } else {
          store = BlobReviewStore.open(p.join(temp.path, 'checkpoints'));
        }
        review = ChangeReview(store, root: root)..session = 'acp';
      });

      tearDown(() async {
        await review.discard();
        review.dispose();
        await harness?.close();
        harness = null;
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });

      test('reported edits, creations and deletions can be undone', () async {
        write('edit.txt', 'before\n');
        write('delete.txt', 'delete me\n');
        await edit('edit.txt', 'after\n');
        await edit('new.txt', 'created\n');
        await edit('delete.txt', null);
        expect(review.changes, hasLength(3));
        expect(review.changes.every((change) => change.tracked), isTrue);
        await review.undoAll();
        expect(File(at('edit.txt')).readAsStringSync(), 'before\n');
        expect(File(at('delete.txt')).readAsStringSync(), 'delete me\n');
        expect(File(at('new.txt')).existsSync(), isFalse);
        expect(review.failure, isNull);
      });

      test(
        'Keep makes the next reported edit start from the kept content',
        () async {
          write('file.txt', 'before\n');
          await edit('file.txt', 'kept\n');
          await review.keepAll();
          await edit('file.txt', 'later\n');
          expect(await review.original(at('file.txt'))!(), 'kept\n');
          await review.undoAll();
          expect(File(at('file.txt')).readAsStringSync(), 'kept\n');
        },
      );

      test('unreported files never belong to the conversation', () async {
        write('user.txt', 'user content\n');
        await edit('nested/agent.txt', 'agent content\n');
        expect(review.changes.map((change) => change.path), [
          at('nested/agent.txt'),
        ]);
        await review.undoAll();
        expect(File(at('user.txt')).readAsStringSync(), 'user content\n');
      });

      test(
        'an unknown after snapshot cannot undo a later user write',
        () async {
          write('file.txt', 'user content\n');
          review.reportEdit(
            FileEdited(
              ++seq,
              FileChange(path: at('file.txt'), added: 1, removed: 1),
              original: const OriginalText('before\n'),
              after: const FileSnapshot.unknown(),
            ),
          );
          await review.look();
          expect(review.changes.single.tracked, isFalse);
          await review.undoAll();
          expect(File(at('file.txt')).readAsStringSync(), 'user content\n');
          expect(review.failure, isNull);
        },
      );
    });
  }
}

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/review/review_store.dart';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store_io.dart';
import 'package:baocode/kernel/kernel_event.dart' show FileEdited, FileSnapshot;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _ReplacingFile extends Fake implements File {
  _ReplacingFile(this.file, this.replace, {this.failures = 1});

  final int failures;
  final File file;
  final void Function() replace;
  var reads = 0;

  @override
  Future<FileStat> stat() => file.stat();

  @override
  Future<Uint8List> readAsBytes() async {
    if (reads++ < failures) {
      if (reads == 1) replace();
      throw FileSystemException('File replaced during read', file.path);
    }
    return file.readAsBytes();
  }
}

final class _ReadOverrides extends IOOverrides {
  _ReadOverrides(this.file);

  final _ReplacingFile file;

  @override
  File createFile(String path) =>
      path == file.file.path ? file : super.createFile(path);
}

/// A project in a temporary folder, what its files were kept in another:
/// the agent's edits told as the kernel tells them.
void main() {
  late Directory temp;
  late String root;
  late String checkpoints;

  String path(String relative) => p.joinAll([root, ...relative.split('/')]);

  void write(String relative, String text) {
    final file = File(path(relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String read(String relative) => File(path(relative)).readAsStringSync();

  ChangeReview open({String? session}) {
    final review = ChangeReview(BlobReviewStore.open(checkpoints), root: root);
    addTearDown(review.dispose);
    if (session != null) review.session = session;
    return review;
  }

  /// The agent of [review] writes [text] to [relative] (null deletes it),
  /// as Claude Code tells it: before, and after.
  Future<void> edit(ChangeReview review, String relative, String? text) async {
    await review.before(path(relative));
    if (text == null) {
      File(path(relative)).deleteSync();
    } else {
      write(relative, text);
    }
    await review.after(path(relative));
  }

  /// The pending changes, by path relative to the project.
  Map<String, FileChange> changesOf(ChangeReview review) => {
    for (final change in review.changes)
      p.split(p.relative(change.path, from: root)).join('/'): change,
  };

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode_review_');
    final resolved = await temp.resolveSymbolicLinks();
    root = p.join(resolved, 'project');
    checkpoints = p.join(resolved, 'checkpoints');
    write('a.txt', '1\n2\n3\n4\n5\n');
    write('lib/b.txt', 'b\n');
  });

  tearDown(() => temp.delete(recursive: true));

  for (final operation in [
    'before',
    'after',
    'begin',
    'look',
    'report',
    'settle',
  ]) {
    test(
      'an oversized file during $operation does not stop other changes',
      () async {
        final limit = BlobReviewStore.maxFileBytes;
        BlobReviewStore.maxFileBytes = 16;
        addTearDown(() => BlobReviewStore.maxFileBytes = limit);
        final review = open(session: 'large-$operation');
        await edit(review, 'a.txt', 'agent\n');
        if (operation == 'after') await review.before(path('a.txt'));
        final large = 'x' * 32;
        write('a.txt', large);
        switch (operation) {
          case 'before':
            await review.before(path('a.txt'));
            await review.after(path('a.txt'));
          case 'after':
            await review.after(path('a.txt'));
          case 'begin':
            await review.begin();
          case 'look':
            await review.look();
          case 'settle':
            await review.settle([path('a.txt')]);
          case 'report':
            review.report(
              FileChange(path: path('a.txt'), added: 1, removed: 1),
            );
            await review.look();
        }
        expect(review.failure, isNull);
        expect(changesOf(review)['a.txt']!.tracked, isFalse);
        expect(review.original(path('a.txt')), isNull);
        expect(review.baseOf(path('a.txt')), isNull);
        await edit(review, 'lib/b.txt', 'bee\n');
        expect(changesOf(review)['lib/b.txt']!.tracked, isTrue);
        await review.undoAll();
        expect(read('a.txt'), large);
        expect(read('lib/b.txt'), 'b\n');
        await review.begin();
        await edit(review, 'lib/b.txt', 'next\n');
        expect(review.failure, isNull);
        expect(changesOf(review)['lib/b.txt']!.tracked, isTrue);
        await review.undoAll();
        expect(read('lib/b.txt'), 'b\n');

        // Smaller again does not make unknown writes safe to undo.
        await edit(review, 'a.txt', 'small\n');
        await review.observe();
        expect(changesOf(review)['a.txt']!.tracked, isFalse);
        await review.undoAll();
        expect(read('a.txt'), 'small\n');
        final resumed = await ChangeReview.resume(
          BlobReviewStore.open(checkpoints),
          'large-$operation',
          root: root,
        );
        addTearDown(resumed.dispose);
        expect(changesOf(resumed)['a.txt']!.tracked, isFalse);
        await resumed.begin();
        write('a.txt', 'external\n');
        await resumed.observe();
        expect(changesOf(resumed)['a.txt']!.tracked, isFalse);
        await resumed.undoAll();
        expect(read('a.txt'), 'external\n');
        await resumed.keep([path('a.txt')]);
        await edit(resumed, 'a.txt', 'later\n');
        expect(changesOf(resumed)['a.txt']!.tracked, isTrue);
        await resumed.undoAll();
        expect(read('a.txt'), 'external\n');
      },
    );
  }

  test('a workspace snapshot fills an unknown after event', () async {
    final review = open();
    const initial = 'before\n';
    write('a.txt', initial);
    await review.begin();
    write('a.txt', 'agent\n');
    review.reportEdit(
      const FileEdited(
        1,
        FileChange(path: 'a.txt', added: 1, removed: 1),
        after: FileSnapshot.unknown(),
      ),
    );
    await review.look();
    expect(changesOf(review)['a.txt']!.tracked, isFalse);
    await review.observe();
    expect(review.failure, isNull);
    expect(changesOf(review)['a.txt']!.tracked, isTrue);
    expect(await review.original(path('a.txt'))!(), initial);
    await review.undoAll();
    expect(read('a.txt'), initial);
  });

  test('legacy unknown changes without read-failure flags stay recoverable', () async {
    final store = BlobReviewStore.open(checkpoints);
    await store.save(
      'legacy',
      '{"version":4,"entries":{},"unseen":[{"path":${jsonEncode(path('a.txt'))},"added":1,"removed":1}]}',
      blobs: const [],
    );
    final resumed = await ChangeReview.resume(store, 'legacy', root: root);
    addTearDown(resumed.dispose);
    expect(changesOf(resumed)['a.txt']!.tracked, isFalse);
    final original = read('a.txt');
    await resumed.begin();
    write('a.txt', 'next agent\n');
    await resumed.observe();
    expect(resumed.failure, isNull);
    expect(changesOf(resumed)['a.txt']!.tracked, isTrue);
    expect(await resumed.original(path('a.txt'))!(), original);
    await resumed.undoAll();
    expect(read('a.txt'), original);
  });

  for (final cleanup in ['keepAll', 'deleted']) {
    test('a $cleanup file clears its read-failure marker', () async {
      final limit = BlobReviewStore.maxFileBytes;
      BlobReviewStore.maxFileBytes = 16;
      addTearDown(() => BlobReviewStore.maxFileBytes = limit);
      final review = open(session: cleanup);
      await edit(review, 'a.txt', 'agent\n');
      write('a.txt', 'x' * 32);
      await review.look();
      expect(changesOf(review)['a.txt']!.tracked, isFalse);
      if (cleanup == 'keepAll') {
        await review.keepAll();
      } else {
        File(path('a.txt')).deleteSync();
        await review.look();
      }
      expect(review.changes, isEmpty);
      write('a.txt', 'base\n');
      await review.begin();
      await edit(review, 'a.txt', 'later\n');
      expect(changesOf(review)['a.txt']!.tracked, isTrue);
      await review.undoAll();
      expect(read('a.txt'), 'base\n');
      expect(review.failure, isNull);
    });
  }

  test('discard removes persisted read-failure markers', () async {
    final limit = BlobReviewStore.maxFileBytes;
    BlobReviewStore.maxFileBytes = 16;
    addTearDown(() => BlobReviewStore.maxFileBytes = limit);
    final review = open(session: 'discarded');
    await edit(review, 'a.txt', 'agent\n');
    write('a.txt', 'x' * 32);
    await review.look();
    expect(changesOf(review)['a.txt']!.tracked, isFalse);
    await review.discard();
    final store = BlobReviewStore.open(checkpoints);
    expect(await store.load('discarded'), isNull);
    write('a.txt', 'base\n');
    final resumed = await ChangeReview.resume(store, 'discarded', root: root);
    addTearDown(resumed.dispose);
    await edit(resumed, 'a.txt', 'later\n');
    expect(changesOf(resumed)['a.txt']!.tracked, isTrue);
    await resumed.undoAll();
    expect(read('a.txt'), 'base\n');
  });

  test('an oversized untracked report does not stop the review', () async {
    final limit = BlobReviewStore.maxFileBytes;
    BlobReviewStore.maxFileBytes = 16;
    addTearDown(() => BlobReviewStore.maxFileBytes = limit);
    final review = open();
    write('large.txt', 'x' * 32);
    review.report(FileChange(path: path('large.txt'), added: 1, removed: 0));
    await review.look();
    expect(review.failure, isNull);
    expect(changesOf(review)['large.txt']!.tracked, isFalse);
    await edit(review, 'lib/b.txt', 'bee\n');
    await review.undoAll();
    expect(read('lib/b.txt'), 'b\n');
    expect(read('large.txt'), 'x' * 32);
  });

  test(
    'an unreadable live file is isolated without guessing a deletion',
    () async {
      final review = open(session: 'unreadable');
      await edit(review, 'a.txt', 'agent\n');
      final file = File(path('a.txt'));
      final failing = _ReplacingFile(file, () {}, failures: 100);
      await IOOverrides.runWithIOOverrides(
        review.look,
        _ReadOverrides(failing),
      );
      expect(review.failure, isNull);
      expect(changesOf(review)['a.txt']!.tracked, isFalse);
      expect(review.original(path('a.txt')), isNull);
      await edit(review, 'lib/b.txt', 'bee\n');
      await review.undoAll();
      expect(read('a.txt'), 'agent\n');
      expect(read('lib/b.txt'), 'b\n');
    },
  );

  test('an oversized reported original degrades only that file', () async {
    final limit = BlobReviewStore.maxFileBytes;
    BlobReviewStore.maxFileBytes = 16;
    addTearDown(() => BlobReviewStore.maxFileBytes = limit);
    final review = open();
    write('large.txt', 'x' * 32);
    review.report(
      FileChange(path: path('large.txt'), added: 1, removed: 1),
      original: const OriginalText('old\n'),
    );
    await review.look();
    expect(review.failure, isNull);
    expect(changesOf(review)['large.txt']!.tracked, isFalse);
    await edit(review, 'lib/b.txt', 'bee\n');
    await review.undoAll();
    expect(read('large.txt'), 'x' * 32);
    expect(read('lib/b.txt'), 'b\n');
  });

  test('a missing historical blob still stops unsafe review', () async {
    final review = open();
    await edit(review, 'a.txt', 'agent\n');
    final oid = review.baseOf(path('a.txt'))!;
    File(p.join(checkpoints, 'blobs', oid.substring(0, 2), oid.substring(2)))
        .deleteSync();
    write('a.txt', 'user\n');
    await review.before(path('a.txt'));
    expect(review.failure, isNotNull);
    await review.undoAll();
    expect(read('a.txt'), 'user\n');
  });

  test('a replaced file is read again instead of ending review', () async {
    final store = BlobReviewStore.open(checkpoints);
    final file = File(path('a.txt'));
    final replacing = _ReplacingFile(
      file,
      () => file.writeAsStringSync('replacement\n'),
    );
    final found = await IOOverrides.runZoned(
      () => store.current(file.path),
      createFile: (_) => replacing,
    );
    expect(replacing.reads, 2);
    expect(found, await store.current(file.path));
    expect(found, isNotNull);
  });

  test('a file lost during reading is not guessed to be a deletion', () async {
    final store = BlobReviewStore.open(checkpoints);
    final file = File(path('a.txt'));
    final replacing = _ReplacingFile(file, file.deleteSync);
    await expectLater(
      IOOverrides.runZoned(
        () => store.current(file.path),
        createFile: (_) => replacing,
      ),
      throwsA(
        isA<ReviewUnavailable>().having(
          (error) => error.retryable,
          'retryable',
          isTrue,
        ),
      ),
    );
  });

  test('lists what the agent edited, not what changed otherwise', () async {
    final review = open();
    // Not the agent's.
    write('notes.txt', 'mine\n');

    await edit(review, 'a.txt', 'one\n2\n3\n4\n5\n6\n');
    await edit(review, 'lib/c.txt', 'c\nc\n');
    await edit(review, 'lib/b.txt', null);

    final changes = changesOf(review);
    expect(changes.keys, unorderedEquals(['a.txt', 'lib/b.txt', 'lib/c.txt']));
    expect(changes['a.txt']!.kind, FileChangeKind.modified);
    expect((changes['a.txt']!.added, changes['a.txt']!.removed), (2, 1));
    expect(changes['lib/c.txt']!.kind, FileChangeKind.added);
    expect(changes['lib/c.txt']!.added, 2);
    expect(changes['lib/b.txt']!.kind, FileChangeKind.deleted);
    expect(changes['lib/b.txt']!.removed, 1);

    // Changed back by the agent: nothing pending.
    await edit(review, 'lib/c.txt', null);
    expect(changesOf(review).keys, unorderedEquals(['a.txt', 'lib/b.txt']));
  });

  test('an edit not let through, or never told the end of, is not listed '
      'once the turn ends', () async {
    final review = open();
    await review.before(path('a.txt'));
    await review.after(path('a.txt'));
    await review.before(path('lib/b.txt'));
    expect(review.changes, isEmpty);
    await review.look();
    expect(review.changes, isEmpty);

    // What the user does after is not the agent's.
    write('lib/b.txt', 'mine\n');
    await review.look();
    expect(review.changes, isEmpty);
  });

  test('keeps a change without touching the file', () async {
    final review = open();
    await edit(review, 'a.txt', 'one\n');
    await edit(review, 'lib/b.txt', 'bee\n');

    await review.keep([path('a.txt')]);
    expect(changesOf(review).keys, ['lib/b.txt']);
    expect(read('a.txt'), 'one\n');

    // Edited again: listed against what was kept.
    await edit(review, 'a.txt', 'one\ntwo\n');
    expect(changesOf(review)['a.txt']!.added, 1);
    expect(changesOf(review)['a.txt']!.removed, 0);

    await review.keepAll();
    expect(review.changes, isEmpty);
  });

  test('undoes edits, creations and deletions', () async {
    final review = open();
    await edit(review, 'a.txt', 'one\n');
    await edit(review, 'new/deep/c.txt', 'c\n');
    await edit(review, 'lib/b.txt', null);
    expect(review.changes, hasLength(3));

    await review.undoAll();
    expect(review.changes, isEmpty);
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
    expect(read('lib/b.txt'), 'b\n');
    // The folders it made go with the file.
    expect(Directory(path('new')).existsSync(), isFalse);

    // Undone, it is not the agent's change.
    await review.look();
    expect(review.changes, isEmpty);
  });

  test('undo keeps what changed since the agent, or leaves the file', () async {
    final review = open();
    await edit(review, 'a.txt', 'one\n2\n3\n4\n5\n');
    await edit(review, 'lib/b.txt', 'bee\n');

    // The user, after the turn.
    write('a.txt', 'one\n2\n3\n4\nfive\n');
    write('lib/b.txt', 'B\n');
    await review.look();

    await review.undo([path('a.txt')]);
    expect(read('a.txt'), '1\n2\n3\n4\nfive\n');
    expect(changesOf(review).keys, ['lib/b.txt']);

    // The same line: left as it is, and marked.
    await review.undo([path('lib/b.txt')]);
    expect(read('lib/b.txt'), 'B\n');
    expect(changesOf(review)['lib/b.txt']!.conflict, isTrue);
  });

  test('what changed between two of its edits is not the agent\'s', () async {
    final review = open();
    await edit(review, 'a.txt', 'one\n2\n3\n4\n5\n');
    // The user, between turns.
    write('a.txt', 'one\n2\n3\n4\nfive\n');
    await edit(review, 'a.txt', 'one\n2\nthree\n4\nfive\n');

    final change = changesOf(review)['a.txt']!;
    expect((change.added, change.removed), (2, 2));
    expect(await review.original(path('a.txt'))!(), '1\n2\n3\n4\nfive\n');

    await review.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\nfive\n');
  });

  test('two conversations in one file: each lists and undoes its own '
      'change', () async {
    final first = open(session: 'first');
    final second = open(session: 'second');
    await edit(first, 'a.txt', 'one\n2\n3\n4\n5\n');
    await edit(second, 'a.txt', 'one\n2\n3\n4\nfive\n');
    await edit(first, 'a.txt', 'ONE\n2\n3\n4\nfive\n');

    final mine = changesOf(first)['a.txt']!;
    final theirs = changesOf(second)['a.txt']!;
    expect((mine.added, mine.removed), (1, 1));
    expect((theirs.added, theirs.removed), (1, 1));
    expect(await first.original(path('a.txt'))!(), '1\n2\n3\n4\nfive\n');
    expect(await second.original(path('a.txt'))!(), 'one\n2\n3\n4\n5\n');

    await first.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\nfive\n');
    await second.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
  });

  test('its own edits under way at once are its own', () async {
    final review = open();
    // Two subagents, one file: the second begins as the first writes.
    await review.before(path('a.txt'));
    write('a.txt', 'one\n2\n3\n4\n5\n');
    await review.before(path('a.txt'));
    await review.after(path('a.txt'));
    write('a.txt', 'one\n2\n3\n4\nfive\n');
    await review.after(path('a.txt'));

    expect(await review.original(path('a.txt'))!(), '1\n2\n3\n4\n5\n');
    expect(changesOf(review)['a.txt']!.added, 2);
  });

  test('keeps and undoes a change part by part', () async {
    final review = open();
    await edit(review, 'a.txt', 'one\n2\n3\n4\nfive\n');
    final a = path('a.txt');
    final created = review.baseOf(a);
    expect(created, isNotNull);
    expect(await review.original(a)!(), '1\n2\n3\n4\n5\n');

    // The first line kept: held against what was there with it in.
    await review.keepPart(a, 'one\n2\n3\n4\n5\n');
    expect(review.baseOf(a), isNot(created));
    expect(await review.original(a)!(), 'one\n2\n3\n4\n5\n');
    expect(
      (changesOf(review)['a.txt']!.added, changesOf(review)['a.txt']!.removed),
      (1, 1),
    );
    expect(read('a.txt'), 'one\n2\n3\n4\nfive\n');

    // The last undone in the file, as the editor does it: nothing left.
    write('a.txt', 'one\n2\n3\n4\n5\n');
    await review.settle([a]);
    expect(review.changes, isEmpty);
    expect(review.baseOf(a), isNull);
  });

  test('keeping every part of a change keeps it', () async {
    final review = open(session: 's');
    await edit(review, 'a.txt', '1\n2\nthree\n4\n5\n');
    await review.keepPart(path('a.txt'), '1\n2\nthree\n4\n5\n');
    expect(review.changes, isEmpty);
    expect(read('a.txt'), '1\n2\nthree\n4\n5\n');
  });

  test('puts back line endings, bytes and links as they were', () async {
    File(path('crlf.txt')).writeAsBytesSync([...'x\r\ny\r\n'.codeUnits, 0xff]);
    Link(path('link')).createSync('a.txt');
    final review = open();
    await review.before(path('crlf.txt'));
    File(path('crlf.txt')).writeAsBytesSync('x\r\nz\r\n'.codeUnits);
    await review.after(path('crlf.txt'));
    await review.before(path('link'));
    Link(path('link')).updateSync('lib/b.txt');
    await review.after(path('link'));
    expect(review.changes, hasLength(2));

    await review.undoAll();
    expect(File(path('crlf.txt')).readAsBytesSync(), [
      ...'x\r\ny\r\n'.codeUnits,
      0xff,
    ]);
    expect(Link(path('link')).targetSync(), 'a.txt');
  });

  test('an edit told only once made is held against what the agent told '
      'it was', () async {
    final review = open(session: 's');
    String beside(String name) => p.join(p.dirname(root), 'elsewhere', name);
    File(beside('o.txt'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('keep\nnew line\nkeep\n');
    write('a.txt', 'changed\n');
    write('patched.txt', 'x\nY\nz\n');
    write('new.txt', 'n\n');
    // Claude Code tells the text (a subagent's, its edits); Codex, its
    // diff; a new file.
    review
      ..report(
        FileChange(path: path('a.txt'), added: 1, removed: 5),
        original: const OriginalText('1\n2\n3\n4\n5\n'),
      )
      ..report(
        FileChange(path: beside('o.txt'), added: 1, removed: 1),
        original: const OriginalByEdits([(before: 'old', after: 'new')]),
      )
      ..report(
        FileChange(path: path('patched.txt'), added: 1, removed: 1),
        original: const OriginalByPatch('@@ -1,3 +1,3 @@\n x\n-y\n+Y\n z\n'),
      )
      ..report(
        FileChange(path: path('new.txt'), added: 1, removed: 0),
        original: const OriginalText(null),
      );
    await review.look();
    expect(review.changes, hasLength(4));
    expect(review.changes.every((change) => change.tracked), isTrue);

    await review.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
    expect(File(beside('o.txt')).readAsStringSync(), 'keep\nold line\nkeep\n');
    expect(read('patched.txt'), 'x\ny\nz\n');
    expect(File(path('new.txt')).existsSync(), isFalse);
  });

  test('lists an edit it was not told the before of, to keep and not '
      'undo, till its file is gone', () async {
    final review = open();
    write('gen.txt', 'g\n');
    write('script.sh', 's\n');
    review
      ..report(FileChange(path: path('gen.txt'), added: 1, removed: 0))
      ..report(FileChange(path: path('script.sh'), added: 1, removed: 0));
    await review.look();
    expect(review.changes.where((c) => !c.tracked), hasLength(2));

    await review.undoAll();
    expect(File(path('gen.txt')).existsSync(), isTrue);
    File(path('script.sh')).deleteSync();
    await review.look();
    expect(changesOf(review).keys, ['gen.txt']);
    await review.keepAll();
    expect(review.changes, isEmpty);
  });

  test('a project opened through a link: its files told by their real '
      'path are its own', () async {
    final link = p.join(temp.path, 'linked');
    Link(link).createSync(root);
    final review = ChangeReview(
      BlobReviewStore.open(checkpoints),
      root: link,
      realRoot: root,
    );
    addTearDown(review.dispose);
    // As the agent tells it: by the real path.
    await edit(review, 'a.txt', 'changed\n');
    expect([for (final c in review.changes) c.path], [p.join(link, 'a.txt')]);
    await review.undo([p.join(link, 'a.txt')]);
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
  });

  test('carries on where the session left off', () async {
    final review = open(session: 'session-1');
    await edit(review, 'a.txt', 'one\n');
    await review.look();

    final reopened = await ChangeReview.resume(
      BlobReviewStore.open(checkpoints),
      'session-1',
      root: root,
    );
    addTearDown(reopened.dispose);
    expect(changesOf(reopened).keys, ['a.txt']);
    await edit(reopened, 'lib/b.txt', 'agent\n');
    expect(changesOf(reopened).keys, unorderedEquals(['a.txt', 'lib/b.txt']));
    await reopened.undo([path('a.txt')]);
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');

    // Nothing left pending: nothing kept.
    await reopened.keepAll();
    final again = await ChangeReview.resume(
      BlobReviewStore.open(checkpoints),
      'session-1',
      root: root,
    );
    addTearDown(again.dispose);
    expect(again.changes, isEmpty);
  });

  test('a session renamed keeps its changes under its new name', () async {
    final review = open(session: 'old');
    await edit(review, 'a.txt', 'one\n');
    review.session = 'new';
    await review.look();
    final moved = await ChangeReview.resume(
      BlobReviewStore.open(checkpoints),
      'new',
      root: root,
    );
    addTearDown(moved.dispose);
    expect(changesOf(moved).keys, ['a.txt']);
    final gone = await ChangeReview.resume(
      BlobReviewStore.open(checkpoints),
      'old',
      root: root,
    );
    addTearDown(gone.dispose);
    expect(gone.changes, isEmpty);
  });
}

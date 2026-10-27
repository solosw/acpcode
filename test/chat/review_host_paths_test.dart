import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/change_reviews.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Only store-relative POSIX paths go to the store; host paths go to the UI.
class _Store implements ReviewStore {
  _Store(this.root);

  @override
  final String root;
  final files = <String, ReviewBlob>{};
  final _texts = <ReviewBlob, String>{};
  final _saved = <String, String>{};
  final restored = <String>[];
  final _trees = <String, Map<String, ReviewBlob>>{};
  Map<String, ReviewBlob> _latest = {};

  String _tree(Map<String, ReviewBlob> files) {
    final id = 'tree-${_trees.length}';
    _trees[id] = Map.of(files);
    return id;
  }

  ReviewBlob _blob(String mode, String text) {
    for (final MapEntry(key: blob, value: stored) in _texts.entries) {
      if (stored == text && blob.mode == mode) return blob;
    }
    final blob = ReviewBlob(mode, '${_texts.length}');
    _texts[blob] = text;
    return blob;
  }

  void edit(String path, String text) {
    files[path] = _blob('100644', text);
  }

  @override
  Future<String?> snapshot({Iterable<String>? paths}) async {
    if (paths == null) {
      _latest = Map.of(files);
    } else {
      for (final path in paths) {
        if (files[path] case final blob?) {
          _latest[path] = blob;
        } else {
          _latest.remove(path);
        }
      }
    }
    return _tree(_latest);
  }

  @override
  Future<List<ReviewTreeChange>> diff(String from, String to) async => [
    for (final path in {..._trees[from]!.keys, ..._trees[to]!.keys})
      if (_trees[from]![path] != _trees[to]![path])
        ReviewTreeChange(path, _trees[from]![path], _trees[to]![path]),
  ];

  @override
  Future<String> overlay(String tree, Map<String, ReviewBlob?> entries) async {
    final files = <String, ReviewBlob>{...?_trees[tree]};
    for (final MapEntry(key: path, value: blob) in entries.entries) {
      if (blob == null) {
        files.remove(path);
      } else {
        files[path] = blob;
      }
    }
    return _tree(files);
  }

  @override
  Future<bool> contains(String tree, String path) async =>
      _trees[tree]!.containsKey(path);

  @override
  Future<ReviewBlob?> take(String path) async => files[path];

  @override
  Future<ReviewBlob> store(Uint8List bytes, {required String mode}) async {
    return _blob(mode, utf8.decode(bytes));
  }

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String from,
    String to,
  ) async => {
    for (final change in await diff(from, to))
      change.path: (added: 1, removed: 1),
  };

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<ReviewBlob?> current(String path) async => files[path];

  @override
  Future<Uint8List> read(ReviewBlob blob) async =>
      Uint8List.fromList(utf8.encode(_texts[blob]!));

  @override
  Future<void> restore(String path, ReviewBlob? blob) async {
    restored.add(path);
    if (blob == null) {
      files.remove(path);
    } else {
      files[path] = blob;
    }
  }

  @override
  Future<Uint8List?> merge(String path, ReviewBlob from, ReviewBlob to) =>
      throw UnimplementedError();

  @override
  Future<void> write(String path, Uint8List bytes) async =>
      edit(path, utf8.decode(bytes));

  @override
  Future<String?> load(String session) async => _saved[session];

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) async => _saved[session] = data;

  @override
  Future<void> forget(String session) async => _saved.remove(session);
}

void main() {
  test('a remote store selects POSIX paths regardless of the client OS', () {
    final peer = RpcPeer(const Stream.empty(), (_) {});
    addTearDown(peer.close);
    final review = ChangeReview(
      RemoteReviewStore(peer, 1, '/home/dev/project'),
    );
    addTearDown(review.dispose);
    expect(review.paths, same(p.posix));
  });

  for (final (context, root) in [
    (p.posix, '/home/dev/project'),
    (p.windows, r'C:\work\project'),
  ]) {
    group('${context.style} host', () {
      late _Store store;
      late ChangeReview review;
      final absolute = context.join(root, 'lib', 'main.dart');

      setUp(() async {
        store = _Store(root)..edit('lib/main.dart', 'before\n');
        review = ChangeReview(store, paths: context)..session = 's1';
        addTearDown(review.dispose);
        await review.begin();
      });

      test(
        'listed files, originals and undo use the host path context',
        () async {
          store.edit('lib/main.dart', 'after\n');
          review.reportEdit(
            FileEdited(
              1,
              FileChange(path: absolute, added: 1, removed: 1),
              after: FileSnapshot.text('after\n'),
            ),
          );
          await review.observe();
          expect(review.changes.single.path, absolute);
          expect(review.changes.single.tracked, isTrue);
          expect(await review.original(absolute)!(), 'before\n');

          await review.undo([absolute]);
          expect(store.restored, ['lib/main.dart']);
          expect(review.changes, isEmpty);
          expect(review.failure, isNull);
        },
      );

      test('resumed changes and keep preserve host paths', () async {
        review.session = 's1';
        store.edit('lib/main.dart', 'after\n');
        await review.observe();

        final resumed = await ChangeReview.resume(store, 's1', paths: context);
        addTearDown(resumed.dispose);
        expect(resumed.changes.single.path, absolute);
        expect(await resumed.original(absolute)!(), 'before\n');
        await resumed.keep([absolute]);
        expect(resumed.changes, isEmpty);
        expect(store.restored, isEmpty);
        expect(resumed.failure, isNull);
      });
    });

    test('${context.style} multi-folder review routes host paths', () async {
      final other = context.join(context.dirname(root), 'other');
      final stores = <String, _Store>{};
      final reviews = await ChangeReviews.open(
        [root, other, context.join(root, 'nested'), root],
        paths: context,
        open: (root, {session}) async {
          final store = stores[root] = _Store(root)
            ..edit('lib/main.dart', 'before\n');
          return ChangeReview(store, paths: context);
        },
      );
      addTearDown(reviews!.dispose);
      expect(stores.keys, [root, other]);
      reviews.session = 's1';
      await reviews.begin();
      for (final store in stores.values) {
        store.edit('lib/main.dart', 'after\n');
      }
      final first = context.join(root, 'lib', 'main.dart');
      final second = context.join(other, 'lib', 'main.dart');
      reviews
        ..reportEdit(
          FileEdited(
            1,
            const FileChange(path: 'lib/main.dart', added: 1, removed: 1),
            after: FileSnapshot.text('after\n'),
          ),
        )
        ..reportEdit(
          FileEdited(
            2,
            FileChange(path: second, added: 1, removed: 1),
            after: FileSnapshot.text('after\n'),
          ),
        );
      await reviews.observe();
      expect(reviews.changes.map((c) => c.path), [first, second]);
      expect(await reviews.original(second)!(), 'before\n');
      await reviews.undo([second]);
      expect(stores[other]!.restored, ['lib/main.dart']);
      expect(stores[root]!.restored, isEmpty);
      await reviews.keep(['lib/main.dart']);
      expect(reviews.changes, isEmpty);
    });
  }

  test('remote multi-folder roots are filtered with POSIX rules', () async {
    final opened = <String>[];
    final reviews = await ChangeReviews.open(
      [
        'ssh://dev/home/Project',
        'ssh://dev/home/project',
        'ssh://dev/home/Project/nested',
        'ssh://dev/home/Project',
      ],
      open: (location, {session}) async {
        opened.add(location);
        return ChangeReview(
          _Store(RemoteLocation.pathOf(location)),
          paths: p.posix,
        );
      },
    );
    addTearDown(reviews!.dispose);
    expect(opened, ['ssh://dev/home/Project', 'ssh://dev/home/project']);
  });
}

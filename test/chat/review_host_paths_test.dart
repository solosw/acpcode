import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/change_reviews.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Only store-relative POSIX paths go to the store; host paths go to the UI.
class _Store implements ReviewStore {
  _Store(this.root);

  @override
  final String root;
  final files = <String, ReviewBlob>{};
  final _texts = <ReviewBlob, String>{};
  final _trees = <String, Map<String, ReviewBlob>>{};
  final _saved = <String, String>{};
  final snapshots = <List<String>?>[];
  final restored = <String>[];

  void edit(String path, String text) {
    final blob = ReviewBlob('100644', '${_texts.length}');
    files[path] = blob;
    _texts[blob] = text;
  }

  String _tree(Map<String, ReviewBlob> files) {
    final id = '${_trees.length}';
    _trees[id] = Map.of(files);
    return id;
  }

  @override
  Future<String> snapshot({Iterable<String>? paths}) async {
    snapshots.add(paths?.toList());
    return _tree(files);
  }

  @override
  Future<List<ReviewTreeChange>> diff(String from, String to) async => [
    for (final path in {..._trees[from]!.keys, ..._trees[to]!.keys})
      if (_trees[from]![path] != _trees[to]![path])
        ReviewTreeChange(path, _trees[from]![path], _trees[to]![path]),
  ];

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String from,
    String to,
  ) async => {
    for (final change in await diff(from, to))
      change.path: (added: 1, removed: 1),
  };

  @override
  Future<String> overlay(String tree, Map<String, ReviewBlob?> entries) async {
    final result = Map.of(_trees[tree]!);
    for (final MapEntry(:key, :value) in entries.entries) {
      if (value == null) {
        result.remove(key);
      } else {
        result[key] = value;
      }
    }
    return _tree(result);
  }

  @override
  Future<bool> contains(String tree, String path) async =>
      _trees[tree]!.containsKey(path);

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
    required Iterable<String> trees,
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
        review = ChangeReview(store, paths: context);
        addTearDown(review.dispose);
        await review.begin();
      });

      test(
        'listed files, originals and undo use the host path context',
        () async {
          store.edit('lib/main.dart', 'after\n');
          review.report(FileChange(path: absolute, added: 1, removed: 1));
          await review.observe(full: false);

          expect(store.snapshots.last, ['lib/main.dart']);
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
      await reviews.begin();
      for (final store in stores.values) {
        store.edit('lib/main.dart', 'after\n');
      }
      final first = context.join(root, 'lib', 'main.dart');
      final second = context.join(other, 'lib', 'main.dart');
      reviews
        ..report(const FileChange(path: 'lib/main.dart', added: 1, removed: 1))
        ..report(FileChange(path: second, added: 1, removed: 1));
      await reviews.observe(full: false);
      expect(stores.values.map((s) => s.snapshots.last), [
        ['lib/main.dart'],
        ['lib/main.dart'],
      ]);
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

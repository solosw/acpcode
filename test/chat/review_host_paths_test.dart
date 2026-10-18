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
class _Store implements ReviewStore, ScanningReviewStore {
  _Store(this.root);

  @override
  final String root;
  final files = <String, ReviewBlob>{};
  final _texts = <ReviewBlob, String>{};
  final _saved = <String, String>{};
  final restored = <String>[];

  void edit(String path, String text) {
    final blob = ReviewBlob('100644', '${_texts.length}');
    files[path] = blob;
    _texts[blob] = text;
  }

  @override
  Future<Map<String, ReviewBlob?>> scan(String session) async => Map.of(files);

  @override
  Future<ReviewBlob?> take(String session, String path) async => files[path];

  @override
  Future<ReviewBlob> store(
    String session,
    Uint8List bytes, {
    required String mode,
  }) async {
    final blob = ReviewBlob(mode, '${_texts.length}');
    _texts[blob] = utf8.decode(bytes);
    return blob;
  }

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String session,
    Map<String, ReviewBlob?> bases,
  ) async => {for (final path in bases.keys) path: (added: 1, removed: 1)};

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<ReviewBlob?> current(String path) async => files[path];

  @override
  Future<Uint8List> read(String session, ReviewBlob blob) async =>
      Uint8List.fromList(utf8.encode(_texts[blob]!));

  @override
  Future<void> restore(String session, String path, ReviewBlob? blob) async {
    restored.add(path);
    if (blob == null) {
      files.remove(path);
    } else {
      files[path] = blob;
    }
  }

  @override
  Future<Uint8List?> merge(
    String session,
    String path,
    ReviewBlob from,
    ReviewBlob to,
  ) => throw UnimplementedError();

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
          review.report(FileChange(path: absolute, added: 1, removed: 1));
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
        ..report(const FileChange(path: 'lib/main.dart', added: 1, removed: 1))
        ..report(FileChange(path: second, added: 1, removed: 1));
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

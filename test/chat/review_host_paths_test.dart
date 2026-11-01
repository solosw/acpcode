import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Both the store and the UI use absolute paths in the host context.
class _Store implements ReviewStore {
  _Store(this.root);

  final String root;
  final files = <String, ReviewBlob>{};
  final _texts = <ReviewBlob, String>{};
  final _saved = <String, String>{};
  final restored = <String>[];
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
  Future<ReviewBlob?> take(String path) async => files[path];

  @override
  Future<ReviewBlob> store(Uint8List bytes, {required String mode}) async {
    return _blob(mode, utf8.decode(bytes));
  }

  @override
  Future<({int added, int removed})?> lineCounts(
    ReviewBlob? from,
    ReviewBlob? to,
  ) async => (added: 1, removed: 1);

  @override
  Future<ReviewBlob?> current(String path) async => files[path];

  @override
  Future<Uint8List> read(ReviewBlob blob) async =>
      Uint8List.fromList(utf8.encode(_texts[blob]!));

  @override
  Future<void> restore(String path, ReviewBlob? blob, {String? root}) async {
    restored.add(path);
    if (blob == null) {
      files.remove(path);
    } else {
      files[path] = blob;
    }
  }

  @override
  Future<Uint8List?> merge(ReviewBlob mine, ReviewBlob from, ReviewBlob to) =>
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
      RemoteReviewStore(peer, 1),
      root: '/home/dev/project',
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
        store = _Store(root)..edit(absolute, 'before\n');
        review = ChangeReview(store, root: root, paths: context)
          ..session = 's1';
        addTearDown(review.dispose);
        await review.before(absolute);
      });

      test(
        'listed files, originals and undo use the host path context',
        () async {
          store.edit(absolute, 'after\n');
          review.reportEdit(
            FileEdited(
              1,
              FileChange(path: absolute, added: 1, removed: 1),
              after: FileSnapshot.text('after\n'),
            ),
          );
          await review.after(absolute);
          expect(review.changes.single.path, absolute);
          expect(review.changes.single.tracked, isTrue);
          expect(await review.original(absolute)!(), 'before\n');

          await review.undo([absolute]);
          expect(store.restored, [absolute]);
          expect(review.changes, isEmpty);
          expect(review.failure, isNull);
        },
      );

      test('resumed changes and keep preserve host paths', () async {
        review.session = 's1';
        store.edit(absolute, 'after\n');
        await review.after(absolute);

        final resumed = await ChangeReview.resume(
          store,
          's1',
          root: root,
          paths: context,
        );
        addTearDown(resumed.dispose);
        expect(resumed.changes.single.path, absolute);
        expect(await resumed.original(absolute)!(), 'before\n');
        await resumed.keep([absolute]);
        expect(resumed.changes, isEmpty);
        expect(store.restored, isEmpty);
        expect(resumed.failure, isNull);
      });
    });

    test(
      'one conversation reviews absolute paths in another workspace folder',
      () async {
        final store = _Store(root);
        final review = ChangeReview(store, root: root, paths: context)
          ..session = 'workspace';
        addTearDown(review.dispose);
        final other = context.join(context.dirname(root), 'other', 'file.dart');
        store.edit(other, 'before\n');
        await review.before(other);
        store.edit(other, 'after\n');
        await review.after(other);
        expect(review.changes.single.path, other);
        expect(await review.original(other)!(), 'before\n');
        await review.undoAll();
        expect(store.restored, [other]);
        expect(review.failure, isNull);
      },
    );
  }
}

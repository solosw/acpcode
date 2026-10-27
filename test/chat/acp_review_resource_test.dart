@TestOn('vm')
library;

import 'dart:io';

import 'package:bao_remote/local.dart' show GitReviewStore;
import 'package:bao_remote/protocol.dart' show RpcError;
import 'package:bao_remote/review.dart' show ReviewUnavailable;
import 'package:baocode/chat/review/change_review.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Fail at the Git snapshot's index-directory access, before staging changes.
/// The old scanner used systemTemp; Git no longer does, so injecting there
/// would let these tests pass without exercising a failed discovery.
final class _SnapshotFailure extends IOOverrides {
  _SnapshotFailure(this.gitDir, this.code);

  final String gitDir;
  final int code;
  var attempts = 0;

  @override
  Directory createDirectory(String path) {
    if (p.equals(path, gitDir)) {
      attempts++;
      throw FileSystemException(
        code == 13 ? 'Permission denied' : 'Too many open files',
        path,
        OSError(code == 13 ? 'Permission denied' : 'Too many open files', code),
      );
    }
    return super.createDirectory(path);
  }
}

void main() {
  late Directory temp;
  late String root;
  late ChangeReview review;
  late GitReviewStore store;

  void write(String text) =>
      File(p.join(root, 'file.txt')).writeAsStringSync(text);
  String read() => File(p.join(root, 'file.txt')).readAsStringSync();

  Future<void> exhausted(Future<void> Function() action, {int? code}) async {
    final failure = _SnapshotFailure(
      store.gitDir,
      code ?? (Platform.isWindows ? 4 : 24),
    );
    await IOOverrides.runWithIOOverrides(action, failure);
    expect(
      failure.attempts,
      isPositive,
      reason: 'discovery must hit the fault',
    );
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('acp-resource-');
    root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
    store = (await GitReviewStore.open(
      root,
      checkpoints: p.join(temp.path, 'checkpoints'),
    ))!;
    review = ChangeReview(store)..session = 'resource';
  });
  tearDown(() async {
    review.dispose();
    await review.discard();
    temp.deleteSync(recursive: true);
  });

  test(
    'resource errors keep their retry flag over RPC; corruption does not',
    () {
      for (final retryable in [false, true]) {
        final error = ReviewUnavailable(
          'discovery failed',
          retryable: retryable,
        );
        final decoded = RpcError.fromJson(RpcError.from(error).toJson())
            .toException();
        expect(decoded, isA<ReviewUnavailable>());
        expect((decoded as ReviewUnavailable).retryable, retryable);
        expect(decoded.message, 'discovery failed');
      }
      final legacy =
          RpcError.fromJson({
                'code': -32000,
                'message': 'broken repository',
                'data': {'type': 'reviewUnavailable'},
              }).toException()
              as ReviewUnavailable;
      expect(legacy.retryable, isFalse);
    },
  );

  test(
    'permission failures still stop discovery rather than retrying forever',
    () async {
      await exhausted(review.begin, code: 13);
      expect(review.failure, isNotNull);
    },
  );

  for (final code in Platform.isWindows ? [4] : [23, 24]) {
    test(
      'descriptor error $code preserves pending changes and the next scan retries',
      () async {
        write('before\n');
        await review.begin();
        write('agent one\n');
        await review.observe();
        expect(review.changes, hasLength(1));
        await exhausted(review.observe, code: code);
        expect(review.failure, isNull);
        expect(review.changes, hasLength(1));
        write('agent two\n');
        await review.observe();
        expect(await review.original(p.join(root, 'file.txt'))!(), 'before\n');
        await review.undoAll();
        expect(read(), 'before\n');
      },
    );
  }

  test(
    'a failed initial baseline never turns an existing file into a creation',
    () async {
      write('user content\n');
      await exhausted(review.begin);
      expect(review.failure, isNull);
      write('missed edit\n');
      await review.observe();
      expect(
        review.changes,
        isEmpty,
        reason: 'there was no safe before snapshot',
      );
      write('tracked edit\n');
      await review.observe();
      await review.undoAll();
      expect(read(), 'missed edit\n');
    },
  );

  test(
    'a failed turn baseline protects intervening user edits from Undo',
    () async {
      write('original\n');
      await review.begin();
      write('agent\n');
      await review.observe();
      write('user edit\n');
      await exhausted(review.begin);
      expect(review.failure, isNull);
      await review.undoAll();
      expect(read(), 'user edit\n');
      write('next agent\n');
      await review.observe();
      expect(review.changes.single.conflict, isTrue);
      await review.undoAll();
      expect(read(), 'next agent\n');
    },
  );
}

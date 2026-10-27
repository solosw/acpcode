@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show GitReviewStore;
import 'package:baocode/chat/review/change_review.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late String root;
  late String checkpoints;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('legacy-review-name-');
    root = (await Directory(p.join(temporary.path, 'project')).create()).path;
    checkpoints = p.join(temporary.path, 'checkpoints');
  });
  tearDown(() async => temporary.delete(recursive: true));

  Future<File> seed(String source) async {
    final folder = p.join(source, 'sessions-v2');
    Future<List<String>> blob(String text) async {
      final bytes = utf8.encode(text);
      final oid = sha1.convert(bytes).toString();
      final file = File(p.join(folder, 'blobs', oid));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(zlib.encode(bytes));
      return ['100644', oid];
    }

    final base = await blob('before\n');
    final after = await blob('after\n');
    await File(p.join(root, 'file.txt')).writeAsString('after\n');
    final metadata = File(p.join(folder, 'review.json'));
    await metadata.writeAsString(
      jsonEncode({
        'version': 2,
        'entries': {
          'file.txt': {'base': base, 'after': after, 'current': after},
        },
        'unseen': [],
      }),
    );
    return metadata;
  }

  test('open preserves a direct legacy session named sessions-v2', () async {
    final initial = (await GitReviewStore.open(
      root,
      checkpoints: checkpoints,
    ))!;
    final source = initial.gitDir;
    await Directory(source).delete(recursive: true);
    final metadata = await seed(source);
    final original = await metadata.readAsString();

    final store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    final review = await ChangeReview.resume(store, 'sessions-v2');
    addTearDown(review.dispose);
    expect(review.failure, isNull);
    expect(review.changes, hasLength(1));
    expect(await review.original(p.join(root, 'file.txt'))!(), 'before\n');
    expect(await metadata.readAsString(), original);
    await review.undoAll();
    expect(await File(p.join(root, 'file.txt')).readAsString(), 'before\n');
  });

  test('tidy preserves an unopened direct session named sessions-v2', () async {
    final metadata = await seed(p.join(checkpoints, 'unopened-legacy'));
    final original = await metadata.readAsString();
    await GitReviewStore.tidy(
      checkpoints,
      every: Duration.zero,
      now: DateTime.now().add(const Duration(days: 365)),
    );
    expect(await metadata.readAsString(), original);
    expect(await metadata.parent.list().isEmpty, isFalse);
  });
}

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show GitReviewStore;
import 'package:bao_remote/protocol.dart' show RpcError;
import 'package:bao_remote/review.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  late Directory temp;
  late String root;
  late String checkpoints;
  late String source;
  RemoteHarness? harness;

  void write(String name, String text) {
    final file = File(p.join(root, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  Future<String> git(String folder, List<String> arguments) async {
    final result = await Process.run('git', [
      '--git-dir=$folder',
      ...arguments,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return '${result.stdout}'.trim();
  }

  Future<ReviewBlob> blob(
    String sessionFolder,
    String text, {
    String mode = '100644',
  }) async {
    final bytes = utf8.encode(text);
    final oid = sha1.convert(bytes).toString();
    final file = File(p.join(sessionFolder, 'blobs', oid));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(zlib.encode(bytes));
    return ReviewBlob(mode, oid);
  }

  Future<({String folder, ReviewBlob base, ReviewBlob after})> seed(
    String session, {
    bool nested = false,
  }) async {
    final folder = p.joinAll([source, if (nested) 'sessions-v2', session]);
    final base = await blob(folder, 'before\n', mode: '100755');
    final after = await blob(folder, 'after\n', mode: '100755');
    final deleted = await blob(folder, 'deleted\n');
    final added = await blob(folder, 'created\n');
    final unrelated = ReviewBlob(
      '100644',
      sha1.convert(utf8.encode('unrelated\n')).toString(),
    );
    Map<String, Object?> entry(ReviewBlob? base, ReviewBlob? after) => {
      'base': base?.toJson(),
      'after': after?.toJson(),
      'current': after?.toJson(),
    };
    await File(p.join(folder, 'review.json')).writeAsString(
      jsonEncode({
        'version': 2,
        'entries': {
          'edit.txt': entry(base, after),
          'new.txt': entry(null, added),
          'deleted.txt': entry(deleted, null),
          // Its missing blob must not be read or imported: nothing is pending.
          'unrelated.txt': entry(unrelated, unrelated),
        },
        'unseen': [
          {'path': p.join(root, 'unknown.txt'), 'added': 2, 'removed': 1},
        ],
      }),
    );
    write('edit.txt', 'after\n');
    write('new.txt', 'created\n');
    write('unknown.txt', 'untracked edit\n');
    return (folder: folder, base: base, after: after);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('git-review-compat-');
    root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
    checkpoints = p.join(temp.path, 'checkpoints');
  });

  tearDown(() async {
    await harness?.close();
    harness = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  for (final remote in [false, true]) {
    group(remote ? 'remote v2 migration' : 'local v2 migration', () {
      setUp(() async {
        if (remote) {
          harness = await RemoteHarness.start();
          checkpoints = p.join(harness!.dataDir.path, 'checkpoints');
        }
        final initial = (await GitReviewStore.open(
          root,
          checkpoints: checkpoints,
        ))!;
        source = initial.gitDir;
        await Directory(source).delete(recursive: true);
      });

      Future<ReviewStore> open() async => remote
          ? (await harness!.client.openReview(root))!
          : (await GitReviewStore.open(root, checkpoints: checkpoints))!;

      test('imports only pending blobs, preserves source and modes, and Undo works', () async {
        final old = await seed('s');
        final original = await File(p.join(old.folder, 'review.json'))
            .readAsBytes();
        await GitReviewStore.tidy(
          checkpoints,
          every: Duration.zero,
          now: DateTime.now().add(const Duration(days: 365)),
        );
        final store = await open();
        final review = await ChangeReview.resume(store, 's');
        addTearDown(review.dispose);
        expect(review.failure, isNull);
        expect(review.changes, hasLength(4));
        final data = jsonDecode((await store.load('s'))!) as Map;
        expect(data['version'], 3);
        expect(data.containsKey('snapshot'), isFalse);
        final base = ReviewBlob.fromJson(data['entries']['edit.txt']['base'])!;
        expect(base.mode, '100755');
        expect(base.oid, isNot(old.base.oid));
        expect(utf8.decode(await store.read(base)), 'before\n');
        final objects = await git('$source.v3', [
          'cat-file',
          '--batch-all-objects',
          '--batch-check=%(objecttype) %(objectname)',
        ]);
        expect(
          objects.split('\n').where((line) => line.startsWith('blob ')),
          hasLength(4),
        );
        expect(
          await File(p.join(old.folder, 'review.json')).readAsBytes(),
          original,
        );
        await review.undoAll();
        expect(File(p.join(root, 'edit.txt')).readAsStringSync(), 'before\n');
        expect(
          File(p.join(root, 'deleted.txt')).readAsStringSync(),
          'deleted\n',
        );
        expect(File(p.join(root, 'new.txt')).existsSync(), isFalse);
        await review.keepAll();
        expect(await (await open()).load('s'), isNull);
        expect(File(p.join(source, '.migrated-v3-s')).existsSync(), isTrue);
      });

      test(
        'a failed import preserves metadata and blobs and can be retried',
        () async {
          final old = await seed('s');
          final file = File(p.join(old.folder, 'blobs', old.after.oid));
          final bytes = await file.readAsBytes();
          await file.delete();
          final store = await open();
          await expectLater(store.load('s'), throwsA(isA<ReviewUnavailable>()));
          expect(File(p.join(source, '.migrated-v3-s')).existsSync(), isFalse);
          await GitReviewStore.tidy(
            checkpoints,
            every: Duration.zero,
            now: DateTime.now().add(const Duration(days: 365)),
          );
          expect(File(p.join(old.folder, 'review.json')).existsSync(), isTrue);
          await file.writeAsBytes(bytes);
          final review = await ChangeReview.resume(await open(), 's');
          addTearDown(review.dispose);
          expect(review.failure, isNull);
          expect(
            await review.original(p.join(root, 'edit.txt'))!(),
            'before\n',
          );
        },
      );

      test(
        'source tombstones prevent revival after the new repository is removed',
        () async {
          await seed('s');
          final store = await open();
          expect(await store.load('s'), isNotNull);
          await store.forget('s');
          await Directory('$source.v3').delete(recursive: true);
          expect(await (await open()).load('s'), isNull);
        },
      );

      test(
        'unsafe v2 changes stay protected after import and resume',
        () async {
          final old = await seed('s');
          final metadata = File(p.join(old.folder, 'review.json'));
          final data = jsonDecode(await metadata.readAsString()) as Map;
          data['entries']['edit.txt']['unsafe'] = true;
          data['entries']['edit.txt']['conflict'] = true;
          await metadata.writeAsString(jsonEncode(data));
          final store = await open();
          final review = await ChangeReview.resume(store, 's');
          addTearDown(review.dispose);
          await review.undoAll();
          expect(File(p.join(root, 'edit.txt')).readAsStringSync(), 'after\n');
          final resumed = await ChangeReview.resume(await open(), 's');
          addTearDown(resumed.dispose);
          await resumed.undoAll();
          expect(File(p.join(root, 'edit.txt')).readAsStringSync(), 'after\n');
          expect(
            resumed.changes
                .singleWhere((change) => change.path.endsWith('edit.txt'))
                .conflict,
            isTrue,
          );
        },
      );

      test('simultaneous stores publish one complete migration', () async {
        final old = await seed('s');
        final stores = await Future.wait([open(), open()]);
        final results = await Future.wait([
          for (final store in stores) store.load('s'),
        ]);
        expect(results.first, isNotNull);
        expect(results.last, results.first);
        final data = jsonDecode(results.first!) as Map;
        final base = ReviewBlob.fromJson(data['entries']['edit.txt']['base'])!;
        expect(utf8.decode(await stores.last.read(base)), 'before\n');
        expect(
          File(p.join(old.folder, 'blobs', old.after.oid)).existsSync(),
          isTrue,
        );
        await stores.first.forget('s');
        expect(await stores.last.load('s'), isNull);
      });

      test('v2 inside a v1 repository and its old completion marker still migrates', () async {
        await Directory(source).create(recursive: true);
        await git(source, ['init', '-q', '--bare', '--template=', source]);
        await seed('objects', nested: true);
        await File(p.join(source, '.migrated-objects')).writeAsString('2\n');
        final store = await open();
        final review = await ChangeReview.resume(store, 'objects');
        addTearDown(review.dispose);
        expect(review.failure, isNull);
        expect(await review.original(p.join(root, 'edit.txt'))!(), 'before\n');
        await review.keepAll();
        expect(Directory(p.join(source, 'objects')).existsSync(), isTrue);
        expect(await store.load('objects'), isNull);
      });
    });
  }

  for (final code in Platform.isWindows ? [4] : [23, 24, 13]) {
    test(
      'native filesystem error $code maps retryability through RPC',
      () async {
        final store = (await GitReviewStore.open(
          root,
          checkpoints: checkpoints,
        ))!;
        write('file.txt', 'before\n');
        await store.snapshot();
        Object? failure;
        await IOOverrides.runZoned(
          () async {
            try {
              await store.snapshot();
            } on Object catch (error) {
              failure = error;
            }
          },
          createFile: (path) => throw FileSystemException(
            'injected native failure',
            path,
            OSError('native failure', code),
          ),
        );
        if (code == 13) {
          expect(failure, isA<FileSystemException>());
        } else {
          expect(failure, isA<ReviewUnavailable>());
          final decoded =
              RpcError.fromJson(RpcError.from(failure!).toJson()).toException()
                  as ReviewUnavailable;
          expect(decoded.retryable, isTrue);
        }
        expect(await store.snapshot(), isNotNull);
      },
    );
  }
}

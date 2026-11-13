@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_remote/review.dart' show ReviewUnavailable;
import 'package:bao_remote/src/review/git_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String root;
  late GitReviewStore store;
  final run = GitReviewStore.run;
  final maxBytes = GitReviewStore.maxBytes;
  final maxFiles = GitReviewStore.maxFiles;
  final retryDelay = GitReviewStore.oversizedRetryDelay;

  void write(String path, String text) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('git-review-recovery-');
    root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
    store = (await GitReviewStore.open(
      root,
      checkpoints: p.join(temp.path, 'checkpoints'),
    ))!;
  });

  tearDown(() {
    GitReviewStore.run = run;
    GitReviewStore.maxBytes = maxBytes;
    GitReviewStore.maxFiles = maxFiles;
    GitReviewStore.oversizedRetryDelay = retryDelay;
    temp.deleteSync(recursive: true);
  });

  for (final limit in ['bytes', 'files']) {
    test(
      'recovers from a temporary $limit limit without rescanning during cooldown',
      () async {
        write('kept.txt', 'before\n');
        final before = (await store.snapshot())!;
        write('kept.txt', 'after\n');
        write('generated.txt', 'generated output\n');
        if (limit == 'bytes') {
          GitReviewStore.maxBytes = 10;
        } else {
          GitReviewStore.maxFiles = 1;
        }

        expect(await store.snapshot(), isNull);
        expect(File(p.join(store.gitDir, 'index')).existsSync(), isFalse);
        final runs = GitReviewStore.runs;
        expect(await store.snapshot(), isNull);
        expect(
          GitReviewStore.runs,
          runs,
          reason: 'Do not rescan a huge project on every poll',
        );

        File(p.join(root, 'generated.txt')).deleteSync();
        // Equivalent to the cooldown expiring, without sleeping for a minute.
        GitReviewStore.oversizedRetryDelay = Duration.zero;
        final after = (await store.snapshot())!;
        final changes = await store.diff(before, after);
        expect(changes.map((change) => change.path), ['kept.txt']);
        expect(changes.single.before, isNotNull);
        expect(changes.single.after, isNotNull);
        expect(await store.snapshot(), after);
      },
    );
  }

  test(
    'a project still over the limit is checked again only after cooldown',
    () async {
      write('generated.txt', 'generated output\n');
      GitReviewStore.maxBytes = 1;
      expect(await store.snapshot(), isNull);
      final first = GitReviewStore.runs;
      expect(await store.snapshot(), isNull);
      expect(GitReviewStore.runs, first);
      GitReviewStore.oversizedRetryDelay = Duration.zero;
      expect(await store.snapshot(), isNull);
      expect(GitReviewStore.runs, greaterThan(first));
      GitReviewStore.oversizedRetryDelay = retryDelay;
      final last = GitReviewStore.runs;
      expect(await store.snapshot(), isNull);
      expect(GitReviewStore.runs, last);
    },
  );

  test(
    'a filesystem root remains disabled even when the cooldown expires',
    () async {
      final top = p.rootPrefix(root);
      final wide = (await GitReviewStore.open(
        top,
        checkpoints: p.join(temp.path, 'wide-checkpoints'),
      ))!;
      GitReviewStore.oversizedRetryDelay = Duration.zero;
      final runs = GitReviewStore.runs;
      expect(await wide.snapshot(), isNull);
      expect(await wide.snapshot(), isNull);
      expect(GitReviewStore.runs, runs);
    },
  );

  for (final throwsTimeout in [false, true]) {
    test(
      '${throwsTimeout ? 'a thrown timeout' : 'a timed-out Git exit code'} is retryable and does not poison later commands',
      () async {
        write('file.txt', 'before\n');
        final before = (await store.snapshot())!;
        GitReviewStore.run =
            (
              executable,
              arguments, {
              required workingDirectory,
              environment = const {},
              input,
              required timeout,
            }) async {
              if (throwsTimeout) {
                throw TimeoutException('Git timed out', timeout);
              }
              return (exitCode: -1, stdout: Uint8List(0), stderr: '');
            };
        await expectLater(
          store.take('file.txt'),
          throwsA(
            isA<ReviewUnavailable>().having(
              (error) => error.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
        await expectLater(
          store.contains(before, 'file.txt'),
          throwsA(
            isA<ReviewUnavailable>().having(
              (error) => error.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
        await expectLater(store.snapshot(), throwsA(isA<ReviewUnavailable>()));
        GitReviewStore.run = run;
        write('file.txt', 'after\n');
        expect(await store.take('file.txt'), isNotNull);
        final after = (await store.snapshot())!;
        final changes = await store.diff(before, after);
        expect(changes.map((change) => change.path), ['file.txt']);
      },
    );
  }

  for (final scenario in ['stale', 'released', 'reacquired', 'permission']) {
    test('snapshot index lock: $scenario', () async {
      write('file.txt', 'before\n');
      final before = (await store.snapshot())!;
      write('file.txt', 'after\n');
      final lock = File(p.join(store.gitDir, 'index.lock'));
      if (scenario != 'permission') {
        lock.writeAsStringSync('old writer');
        if (scenario != 'released') {
          lock.setLastModifiedSync(
            DateTime.now().subtract(const Duration(minutes: 6)),
          );
        }
      }
      var adds = 0;
      GitReviewStore.run =
          (
            executable,
            arguments, {
            required workingDirectory,
            environment = const {},
            input,
            required timeout,
          }) async {
            if (arguments.contains('add')) {
              expect(environment['LC_ALL'], 'C');
              adds++;
              if (scenario == 'permission') {
                return (
                  exitCode: 128,
                  stdout: Uint8List(0),
                  stderr:
                      "fatal: Unable to create '${lock.path}': Permission denied",
                );
              }
              if (scenario == 'reacquired' && adds == 2) {
                lock.writeAsStringSync('new writer');
              }
            }
            final result = await run(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
              input: input,
              timeout: timeout,
            );
            // Release after Git reports the collision, before _add inspects it.
            if (scenario == 'released' && arguments.contains('add')) {
              lock.deleteSync();
            }
            return result;
          };
      if (scenario == 'stale') {
        expect(await store.snapshot(), isNotNull);
        expect(lock.existsSync(), isFalse);
      } else {
        await expectLater(
          store.snapshot(),
          throwsA(
            scenario == 'permission'
                ? isA<GitReviewError>()
                : isA<ReviewUnavailable>().having(
                    (error) => error.retryable,
                    'retryable',
                    isTrue,
                  ),
          ),
        );
        if (scenario == 'reacquired') {
          expect(lock.readAsStringSync(), 'new writer');
        }
      }
      expect(adds, scenario == 'stale' || scenario == 'reacquired' ? 2 : 1);
      GitReviewStore.run = run;
      if (lock.existsSync()) lock.deleteSync();
      final after = (await store.snapshot())!;
      expect((await store.diff(before, after)).map((change) => change.path), [
        'file.txt',
      ]);
    });
  }

  test(
    'an ordinary Git failure is not silently treated as retryable',
    () async {
      write('file.txt', 'before\n');
      GitReviewStore.run =
          (
            executable,
            arguments, {
            required workingDirectory,
            environment = const {},
            input,
            required timeout,
          }) async => (
            exitCode: 128,
            stdout: Uint8List(0),
            stderr: 'fatal: broken object',
          );
      await expectLater(store.take('file.txt'), throwsA(isA<GitReviewError>()));
    },
  );
}

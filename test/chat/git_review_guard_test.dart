@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/src/review/git_review_store.dart';
import 'package:bao_remote/review.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FailsFirstGuardOpen implements File {
  _FailsFirstGuardOpen(this.file);

  final File file;
  int opens = 0;

  @override
  Directory get parent => file.parent;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    if (++opens == 1) {
      return Future.error(
        FileSystemException(
          'Failed to open guard',
          file.path,
          const OSError('Too many open files', 24),
        ),
      );
    }
    return file.open(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late String root;
  late String checkpoints;
  late GitReviewStore store;
  final run = GitReviewStore.run;
  final owners = <Process>[];

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('git-review-guard-');
    root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
    checkpoints = p.join(temp.path, 'checkpoints');
    File(p.join(root, 'file.txt')).writeAsStringSync('before\n');
    store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
  });

  tearDown(() async {
    GitReviewStore.run = run;
    for (final owner in owners) {
      owner.kill(ProcessSignal.sigkill);
      await owner.exitCode;
    }
    owners.clear();
    temp.deleteSync(recursive: true);
  });

  Future<Process> ownerOf(String gitDir) async {
    final sdkRoot = Platform.environment['FLUTTER_ROOT'];
    final dart = sdkRoot == null
        ? 'dart'
        : p.join(
            sdkRoot,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            Platform.isWindows ? 'dart.exe' : 'dart',
          );
    final owner = await Process.start(dart, [
      p.absolute('test/fixtures/review_guard_owner.dart'),
      '$gitDir.guard',
      p.join(gitDir, 'index.lock'),
    ]);
    owners.add(owner);
    unawaited(owner.stderr.drain<void>());
    final ready = await owner.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    expect(ready, 'locked');
    return owner;
  }

  test('a live guard owner keeps its stale index lock until the OS releases the guard', () async {
    final before = (await store.snapshot())!;
    final owner = await ownerOf(store.gitDir);
    final lock = File(p.join(store.gitDir, 'index.lock'));
    File(p.join(root, 'file.txt')).writeAsStringSync('after\n');
    final runs = GitReviewStore.runs;
    await expectLater(
      store.snapshot().timeout(const Duration(seconds: 2)),
      throwsA(
        isA<ReviewUnavailable>().having(
          (error) => error.retryable,
          'retryable',
          isTrue,
        ),
      ),
    );
    expect(
      GitReviewStore.runs,
      runs,
      reason: 'no Git starts before the guard is held',
    );
    expect(lock.readAsStringSync(), 'owned by another server');
    owner.kill(ProcessSignal.sigkill);
    await owner.exitCode;
    owners.remove(owner);
    final after = (await store.snapshot().timeout(const Duration(seconds: 5)))!;
    expect(lock.existsSync(), isFalse);
    expect(File('${store.gitDir}.guard').existsSync(), isTrue);
    final diff = (await store.snapshotDiff(before, after))!;
    expect(diff.single.path, 'file.txt');
    expect(utf8.decode(await store.read(diff.single.before!)), 'before\n');
    expect(utf8.decode(await store.read(diff.single.after!)), 'after\n');
  });

  test('initial opening retries a busy guard without rewriting repository metadata', () async {
    final info = File(p.join(store.gitDir, 'info', 'exclude'));
    info.writeAsStringSync('owner metadata\n');
    await ownerOf(store.gitDir);
    await expectLater(
      GitReviewStore.open(
        root,
        checkpoints: checkpoints,
      ).timeout(const Duration(seconds: 2)),
      throwsA(
        isA<ReviewUnavailable>().having(
          (error) => error.retryable,
          'retryable',
          isTrue,
        ),
      ),
    );
    expect(info.readAsStringSync(), 'owner metadata\n');
  });

  test('tidy and clear leave a guarded repository untouched', () async {
    await store.snapshot();
    await ownerOf(store.gitDir);
    final commands = <List<String>>[];
    GitReviewStore.run =
        (
          executable,
          arguments, {
          required workingDirectory,
          environment = const {},
          input,
          required timeout,
        }) {
          commands.add(arguments);
          return run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            input: input,
            timeout: timeout,
          );
        };
    await GitReviewStore.tidy(
      checkpoints,
      every: Duration.zero,
    ).timeout(const Duration(seconds: 2));
    await GitReviewStore.clear(checkpoints).timeout(const Duration(seconds: 2));
    expect(commands, isEmpty);
    expect(
      File(p.join(store.gitDir, 'index.lock')).readAsStringSync(),
      'owned by another server',
    );
  });

  for (final operation in ['tidy', 'clear']) {
    test(
      '$operation does not delete an initializing directory owned by another process',
      () async {
        final initializing = Directory(p.join(checkpoints, 'initializing'))
          ..createSync();
        await ownerOf(initializing.path);
        if (operation == 'tidy') {
          await GitReviewStore.tidy(
            checkpoints,
            every: Duration.zero,
          ).timeout(const Duration(seconds: 2));
        } else {
          await GitReviewStore.clear(checkpoints)
              .timeout(const Duration(seconds: 2));
        }
        expect(initializing.existsSync(), isTrue);
        expect(
          File(p.join(initializing.path, 'index.lock')).readAsStringSync(),
          'owned by another server',
        );
      },
    );
  }

  test(
    'guard.open descriptor exhaustion is retryable and the same store recovers',
    () async {
      final before = (await store.snapshot())!;
      File(p.join(root, 'file.txt')).writeAsStringSync('after\n');
      final guard = _FailsFirstGuardOpen(File('${store.gitDir}.guard'));
      final outer = Zone.current;
      await IOOverrides.runZoned(
        () async {
          await expectLater(
            store.snapshot(),
            throwsA(
              isA<ReviewUnavailable>().having(
                (error) => error.retryable,
                'retryable',
                isTrue,
              ),
            ),
          );
          expect(guard.opens, 1);
          final after = (await store.snapshot())!;
          expect(guard.opens, 2);
          final diff = (await store.snapshotDiff(before, after))!;
          expect(diff.single.path, 'file.txt');
          expect(
            utf8.decode(await store.read(diff.single.before!)),
            'before\n',
          );
          expect(utf8.decode(await store.read(diff.single.after!)), 'after\n');
        },
        createFile: (path) =>
            path.endsWith('.guard') ? guard : outer.run(() => File(path)),
      );
    },
    skip: Platform.isWindows,
  );

  test('guard permission failures are not retryable contention', () async {
    if ('${(await Process.run('id', ['-u'])).stdout}'.trim() == '0') {
      markTestSkipped('Root can open a read-only guard for writing.');
      return;
    }
    final guard = File('${store.gitDir}.guard');
    expect((await Process.run('chmod', ['400', guard.path])).exitCode, 0);
    try {
      await expectLater(store.snapshot(), throwsA(isA<FileSystemException>()));
    } finally {
      await Process.run('chmod', ['600', guard.path]);
    }
  }, skip: Platform.isWindows);

  test(
    'guard open failures remain filesystem errors rather than busy errors',
    () async {
      final guard = File('${store.gitDir}.guard');
      if (guard.existsSync()) guard.deleteSync();
      Directory(guard.path).createSync();
      await expectLater(store.snapshot(), throwsA(isA<FileSystemException>()));
    },
  );
}

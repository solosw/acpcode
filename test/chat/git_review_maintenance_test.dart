@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/src/platform/process_isolate.dart';
import 'package:bao_remote/src/review/git_review_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String root;
  late String checkpoints;
  late GitReviewStore store;
  final run = GitReviewStore.run;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('git-maintenance-deadline-');
    root = (Directory(p.join(temp.path, 'project'))..createSync()).path;
    checkpoints = p.join(temp.path, 'checkpoints');
    File(p.join(root, 'file.txt')).writeAsStringSync('before\n');
    store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
  });

  tearDown(() {
    GitReviewStore.run = run;
    temp.deleteSync(recursive: true);
  });

  test(
    'a timed-out collector releases the project queue for the next snapshot',
    () async {
      final before = (await store.snapshot())!;
      final collecting = Completer<void>();
      final release = Completer<void>();
      final pidFile = File(p.join(temp.path, 'collector-pid'));
      GitReviewStore.run =
          (
            executable,
            arguments, {
            required workingDirectory,
            environment = const {},
            input,
            required timeout,
          }) async {
            if (arguments.contains('gc')) {
              expect(timeout, greaterThan(Duration.zero));
              collecting.complete();
              await release.future;
              return runProcess(
                '/bin/sh',
                [
                  '-c',
                  r'''trap '' TERM; echo "$$" > "$1"; exec sleep 30''',
                  'collector',
                  pidFile.path,
                ],
                workingDirectory: workingDirectory,
                timeout: const Duration(milliseconds: 250),
              );
            }
            return run(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
              input: input,
              timeout: timeout,
            );
          };
      final tidying = GitReviewStore.tidy(checkpoints, every: Duration.zero);
      try {
        await collecting.future.timeout(const Duration(seconds: 2));
        File(p.join(root, 'file.txt')).writeAsStringSync('after\n');
        final snapshot = store.snapshot();
        var finished = false;
        unawaited(snapshot.then((_) => finished = true));
        await pumpEventQueue(times: 10);
        expect(
          finished,
          isFalse,
          reason: 'The collector holds the shared project queue',
        );
        release.complete();
        await tidying.timeout(const Duration(seconds: 3));
        final after = (await snapshot.timeout(const Duration(seconds: 3)))!;
        expect((await store.diff(before, after)).map((change) => change.path), [
          'file.txt',
        ]);
        expect(await store.snapshot(), after);
      } finally {
        if (!release.isCompleted) release.complete();
        if (pidFile.existsSync()) {
          Process.killPid(
            int.parse(pidFile.readAsStringSync().trim()),
            ProcessSignal.sigkill,
          );
        }
        await tidying.timeout(const Duration(seconds: 3));
      }
    },
    skip: Platform.isWindows,
  );

  test('real automatic Git GC is foreground and its waiting hook tree is stopped', () async {
    final before = (await store.snapshot())!;
    // Git samples bucket 17 to decide whether loose objects need automatic GC.
    var loose = 0;
    for (var i = 0; loose < 3; i++) {
      final bytes = utf8.encode('automatic-gc-$i');
      final oid = sha1.convert([
        ...utf8.encode('blob ${bytes.length}\x00'),
        ...bytes,
      ]).toString();
      if (!oid.startsWith('17')) continue;
      await store.store(bytes, mode: '100644');
      loose++;
    }
    for (final entry in {
      'gc.auto': '1',
      'gc.autoDetach': 'true',
      'maintenance.autoDetach': 'true',
    }.entries) {
      expect(
        (await Process.run('git', [
          '--git-dir=${store.gitDir}',
          'config',
          entry.key,
          entry.value,
        ])).exitCode,
        0,
      );
    }
    final hookPid = File(p.join(temp.path, 'hook-pid'));
    final leafPid = File(p.join(temp.path, 'gc-leaf-pid'));
    final config = File(p.join(temp.path, 'effective-gc-config'));
    final hook = File(p.join(store.gitDir, 'hooks', 'pre-auto-gc'));
    hook.parent.createSync(recursive: true);
    hook.writeAsStringSync(r'''#!/bin/sh
trap '' TERM
echo "$$" > "$BAOCODE_TEST_GC_HOOK_PID"
git --git-dir="$BAOCODE_TEST_GIT_DIR" config --get gc.autoDetach > "$BAOCODE_TEST_GC_CONFIG"
git --git-dir="$BAOCODE_TEST_GIT_DIR" config --get maintenance.autoDetach >> "$BAOCODE_TEST_GC_CONFIG"
sleep 30 & echo "$!" > "$BAOCODE_TEST_GC_LEAF_PID"
wait
''');
    expect((await Process.run('chmod', ['+x', hook.path])).exitCode, 0);
    addTearDown(() {
      for (final file in [leafPid, hookPid]) {
        if (file.existsSync()) {
          Process.killPid(
            int.parse(file.readAsStringSync().trim()),
            ProcessSignal.sigkill,
          );
        }
      }
    });
    GitReviewStore.run =
        (
          executable,
          arguments, {
          required workingDirectory,
          environment = const {},
          input,
          required timeout,
        }) => run(
          executable,
          [...arguments, if (arguments.contains('gc')) '--auto'],
          workingDirectory: workingDirectory,
          environment: {
            ...environment,
            'BAOCODE_TEST_GIT_DIR': store.gitDir,
            'BAOCODE_TEST_GC_HOOK_PID': hookPid.path,
            'BAOCODE_TEST_GC_LEAF_PID': leafPid.path,
            'BAOCODE_TEST_GC_CONFIG': config.path,
          },
          input: input,
          timeout: arguments.contains('gc')
              ? const Duration(milliseconds: 500)
              : timeout,
        );
    await GitReviewStore.tidy(
      checkpoints,
      every: Duration.zero,
    ).timeout(const Duration(seconds: 3));
    expect(config.readAsStringSync(), 'false\nfalse\n');
    for (final file in [hookPid, leafPid]) {
      final pid = int.parse(file.readAsStringSync().trim());
      final state = (await Process.run('ps', [
        '-o',
        'stat=',
        '-p',
        '$pid',
      ])).stdout.toString().trim();
      expect(
        state.isEmpty || state.startsWith('Z'),
        isTrue,
        reason: 'Git descendant $pid must be stopped',
      );
    }
    GitReviewStore.run = run;
    File(p.join(root, 'file.txt')).writeAsStringSync('after\n');
    final after = (await store.snapshot())!;
    expect((await store.diff(before, after)).map((change) => change.path), [
      'file.txt',
    ]);
  }, skip: Platform.isWindows);

  test(
    'a timed-out latest lookup preserves the nested snapshot indexes',
    () async {
      final nested = Directory(p.join(root, 'nested'))..createSync();
      expect((await Process.run('git', ['init', nested.path])).exitCode, 0);
      final file = File(p.join(nested.path, 'file.txt'))
        ..writeAsStringSync('before\n');
      final before = (await store.snapshot())!;
      final indexes = Directory(p.join(store.gitDir, 'nested'));
      expect(indexes.existsSync(), isTrue);
      var timedOut = false;
      GitReviewStore.run =
          (
            executable,
            arguments, {
            required workingDirectory,
            environment = const {},
            input,
            required timeout,
          }) async {
            if (arguments.contains('rev-parse')) {
              timedOut = true;
              return (exitCode: -1, stdout: utf8.encode(''), stderr: '');
            }
            return run(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
              input: input,
              timeout: timeout,
            );
          };
      await GitReviewStore.tidy(checkpoints, every: Duration.zero);
      expect(timedOut, isTrue);
      expect(indexes.existsSync(), isTrue);
      GitReviewStore.run = run;
      file.writeAsStringSync('after\n');
      final after = (await store.snapshot())!;
      expect((await store.diff(before, after)).map((change) => change.path), [
        'nested/file.txt',
      ]);
    },
  );

  test(
    'maintenance deletes expired refs through the bounded runner with stdin',
    () async {
      final tree = (await store.snapshot())!;
      final old = DateTime.now()
          .subtract(const Duration(days: 60))
          .toIso8601String();
      final committed = await Process.run(
        'git',
        ['--git-dir=${store.gitDir}', 'commit-tree', tree, '-m', 'expired'],
        environment: {
          'GIT_AUTHOR_NAME': 'Test',
          'GIT_AUTHOR_EMAIL': 'test@example.invalid',
          'GIT_AUTHOR_DATE': old,
          'GIT_COMMITTER_NAME': 'Test',
          'GIT_COMMITTER_EMAIL': 'test@example.invalid',
          'GIT_COMMITTER_DATE': old,
        },
      );
      expect(committed.exitCode, 0);
      const ref = 'refs/baocode/sessions/expired';
      expect(
        (await Process.run('git', [
          '--git-dir=${store.gitDir}',
          'update-ref',
          ref,
          '${committed.stdout}'.trim(),
        ])).exitCode,
        0,
      );
      var boundedDeletion = false;
      GitReviewStore.run =
          (
            executable,
            arguments, {
            required workingDirectory,
            environment = const {},
            input,
            required timeout,
          }) async {
            if (arguments.contains('update-ref')) {
              boundedDeletion = true;
              expect(utf8.decode(input!), 'delete $ref\n');
              expect(timeout, greaterThan(Duration.zero));
            }
            return run(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
              input: input,
              timeout: timeout,
            );
          };
      await GitReviewStore.tidy(checkpoints, every: Duration.zero);
      expect(boundedDeletion, isTrue);
      expect(
        (await Process.run('git', [
          '--git-dir=${store.gitDir}',
          'show-ref',
          '--verify',
          '--quiet',
          ref,
        ])).exitCode,
        1,
      );
      expect(await store.snapshot(), tree);
    },
  );
}

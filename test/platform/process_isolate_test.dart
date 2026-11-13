@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/src/platform/process_isolate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('process deadline', () {
    late Directory temp;
    late File pidFile;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('process-deadline-');
      pidFile = File(p.join(temp.path, 'pid'));
    });

    tearDown(() {
      if (pidFile.existsSync()) {
        Process.killPid(
          int.parse(pidFile.readAsStringSync().trim()),
          ProcessSignal.sigkill,
        );
      }
      temp.deleteSync(recursive: true);
    });

    test('kills a child that ignores TERM and finishes its output', () async {
      final result = runProcess(
        '/bin/sh',
        [
          '-c',
          r'''trap '' TERM; echo "$$" > "$1"; printf ready; exec sleep 30''',
          'deadline',
          pidFile.path,
        ],
        workingDirectory: temp.path,
        timeout: const Duration(milliseconds: 250),
      );
      final ran = await result.timeout(const Duration(seconds: 2));
      expect(ran.exitCode, -1);
      expect(utf8.decode(ran.stdout), 'ready');
      final child = int.parse(pidFile.readAsStringSync().trim());
      expect(
        (await Process.run('/bin/kill', ['-0', '$child'])).exitCode,
        isNot(0),
      );
    });

    test(
      'finishes when an exited child leaves descendants holding its pipes',
      () async {
        final ran = await runProcess(
          '/bin/sh',
          [
            '-c',
            r'''sleep 30 & echo "$!" > "$1"; printf ready''',
            'deadline',
            pidFile.path,
          ],
          workingDirectory: temp.path,
          timeout: const Duration(milliseconds: 250),
        ).timeout(const Duration(seconds: 2));
        expect(ran.exitCode, -1);
        expect(utf8.decode(ran.stdout), 'ready');
        final orphan = int.parse(pidFile.readAsStringSync().trim());
        expect(
          (await Process.run('/bin/kill', ['-0', '$orphan'])).exitCode,
          0,
          reason: 'An exited parent no longer proves ownership of an orphan',
        );
      },
    );

    test(
      'kills waiting descendants before releasing the process deadline',
      () async {
        final childPid = File(p.join(temp.path, 'child-pid'));
        final leafPid = File(p.join(temp.path, 'leaf-pid'));
        final unrelated = await Process.start('/bin/sleep', ['30']);
        var unrelatedExited = false;
        unawaited(unrelated.exitCode.then((_) => unrelatedExited = true));
        addTearDown(() async {
          for (final file in [leafPid, childPid]) {
            if (file.existsSync()) {
              Process.killPid(
                int.parse(file.readAsStringSync().trim()),
                ProcessSignal.sigkill,
              );
            }
          }
          unrelated.kill(ProcessSignal.sigkill);
          await unrelated.exitCode;
        });
        final ran = await runProcess(
          '/bin/sh',
          [
            '-c',
            r'''trap '' TERM; echo "$$" > "$1"; /bin/sh -c 'trap "" TERM; echo "$$" > "$1"; sleep 30 & echo "$!" > "$2"; wait' tree "$2" "$3" & wait''',
            'deadline',
            pidFile.path,
            childPid.path,
            leafPid.path,
          ],
          workingDirectory: temp.path,
          timeout: const Duration(milliseconds: 400),
        ).timeout(const Duration(seconds: 3));
        expect(ran.exitCode, -1);
        for (final file in [pidFile, childPid, leafPid]) {
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
            reason: 'The owned process $pid must no longer be running',
          );
        }
        expect(
          unrelatedExited,
          isFalse,
          reason: 'A process outside this tree is untouched',
        );
      },
    );

    test('keeps normal input, output and exit status', () async {
      final ran = await runProcess(
        '/bin/sh',
        ['-c', 'cat; printf diagnostic >&2; exit 7'],
        workingDirectory: temp.path,
        input: utf8.encode('input\n'),
        timeout: const Duration(seconds: 2),
      );
      expect(ran.exitCode, 7);
      expect(utf8.decode(ran.stdout), 'input\n');
      expect(ran.stderr, 'diagnostic');
    });
  }, skip: Platform.isWindows);
}

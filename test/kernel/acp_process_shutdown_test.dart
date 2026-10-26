import 'dart:async';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/kernel/acp/acp_process_shutdown.dart';
import 'package:baocode/kernel/acp/acp_transport.dart';
import 'package:baocode/kernel/acp/acp_transport_io.dart';
import 'package:baocode/remote/remote_acp.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/lsp/fake_lsp.dart' show dartExecutable;

class _Process implements RemoteProcess {
  _Process({this.failStdin = false});
  final bool failStdin;
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final exited = Completer<int>();
  final kills = <bool>[];
  @override
  int get pid => 1;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  void write(List<int> bytes) {}
  @override
  Future<void> closeStdin() {
    if (failStdin) throw StateError('stdin closed');
    return Future.value();
  }

  @override
  void kill({bool force = false}) => kills.add(force);
}

void main() {
  const short = Duration(milliseconds: 10);

  test('shutdown waits for graceful process exit', () async {
    final exit = Completer<int>();
    final kills = <bool>[];
    var stopped = false;
    final closing = stopAcpProcess(
      exitCode: exit.future,
      kill: kills.add,
      grace: const Duration(seconds: 1),
    ).then((_) => stopped = true);
    await pumpEventQueue();
    expect(kills, [false]);
    expect(stopped, isFalse);
    exit.complete(0);
    await closing;
  });

  test('grace timeout escalates then waits for forced exit', () async {
    final exit = Completer<int>();
    final kills = <bool>[];
    final forced = Completer<void>();
    var stopped = false;
    final closing = stopAcpProcess(
      exitCode: exit.future,
      grace: short,
      forceWait: const Duration(seconds: 1),
      kill: (force) {
        kills.add(force);
        if (force) forced.complete();
      },
    ).then((_) => stopped = true);
    await forced.future;
    expect(kills, [false, true]);
    expect(stopped, isFalse);
    exit.complete(-9);
    await closing;
  });

  test('final timeout fails rather than claiming a successful exit', () async {
    final kills = <bool>[];
    await expectLater(
      stopAcpProcess(
        exitCode: Completer<int>().future,
        kill: kills.add,
        grace: short,
        forceWait: short,
      ),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          contains('forced termination'),
        ),
      ),
    );
    expect(kills, [false, true]);
  });

  for (final failStdin in [false, true]) {
    test(
      'remote close awaits exit and is idempotent (stdin throws: $failStdin)',
      () async {
        final process = _Process(failStdin: failStdin);
        final transport = RemoteAcpTransport.forProcess(process);
        var outCancelled = false;
        var errCancelled = false;
        process.out.onCancel = () => outCancelled = true;
        process.err.onCancel = () => errCancelled = true;
        final closing = transport.close();
        expect(identical(closing, transport.close()), isTrue);
        var stopped = false;
        final waiting = closing.then((_) => stopped = true);
        await pumpEventQueue();
        expect(process.kills, [false]);
        expect(stopped, isFalse);
        process.exited.complete(0);
        await waiting;
        expect(outCancelled, isTrue);
        expect(errCancelled, isTrue);
        await process.out.close();
        await process.err.close();
      },
    );
  }

  test(
    'queued transport propagates close failure and cancels subscriptions',
    () async {
      final process = _Process();
      final transport = QueuedAcpTransport(
        RemoteAcpTransport.forProcess(process),
      );
      var cancelled = false;
      process.out.onCancel = () => cancelled = true;
      final closing = transport.close();
      final check = expectLater(closing, throwsStateError);
      process.exited.completeError(StateError('connection lost'));
      await check;
      expect(cancelled, isTrue);
      expect(identical(closing, transport.close()), isTrue);
      await process.out.close();
      await process.err.close();
    },
  );

  for (final ignoreTerm in [false, true]) {
    test(
      'local close waits for managed process (ignore SIGTERM: $ignoreTerm)',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'baocode-acp-shutdown-',
        );
        final marker = File('${dir.path}/stopped');
        final script = File('${dir.path}/agent.dart')
          ..writeAsStringSync(r"""
import 'dart:async';
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  ProcessSignal.sigterm.watch().listen((_) {
    if (args[1] == 'true') return;
    Timer(const Duration(milliseconds: 100), () {
      File(args[0]).writeAsStringSync('exiting');
      exit(0);
    });
  });
  stdout.writeln(jsonEncode({'ready': true, 'pid': pid}));
}
""");
        StdioAcpTransport? transport;
        var childPid = 0;
        try {
          transport = await StdioAcpTransport.start(
            dartExecutable,
            arguments: [script.path, marker.path, '$ignoreTerm'],
          );
          final ready = await transport.messages.first.timeout(
            const Duration(seconds: 10),
          );
          childPid = ready['pid'] as int;
          final closing = transport.close();
          expect(identical(closing, transport.close()), isTrue);
          await closing.timeout(const Duration(seconds: 6));
          childPid = 0;
          expect(marker.existsSync(), !ignoreTerm);
        } finally {
          if (childPid != 0) Process.killPid(childPid, ProcessSignal.sigkill);
          await transport?.close();
          dir.deleteSync(recursive: true);
        }
      },
      skip: Platform.isWindows,
    );
  }
}

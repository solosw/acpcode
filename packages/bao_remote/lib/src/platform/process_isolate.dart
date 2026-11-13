import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Runs [body], which starts processes, on an isolate of its own, for what
/// it returns or throws (both sent back, so to be sent). A process is
/// started by forking this one, which holds up the isolate that asks for
/// milliseconds each time: in the app, the one the UI is drawn on, and Git
/// is started dozens of times a minute (the checkpoints, the IDE's status,
/// each folder of a workspace). Where no isolate starts, [body] runs here.
Future<T> onProcessIsolate<T>(Future<T> Function() body) async {
  final starter = await _Starter.shared;
  if (starter == null) return body();
  return await starter.run(body) as T;
}

/// What a process ran to: its exit code, and what it wrote.
typedef ProcessRun = ({int exitCode, Uint8List stdout, String stderr});

/// Runs [executable] to its end on the isolate of [onProcessIsolate].
/// [timeout] bounds startup, exit and output collection: past it the child
/// is killed and its pipes closed (exit code -1). Throws a [ProcessException]
/// where it cannot be started.
Future<ProcessRun> runProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Map<String, String> environment = const {},
  List<int>? input,
  required Duration timeout,
}) {
  final bytes = input == null
      ? null
      : TransferableTypedData.fromList([
          input is Uint8List ? input : Uint8List.fromList(input),
        ]);
  return onProcessIsolate(() async {
    final ran = await _run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      input: bytes?.materialize().asUint8List(),
      timeout: timeout,
    );
    return _Sent(
      ran.exitCode,
      TransferableTypedData.fromList([ran.stdout]),
      ran.stderr,
    );
  }).then(
    (sent) => (
      exitCode: sent.exitCode,
      stdout: sent.stdout.materialize().asUint8List(),
      stderr: sent.stderr,
    ),
  );
}

/// A [ProcessRun] on its way, its output not copied.
final class _Sent {
  const _Sent(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final TransferableTypedData stdout;
  final String stderr;
}

Future<ProcessRun> _run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
  required Uint8List? input,
  required Duration timeout,
  bool descendants = true,
}) async {
  final elapsed = Stopwatch()..start();
  final starting = Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final Process process;
  try {
    process = await starting.timeout(timeout);
  } on TimeoutException {
    // A spawn already in progress can still finish after the deadline.
    unawaited(
      starting.then((late) async {
        await _killTimedOut(late, workingDirectory, descendants: descendants);
        unawaited(late.stdin.close().catchError((Object _) {}));
        await Future.wait([
          late.stdout.listen(null).cancel(),
          late.stderr.listen(null).cancel(),
        ]);
      }, onError: (Object _) {}),
    );
    return (exitCode: -1, stdout: Uint8List(0), stderr: '');
  }
  final stdout = BytesBuilder(copy: false);
  final stderr = StringBuffer();
  final out = process.stdout.listen(stdout.add);
  final err = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(stderr.write);
  final reading = Future.wait([out.asFuture<void>(), err.asFuture<void>()]);
  // It may be done before it read it all.
  unawaited(process.stdin.done.catchError((Object _) {}));
  if (input != null) process.stdin.add(input);
  unawaited(process.stdin.close().catchError((Object _) {}));
  var code = -1;
  try {
    // Descendants can keep these pipes open after the child itself exits.
    final finished = Future.wait([process.exitCode, reading]);
    code = (await finished.timeout(timeout - elapsed.elapsed)).first as int;
  } on TimeoutException {
    await _killTimedOut(process, workingDirectory, descendants: descendants);
    // Closing our ends also bounds collection when descendants retain theirs.
    await Future.wait([out.cancel(), err.cancel()]);
    await process.exitCode.timeout(
      const Duration(seconds: 1),
      onTimeout: () => -1,
    );
  }
  return (exitCode: code, stdout: stdout.takeBytes(), stderr: '$stderr');
}

/// Ends a waiting command's descendants while their parentage is still known.
/// An exited parent proves nothing about orphaned pipes: only close our ends.
Future<void> _killTimedOut(
  Process process,
  String directory, {
  required bool descendants,
}) async {
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));
  // Deliver a completion already queued before inspecting numeric PIDs.
  await Future<void>.delayed(Duration.zero);
  if (exited) return;
  try {
    if (!descendants) return;
    if (Platform.isWindows) {
      await _run(
        'taskkill',
        ['/T', '/F', '/PID', '${process.pid}'],
        workingDirectory: directory,
        environment: const {},
        input: null,
        timeout: const Duration(seconds: 1),
        descendants: false,
      );
      return;
    }
    final elapsed = Stopwatch()..start();
    Future<Map<int, ({int parent, String started})>?> inspect(
      List<int>? pids,
    ) async {
      final remaining = const Duration(seconds: 1) - elapsed.elapsed;
      if (remaining <= Duration.zero || exited) return null;
      final result = await _run(
        'ps',
        [
          if (pids == null) '-A' else ...['-p', pids.join(',')],
          '-o',
          'pid=,ppid=,lstart=',
        ],
        workingDirectory: directory,
        environment: const {'LC_ALL': 'C'},
        input: null,
        timeout: remaining < const Duration(milliseconds: 250)
            ? remaining
            : const Duration(milliseconds: 250),
        descendants: false,
      );
      if (result.exitCode != 0) return null;
      final found = <int, ({int parent, String started})>{};
      final row = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.+)$');
      for (final line in LineSplitter.split(
        utf8.decode(result.stdout, allowMalformed: true),
      )) {
        final match = row.firstMatch(line);
        if (match == null) continue;
        found[int.parse(match[1]!)] = (
          parent: int.parse(match[2]!),
          started: match[3]!.trim(),
        );
      }
      return found;
    }

    final before = await inspect(null);
    if (before == null || !before.containsKey(process.pid) || exited) return;
    final branches = <List<int>>[];
    void visit(int parent, List<int> ancestors) {
      for (final entry in before.entries) {
        if (entry.value.parent != parent || ancestors.contains(entry.key)) {
          continue;
        }
        final chain = [entry.key, ...ancestors];
        branches.add(chain);
        visit(entry.key, chain);
      }
    }

    visit(process.pid, [process.pid]);
    for (final chain in branches.reversed) {
      final current = await inspect(chain);
      if (current == null || exited) break;
      // Recheck every ancestor and its start time before using a child PID.
      // Reparented or replaced processes no longer belong to this snapshot.
      if (chain.every((pid) => current[pid] == before[pid])) {
        Process.killPid(chain.first, ProcessSignal.sigkill);
      }
    }
  } on ProcessException {
    // No supported ps/taskkill: still bound the direct child and our pipes.
  } finally {
    if (!exited) process.kill(ProcessSignal.sigkill);
  }
}

/// The isolate the processes are started from.
final class _Starter {
  _Starter._();

  static Future<_Starter?>? _starting;

  /// Null where no isolate starts.
  static Future<_Starter?> get shared => _starting ??= _spawn();

  final _replies = RawReceivePort();
  final _requests = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  int _next = 0;

  static Future<_Starter?> _spawn() async {
    final starter = _Starter._();
    starter._replies
      ..handler = starter._reply
      ..keepIsolateAlive = false;
    try {
      final isolate = await Isolate.spawn(
        _serve,
        starter._replies.sendPort,
        debugName: 'processes',
        errorsAreFatal: false,
      );
      isolate.addOnExitListener(starter._replies.sendPort);
    } on Object {
      starter._replies.close();
      return null;
    }
    return starter;
  }

  Future<Object?> run(Future<Object?> Function() body) async {
    final id = _next++;
    final done = _pending[id] = Completer();
    // Waited for, a process keeps this isolate (a command line's) on.
    _replies.keepIsolateAlive = true;
    try {
      (await _requests.future).send((id, body));
      return await done.future;
    } finally {
      _pending.remove(id);
      _replies.keepIsolateAlive = _pending.isNotEmpty;
    }
  }

  void _reply(Object? message) {
    switch (message) {
      case final SendPort requests:
        _requests.complete(requests);
      case (final int id, true, final Object? value):
        _pending.remove(id)?.complete(value);
      case (final int id, false, final Object error, final String stack):
        _pending.remove(id)?.completeError(error, StackTrace.fromString(stack));
      case null:
        // Gone (it should not be): the next run from another.
        _starting = null;
        _replies.close();
        const gone = ProcessException('', [], 'Not started');
        for (final done in _pending.values) {
          done.completeError(gone);
        }
        if (!_requests.isCompleted) _requests.completeError(gone);
    }
  }
}

void _serve(SendPort replies) {
  final requests = RawReceivePort();
  requests.handler = (Object? message) {
    if (message case (final int id, final Future<Object?> Function() body)) {
      Future.sync(body)
          .then((value) => replies.send((id, true, value)))
          .catchError((Object error, StackTrace stack) {
            try {
              replies.send((id, false, error, '$stack'));
            } on Object {
              // Not to be sent: what it says.
              replies.send((id, false, '$error', '$stack'));
            }
          });
    }
  };
  replies.send(requests.sendPort);
}

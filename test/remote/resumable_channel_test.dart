import 'dart:async';
import 'dart:math';

import 'package:bao_remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two ends of a link in memory: [cut] as a network would (each side's
/// input ends), [silence] as one gone quiet (nothing passes, nothing ends);
/// after [budget] bytes, cut in the middle of what is written.
class MemoryPipe {
  MemoryPipe({this.budget});

  int? budget;
  final _toA = StreamController<List<int>>();
  final _toB = StreamController<List<int>>();
  bool _cut = false;
  bool silent = false;

  late final ChannelLink a = _end(_toA, _toB);
  late final ChannelLink b = _end(_toB, _toA);

  ChannelLink _end(
    StreamController<List<int>> input,
    StreamController<List<int>> output,
  ) => ChannelLink(
    input: input.stream,
    write: (bytes) {
      if (_cut || silent) return;
      if (budget case final left?) {
        if (bytes.length >= left) {
          output.add(bytes.sublist(0, left));
          cut();
          return;
        }
        budget = left - bytes.length;
      }
      output.add(bytes);
    },
    close: cut,
  );

  void cut() {
    if (_cut) return;
    _cut = true;
    unawaited(_toA.close());
    unawaited(_toB.close());
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

Future<void> until(bool Function() condition, {int millis = 5000}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsedMilliseconds > millis) fail('timed out');
    await settle();
  }
}

void main() {
  test('messages go both ways; acknowledged ones are let go', () async {
    final client = ResumableChannel();
    final server = ResumableChannel();
    final atServer = <String>[];
    final atClient = <String>[];
    server.messages.listen(atServer.add);
    client.messages.listen(atClient.add);
    final pipe = MemoryPipe();
    unawaited(client.attach(pipe.a));
    unawaited(server.attach(pipe.b));
    await until(() => client.linked && server.linked);
    for (var i = 0; i < 200; i++) {
      client.send('{"n":$i}');
    }
    server.send('hello');
    await until(() => atServer.length == 200 && atClient.length == 1);
    expect(atServer.first, '{"n":0}');
    expect(atServer.last, '{"n":199}');
    expect(atClient, ['hello']);
    client.close();
    server.close();
  });

  test('a cut link: what was not had is sent again over the next, once, in '
      'order; a line cut short is not taken for a message', () async {
    final client = ResumableChannel();
    final server = ResumableChannel();
    final atServer = <String>[];
    server.messages.listen(atServer.add);
    // Cut in the middle of the third message: past both handshakes
    // (`H0`) and two messages (`:message-n`).
    final first = MemoryPipe(budget: 2 * 3 + 2 * 11 + 6);
    unawaited(client.attach(first.a));
    unawaited(server.attach(first.b));
    await until(() => client.linked);
    for (var i = 0; i < 5; i++) {
      client.send('message-$i');
    }
    await until(() => !client.linked && !server.linked);
    expect(atServer, ['message-0', 'message-1']);
    // Sent while unlinked: kept.
    client.send('message-5');
    final second = MemoryPipe();
    unawaited(client.attach(second.a));
    unawaited(server.attach(second.b));
    await until(() => atServer.length == 6);
    expect(atServer, [for (var i = 0; i < 6; i++) 'message-$i']);
    client.close();
    server.close();
  });

  test('cut again and again under load: everything, once, in order, both '
      'ways', () async {
    final random = Random(7);
    final client = ResumableChannel();
    final server = ResumableChannel();
    final atServer = <String>[];
    final atClient = <String>[];
    server.messages.listen(atServer.add);
    client.messages.listen(atClient.add);
    const total = 3000;
    var sentUp = 0;
    var sentDown = 0;
    while (atServer.length < total || atClient.length < total) {
      final pipe = MemoryPipe(budget: 200 + random.nextInt(4000));
      unawaited(client.attach(pipe.a));
      unawaited(server.attach(pipe.b));
      for (var i = 0; i < 40; i++) {
        if (sentUp < total) {
          client.send('up ${sentUp++} ${'x' * random.nextInt(80)}');
        }
        if (sentDown < total) {
          server.send('down ${sentDown++} ${'y' * random.nextInt(80)}');
        }
        if (random.nextInt(5) == 0) await settle();
      }
      await settle();
      pipe.cut();
      await settle();
    }
    expect(
      [for (final line in atServer) int.parse(line.split(' ')[1])],
      [for (var i = 0; i < total; i++) i],
    );
    expect(
      [for (final line in atClient) int.parse(line.split(' ')[1])],
      [for (var i = 0; i < total; i++) i],
    );
    client.close();
    server.close();
  });

  test('a link gone silent is dropped; the next one carries on', () async {
    final client = ResumableChannel(
      heartbeat: const Duration(milliseconds: 20),
      silence: const Duration(milliseconds: 150),
    );
    final server = ResumableChannel(
      heartbeat: const Duration(milliseconds: 20),
      silence: const Duration(seconds: 10),
    );
    final atServer = <String>[];
    server.messages.listen(atServer.add);
    final quiet = MemoryPipe();
    final gone = client.attach(quiet.a);
    unawaited(server.attach(quiet.b));
    await until(() => client.linked);
    // Heartbeats keep it up.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(client.linked, isTrue);
    quiet.silent = true;
    client.send('during');
    await gone;
    expect(client.linked, isFalse);
    final next = MemoryPipe();
    unawaited(client.attach(next.a));
    unawaited(server.attach(next.b));
    await until(() => atServer.contains('during'));
    client.close();
    server.close();
  });

  test('patient: not dropped for silence while asking', () async {
    final client = ResumableChannel(
      heartbeat: const Duration(milliseconds: 20),
      silence: const Duration(milliseconds: 100),
    );
    var asking = true;
    final pipe = MemoryPipe();
    var dropped = false;
    unawaited(
      client
          .attach(
            ChannelLink(
              input: pipe.a.input,
              write: pipe.a.write,
              close: pipe.a.close,
              patient: () => asking,
            ),
          )
          .then((_) => dropped = true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(dropped, isFalse);
    asking = false;
    await until(() => dropped);
    client.close();
  });

  test('no session to resume: the channel ends, its peer with it', () async {
    final client = ResumableChannel();
    final peer = RpcPeer(client.messages, client.send);
    final asked = peer.request('fs/list');
    final pipe = MemoryPipe();
    unawaited(client.attach(pipe.a));
    // A shell's startup files may say something first.
    pipe.b.write('Welcome!\n'.codeUnits);
    pipe.b.write('${ResumableChannel.goneLine}\n'.codeUnits);
    expect(await client.ended, ChannelEnd.gone);
    await expectLater(asked, throwsA(isA<RpcClosed>()));
    expect(peer.isClosed, isTrue);
  });

  test('another session (counts that cannot be): ended', () async {
    final client = ResumableChannel();
    client.send('one');
    final pipe = MemoryPipe();
    unawaited(client.attach(pipe.a));
    pipe.b.write('H5\n'.codeUnits);
    expect(await client.ended, ChannelEnd.mismatch);
  });

  test('more kept while unlinked than allowed: ended', () async {
    final client = ResumableChannel(maxUnlinked: 100);
    client.send('x' * 60);
    expect(client.isClosed, isFalse);
    client.send('x' * 60);
    expect(await client.ended, ChannelEnd.overflow);
  });

  test('a request asked before a cut is answered after it', () async {
    final client = ResumableChannel();
    final server = ResumableChannel();
    final asking = RpcPeer(client.messages, client.send);
    final answering = RpcPeer(server.messages, server.send);
    final release = Completer<void>();
    answering.handlers['slow'] = (params, _) async {
      await release.future;
      return 'done';
    };
    final first = MemoryPipe();
    unawaited(client.attach(first.a));
    unawaited(server.attach(first.b));
    final answer = asking.request('slow');
    await until(() => client.linked);
    await settle();
    first.cut();
    release.complete();
    await settle();
    expect(asking.isClosed, isFalse);
    final second = MemoryPipe();
    unawaited(client.attach(second.a));
    unawaited(server.attach(second.b));
    expect(await answer, 'done');
    client.close();
    server.close();
  });
}

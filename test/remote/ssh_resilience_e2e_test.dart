// A bad network between the app and a host, for real: the system's ssh to
// an sshd container (bao-e2e-flaky, tool/ssh_e2e.sh), through a proxy here
// that cuts, silences, refuses and slows the connection (FaultProxy), and
// the container's own netem losing packets. What runs there has to go on,
// and nothing asked or said be lost or come twice.
@Tags(['ssh-e2e'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:baocode/remote/remote_binaries.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fault_proxy.dart';

const _container = 'bao-e2e-flaky';
const _port = 2224;

Future<String> docker(List<String> arguments) async {
  final result = await Process.run('docker', arguments);
  return '${result.stdout}'.trim();
}

/// The session daemons running there.
Future<int> daemons() async {
  final out = await docker([
    'exec',
    _container,
    'sh',
    '-c',
    // [b]: not the shell running it, whose command says it too.
    "pgrep -f '[b]aocode-server --daemon' | wc -l",
  ]);
  return int.tryParse(out) ?? -1;
}

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String? what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(what ?? 'Condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A process there printing 0 to [count] - 1, a line every [pause].
Future<(RemoteProcess, List<String>)> counter(
  RemoteClient client,
  int count, {
  String pause = '0.02',
}) async {
  final process = await client.start('sh', [
    '-c',
    'i=0; while [ \$i -lt $count ]; do echo \$i; i=\$((i+1)); sleep $pause; '
        'done',
  ], login: false);
  final lines = <String>[];
  process.stdout
      .transform(const Utf8Decoder())
      .transform(const LineSplitter())
      .listen(lines.add);
  return (process, lines);
}

void main() {
  final setup = Platform.environment['BAOCODE_SSH_E2E'];
  if (setup == null) {
    test(
      'ssh resilience end to end',
      () {},
      skip: 'BAOCODE_SSH_E2E is not set',
    );
    return;
  }
  final key = p.join(setup, 'testkey');
  final address = Platform.environment['BAOCODE_SSH_E2E_HOST'] ?? '127.0.0.1';
  const timeout = Timeout(Duration(minutes: 3));

  late Directory dir;
  late FaultProxy proxy;
  late SshHost host;
  late List<RemoteClient> reconnected;
  late StreamSubscription<RemoteClient> watching;

  SshLauncher launcher({Duration? grace}) {
    final config = File(p.join(dir.path, 'config'))
      ..writeAsStringSync(
        'Host *\n'
        '  User tester\n'
        '  IdentityFile "$key"\n'
        '  IdentitiesOnly yes\n'
        '  UserKnownHostsFile "${p.join(dir.path, 'known_hosts')}"\n'
        '  GlobalKnownHostsFile /dev/null\n'
        '  StrictHostKeyChecking accept-new\n',
      );
    return SshLauncher(
      ssh: findSsh(Platform.environment)!,
      binaries: bundledServerBinaries()!,
      options: ['-F', config.path, ...SshLauncher.defaultOptions],
      // Quick to notice a silent network, and to try again.
      heartbeat: const Duration(milliseconds: 500),
      silence: const Duration(seconds: 4),
      maxBackoff: const Duration(seconds: 2),
      sessionGrace: grace,
    );
  }

  Future<RemoteClient> open({Duration? grace}) async {
    host = SshHost(
      '$address:${proxy.port}',
      connect: launcher(grace: grace).connect,
    );
    watching = host.reconnected.listen(reconnected.add);
    final client = await host.ready;
    expect(await daemons(), 1);
    return client;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bao-flaky-');
    proxy = await FaultProxy.start(address, _port);
    reconnected = [];
    await docker(['exec', _container, 'pkill', '-f', 'baocode-server']);
    // What an earlier run wrote there.
    await docker([
      'exec',
      _container,
      'rm',
      '-f',
      '/home/tester/weak.bin',
      '/home/tester/lossy.txt',
    ]);
  });

  tearDown(() async {
    await watching.cancel();
    proxy.restore();
    await host.close();
    host.dispose();
    await proxy.close();
    await docker([
      'exec',
      _container,
      'tc',
      'qdisc',
      'del',
      'dev',
      'eth0',
      'root',
    ]);
    await docker(['exec', _container, 'pkill', '-f', 'baocode-server']);
    await docker([
      'exec',
      _container,
      'rm',
      '-rf',
      '/home/tester/.baocode-server/run',
    ]);
    await dir.delete(recursive: true);
  });

  test('cut again and again: the same session each time, a process there '
      'running on, none of its output lost or twice', () async {
    final client = await open();
    final (process, lines) = await counter(client, 300);
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      proxy.cut();
      await until(() => host.state != SshHostState.connected, what: 'lost');
      await until(() => host.state == SshHostState.connected, what: 'back');
    }
    expect(await process.exitCode.timeout(const Duration(seconds: 60)), 0);
    expect(lines, [for (var i = 0; i < 300; i++) '$i']);
    expect(identical(host.client, client), isTrue);
    expect(reconnected, isEmpty);
    expect(proxy.accepted, greaterThanOrEqualTo(5));
    expect(await daemons(), 1);
  }, timeout: timeout);

  test('a network gone silent (nothing sent, nothing reset) is noticed, '
      'and what was asked meanwhile answered once it is back', () async {
    final client = await open();
    final home = client.hello!.home;
    proxy.blackhole();
    final listed = client.list(home, home);
    final noticed = Stopwatch()..start();
    await until(
      () => host.state == SshHostState.reconnecting,
      what: 'silence noticed',
    );
    // 4 seconds of silence, and a heartbeat's.
    expect(noticed.elapsed, lessThan(const Duration(seconds: 8)));
    await Future<void>.delayed(const Duration(seconds: 6));
    proxy.restore();
    expect([
      for (final file in await listed.timeout(const Duration(seconds: 30)))
        file.name,
    ], contains('.baocode-server'));
    await until(() => host.state == SshHostState.connected);
    expect(identical(host.client, client), isTrue);
    expect(reconnected, isEmpty);
  }, timeout: timeout);

  test('down for a while (no connection taken): tried again and again, '
      'then the terminal there carries on', () async {
    final client = await open();
    final pty = await client.startPty(
      cwd: client.hello!.home,
      shell: ['/bin/sh'],
      shellIntegration: false,
    );
    final output = StringBuffer();
    pty.output.listen((data) => output.write(utf8.decode(data)));
    pty.write(utf8.encode('echo before-\$((40+2))\n'));
    await until(() => output.toString().contains('before-42'));

    proxy.refusing = true;
    proxy.cut();
    await until(() => host.state == SshHostState.reconnecting);
    expect(host.retryAt, isNotNull);
    // Typed while down: sent once it is back.
    pty.write(utf8.encode('echo after-\$((50+5))\n'));
    await Future<void>.delayed(const Duration(seconds: 8));
    expect(proxy.refused, greaterThanOrEqualTo(3));
    expect(host.state, SshHostState.reconnecting);

    proxy.restore();
    await until(() => output.toString().contains('after-55'));
    expect(host.state, SshHostState.connected);
    expect(pty.exited, isFalse);
    expect(identical(host.client, client), isTrue);
    expect(reconnected, isEmpty);
    expect(RegExp('after-55').allMatches(output.toString()), hasLength(1));
  }, timeout: timeout);

  // An ssh handshake takes about 8 round trips: some seconds on this one,
  // which has to stay up that long for any to be made.
  test('a weak network (slow, jittery, cut every few seconds): files and '
      'output come whole', () async {
    final client = await open();
    final home = client.hello!.home;
    proxy
      ..latency = const Duration(milliseconds: 80)
      ..jitter = const Duration(milliseconds: 160)
      ..bytesPerSecond = 256 * 1024;
    final random = Random(1);
    var flapping = true;
    unawaited(() async {
      while (flapping) {
        await Future<void>.delayed(
          Duration(milliseconds: 5000 + random.nextInt(3000)),
        );
        if (flapping) proxy.cut();
      }
    }());
    final (process, lines) = await counter(client, 200, pause: '0.05');
    final bytes = Uint8List.fromList(
      List.generate(192 * 1024, (_) => random.nextInt(256)),
    );
    final path = '$home/weak.bin';
    await client.writeBytes(home, path, bytes);
    for (var i = 0; i < 3; i++) {
      expect(await client.readBytes(path), bytes);
      expect([
        for (final file in await client.list(home, home)) file.name,
      ], contains('weak.bin'));
    }
    expect(await process.exitCode.timeout(const Duration(seconds: 90)), 0);
    flapping = false;
    expect(lines, [for (var i = 0; i < 200; i++) '$i']);
    expect(identical(host.client, client), isTrue);
    expect(reconnected, isEmpty);
    expect(proxy.accepted, greaterThan(2));
  }, timeout: timeout);

  test('packets lost and late on the host side (netem), and a cut: all '
      'answered, in order', () async {
    final client = await open();
    final home = client.hello!.home;
    final shaped = await Process.run('docker', [
      'exec',
      _container,
      'tc',
      'qdisc',
      'add',
      'dev',
      'eth0',
      'root',
      'netem',
      'delay',
      '80ms',
      '40ms',
      'loss',
      '10%',
    ]);
    expect(shaped.exitCode, 0, reason: '${shaped.stderr}');
    final (process, lines) = await counter(client, 150, pause: '0.03');
    final path = '$home/lossy.txt';
    final text = List.generate(2000, (i) => 'line $i').join('\n');
    await client.writeBytes(home, path, utf8.encode(text));
    expect(await client.read(home, path), text);
    proxy.cut();
    final edited = text.replaceAll('line', 'row');
    await client.write(home, path, edited);
    await Future<void>.delayed(const Duration(seconds: 1));
    proxy.cut();
    expect(await client.read(home, path), edited);
    expect(await process.exitCode.timeout(const Duration(seconds: 90)), 0);
    expect(lines, [for (var i = 0; i < 150; i++) '$i']);
    expect(reconnected, isEmpty);
  }, timeout: timeout);

  test('the session gone there (its daemon killed): a new one made, and '
      'said so', () async {
    final client = await open();
    final (process, _) = await counter(client, 100000, pause: '1');
    await docker([
      'exec',
      _container,
      'pkill',
      '-f',
      'baocode-server --daemon',
    ]);
    expect(
      await process.exitCode.timeout(const Duration(seconds: 30)),
      RemoteProcess.lostExitCode,
    );
    await until(() => reconnected.isNotEmpty, what: 'a new session');
    await until(() => host.state == SshHostState.connected);
    expect(identical(host.client, client), isFalse);
    expect(
      await host.client!.read(client.hello!.home, '/etc/hostname'),
      isNotEmpty,
    );
    expect(await daemons(), 1);
  }, timeout: timeout);

  test('away longer than the grace: the session ends there, what it ran '
      'with it; a new one once back', () async {
    final client = await open(grace: const Duration(seconds: 3));
    final (process, _) = await counter(client, 100000, pause: '1');
    proxy.refusing = true;
    proxy.cut();
    // The daemon hears the bridge go, waits 3 seconds, ends.
    await Future<void>.delayed(const Duration(seconds: 8));
    expect(await daemons(), 0);
    proxy.restore();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 30)),
      RemoteProcess.lostExitCode,
    );
    await until(() => reconnected.isNotEmpty, what: 'a new session');
    expect(identical(host.client, client), isFalse);
  }, timeout: timeout);

  test('closed: the session ends there, nothing left running', () async {
    await open();
    await host.close();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(await daemons(), 0);
    final sockets = await docker([
      'exec',
      _container,
      'sh',
      '-c',
      'ls /home/tester/.baocode-server/run 2>/dev/null | grep -v log | wc -l',
    ]);
    expect(sockets, '0');
  }, timeout: timeout);
}

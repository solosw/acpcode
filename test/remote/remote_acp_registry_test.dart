@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:baocode/kernel/acp_registry.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:baocode/remote/remote_acp_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

class _Process implements RemoteProcess {
  _Process(this.code);
  final int code;
  @override
  int get pid => 1;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => Stream.value('secret-output'.codeUnits);
  @override
  Future<int> get exitCode async => code;
  @override
  void write(List<int> bytes) {}
  @override
  Future<void> closeStdin() async {}
  @override
  void kill({bool force = false}) {}
}

class _Client extends RemoteClient {
  _Client(RemoteClient original) : super(original.peer) {
    hello = original.hello;
  }
  final calls =
      <({String command, List<String> args, Map<String, String>? env})>[];
  bool failInstall = false;
  bool failForward = false;
  bool missingRuntime = false;
  @override
  Future<RemoteProcess> start(
    String executable,
    List<String> arguments, {
    String? cwd,
    Map<String, String>? environment,
    bool login = true,
  }) async {
    calls.add((command: executable, args: arguments, env: environment));
    if (missingRuntime) throw StateError('Runtime missing');
    return _Process(failInstall && arguments.first != '--version' ? 1 : 0);
  }

  @override
  Future<RemoteForward> forward(
    int localPort, {
    String localHost = '127.0.0.1',
  }) {
    if (failForward) throw StateError('Forwarding unavailable');
    return super.forward(localPort, localHost: localHost);
  }
}

class _Binary extends AcpRegistry {
  final plans = <AcpInstallPlan>[];
  bool missingCommand = false;
  @override
  Future<List<String>> unpackBinary(
    AcpInstallPlan plan,
    Directory directory, {
    Uint8List? bytes,
  }) async {
    plans.add(plan);
    final file = File(
      p.join(directory.path, missingCommand ? 'other' : 'agent'),
    );
    await file.writeAsString('#!/bin/sh\necho remote-binary\n');
    return [file.path];
  }
}

const _entry = AcpRegistryEntry(
  id: 'example',
  name: 'Example',
  description: 'ACP',
  version: '1',
  distribution: {
    'npx': {
      'package': '@example/agent@1.2.3',
      'args': ['--acp'],
    },
  },
);

void main() {
  late RemoteHarness harness;
  late NetworkProxy previous;
  setUp(() async {
    harness = await RemoteHarness.start();
    previous = NetworkProxy.instance;
    NetworkProxy.instance = NetworkProxy(
      system: () async => const ProxyRoute.direct(),
      environment: () async => {},
    );
  });
  tearDown(() async {
    NetworkProxy.instance = previous;
    await harness.close();
  });

  test('npm prepares remotely with temporary proxy, returned launch has no proxy token', () async {
    final client = _Client(harness.client);
    final registry = RemoteAcpRegistry(client);
    final config = await registry.install(_entry);
    expect(client.calls.map((c) => c.command), ['npm', 'node', 'npx', 'npm']);
    final call = client.calls.last;
    expect(call.args, [
      'exec',
      '--yes',
      '--package',
      '@example/agent@1.2.3',
      '--',
      'node',
      '-e',
      'process.exit(0)',
    ]);
    final proxy = Uri.parse(call.env!['HTTPS_PROXY']!);
    expect(proxy.userInfo, startsWith('baocode:'));
    expect(call.env!['ALL_PROXY'], isEmpty);
    expect(call.env!['npm_config_proxy'], proxy.toString());
    expect(config.command, 'npx');
    expect(config.arguments, ['-y', '@example/agent@1.2.3', '--acp']);
    expect(config.environment, isEmpty);
    await expectLater(
      Socket.connect('127.0.0.1', proxy.port),
      throwsA(isA<SocketException>()),
    );
  });

  test('server network mode does not forward or inject local proxy', () async {
    final client = _Client(harness.client)..failForward = true;
    await RemoteAcpRegistry(client, useNetworkSettings: false).install(_entry);
    expect(client.calls.every((c) => c.env == null), isTrue);
    expect(harness.sent.join(), isNot(contains('tcp/listen')));
  });

  test(
    'installation failure cleans tunnel and does not expose script output',
    () async {
      final client = _Client(harness.client)..failInstall = true;
      await expectLater(
        RemoteAcpRegistry(client).install(_entry),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'diagnostic',
            isNot(contains('secret-output')),
          ),
        ),
      );
      final proxy = Uri.parse(client.calls.last.env!['HTTPS_PROXY']!);
      await expectLater(
        Socket.connect('127.0.0.1', proxy.port),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'unavailable tunnel or runtime never proceeds with installation',
    () async {
      final client = _Client(harness.client)..failForward = true;
      await expectLater(
        RemoteAcpRegistry(client).install(_entry),
        throwsStateError,
      );
      expect(client.calls, hasLength(3));
      client.calls.clear();
      client.missingRuntime = true;
      await expectLater(
        RemoteAcpRegistry(client).install(_entry),
        throwsStateError,
      );
      expect(client.calls, hasLength(1));
    },
  );

  test(
    'binary chooses remote architecture, uploads privately, never launches it',
    () async {
      final local = _Binary();
      final registry = RemoteAcpRegistry(harness.client, local: local);
      final entry = AcpRegistryEntry(
        id: 'binary',
        name: 'Binary',
        description: '',
        version: '1',
        distribution: {
          'binary': {
            registry.platform: {
              'archive': 'https://example.com/agent.tgz',
              'cmd': './agent',
            },
          },
        },
      );
      final config = await registry.install(entry);
      expect(local.plans.single.source, 'https://example.com/agent.tgz');
      expect(
        p.isWithin(
          p.join(harness.dataDir.path, 'acp-agents', 'binary'),
          config.command,
        ),
        isTrue,
      );
      expect(
        await File(config.command).readAsString(),
        contains('remote-binary'),
      );
      expect((await File(config.command).stat()).mode & 0x1ff, 0x1c0); // 0700
      expect(
        harness.sent.join(),
        isNot(contains('"executable":"${config.command}"')),
      );
      expect(config.command, isNot(contains('baocode-acp-upload-')));
      local.missingCommand = true;
      final before = Directory(p.dirname(p.dirname(config.command)))
          .listSync()
          .length;
      await expectLater(
        registry.install(entry),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        Directory(p.dirname(p.dirname(config.command))).listSync(),
        hasLength(before),
      );
    },
  );
}

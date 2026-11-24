import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:path/path.dart' as p;

import '../kernel/acp/acp_agent.dart';
import '../kernel/acp_registry.dart';
import '../network/install_proxy_relay.dart';
import '../network/network_proxy.dart';
import 'ssh_host.dart';

/// Both listeners are loopback-only. The remote process gets an ephemeral token,
/// not the upstream proxy's credentials. Closing tears down active sockets too.
class RemoteInstallNetwork {
  RemoteInstallNetwork._(this.relay, this.forward);
  final InstallProxyRelay relay;
  final RemoteForward forward;

  static Future<RemoteInstallNetwork> open(
    RemoteClient client,
    ProxyRoute route,
  ) async {
    final relay = await InstallProxyRelay.open(route);
    try {
      return RemoteInstallNetwork._(relay, await client.forward(relay.port));
    } catch (_) {
      await relay.close();
      rethrow;
    }
  }

  Map<String, String> get environment {
    final url = ProxyServer(
      '127.0.0.1',
      forward.remotePort,
      username: 'baocode',
      password: relay.token,
    ).url;
    return {
      for (final key in ProxyRoute.variables) key: '',
      'HTTP_PROXY': url, 'http_proxy': url,
      'HTTPS_PROXY': url, 'https_proxy': url,
      // All bypass decisions are made on this machine using the same route.
      'npm_config_proxy': url, 'npm_config_https_proxy': url,
      'npm_config_noproxy': '',
    };
  }

  Future<void> close() async {
    await relay.close();
    await forward.close().timeout(const Duration(seconds: 3), onTimeout: () {});
  }
}

/// Installs through the existing remote server; no separate SSH credentials,
/// shell rc changes, sudo, or runtime installation. No local install fallback.
class RemoteAcpRegistry extends AcpRegistry {
  const RemoteAcpRegistry(
    this.client, {
    this.local = const AcpRegistry(),
    this.useNetworkSettings = true,
  });
  final RemoteClient client;
  final AcpRegistry local;
  final bool useNetworkSettings;
  RemoteHello get _hello =>
      client.hello ?? (throw StateError('Remote server is not initialized'));

  static Future<AcpRegistry> connect(
    String host,
    AcpRegistry local,
    bool useNetworkSettings,
  ) async => RemoteAcpRegistry(
    await SshHosts.instance[host].ready,
    local: local,
    useNetworkSettings: useNetworkSettings,
  );

  @override
  String get platform {
    final target = _hello.platform;
    final os = switch (target.os) {
      'darwin' => 'darwin',
      'linux' => 'linux',
      'win' => 'windows',
      _ => 'unsupported',
    };
    final arch = switch (target.arch) {
      'arm64' => 'aarch64',
      'x64' => 'x86_64',
      _ => 'unsupported',
    };
    final suffix = os == 'linux' && target.libc == 'musl' ? '-musl' : '';
    return '$os-$arch$suffix';
  }

  @override
  Future<List<AcpRegistryEntry>> load() => local.load();

  @override
  Future<AcpAgentConfig> install(AcpRegistryEntry entry) async {
    if (platform.contains('unsupported')) {
      throw UnsupportedError('Unsupported remote platform: $platform');
    }
    // Base class validates the id before preparing anything.
    return super.install(entry);
  }

  @override
  Future<void> prepare(String command, List<String> arguments) async {
    // Verify the required runtime before creating the proxy listener.
    await _run(command, const ['--version']);
    if (command == 'npm') {
      await _run('node', const ['--version']);
      await _run('npx', const ['--version']);
    }
    RemoteInstallNetwork? network;
    try {
      if (useNetworkSettings) {
        network = await RemoteInstallNetwork.open(
          client,
          await currentProxyRoute(),
        );
      }
      await _run(command, arguments, environment: network?.environment);
    } finally {
      await network?.close();
    }
  }

  Future<void> _run(
    String command,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final process = await client.start(
      command,
      arguments,
      environment: environment,
      login: true,
    );
    // Do not surface package-manager output: scripts can echo proxy variables.
    // Keep the failure diagnostic useful without leaking even ephemeral tokens.
    final out = process.stdout.listen((_) {});
    final err = process.stderr.listen((_) {});
    try {
      await process.closeStdin().timeout(const Duration(seconds: 15));
      final code = await process.exitCode.timeout(const Duration(minutes: 5));
      if (code != 0) {
        throw StateError(
          'Remote $command exited $code. Check its runtime and network on the selected host.',
        );
      }
    } on TimeoutException {
      process.kill(force: true);
      throw StateError('Remote $command installation timed out');
    } catch (_) {
      process.kill(force: true);
      rethrow;
    } finally {
      await out.cancel();
      await err.cancel();
    }
  }

  // In-flight uploads are shared by connection prefetch and agent launch.
  static final _pending = Expando<Map<String, Future<String>>>();

  Future<void> sync(
    Iterable<AcpAgentConfig> agents,
    String host, {
    required void Function(Object) onError,
  }) async {
    for (final agent in agents) {
      final override = agent.hostConfigurations[host];
      final entry =
          override?.registry ??
          (override == null || override.command.isEmpty
              ? agent.registry
              : null);
      if (entry == null) continue;
      try {
        if (launchPlan(entry) case final plan?) await deploy(entry, plan);
      } on Object catch (error) {
        onError(error);
      }
    }
  }

  @override
  Future<String> deploy(AcpRegistryEntry entry, AcpInstallPlan plan) async {
    final pending = _pending[client] ??= {};
    final key = '${entry.id}/${plan.cacheKey}';
    if (pending[key] case final upload?) return upload;
    final upload = _deploy(entry, plan);
    pending[key] = upload;
    try {
      return await upload;
    } finally {
      pending.remove(key);
    }
  }

  Future<String> _deploy(AcpRegistryEntry entry, AcpInstallPlan plan) async {
    final root = _root(entry);
    final binary = plan.kind == 'binary';
    final cacheKey = binary ? plan.cacheKey : 'runner-${plan.cacheKey}';
    var destination = _paths.join(root, cacheKey);
    for (var attempt = 1; ; attempt++) {
      final ready = binary
          ? _commandAt(destination, plan)
          : _paths.join(destination, AcpRegistry.runnerReady);
      if (await client.stat(ready) == 'file') {
        return binary ? ready : destination;
      }
      if (await client.stat(destination) == null) break;
      // Recover a build partially removed outside BaoCode without deleting it.
      destination = _paths.join(root, '$cacheKey-$attempt');
    }
    if (!binary) {
      final cache = local.cachedRunner(plan);
      if (!await File(p.join(cache.path, AcpRegistry.runnerReady)).exists()) {
        throw StateError(
          'Missing local ACP package. Download it again in Settings → Agents.',
        );
      }
      return _upload(root, plan, destination: destination, runnerCache: cache);
    }
    final cache = local.cachedBinary(plan);
    if (!await cache.exists()) {
      throw StateError(
        'Missing ACP package for $platform. Download it again in Settings → Agents.',
      );
    }
    final bytes = await cache.readAsBytes();
    local.verifyBinary(plan, bytes);
    return _upload(root, plan, bytes: bytes, destination: destination);
  }

  bool get _windows => _hello.platform.os == 'win';
  p.Context get _paths => _windows ? p.windows : p.posix;

  String _root(AcpRegistryEntry entry) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(entry.id)) {
      throw const FormatException('Invalid agent id');
    }
    if (!_paths.isAbsolute(_hello.dataDir)) {
      throw StateError('Remote server has no absolute data directory');
    }
    return _paths.join(_hello.dataDir, 'acp-agents', entry.id);
  }

  String _commandAt(String directory, AcpInstallPlan plan) =>
      plan.commandIn(directory, _paths);

  @override
  Future<String> installBinary(AcpRegistryEntry entry, AcpInstallPlan plan) =>
      _upload(_root(entry), plan);

  Future<void> _mkdir(String path) async {
    if (await client.stat(path) == 'directory') return;
    try {
      await client.create(_hello.dataDir, path, directory: true);
    } catch (_) {
      if (await client.stat(path) != 'directory') rethrow;
    }
  }

  Stream<FileSystemEntity> _packageFiles(FileSystemEntity entity) async* {
    yield entity;
    if (entity is Directory) {
      yield* entity.list(recursive: true, followLinks: false);
    }
  }

  Future<String> _upload(
    String root,
    AcpInstallPlan plan, {
    Uint8List? bytes,
    String? destination,
    Directory? runnerCache,
  }) async {
    // Inspect and unpack on the client; never execute a foreign build here.
    final staging =
        runnerCache ??
        await Directory.systemTemp.createTemp('baocode-acp-upload-');
    final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
    final temporary = _paths.join(root, 'install-$nonce');
    final dataDir = _hello.dataDir;
    var cleanup = false;
    try {
      final executablePaths = <String>{};
      if (runnerCache == null) {
        final executables = await local.unpackBinary(
          plan,
          staging,
          bytes: bytes,
        );
        final command = plan.commandIn(staging.path, p.context);
        final resolved = await File(command).resolveSymbolicLinks();
        if (!p.isWithin(await staging.resolveSymbolicLinks(), resolved) ||
            !await File(command).exists()) {
          throw const FormatException('Invalid agent executable');
        }
        executablePaths.addAll([
          ...executables,
          p.normalize(command),
          resolved,
        ]);
      }
      await _mkdir(_paths.dirname(root));
      await _mkdir(root);
      await client.create(dataDir, temporary, directory: true);
      cleanup = true;
      if (!_windows) await _run('chmod', ['700', temporary]);
      final directories = <String>{temporary};
      Future<void> ensureParent(String path) async {
        if (directories.contains(path)) return;
        await ensureParent(_paths.dirname(path));
        await _mkdir(path);
        directories.add(path);
      }

      final contents = staging.list(followLinks: false);
      await for (final rootEntity in contents) {
        final name = p.basename(rootEntity.path);
        // Runner environments and interpreter paths are specific to this machine.
        if (runnerCache != null &&
            (plan.kind == 'npx' &&
                    name != '_cacache' &&
                    name != AcpRegistry.runnerReady ||
                name.startsWith('environments-') ||
                name.startsWith('interpreter-'))) {
          continue;
        }
        final entities = _packageFiles(rootEntity);
        await for (final entity in entities) {
          final relative = p.split(p.relative(entity.path, from: staging.path));
          if (_windows &&
              relative.any(
                (part) =>
                    part.contains('\\') ||
                    part.contains(':') ||
                    part.endsWith('.') ||
                    part.endsWith(' '),
              )) {
            throw const FormatException('Invalid Windows archive path');
          }
          final target = _paths.joinAll([temporary, ...relative]);
          if (!_paths.isWithin(temporary, target)) {
            throw const FormatException('Archive file escapes installation');
          }
          if (entity is Directory) {
            await ensureParent(target);
          } else if (entity is Link) {
            final link = (await entity.target()).replaceAll('\\', '/');
            if (_windows ||
                p.posix.isAbsolute(link) ||
                !p.posix.isWithin(
                  temporary,
                  p.posix.normalize(
                    p.posix.join(p.posix.dirname(target), link),
                  ),
                )) {
              throw const FormatException('Unsupported link in agent archive');
            }
            await ensureParent(_paths.dirname(target));
            await _run('ln', ['-s', '--', link, target]);
          } else if (entity is File) {
            await ensureParent(_paths.dirname(target));
            // Offset-checked chunks keep the RPC bounded on all platforms.
            await client.writeBytes(dataDir, target, const []);
            final file = await entity.open();
            try {
              var offset = 0;
              while (true) {
                final chunk = await file.read(1 << 20);
                if (chunk.isEmpty) break;
                await client.appendBytes(dataDir, target, offset, chunk);
                offset += chunk.length;
              }
            } finally {
              await file.close();
            }
            if (!_windows && executablePaths.contains(entity.path)) {
              await _run('chmod', ['700', target]);
            }
          }
        }
      }
      final commandAtStage = _commandAt(temporary, plan);
      if (!_windows && runnerCache == null) {
        await _run('chmod', ['700', commandAtStage]);
      }
      if (destination == null) {
        cleanup = false;
        return commandAtStage;
      }
      final ready = runnerCache == null
          ? _commandAt(destination, plan)
          : _paths.join(destination, AcpRegistry.runnerReady);
      // Publish only a complete directory. A concurrent app may have won.
      try {
        await client.rename(dataDir, temporary, destination);
        cleanup = false;
      } catch (_) {
        if (await client.stat(ready) != 'file') rethrow;
      }
      return runnerCache == null ? ready : destination;
    } finally {
      if (cleanup) {
        try {
          await client.delete(dataDir, temporary);
        } on Object {
          // The connection may have closed during transfer.
        }
      }
      if (runnerCache == null) await staging.delete(recursive: true);
    }
  }
}

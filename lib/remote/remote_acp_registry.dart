import 'dart:async';
import 'dart:io';

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
      _ => 'unsupported',
    };
    final arch = switch (target.arch) {
      'arm64' => 'aarch64',
      'x64' => 'x86_64',
      _ => 'unsupported',
    };
    return '$os-$arch';
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

  @override
  Future<String> installBinary(
    AcpRegistryEntry entry,
    AcpInstallPlan plan,
  ) async {
    // Download and inspect locally for the REMOTE architecture. Never execute
    // the remote build here. Upload regular files only, preserving executables.
    final staging = await Directory.systemTemp.createTemp(
      'baocode-acp-upload-',
    );
    String? installed;
    try {
      final executables = await local.unpackBinary(plan, staging);
      final command = p.join(staging.path, plan.command.replaceAll('\\', '/'));
      final resolved = await File(command).resolveSymbolicLinks();
      if (!p.isWithin(await staging.resolveSymbolicLinks(), resolved) ||
          !await File(command).exists()) {
        throw const FormatException('Invalid agent executable');
      }
      final dataDir = _hello.dataDir;
      if (!p.posix.isAbsolute(dataDir)) {
        throw StateError('Remote server has no absolute data directory');
      }
      final root = p.posix.join(dataDir, 'acp-agents', entry.id);
      await _run('mkdir', ['-p', '--', root]);
      // mktemp creates a private unique directory; existing installs stay intact.
      final temp = await client.run('mktemp', [
        '-d',
        p.posix.join(root, 'install-XXXXXXXX'),
      ]);
      if (temp.exitCode != 0) {
        throw StateError('Could not create remote installation directory');
      }
      final destination = temp.stdout.trim();
      if (!p.posix.isWithin(root, destination) ||
          p.posix.dirname(destination) != root) {
        throw StateError('Invalid remote installation directory');
      }
      installed = destination;
      final executablePaths = {...executables, command, resolved};
      await for (final entity in staging.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = p
            .relative(entity.path, from: staging.path)
            .split(p.separator)
            .join('/');
        final target = p.posix.join(destination, relative);
        if (entity is Link) {
          // Registry archives may have internal links. Recreate only checked,
          // relative links within this install; never dereference during upload.
          final link = await entity.target();
          final normalized = link.replaceAll('\\', '/');
          if (p.posix.isAbsolute(normalized) ||
              !p.posix.isWithin(
                destination,
                p.posix.normalize(
                  p.posix.join(p.posix.dirname(target), normalized),
                ),
              )) {
            throw const FormatException('Archive link escapes installation');
          }
          await _run('mkdir', ['-p', '--', p.posix.dirname(target)]);
          await _run('ln', ['-s', '--', normalized, target]);
        } else if (entity is Directory) {
          await _run('mkdir', ['-p', '--', target]);
        } else if (entity is File) {
          await _run('mkdir', ['-p', '--', p.posix.dirname(target)]);
          // File RPC bounds a message's size. Split using the existing streamed
          // process stdin instead of sending a potentially huge JSON message.
          final process = await client.start('sh', [
            '-c',
            r'umask 077; cat > "$1"',
            'bao-acp',
            target,
          ]);
          final out = process.stdout.drain<void>();
          final err = process.stderr.drain<void>();
          try {
            await for (final bytes in entity.openRead()) {
              process.write(bytes);
            }
            await process.closeStdin().timeout(const Duration(seconds: 15));
            if (await process.exitCode.timeout(const Duration(minutes: 5)) !=
                0) {
              throw StateError('Could not upload remote agent file');
            }
            await Future.wait([out, err]);
          } catch (_) {
            process.kill(force: true);
            rethrow;
          }
          if (executablePaths.contains(entity.path)) {
            await _run('chmod', ['700', target]);
          }
        }
      }
      final executable = p.posix.join(
        destination,
        plan.command.replaceAll('\\', '/'),
      );
      await _run('chmod', ['700', executable]);
      return executable;
    } catch (_) {
      if (installed != null) {
        try {
          await _run('rm', ['-rf', '--', installed]);
        } on Object {
          /* Disconnected: never touch another host. */
        }
      }
      rethrow;
    } finally {
      await staging.delete(recursive: true);
    }
  }
}

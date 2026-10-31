import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../ide/lsp/install/archive.dart' show extractTar, extractZip;
import '../platform/data_dir.dart';
import '../network/network_proxy.dart';
import 'acp/acp_agent.dart';
import 'claude_code/claude_environment.dart';

/// The stable, public ACP catalog. Reading it never installs or runs an agent.
const acpRegistryUrl =
    'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json';

class AcpRegistryEntry {
  const AcpRegistryEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.distribution,
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final Map<String, Object?> distribution;

  static List<AcpRegistryEntry> parse(Object? value) {
    if (value is! Map || value['agents'] is! List) {
      throw const FormatException('Invalid ACP registry');
    }
    return [
      for (final agent in value['agents'] as List)
        if (agent is Map &&
            agent['id'] is String &&
            RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(agent['id'] as String) &&
            agent['name'] is String &&
            agent['distribution'] is Map)
          AcpRegistryEntry(
            id: agent['id'] as String,
            name: agent['name'] as String,
            description: agent['description'] is String
                ? agent['description'] as String
                : '',
            version: agent['version'] is String
                ? agent['version'] as String
                : '',
            distribution: Map<String, Object?>.from(
              agent['distribution'] as Map,
            ),
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  AcpInstallPlan? planFor(String platform) {
    for (final kind in ['npx', 'uvx']) {
      if (distribution[kind] case final Map recipe) {
        final package = recipe['package'];
        if (package is! String ||
            !RegExp(
              r'^(?:@[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_.-]+(?:@|==)[a-zA-Z0-9_.+-]+$',
            ).hasMatch(package)) {
          continue;
        }
        final spec = kind == 'uvx' ? package.replaceFirst('@', '==') : package;
        return AcpInstallPlan(
          kind: kind,
          source: spec,
          command: kind,
          arguments: [if (kind == 'npx') '-y', spec, ..._args(recipe)],
          environment: _env(recipe),
        );
      }
    }
    if (distribution['binary'] case final Map platforms) {
      if (platforms[platform] case final Map recipe) {
        final archive = Uri.tryParse(
          recipe['archive'] is String ? recipe['archive'] as String : '',
        );
        final cmd = recipe['cmd'];
        if (archive == null ||
            archive.scheme != 'https' ||
            archive.host.isEmpty ||
            cmd is! String ||
            cmd.isEmpty ||
            !_relativeCommand(cmd)) {
          return null;
        }
        final hash = recipe['sha256'];
        if (hash != null &&
            (hash is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash))) {
          return null;
        }
        return AcpInstallPlan(
          kind: 'binary',
          source: archive.toString(),
          command: cmd,
          arguments: _args(recipe),
          environment: _env(recipe),
          sha256: hash as String?,
        );
      }
    }
    return null;
  }

  static bool _relativeCommand(String command) {
    final path = command.replaceAll('\\', '/');
    return !p.posix.isAbsolute(path) &&
        !p.windows.isAbsolute(path) &&
        !path.split('/').contains('..');
  }

  static List<String> _args(Map recipe) => [
    if (recipe['args'] case final List args) ...args.whereType<String>(),
  ];
  static Map<String, String> _env(Map recipe) => {
    if (recipe['env'] case final Map env)
      for (final entry in env.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
  };
}

class AcpInstallPlan {
  const AcpInstallPlan({
    required this.kind,
    required this.source,
    required this.command,
    required this.arguments,
    this.environment = const {},
    this.sha256,
  });
  final String kind;
  final String source;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? sha256;

  String get launchPreview => '$command ${arguments.map(jsonEncode).join(' ')}';
}

/// Injectable for settings tests; real installation only after explicit consent.
class AcpRegistry {
  const AcpRegistry();

  String get platform => switch (Abi.current()) {
    Abi.macosArm64 => 'darwin-aarch64',
    Abi.macosX64 => 'darwin-x86_64',
    Abi.linuxArm64 => 'linux-aarch64',
    Abi.linuxX64 => 'linux-x86_64',
    Abi.windowsArm64 => 'windows-aarch64',
    Abi.windowsX64 => 'windows-x86_64',
    _ => 'unsupported',
  };

  Future<List<AcpRegistryEntry>> load() async => AcpRegistryEntry.parse(
    jsonDecode(utf8.decode(await download(Uri.parse(acpRegistryUrl), 8 << 20))),
  );

  Future<Uint8List> download(Uri uri, int maxBytes) async {
    if (uri.scheme != 'https') throw const FormatException('HTTPS required');
    final route = await currentProxyRoute();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = route.findProxy;
    try {
      late HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 30));
        if (!response.isRedirect) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (redirects >= 5 || location == null) {
          throw const FormatException('Too many redirects');
        }
        uri = uri.resolve(location);
        if (uri.scheme != 'https') {
          throw const FormatException('HTTPS required');
        }
        await response.drain<void>().timeout(const Duration(seconds: 30));
      }
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}: $uri');
      }
      if (response.contentLength > maxBytes) {
        throw const FormatException('Download exceeds size limit');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw const FormatException('Download exceeds size limit');
        }
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// Package runners cache the pinned distribution without starting the agent.
  /// Binary distributions are unpacked in the app's own data directory.
  Future<AcpAgentConfig> install(AcpRegistryEntry entry) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(entry.id)) {
      throw const FormatException('Invalid agent id');
    }
    final plan = entry.planFor(platform);
    if (plan == null) throw UnsupportedError('No distribution for $platform');
    var command = plan.command;
    if (plan.kind == 'npx') {
      await prepare('npm', [
        'exec',
        '--yes',
        '--package',
        plan.source,
        '--',
        'node',
        '-e',
        'process.exit(0)',
      ]);
    } else if (plan.kind == 'uvx') {
      await prepare('uvx', ['--from', plan.source, 'python', '-c', 'pass']);
    } else {
      command = await installBinary(entry, plan);
    }
    return AcpAgentConfig(
      id: entry.id,
      label: entry.name,
      hostScoped: true,
      command: command,
      arguments: plan.arguments,
      environment: plan.environment,
      description: entry.description,
    );
  }

  Future<void> prepare(String command, List<String> arguments) async {
    final environment = {
      ...await ClaudeEnvironment.of(),
      ...(await currentProxyRoute()).environment,
    };
    final process = await Process.start(
      command,
      arguments,
      environment: environment,
      runInShell: Platform.isWindows,
    );
    final output = StringBuffer();
    void collect(String text) {
      if (output.length < 12000) output.write(text);
    }

    final out = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(collect);
    final err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(collect);
    final drained = Future.wait([out.asFuture<void>(), err.asFuture<void>()]);
    try {
      final exit = await process.exitCode.timeout(const Duration(minutes: 5));
      await drained.timeout(const Duration(seconds: 15));
      if (exit != 0) throw StateError('$command exited $exit: $output');
    } on TimeoutException {
      process.kill();
      throw StateError('$command installation timed out');
    } finally {
      await out.cancel();
      await err.cancel();
    }
  }

  Future<Uint8List> downloadBinary(AcpInstallPlan plan) async {
    final uri = Uri.parse(plan.source);
    final bytes = await download(uri, 256 << 20);
    if (plan.sha256 != null &&
        sha256.convert(bytes).toString() != plan.sha256!.toLowerCase()) {
      throw const FormatException('Agent download SHA-256 mismatch');
    }
    return bytes;
  }

  /// Downloads and verifies a build for any target, without executing it.
  Future<List<String>> unpackBinary(
    AcpInstallPlan plan,
    Directory directory, {
    Uint8List? bytes,
  }) async {
    bytes ??= await downloadBinary(plan);
    final uri = Uri.parse(plan.source);
    if (uri.path.endsWith('.zip')) return extractZip(bytes, directory.path);
    if (uri.path.endsWith('.tar.gz') || uri.path.endsWith('.tgz')) {
      return extractTar(gzip.decode(bytes), directory.path);
    }
    throw const FormatException('Unsupported agent archive format');
  }

  Future<String> installBinary(
    AcpRegistryEntry entry,
    AcpInstallPlan plan,
  ) async {
    final bytes = await downloadBinary(plan);
    final root = Directory(
      p.join(DataDirectory.current.path, 'acp-agents', entry.id),
    );
    await root.create(recursive: true);
    final directory = await root.createTemp('install-');
    try {
      final executables = await unpackBinary(plan, directory, bytes: bytes);
      final executable = File(
        p.join(directory.path, plan.command.replaceAll('\\', '/')),
      );
      final resolved = await executable.resolveSymbolicLinks();
      if (!p.isWithin(await directory.resolveSymbolicLinks(), resolved) ||
          !await executable.exists()) {
        throw const FormatException('Invalid agent executable');
      }
      if (!Platform.isWindows) {
        for (final path in {...executables, resolved}) {
          final result = await Process.run('chmod', ['+x', path]);
          if (result.exitCode != 0) {
            throw StateError('Could not make agent executable');
          }
        }
      }
      return executable.path;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}

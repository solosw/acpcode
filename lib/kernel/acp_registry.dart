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

  /// Accepts a single agent, an array, or an ACP registry document.
  static List<AcpRegistryEntry> parseImport(Object? value) {
    final entries = switch (value) {
      {'agents': final List agents} => agents,
      final List agents => agents,
      final Map agent => [agent],
      _ => throw const FormatException('Expected ACP agent JSON'),
    };
    final parsed = parse({'agents': entries});
    if (parsed.length != entries.length ||
        parsed.map((agent) => agent.id).toSet().length != parsed.length ||
        parsed.any(
          (agent) => agent.runnerPlan == null && agent.binaryPlans.isEmpty,
        )) {
      throw const FormatException(
        'Invalid, duplicate, or unsupported ACP agent entry',
      );
    }
    return parsed;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'distribution': distribution,
  };

  List<AcpInstallPlan> get binaryPlans => [
    if (distribution['binary'] case final Map platforms)
      for (final target in platforms.keys.whereType<String>())
        ?binaryPlanFor(target),
  ];

  AcpInstallPlan? get runnerPlan {
    for (final kind in ['npx', 'uvx']) {
      if (distribution[kind] case final Map recipe) {
        final package = recipe['package'];
        if (package is! String ||
            package.startsWith('-') ||
            !RegExp(
              r'^(?:@[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_.-]+(?:@|==)[a-zA-Z0-9_.+-]+$',
            ).hasMatch(package)) {
          continue;
        }
        final spec = kind == 'uvx' ? package.replaceFirst('@', '==') : package;
        return AcpInstallPlan(
          kind: kind,
          version: version,
          source: spec,
          command: kind,
          arguments: [if (kind == 'npx') '-y', spec, ..._args(recipe)],
          environment: _env(recipe),
        );
      }
    }
    return null;
  }

  AcpInstallPlan? planFor(String platform) =>
      runnerPlan ?? binaryPlanFor(platform);

  AcpInstallPlan? binaryPlanFor(String platform) {
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
          platform: platform,
          version: version,
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
        !path.contains(':') &&
        !path.contains(String.fromCharCode(0)) &&
        p.posix.normalize(path) != '.' &&
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

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

class AcpInstallPlan {
  const AcpInstallPlan({
    required this.kind,
    required this.source,
    required this.command,
    required this.arguments,
    this.environment = const {},
    this.sha256,
    this.platform,
    this.version,
  });
  final String kind;
  final String source;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? sha256;
  final String? platform;
  final String? version;

  String get cacheKey => _hash(
    utf8.encode(jsonEncode([platform, version, source, sha256, command])),
  );

  List<String> offlineArguments(String directory) => [
    '--offline',
    if (kind == 'npx') ...[
      '--cache',
      directory,
      '--ignore-scripts',
    ] else ...[
      '--cache-dir',
      directory,
      '--no-python-downloads',
      '--link-mode',
      'copy',
    ],
    ...arguments,
  ];

  String commandIn(String directory, p.Context paths) => paths.normalize(
    paths.joinAll([directory, ...command.replaceAll('\\', '/').split('/')]),
  );

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

  Future<Uint8List> download(
    Uri uri,
    int maxBytes, {
    void Function(int received, int? total)? onProgress,
  }) async {
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
      final total =
          response.contentLength > 0 &&
              response.compressionState !=
                  HttpClientResponseCompressionState.decompressed
          ? response.contentLength
          : null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw const FormatException('Download exceeds size limit');
        }
        onProgress?.call(bytes.length, total);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Directory get cacheDirectory =>
      Directory(p.join(DataDirectory.current.path, 'acp-agent-packages'));

  File cachedBinary(AcpInstallPlan plan) =>
      File(p.join(cacheDirectory.path, plan.cacheKey));

  Directory cachedRunner(AcpInstallPlan plan) =>
      Directory(p.join(cacheDirectory.path, 'runner-${plan.cacheKey}'));

  static const runnerReady = '.baocode-ready';

  /// Prepare runner packages locally and fetch every published binary.
  /// The server can reconstruct a runner environment from the copied cache.
  Future<void> cacheRunner(AcpInstallPlan plan) async {
    final destination = cachedRunner(plan);
    if (await File(p.join(destination.path, runnerReady)).exists()) return;
    await cacheDirectory.create(recursive: true);
    final staging = await cacheDirectory.createTemp('runner-');
    try {
      if (plan.kind == 'npx') {
        for (final (os, cpu, libc) in const [
          ('darwin', 'arm64', null),
          ('darwin', 'x64', null),
          ('linux', 'arm64', 'glibc'),
          ('linux', 'x64', 'glibc'),
          ('win32', 'arm64', null),
          ('win32', 'x64', null),
          ('linux', 'arm64', 'musl'),
          ('linux', 'x64', 'musl'),
        ]) {
          final prefix = await Directory.systemTemp.createTemp(
            'baocode-acp-npm-',
          );
          try {
            await prepare('npm', [
              'install',
              '--prefix',
              prefix.path,
              '--cache',
              staging.path,
              '--os',
              os,
              '--cpu',
              cpu,
              if (libc != null) ...['--libc', libc],
              '--ignore-scripts',
              '--no-audit',
              '--no-fund',
              '--no-package-lock',
              '--',
              plan.source,
            ]);
          } finally {
            await prefix.delete(recursive: true);
          }
        }
        // npm exec also caches the package metadata used by offline npx.
        await prepare('npm', [
          'exec',
          '--cache',
          staging.path,
          '--ignore-scripts',
          '--yes',
          '--package',
          plan.source,
          '--',
          'node',
          '-e',
          'process.exit(0)',
        ]);
      } else {
        await prepare('uv', [
          '--cache-dir',
          staging.path,
          '--no-python-downloads',
          'tool',
          'run',
          '--link-mode',
          'copy',
          '--from',
          plan.source,
          'python',
          '-c',
          'pass',
        ]);
      }
      await File(p.join(staging.path, runnerReady)).create();
      try {
        await staging.rename(destination.path);
      } on FileSystemException {
        if (!await File(p.join(destination.path, runnerReady)).exists()) {
          rethrow;
        }
      }
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<AcpAgentConfig> cache(
    AcpRegistryEntry entry, {
    void Function(AcpInstallPlan plan, int? received, int? total)? onProgress,
  }) async {
    final validated = AcpRegistryEntry.parseImport(entry.toJson()).single;
    for (final plan in validated.binaryPlans) {
      final file = cachedBinary(plan);
      if (await file.exists() &&
          (plan.sha256 == null ||
              (await sha256.bind(file.openRead()).first).toString() ==
                  plan.sha256!.toLowerCase())) {
        continue;
      }
      onProgress?.call(plan, 0, null);
      final bytes = await downloadBinary(
        plan,
        onProgress: onProgress == null
            ? null
            : (received, total) => onProgress(plan, received, total),
      );
      onProgress?.call(plan, null, null);
      await cacheDirectory.create(recursive: true);
      final staging = await cacheDirectory.createTemp('download-');
      try {
        final package = await File(p.join(staging.path, 'package'))
            .writeAsBytes(bytes);
        await package.rename(file.path);
      } finally {
        await staging.delete(recursive: true);
      }
    }
    if (validated.runnerPlan case final runner?) {
      onProgress?.call(runner, 0, null);
      await cacheRunner(runner);
    }
    return AcpAgentConfig(
      id: validated.id,
      label: validated.name,
      command: '',
      description: validated.description,
      hostScoped: true,
      registry: validated,
    );
  }

  AcpInstallPlan? launchPlan(AcpRegistryEntry entry) =>
      entry.binaryPlanFor(platform) ?? entry.runnerPlan;

  /// Resolves a saved registry entry using the cached package for the host.
  Future<AcpAgentConfig> resolve(AcpRegistryEntry entry) async {
    final plan = launchPlan(entry);
    if (plan == null) throw UnsupportedError('No ACP build for $platform');
    final installed = await deploy(entry, plan);
    final binary = plan.kind == 'binary';
    return AcpAgentConfig(
      id: entry.id,
      label: entry.name,
      command: binary ? installed : plan.command,
      arguments: binary ? plan.arguments : plan.offlineArguments(installed),
      environment: plan.environment,
      description: entry.description,
    );
  }

  /// Returns a binary executable or an offline runner cache directory.
  Future<String> deploy(AcpRegistryEntry entry, AcpInstallPlan plan) async {
    if (plan.kind == 'binary') return _deployBinary(entry, plan);
    final runner = cachedRunner(plan).absolute.path;
    if (!await File(p.join(runner, runnerReady)).exists()) {
      throw StateError(
        'Missing local ACP package. Download it again in Settings → Agents.',
      );
    }
    return runner;
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

  Future<Uint8List> downloadBinary(
    AcpInstallPlan plan, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final uri = Uri.parse(plan.source);
    final bytes = await download(uri, 256 << 20, onProgress: onProgress);
    verifyBinary(plan, bytes);
    return bytes;
  }

  void verifyBinary(AcpInstallPlan plan, Uint8List bytes) {
    if (plan.sha256 != null && _hash(bytes) != plan.sha256!.toLowerCase()) {
      throw const FormatException('Agent download SHA-256 mismatch');
    }
  }

  /// Downloads and verifies a build for any target, without executing it.
  Future<List<String>> unpackBinary(
    AcpInstallPlan plan,
    Directory directory, {
    Uint8List? bytes,
  }) async {
    bytes ??= await downloadBinary(plan);
    final path = Uri.parse(plan.source).path.toLowerCase();
    final data = ByteData.sublistView(bytes);
    final magic = data.lengthInBytes >= 4 ? data.getUint32(0) : 0;
    if (path.endsWith('.zip') || magic == 0x504b0304) {
      return extractZip(bytes, directory.path);
    }
    if (path.endsWith('.tar.gz') ||
        path.endsWith('.tgz') ||
        magic >> 16 == 0x1f8b) {
      return extractTar(gzip.decode(bytes), directory.path);
    }
    if (path.endsWith('.tar')) return extractTar(bytes, directory.path);
    // Some registry URLs deliver the executable directly (ELF, Mach-O, PE).
    if (const {
          0x7f454c46,
          0xfeedface,
          0xfeedfacf,
          0xcefaedfe,
          0xcffaedfe,
          0xcafebabe,
          0xcafebabf,
        }.contains(magic) ||
        magic >> 16 == 0x4d5a) {
      if (!AcpRegistryEntry._relativeCommand(plan.command)) {
        throw const FormatException('Invalid agent executable');
      }
      final executable = File(plan.commandIn(directory.path, p.context));
      if (!p.isWithin(directory.path, executable.path)) {
        throw const FormatException('Invalid agent executable');
      }
      await executable.parent.create(recursive: true);
      await executable.writeAsBytes(bytes);
      return [executable.path];
    }
    throw const FormatException('Unsupported agent archive format');
  }

  static final _pendingDeployments = <String, Future<String>>{};

  Directory _agentRoot(AcpRegistryEntry entry) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(entry.id)) {
      throw const FormatException('Invalid agent id');
    }
    return Directory(
      p.absolute(DataDirectory.current.path, 'acp-agents', entry.id),
    );
  }

  Future<String> _deployBinary(
    AcpRegistryEntry entry,
    AcpInstallPlan plan,
  ) async {
    final root = _agentRoot(entry);
    final destination = p.join(root.path, plan.cacheKey);
    if (_pendingDeployments[destination] case final pending?) return pending;
    final deployment = _unpackCachedBinary(root, destination, plan);
    _pendingDeployments[destination] = deployment;
    try {
      return await deployment;
    } finally {
      _pendingDeployments.remove(destination);
    }
  }

  Future<String> _unpackCachedBinary(
    Directory root,
    String destination,
    AcpInstallPlan plan,
  ) async {
    var target = destination;
    late File executable;
    for (var attempt = 1; ; attempt++) {
      executable = File(plan.commandIn(target, p.context));
      if (await executable.exists()) return executable.path;
      if (await FileSystemEntity.type(target) ==
          FileSystemEntityType.notFound) {
        break;
      }
      target = '$destination-$attempt';
    }
    final archive = cachedBinary(plan);
    if (!await archive.exists()) {
      throw StateError(
        'Missing ACP package for $platform. Download it again in Settings → Agents.',
      );
    }
    final bytes = await archive.readAsBytes();
    verifyBinary(plan, bytes);
    await root.create(recursive: true);
    final staging = await root.createTemp('install-');
    try {
      await _unpackExecutable(plan, staging, bytes);
      try {
        await staging.rename(target);
      } on FileSystemException {
        if (!await executable.exists()) rethrow;
      }
      return executable.path;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<String> installBinary(
    AcpRegistryEntry entry,
    AcpInstallPlan plan,
  ) async {
    final root = _agentRoot(entry);
    final bytes = await downloadBinary(plan);
    await root.create(recursive: true);
    final directory = await root.createTemp('install-');
    try {
      return await _unpackExecutable(plan, directory, bytes);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> _unpackExecutable(
    AcpInstallPlan plan,
    Directory directory,
    Uint8List bytes,
  ) async {
    final executables = await unpackBinary(plan, directory, bytes: bytes);
    final executable = File(plan.commandIn(directory.path, p.context));
    if (!await executable.exists()) {
      throw FormatException(
        'Agent executable ${plan.command} is missing from the archive',
      );
    }
    final resolved = await executable.resolveSymbolicLinks();
    if (!p.isWithin(await directory.resolveSymbolicLinks(), resolved)) {
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
  }
}

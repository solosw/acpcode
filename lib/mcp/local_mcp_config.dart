import 'dart:io';

import 'package:bao_agent/mcp.dart';
import 'package:path/path.dart' as p;

import '../customize/customization_store.dart';
import '../customize/customizations.dart';
import '../customize/mcp_probe.dart';
import '../kernel/claude_code/claude_environment.dart';
import 'local_mcp_endpoint.dart';

/// User MCPs belong to the client machine, independently of the agent's home.
Future<Map<String, Map<String, Object?>>> localMcpDefaults(
  Map<String, String> environment,
) async {
  final home = environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final store = CustomizationStore(
    homeDir: home,
    configDir:
        ClaudeEnvironment.stateDirectory(environment)['CLAUDE_CONFIG_DIR'] ??
        environment['CLAUDE_CONFIG_DIR'],
  );
  return {
    for (final item in await store.list(CustomizationKind.mcps))
      if (item.name != 'baocode' &&
          item.enabled != false &&
          item.server != null)
        item.name: item.server!,
  };
}

LocalMcpEndpoint createLocalMcpEndpoint(
  Map<String, Object?> config,
  Map<String, String> environment,
) {
  String expand(String value) => expandMcpVariables(value, environment);
  Map<String, String> variables(Object? raw) {
    if (raw == null) return {};
    if (raw is! Map ||
        raw.entries.any((e) => e.key is! String || e.value is! String)) {
      throw const FormatException('Invalid local MCP environment or headers');
    }
    return {
      for (final entry in raw.entries)
        entry.key as String: expand(entry.value as String),
    };
  }

  final type = config['type'] ?? (config['url'] == null ? 'stdio' : 'http');
  if (type == 'http' || type == 'streamable-http' || type == 'sse') {
    final rawUrl = config['url'];
    final uri = rawUrl is String ? Uri.tryParse(expand(rawUrl)) : null;
    if (uri == null ||
        uri.host.isEmpty ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException('Invalid local MCP URL');
    }
    final headers = variables(config['headers']);
    return LocalMcpEndpoint(
      type == 'sse'
          ? SseTransport(uri, headers: headers, environment: environment)
          : StreamableHttpTransport(
              uri,
              headers: headers,
              environment: environment,
            ),
    );
  }
  if (type != 'stdio') {
    throw const FormatException('Unsupported local MCP transport');
  }
  final command = config['command'];
  final args = config['args'] ?? const <String>[];
  if (command is! String ||
      command.trim().isEmpty ||
      args is! List ||
      args.any((arg) => arg is! String)) {
    throw const FormatException('Invalid local MCP command');
  }
  final env = {...environment, ...variables(config['env'])};
  final cwd = environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final resolved = resolveLocalMcpCommand(expand(command), env, cwd: cwd);
  if (resolved == null) {
    throw const FormatException('Server executable not found on this machine');
  }
  return LocalMcpEndpoint(
    StdioTransport(
      command: resolved,
      arguments: [for (final arg in args.cast<String>()) expand(arg)],
      environment: env,
      workingDirectory: cwd,
    ),
  );
}

/// ACP requires absolute commands. Search the agent's PATH, not the GUI's;
/// Windows uses ';' and PATHEXT, not the remote host's POSIX spelling.
String? resolveLocalMcpCommand(
  String command,
  Map<String, String> environment, {
  String? cwd,
  p.Context? paths,
  bool? windows,
  bool Function(String path)? fileExists,
}) {
  final isWindows = windows ?? Platform.isWindows;
  final context = paths ?? (isWindows ? p.windows : p.posix);
  String? variable(String name) {
    if (!isWindows) return environment[name];
    for (final entry in environment.entries.toList().reversed) {
      if (entry.key.toUpperCase() == name) return entry.value;
    }
    return null;
  }

  final extensions = <String>[
    '',
    if (isWindows && context.extension(command).isEmpty)
      ...(variable('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
          .split(';')
          .expand((value) => [value, value.toLowerCase()]),
  ];
  final directories =
      context.isAbsolute(command) ||
          command.contains('/') ||
          command.contains('\\')
      ? [cwd ?? Directory.current.path]
      : (variable('PATH') ?? '').split(isWindows ? ';' : ':');
  for (final directory in directories) {
    if (directory.isEmpty) continue;
    final base = context.normalize(
      context.join(cwd ?? Directory.current.path, directory, command),
    );
    for (final extension in extensions) {
      final candidate = '$base$extension';
      if (fileExists?.call(candidate) ?? File(candidate).existsSync()) {
        return candidate;
      }
    }
  }
  return null;
}

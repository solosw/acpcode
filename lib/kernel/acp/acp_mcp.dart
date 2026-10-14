import '../../customize/customizations.dart';
import '../../customize/mcp_probe.dart';
import '../agent_kernel.dart';
import 'acp_mcp_stub.dart' if (dart.library.io) 'acp_mcp_io.dart' as platform;

/// MCP connection details to send, and configuration problems to show rather
/// than silently losing a tool. These are not a report of connected servers.
class AcpMcpServers {
  const AcpMcpServers({this.servers = const [], this.warnings = const []});

  final List<Map<String, Object?>> servers;
  final List<String> warnings;
}

typedef AcpMcpLoader = Future<AcpMcpServers> Function(
  KernelContext context,
  Map<String, Object?> capabilities,
);

typedef AcpMcpCommandResolver = Future<String?> Function(
  String command,
  Map<String, String> environment,
);

/// Uses the same MCP configurations as Customize, on the agent's host.
Future<AcpMcpServers> loadAcpMcpServers(
  KernelContext context,
  Map<String, Object?> capabilities, {
  Map<String, String> environment = const {},
}) =>
    platform.loadAcpMcpServers(context, capabilities, environment: environment);

/// Converts Claude-style configuration maps into ACP's connection objects.
/// Local (private project) > project (shared) > user, independently of the
/// Customize list's display order. A disabled override must not fall back.
Future<AcpMcpServers> buildAcpMcpServers(
  List<Customization> items, {
  required Map<String, Object?> capabilities,
  required Map<String, String> environment,
  required AcpMcpCommandResolver resolveCommand,
}) async {
  int priority(CustomizationScope scope) => switch (scope) {
    CustomizationScope.user => 0,
    CustomizationScope.project => 1,
    CustomizationScope.local => 2,
    _ => -1,
  };
  final effective = <String, Customization>{};
  for (final item in items) {
    if (item.kind != CustomizationKind.mcps || priority(item.scope) < 0) {
      continue;
    }
    final previous = effective[item.name];
    if (previous == null || priority(item.scope) >= priority(previous.scope)) {
      effective[item.name] = item;
    }
  }
  final servers = <Map<String, Object?>>[];
  final warnings = <String>[];
  for (final item in effective.values) {
    if (item.enabled == false) continue;
    try {
      final config = item.server;
      if (config == null) throw const FormatException('Invalid configuration');
      String expand(String value) {
        for (final match in RegExp(
          r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}',
        ).allMatches(value)) {
          if (!environment.containsKey(match[1]) && match[2] == null) {
            throw FormatException('Missing environment variable ${match[1]}');
          }
        }
        return expandMcpVariables(value, environment);
      }

      List<Map<String, String>> variables(Object? raw, String field) {
        if (raw == null) return [];
        if (raw is! Map) throw FormatException('$field must be an object');
        return [
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is String)
              {
                'name': entry.key as String,
                'value': expand(entry.value as String),
              }
            else
              throw FormatException('$field values must be strings'),
        ];
      }

      final type = config['type'] ?? (config['url'] != null ? 'http' : 'stdio');
      if (type == 'http' || type == 'sse') {
        if (capabilities[type] != true) {
          warnings.add(
            'MCP "${item.name}" skipped: this ACP agent does not support $type transport.',
          );
          continue;
        }
        final rawUrl = config['url'];
        if (rawUrl is! String) {
          throw const FormatException('Missing server URL');
        }
        final url = expand(rawUrl);
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !uri.hasAuthority ||
            uri.host.isEmpty ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw const FormatException('Invalid HTTP/SSE server URL');
        }
        servers.add({
          'type': type,
          'name': item.name,
          'url': url,
          'headers': variables(config['headers'], 'headers'),
        });
      } else if (type == 'stdio') {
        final rawCommand = config['command'];
        if (rawCommand is! String || rawCommand.trim().isEmpty) {
          throw const FormatException('Missing server command');
        }
        final rawArgs = config['args'] ?? const <String>[];
        if (rawArgs is! List || rawArgs.any((arg) => arg is! String)) {
          throw const FormatException('args must be an array of strings');
        }
        final env = variables(config['env'], 'env');
        final command = await resolveCommand(expand(rawCommand), {
          ...environment,
          for (final entry in env) entry['name']!: entry['value']!,
        });
        if (command == null || command.isEmpty) {
          throw const FormatException(
            'Server executable not found on the agent host',
          );
        }
        servers.add({
          'name': item.name,
          'command': command,
          'args': [for (final arg in rawArgs) expand(arg as String)],
          'env': env,
        });
      } else {
        throw const FormatException('Unknown MCP transport');
      }
    } on FormatException catch (error) {
      // Only our validation messages: never log URLs, headers, env or tokens.
      warnings.add('MCP "${item.name}" skipped: ${error.message}.');
    }
  }
  return AcpMcpServers(servers: servers, warnings: warnings);
}

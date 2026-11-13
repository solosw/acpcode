import 'dart:io';

import 'package:path/path.dart' as p;

import '../../customize/customization_store.dart';
import '../../customize/customizations.dart';
import '../../mcp/tools_bridge.dart';
import '../../mcp/tools_http.dart';
import '../../mcp/tools_protocol.dart';
import '../../mcp/tools_registration.dart';
import '../../platform/data_dir.dart';
import '../../remote/remote_customization_disk.dart';
import '../../remote/remote_location.dart';
import '../../remote/remote_mcp.dart';
import '../../remote/ssh_host.dart';
import '../agent_kernel.dart';
import '../claude_code/claude_environment.dart';
import 'acp_mcp.dart';

Future<AcpMcpServers> loadAcpMcpServers(
  KernelContext context,
  Map<String, Object?> capabilities, {
  Map<String, String> environment = const {},
}) async {
  final location = context.cwd ?? context.resume?.cwd;
  final hostName = location == null ? null : RemoteLocation.hostOf(location);
  final project = location == null ? null : RemoteLocation.pathOf(location);
  final host = hostName == null ? null : SshHosts.instance[hostName];
  final customHome =
      environment['HOME'] ??
      (host == null && Platform.isWindows ? environment['USERPROFILE'] : null);
  final paths = host == null ? p.context : p.posix;
  final store = CustomizationStore(
    configDir:
        environment['CLAUDE_CONFIG_DIR'] ??
        (customHome == null ? null : paths.join(customHome, '.claude')),
    homeDir: customHome,
    disk: host == null ? null : RemoteCustomizationDisk(host),
  );
  final appDefault = <String, Object?>{};
  final items = await store.list(
    CustomizationKind.mcps,
    project: project,
    mcpDefaults: host != null && ToolsBridge.instance.http != null
        ? {'baocode': appDefault}
        : const {},
  );
  if (items.isEmpty) return const AcpMcpServers();
  final Map<String, String> inherited;
  if (host == null) {
    inherited = await ClaudeEnvironment.of();
  } else if (items.every(
    (item) => item.enabled == false || identical(item.server, appDefault),
  )) {
    // App-generated endpoints need no environment expansion. In particular,
    // a native Windows SSH host need not provide POSIX env or sh commands.
    inherited = const {};
  } else {
    // Read the remote login environment. Never substitute this client's env
    // (Windows paths and credentials in particular) into a remote config.
    final output = await (await host.ready).run('env', const ['-0']);
    if (output.exitCode != 0) {
      throw StateError('Cannot read the ACP agent host environment for MCP');
    }
    inherited = {
      for (final entry in output.stdout.split('\u0000'))
        if (entry.indexOf('=') > 0)
          entry.substring(0, entry.indexOf('=')): entry.substring(
            entry.indexOf('=') + 1,
          ),
    };
  }
  final connections = <ToolsHttpConnection>[];
  final relayCommands = <String>{};
  final AcpMcpServers result;
  try {
    result = await buildAcpMcpServers(
      items,
      capabilities: capabilities,
      environment: {...inherited, ...environment},
      configurationFor: (item) async {
        final config = item.server;
        final http = ToolsBridge.instance.http;
        if (host != null && identical(config, appDefault)) {
          if (http == null) {
            throw const FormatException(
              'the app tools listener is unavailable',
            );
          }
          try {
            final connection = await openRemoteMcp(
              host,
              http,
              cwd: location!,
              useHttp: capabilities['http'] == true,
            );
            connections.add(connection);
            if (connection.configuration['command'] case final String command) {
              relayCommands.add(command);
            }
            return connection.configuration;
          } on FormatException {
            rethrow;
          } on Object {
            // Never expose connection addresses, environment or credentials.
            throw const FormatException('could not open the SSH tools bridge');
          }
        }
        // Only the effective local app-managed entry is upgraded. Explicit
        // remote/project servers always keep their own configuration.
        if (hostName != null ||
            capabilities['http'] != true ||
            http == null ||
            item.name != 'baocode' ||
            config == null ||
            !isManagedBaocodeTools(config)) {
          return null;
        }
        final env = config['env'] as Map;
        if (!p.equals(
          p.normalize(env[ToolsProtocol.dataDirectoryVariable] as String),
          p.normalize(DataDirectory.current.path),
        )) {
          return null;
        }
        final connection = http.open(cwd: project ?? Directory.current.path);
        connections.add(connection);
        return connection.configuration;
      },
      resolveCommand: (command, env) async {
        // The server reports its own absolute launcher; never look it up in
        // a login shell (or reinterpret a Windows command as a POSIX path).
        if (relayCommands.contains(command)) return command;
        if (host == null) {
          return resolveLocalMcpCommand(command, env, cwd: project);
        }
        // Positional arguments, not interpolated shell code: paths, spaces and
        // metacharacters in the configuration cannot change this lookup command.
        final output = await (await host.ready).run(
          'sh',
          ['-c', r'command -v "$1"', 'baocode-mcp', command],
          cwd: project,
          environment: env,
        );
        if (output.exitCode != 0) return null;
        final found = output.stdout.trim();
        if (found.isEmpty || found.contains('\n')) return null;
        return p.posix.isAbsolute(found)
            ? found
            : project == null
            ? null
            : p.posix.normalize(p.posix.join(project, found));
      },
    );
  } on Object {
    for (final connection in connections) {
      connection.close();
    }
    rethrow;
  }
  return AcpMcpServers(
    servers: result.servers,
    warnings: result.warnings,
    onClose: () {
      for (final connection in connections) {
        connection.close();
      }
    },
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

import 'dart:async';

import '../customize/customization_store.dart';
import '../customize/customizations.dart';
import '../kernel/claude_code/claude_environment.dart';
import '../mcp/local_mcp_config.dart';
import '../mcp/local_mcp_endpoint.dart';
import '../mcp/tools_bridge.dart';
import '../mcp/tools_http.dart';
import 'remote_customization_disk.dart';
import 'remote_host_settings.dart';
import 'remote_location.dart';
import 'ssh_host.dart';

/// The user's local MCP endpoints for a Claude session. Explicit and disabled
/// remote entries take precedence over local fallbacks, as they do for ACP.
Future<Map<String, ToolsHttpConnection>> openRemoteUserMcp(
  SshHost host,
  String cwd,
) async {
  final http = ToolsBridge.instance.http;
  if (http == null || !RemoteHostSettings.instance.localAccess(host.host)) {
    return const {};
  }
  final environment = await ClaudeEnvironment.of();
  final local = await localMcpDefaults(environment);
  if (local.isEmpty) return const {};
  final store = CustomizationStore(disk: RemoteCustomizationDisk(host));
  final items = await store.list(
    CustomizationKind.mcps,
    project: RemoteLocation.pathOf(cwd),
    mcpDefaults: local,
  );
  // Any explicit entry displaces its fallback, including invalid or disabled
  // entries. The remaining defaults are owned by this launch alone.
  final overridden = {
    for (final item in items)
      if (!identical(item.server, local[item.name])) item.name,
  };
  final connections = <String, ToolsHttpConnection>{};
  try {
    for (final item in items) {
      final config = local[item.name];
      if (config == null ||
          overridden.contains(item.name) ||
          item.enabled == false) {
        continue;
      }
      try {
        connections[item.name] = await openRemoteMcp(
          host,
          http,
          cwd: cwd,
          useHttp: true,
          localMcp: createLocalMcpEndpoint(config, environment),
        );
      } on FormatException {
        // A misconfigured fallback must not stop the remote CLI from starting.
      }
    }
    return connections;
  } on Object {
    for (final connection in connections.values) {
      connection.close();
    }
    rethrow;
  }
}

/// One conversation's access to a local MCP server through SSH.
/// Only the loopback endpoint and a revocable bearer are sent to the agent.
Future<ToolsHttpConnection> openRemoteMcp(
  SshHost host,
  ToolsHttpServer http, {
  required String cwd,
  required bool useHttp,
  LocalMcpEndpoint? localMcp,
}) async {
  final settings = RemoteHostSettings.instance;
  void checkAccess() {
    if (!settings.localAccess(host.host)) {
      throw const FormatException(
        'local access is disabled in Settings → SSH Servers',
      );
    }
  }

  checkAccess();
  final client = await host.ready;
  checkAccess();
  final command = client.hello?.mcpStdioCommand ?? const <String>[];
  if (!useHttp && command.isEmpty) {
    throw const FormatException(
      'the remote server needs an update for stdio MCP; reconnect SSH',
    );
  }
  final endpoint = http.url;
  if (endpoint == null) {
    throw const FormatException('the app tools listener is unavailable');
  }
  final forward = await client.forward(endpoint.port);
  ToolsHttpConnection? connection;
  try {
    checkAccess();
    if (client.peer.isClosed) {
      throw const FormatException('the SSH connection ended');
    }
    final remoteUrl = endpoint.replace(port: forward.remotePort);
    final opened = connection = http.open(
      cwd: cwd,
      forwardedUrl: remoteUrl,
      localMcp: localMcp,
    );
    var closed = false;
    late void Function() changed;
    void close() {
      if (closed) return;
      closed = true;
      opened.close();
      settings.removeListener(changed);
      unawaited(forward.close());
    }

    // Revocation applies immediately to already-open ACP conversations too.
    void onSettingsChanged() {
      if (!settings.localAccess(host.host)) close();
    }

    changed = onSettingsChanged;
    settings.addListener(changed);
    unawaited(client.peer.done.then((_) => close()));
    final configuration = opened.configuration;
    return ToolsHttpConnection(
      useHttp
          ? configuration
          : {
              'command': command.first,
              'args': command.skip(1).toList(),
              'env': {
                'BAOCODE_MCP_URL': remoteUrl.toString(),
                'BAOCODE_MCP_TOKEN':
                    (configuration['headers'] as Map)['Authorization']
                        .toString()
                        .substring('Bearer '.length),
              },
            },
      close,
    );
  } on Object {
    connection?.close();
    unawaited(forward.close());
    rethrow;
  }
}

import 'dart:async';

import '../mcp/tools_http.dart';
import 'remote_host_settings.dart';
import 'ssh_host.dart';

/// One ACP conversation's access to the app's tools through its SSH connection.
/// Only the loopback endpoint and a revocable bearer are sent to the agent.
Future<ToolsHttpConnection> openRemoteMcp(
  SshHost host,
  ToolsHttpServer http, {
  required String cwd,
  required bool useHttp,
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
    final opened = connection = http.open(cwd: cwd, forwardedUrl: remoteUrl);
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

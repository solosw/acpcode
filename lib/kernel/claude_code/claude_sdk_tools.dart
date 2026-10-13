// Tools of the app's own an agent can call: an MCP server that lives in
// the app rather than in a process of its own (Claude Code's "SDK"
// servers). Claude Code is told of it at launch (`--mcp-config`, type
// `sdk`) and as it is initialized (`sdkMcpServers`), and sends what it
// says to it as control requests (`mcp_message`), whose answers go back
// the same way.

/// Where a tool is called from: the agent's working directory (its
/// project's path, as the workspace has it) and its session.
class ClaudeSdkCall {
  const ClaudeSdkCall({required this.cwd, this.sessionId});

  final String cwd;
  final String? sessionId;
}

/// One tool: its name, what it does and the JSON schema of its input, for
/// the model; [run] answers a call with text, or throws to say it failed.
class ClaudeSdkTool {
  const ClaudeSdkTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final Future<String> Function(Map<String, Object?> input, ClaudeSdkCall call)
  run;
}

/// The app's server and its tools (registered as their features start).
abstract final class ClaudeSdkTools {
  /// The server's name: its tools are `mcp__baocode__<name>` to the agent.
  static const server = 'baocode';

  static final Map<String, ClaudeSdkTool> _tools = {};

  static void register(ClaudeSdkTool tool) => _tools[tool.name] = tool;

  static void unregister(String name) => _tools.remove(name);

  /// Whether there is any tool: the server is only given then.
  static bool get any => _tools.isNotEmpty;

  /// The servers to launch Claude Code with: this one, if it has tools.
  static List<String> get servers => any ? const [server] : const [];

  /// The answer to [message] (JSON-RPC) for the server.
  static Future<Map<String, Object?>> handle(
    Map<String, Object?> message,
    ClaudeSdkCall call,
  ) async {
    final id = message['id'];
    final params = (message['params'] as Map?)?.cast<String, Object?>() ?? {};
    Map<String, Object?> result(Map<String, Object?> result) => {
      'jsonrpc': '2.0',
      'id': id ?? 0,
      'result': result,
    };
    switch (message['method']) {
      case 'initialize':
        return result({
          'protocolVersion': params['protocolVersion'] ?? '2024-11-05',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': server, 'version': '1.0.0'},
        });
      case 'tools/list':
        return result({
          'tools': [
            for (final tool in _tools.values)
              {
                'name': tool.name,
                'description': tool.description,
                'inputSchema': tool.inputSchema,
              },
          ],
        });
      case 'tools/call':
        final tool = _tools[params['name']];
        final input =
            (params['arguments'] as Map?)?.cast<String, Object?>() ?? {};
        if (tool == null) {
          return result({
            'content': [
              {'type': 'text', 'text': 'No tool ${params['name']}.'},
            ],
            'isError': true,
          });
        }
        try {
          final text = await tool.run(input, call);
          return result({
            'content': [
              {'type': 'text', 'text': text},
            ],
          });
        } on Object catch (error) {
          return result({
            'content': [
              {'type': 'text', 'text': '$error'},
            ],
            'isError': true,
          });
        }
      case final String method when method.startsWith('notifications/'):
        return result({});
      default:
        return {
          'jsonrpc': '2.0',
          'id': id ?? 0,
          'error': {
            'code': -32601,
            'message': 'Method not found: ${message['method']}',
          },
        };
    }
  }
}

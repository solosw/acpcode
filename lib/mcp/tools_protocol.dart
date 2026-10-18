/// How the app's own tools are offered to an agent that runs outside the
/// app (see tools_bridge.dart and tools_stdio.dart): the flag it starts the
/// app with, the variables it is given, and the line the process opens
/// with. Pure Dart, imported by both.
abstract final class ToolsProtocol {
  /// The argument the app is started with to be an agent's MCP server: it
  /// speaks MCP on its stdin and stdout, and passes it on to the running
  /// app. Nothing else of the app runs then.
  static const flag = '--mcp-stdio';

  /// Where the running app listens: a socket's path, or `127.0.0.1:port`.
  static const addressVariable = 'BAOCODE_MCP_ADDRESS';

  /// What the app made up for this run, the only answer it takes.
  static const tokenVariable = 'BAOCODE_MCP_TOKEN';

  /// The app's data folder. User-level registration stores this, not the
  /// address or token which change every time the app starts.
  static const dataDirectoryVariable = 'BAOCODE_MCP_DATA_DIR';

  /// The project the agent works in: what its tools are about.
  static const cwdVariable = 'BAOCODE_MCP_CWD';

  /// The agent's session, where it says one.
  static const sessionVariable = 'BAOCODE_MCP_SESSION';

  /// The first line the process sends: who it is, and for what.
  static Map<String, Object?> hello({
    required String token,
    String? cwd,
    String? session,
  }) => {
    'baocode': {'token': token, 'cwd': ?cwd, 'session': ?session},
  };
}

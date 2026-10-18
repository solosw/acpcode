// The app as the host of its own tools for agents that run outside it, where
// the platform has processes (tools_bridge.dart, tools_stdio.dart); nothing
// of it on the web.
import 'tools_host_stub.dart'
    if (dart.library.io) 'tools_host_io.dart'
    as platform;

/// Whether [arguments] ask for the MCP server alone ([ToolsProtocol.flag]).
bool runsToolsStdio(List<String> arguments) =>
    platform.runsToolsStdio(arguments);

/// Serves on stdin/stdout, then exits the native host's event loop too.
Future<void> runToolsStdio(List<String> arguments) =>
    platform.runToolsStdio(arguments);

/// Listens for the agents' processes, to answer with the app's tools.
Future<void> startToolsBridge() => platform.startToolsBridge();

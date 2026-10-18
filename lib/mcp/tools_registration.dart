import '../customize/customization_store.dart';
import 'tools_protocol.dart';

/// Persists the built-in tools as a user-level stdio MCP server. The launcher
/// discovers the running bridge through [dataDirectory]; no session credentials,
/// bridge address, project directory, or other transient state is stored here.
Future<UserMcpRegistration> registerBaocodeTools({
  required CustomizationStore store,
  required String command,
  required String dataDirectory,
}) => store.registerUserMcp(
  'baocode',
  {
    'command': command,
    'args': [ToolsProtocol.flag],
    'env': {ToolsProtocol.dataDirectoryVariable: dataDirectory},
  },
  isManaged: (configuration) {
    final args = configuration['args'];
    final env = configuration['env'];
    return args is List<Object?> &&
        args.contains(ToolsProtocol.flag) &&
        env is Map<String, Object?> &&
        env[ToolsProtocol.dataDirectoryVariable] is String &&
        (env[ToolsProtocol.dataDirectoryVariable] as String).isNotEmpty;
  },
);

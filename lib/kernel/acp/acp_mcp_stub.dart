import '../agent_kernel.dart';
import 'acp_mcp.dart';

Future<AcpMcpServers> loadAcpMcpServers(
  KernelContext context,
  Map<String, Object?> capabilities, {
  Map<String, String> environment = const {},
}) async => const AcpMcpServers();

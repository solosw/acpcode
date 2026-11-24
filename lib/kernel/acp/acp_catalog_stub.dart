import '../agent_kernel.dart';
import 'acp_transport.dart';

/// No ACP session index on the web.
class AcpCatalog implements SessionCatalog {
  const AcpCatalog({
    required this.agentId,
    this.file,
    AcpTransportFactory? start,
    Duration discoveryTimeout = const Duration(seconds: 10),
  });

  final String agentId;
  final String? file;

  @override
  Future<List<ProjectRecord>> projects() async => const [];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id, {String? cwd}) async {}

  Future<bool> discover({String? location}) async => false;

  /// Remembers [session] so the sidebar can open it again after a restart.
  Future<void> upsert(SessionRecord session) async {}
}

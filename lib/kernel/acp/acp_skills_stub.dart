import '../agent_kernel.dart';
import '../extension_switches.dart';
import 'acp_skills.dart';

Future<AcpSkills> loadAcpSkills(
  KernelContext context, {
  Map<String, String> environment = const {},
  ExtensionSwitches? switches,
}) async => const AcpSkills();

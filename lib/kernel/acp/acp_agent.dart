import '../../remote/remote_acp.dart';
import '../../remote/remote_location.dart';
import 'acp_transport.dart';

/// Configuration for one ACP agent executable.
class AcpAgentConfig {
  const AcpAgentConfig({
    required this.id,
    required this.label,
    required this.command,
    this.arguments = const [],
    this.environment = const {},
    this.description = 'Agent Client Protocol agent',
    this.skillsDirectory = '',
    this.rulesDirectory = '',
    this.hostScoped = false,
    this.hostConfigurations = const {},
  });

  final String id;
  final String label;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String description;

  /// User customization destinations on the agent's host. Empty disables copying.
  final String skillsDirectory;
  final String rulesDirectory;

  /// New configurations never reuse a local executable or credentials remotely.
  /// Legacy entries retain their original cross-host behavior until scoped.
  final bool hostScoped;
  final Map<String, AcpAgentConfig> hostConfigurations;

  AcpAgentConfig forHost(String? host) {
    if (host != null && host.isNotEmpty) {
      if (hostConfigurations[host] case final config?) return config;
      if (hostScoped || hostConfigurations.isNotEmpty) {
        throw StateError(
          'ACP agent "$label" is not configured on $host. '
          'Install or configure it in Settings → Agents.',
        );
      }
    }
    if (command.trim().isEmpty) {
      throw StateError(
        'ACP agent "$label" is not configured on this machine. '
        'Install or configure it in Settings → Agents.',
      );
    }
    return this;
  }

  /// On the project's host: this machine, or the remote one an `ssh://`
  /// project names. Slash commands come from that process.
  AcpTransportFactory get transport => (context) async {
    final host = context.cwd == null
        ? null
        : RemoteLocation.hostOf(context.cwd!);
    final config = forHost(host);
    return startAcpAgent(
      config.command,
      arguments: config.arguments,
      location: context.cwd,
      environment: config.environment.isEmpty ? null : config.environment,
    );
  };
}

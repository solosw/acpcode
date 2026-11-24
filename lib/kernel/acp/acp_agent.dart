import '../../remote/remote_acp.dart';
import '../../remote/remote_acp_registry.dart';
import '../../remote/ssh_host.dart';
import '../../remote/remote_location.dart';
import '../acp_registry.dart';
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
    this.registry,
    this.registryImported = false,
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
  final AcpRegistryEntry? registry;

  /// Whether updates should edit the saved JSON instead of the public catalog.
  final bool registryImported;
  final Map<String, AcpAgentConfig> hostConfigurations;

  AcpAgentConfig copyWith({
    String? id,
    String? label,
    String? rulesDirectory,
    bool? hostScoped,
    Map<String, AcpAgentConfig>? hostConfigurations,
    AcpRegistryEntry? registry,
    bool? registryImported,
  }) => AcpAgentConfig(
    id: id ?? this.id,
    label: label ?? this.label,
    command: command,
    arguments: arguments,
    environment: environment,
    description: description,
    skillsDirectory: skillsDirectory,
    rulesDirectory: rulesDirectory ?? this.rulesDirectory,
    hostScoped: hostScoped ?? this.hostScoped,
    hostConfigurations: hostConfigurations ?? this.hostConfigurations,
    registry: registry ?? this.registry,
    registryImported: registryImported ?? this.registryImported,
  );

  AcpAgentConfig forHost(String? host) {
    if (host != null && host.isNotEmpty) {
      if (hostConfigurations[host] case final config?) {
        return config.command.isEmpty &&
                config.registry == null &&
                registry != null
            ? config.copyWith(registry: registry)
            : config;
      }
      if (registry != null) return this;
      if (hostScoped || hostConfigurations.isNotEmpty) {
        throw StateError(
          'ACP agent "$label" is not configured on $host. '
          'Install or configure it in Settings → Agents.',
        );
      }
    }
    if (registry == null && command.trim().isEmpty) {
      throw StateError(
        'ACP agent "$label" is not configured on this machine. '
        'Install or configure it in Settings → Agents.',
      );
    }
    return this;
  }

  Future<Map<String, String>> environmentAt(String? location) async {
    final host = location == null ? null : RemoteLocation.hostOf(location);
    final config = forHost(host);
    final entry = config.registry;
    if (entry == null) return config.environment;
    final installer = host == null
        ? const AcpRegistry()
        : RemoteAcpRegistry(await SshHosts.instance[host].ready);
    return {
      ...?installer.launchPlan(entry)?.environment,
      ...config.environment,
    };
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
      registry: config.registry,
      arguments: config.arguments,
      location: context.cwd,
      environment: config.environment.isEmpty ? null : config.environment,
    );
  };
}

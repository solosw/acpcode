import 'dart:async';

import 'package:flutter/material.dart';

import '../../customize/customization_store.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_agents.dart';
import '../../kernel/acp_registry.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../workspace/window_controls.dart';
import 'agent_edit_dialog.dart';
import '../../remote/remote_acp_registry.dart';
import 'agent_remote_folder_dialog.dart';
import 'settings_widgets.dart';

export 'agent_edit_dialog.dart' show formatEnvironment, parseEnvironment;

class AgentsSettingsPage extends StatelessWidget {
  const AgentsSettingsPage({
    super.key,
    required this.agents,
    this.customizations,
    this.hosts = const [],
    this.pickDirectory,
    this.registry = const AcpRegistry(),
    this.initialHost = '',
    this.connectRegistry = RemoteAcpRegistry.connect,
    this.pickRemoteDirectory = showAgentRemoteFolderDialog,
  });

  final AcpAgents agents;
  final CustomizationStore? customizations;
  final List<String> hosts;
  final Future<String?> Function()? pickDirectory;
  final AcpRegistry registry;
  final String initialHost;
  final Future<AcpRegistry> Function(String, AcpRegistry, bool) connectRegistry;
  final Future<String?> Function(BuildContext, String) pickRemoteDirectory;

  Future<void> _edit(BuildContext context, [AcpAgentConfig? agent]) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AgentEditDialog(
          agent: agent,
          customizations: customizations ?? CustomizationStore(),
          hosts: hosts,
          initialHost: initialHost,
          connectRegistry: connectRegistry,
          pickRemoteDirectory: pickRemoteDirectory,
          registry: registry,
          pickDirectory: pickDirectory ?? WindowControls.pickDirectory,
          onSave: (updated) => agent == null
              ? agents.add(
                  AcpAgentConfig(
                    id: agents.newId(updated.label),
                    label: updated.label,
                    command: updated.command,
                    arguments: updated.arguments,
                    environment: updated.environment,
                    description: updated.description,
                    skillsDirectory: updated.skillsDirectory,
                    rulesDirectory: updated.rulesDirectory,
                    hostScoped: updated.hostScoped,
                    hostConfigurations: updated.hostConfigurations,
                  ),
                )
              : agents.save([
                  for (final item in agents.agents)
                    item.id == agent.id ? updated : item,
                ]),
        ),
      );

  Future<void> _delete(BuildContext context, AcpAgentConfig agent) async {
    final l10n = context.l10n;
    final confirmed = await showIdeDialog(
      context,
      message: '${l10n.agentsDelete}: ${agent.label}',
      detail: l10n.agentsDeleteDetail,
      buttons: [l10n.commonDelete],
    );
    if (confirmed != 0) return;
    try {
      await agents.remove(agent.id);
    } catch (error) {
      if (context.mounted) {
        await showIdeDialog(
          context,
          message: '$error',
          buttons: [l10n.commonOk],
          cancel: null,
          type: IdeDialogType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: agents,
    builder: (context, _) {
      final l10n = context.l10n;
      return SettingsPage(
        title: 'Agents',
        description: l10n.agentsDescription,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IdeButton(
              label: l10n.agentsAdd,
              icon: Codicons.add,
              onPressed: () => unawaited(_edit(context)),
            ),
          ),
          SettingsGroup(
            title: 'ACP Agents',
            children: [
              if (agents.agents.isEmpty)
                SettingsRow(
                  label: l10n.agentsEmpty,
                  description: l10n.agentsEmptyDetail,
                ),
              for (final agent in agents.agents)
                SettingsRow(
                  key: ValueKey(agent.id),
                  label: agent.label,
                  description: agent.description,
                  below: [
                    Text(
                      [
                        if (agent.command.isNotEmpty)
                          [agent.command, ...agent.arguments].join(' '),
                        for (final host in agent.hostConfigurations.keys)
                          'SSH: $host',
                      ].join(' · '),
                      style: SettingsText.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IdeButton(
                        label: l10n.agentsEdit,
                        icon: Codicons.edit,
                        secondary: true,
                        onPressed: () => unawaited(_edit(context, agent)),
                      ),
                      const SizedBox(width: 8),
                      IdeButton(
                        label: l10n.commonDelete,
                        icon: Codicons.trash,
                        secondary: true,
                        onPressed: () => unawaited(_delete(context, agent)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}

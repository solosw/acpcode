import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat/chat_session.dart';
import '../../ide/ide_menu.dart';
import '../../kernel/agent_kernel.dart';
import '../../kernel/kernel_registry.dart';
import '../../kernel/kernel_types.dart';
import '../../l10n/l10n.dart';
import '../../workspace/workspace.dart';
import '../chat_defaults.dart';
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// New-chat defaults, separate from the choices of existing conversations.
class ChatDefaultsCard extends StatelessWidget {
  const ChatDefaultsCard({super.key, this.settings, this.workspace});

  final UserSettings? settings;
  final Workspace? workspace;

  void _write(String key, Object? value) {
    unawaited(
      settings?.update(key, value).catchError((Object error) {
        debugPrint('$key not kept: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, workspace]),
    builder: (context, _) {
      final l10n = context.l10n;
      final kernels = workspace?.kernels ?? KernelRegistry.all;
      final selected = ChatDefaults.agent(settings);
      final configured = kernels.where((k) => k.id == selected).firstOrNull;
      final kernel = configured ?? workspace?.preferredKernel ?? kernels.first;
      final cwd =
          workspace?.current?.project.path ??
          workspace?.projects.firstOrNull?.path;
      return SettingsCard(
        children: [
          SettingsRow(
            label: l10n.generalSettingsDefaultAgent,
            description: l10n.generalSettingsDefaultAgentDescription,
            trailing: SettingsDropdown(
              current: configured?.label ?? l10n.generalSettingsLastUsed,
              semanticLabel: l10n.generalSettingsDefaultAgent,
              entries: () => [
                IdeMenuAction(
                  l10n.generalSettingsLastUsed,
                  checked: configured == null,
                  onSelected: () => _write(ChatDefaults.agentKey, null),
                ),
                for (final descriptor in kernels)
                  IdeMenuAction(
                    descriptor.label,
                    checked: descriptor.id == configured?.id,
                    onSelected: () =>
                        _write(ChatDefaults.agentKey, descriptor.id),
                  ),
              ],
            ),
          ),
          _DefaultModeRow(
            key: ValueKey((kernel.id, cwd)),
            kernel: kernel,
            cwd: cwd,
            settings: settings,
            onSelected: (mode) {
              final modes = ChatDefaults.modes(settings);
              if (mode == null) {
                modes.remove(kernel.id);
              } else {
                modes[kernel.id] = mode;
              }
              _write(ChatDefaults.modesKey, modes.isEmpty ? null : modes);
            },
          ),
        ],
      );
    },
  );
}

class _DefaultModeRow extends StatefulWidget {
  const _DefaultModeRow({
    super.key,
    required this.kernel,
    required this.cwd,
    required this.settings,
    required this.onSelected,
  });

  final KernelDescriptor kernel;
  final String? cwd;
  final UserSettings? settings;
  final ValueChanged<String?> onSelected;

  @override
  State<_DefaultModeRow> createState() => _DefaultModeRowState();
}

class _DefaultModeRowState extends State<_DefaultModeRow> {
  late final ChatSession _preview;

  @override
  void initState() {
    super.initState();
    _preview = ChatSession(
      kernel: widget.kernel,
      kernels: [widget.kernel],
      kernelContext: KernelContext(cwd: widget.cwd),
      historyCount: 0,
    );
    // Native modes are available without starting a process. ACP modes are
    // reported by the agent, as in the scheduled task configuration preview.
    if (_preview.modes == null && widget.cwd != null) _preview.attach();
  }

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _preview,
    builder: (context, _) {
      final l10n = context.l10n;
      final options = _preview.modes?.options ?? const <KernelOption>[];
      final selected = ChatDefaults.modes(widget.settings)[widget.kernel.id];
      final current = options.where((mode) => mode.id == selected).firstOrNull;
      return SettingsRow(
        label: l10n.generalSettingsDefaultMode,
        description: l10n.generalSettingsDefaultModeDescription(
          widget.kernel.label,
        ),
        below: [
          if (options.isEmpty)
            Text(
              _preview.health.message ??
                  l10n.generalSettingsDefaultModeUnavailable,
              style: SettingsText.description,
            ),
        ],
        trailing: SettingsDropdown(
          current: current?.label ?? selected ?? l10n.generalSettingsLastUsed,
          semanticLabel: l10n.generalSettingsDefaultMode,
          entries: () => [
            IdeMenuAction(
              l10n.generalSettingsLastUsed,
              checked: selected == null,
              onSelected: () => widget.onSelected(null),
            ),
            for (final mode in options)
              IdeMenuAction(
                mode.label,
                checked: mode.id == selected,
                onSelected: () => widget.onSelected(mode.id),
              ),
          ],
        ),
      );
    },
  );
}

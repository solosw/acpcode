import 'dart:async';

import 'package:flutter/material.dart';

import '../../customize/customization_directory_copy.dart';
import '../../customize/customization_store.dart';
import '../../customize/customizations.dart';
import '../../ide/ide_button.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../remote/remote_customization_disk.dart';
import '../../remote/ssh_host.dart';
import 'settings_widgets.dart';

/// Explicit, host-local copying. Opening settings never writes customizations.
class AgentCustomizationCopy extends StatefulWidget {
  const AgentCustomizationCopy({
    super.key,
    required this.agent,
    required this.store,
    this.enabled = true,
    this.host,
  });

  final AcpAgentConfig agent;
  final CustomizationStore store;
  final bool enabled;
  final String? host;

  @override
  State<AgentCustomizationCopy> createState() => _AgentCustomizationCopyState();
}

class _AgentCustomizationCopyState extends State<AgentCustomizationCopy> {
  bool _busy = false;
  String? _status;

  @override
  void didUpdateWidget(AgentCustomizationCopy oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.rulesDirectory != widget.agent.rulesDirectory) {
      _status = null;
    }
  }

  Future<void> _preview() async {
    final directory = widget.agent.rulesDirectory;
    final host = widget.host;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final copier = CustomizationDirectoryCopy(
        host == null
            ? widget.store
            : CustomizationStore(
                disk: RemoteCustomizationDisk(SshHosts.instance[host]),
              ),
      );
      final plan = await copier.preview(CustomizationKind.rules, directory);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Copy user rules'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    'Source: ${plan.sourceRoot}\nTarget: ${plan.targetRoot}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    [
                      for (final action in CustomizationCopyAction.values)
                        '${action.name}: ${plan.count(action)}',
                    ].join(' · '),
                  ),
                  const SizedBox(height: 12),
                  if (plan.entries.isEmpty)
                    const Text('No user content to copy.'),
                  for (final entry in plan.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(
                        '${entry.action.name}: ${entry.relativePath}'
                        '${entry.directory ? "/" : ""}'
                        '${entry.reason.isEmpty ? "" : " — ${entry.reason}"}',
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Existing unowned or externally modified files are never '
                    'overwritten. Stale files are kept.',
                  ),
                  if (plan.hasConflicts)
                    const Text(
                      'Resolve conflicts in the target directory, then preview again.',
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: plan.hasConflicts || !plan.hasChanges
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Copy'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      if (!widget.enabled ||
          widget.host != host ||
          widget.agent.rulesDirectory != directory) {
        throw StateError('Settings changed; preview again before copying');
      }
      await copier.apply(plan);
      if (mounted) {
        setState(
          () => _status =
              'Copied user rules to ${host ?? 'this machine'}. '
              'Start a new agent session if needed. Loading depends on the agent.',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _status =
              'Copy failed: $error\n'
              'If copying had started, some files may already be copied. Preview again to continue.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsRow(
    label: 'Copy rules',
    below: [
      const Text(
        'Copy the user rules folder and user CLAUDE.md to the rules directory. Check that the agent reads this layout.',
      ),
      if (!widget.enabled)
        const Text('Save the agent settings before previewing.'),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: IdeButton(
          label: 'Preview rules copy',
          secondary: true,
          onPressed:
              !widget.enabled ||
                  _busy ||
                  widget.agent.rulesDirectory.trim().isEmpty
              ? null
              : () => unawaited(_preview()),
        ),
      ),
      if (_busy) const Text('Preparing or copying rules…'),
      if (_status case final status?) SelectableText(status),
    ],
  );
}

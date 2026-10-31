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
    this.hosts = const [],
    this.enabled = true,
    this.fixedHost,
  });

  final AcpAgentConfig agent;
  final CustomizationStore store;
  final List<String> hosts;
  final bool enabled;
  final String? fixedHost;

  @override
  State<AgentCustomizationCopy> createState() => _AgentCustomizationCopyState();
}

class _AgentCustomizationCopyState extends State<AgentCustomizationCopy> {
  late String _host = widget.fixedHost ?? '';
  bool _busy = false;
  String? _status;

  @override
  void didUpdateWidget(AgentCustomizationCopy oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fixedHost case final host?) {
      _host = host;
    } else if (_host.isNotEmpty && !widget.hosts.contains(_host)) {
      _host = '';
    }
    if (oldWidget.agent.skillsDirectory != widget.agent.skillsDirectory ||
        oldWidget.agent.rulesDirectory != widget.agent.rulesDirectory) {
      _status = null;
    }
  }

  Future<void> _preview(CustomizationKind kind) async {
    final directory = kind == CustomizationKind.skills
        ? widget.agent.skillsDirectory
        : widget.agent.rulesDirectory;
    final selectedHost = _host;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final store = selectedHost.isEmpty
          ? widget.store
          : CustomizationStore(
              disk: RemoteCustomizationDisk(SshHosts.instance[selectedHost]),
            );
      final copier = CustomizationDirectoryCopy(store);
      final plan = await copier.preview(kind, directory);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Copy user ${kind.name}'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    'Host: ${selectedHost.isEmpty ? "This machine" : selectedHost}\n'
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
                    'overwritten. Stale files are kept. Nothing is uploaded between hosts.',
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
      final currentDirectory = kind == CustomizationKind.skills
          ? widget.agent.skillsDirectory
          : widget.agent.rulesDirectory;
      if (!widget.enabled ||
          currentDirectory != directory ||
          _host != selectedHost) {
        throw StateError('Settings changed; preview again before copying');
      }
      await copier.apply(plan);
      if (mounted) {
        setState(
          () => _status =
              'Copied user ${kind.name} on ${selectedHost.isEmpty ? "this machine" : selectedHost}. '
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
    label: 'Copy customizations',
    below: [
      const Text(
        'Manual copy only. Blank destinations disable copying. Skills include '
        'all resources. Rules include the rules folder contents and user CLAUDE.md '
        '(as CLAUDE.md), unchanged. Confirm that the agent reads this layout; '
        'copying does not guarantee loading. Rule conditions and relative '
        'references are not rewritten.',
      ),
      if (widget.fixedHost == null && widget.hosts.isNotEmpty)
        DropdownButton<String>(
          value: _host,
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('This machine')),
            for (final host in widget.hosts)
              DropdownMenuItem(value: host, child: Text('SSH: $host')),
          ],
          onChanged: _busy
              ? null
              : (host) => setState(() {
                  _host = host ?? '';
                  _status = null;
                }),
        ),
      if (!widget.enabled)
        const Text('Save the agent settings before previewing.'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in [
            CustomizationKind.skills,
            CustomizationKind.rules,
          ])
            IdeButton(
              label: 'Preview ${kind.name} copy',
              secondary: true,
              onPressed:
                  !widget.enabled ||
                      _busy ||
                      (kind == CustomizationKind.skills
                              ? widget.agent.skillsDirectory
                              : widget.agent.rulesDirectory)
                          .trim()
                          .isEmpty
                  ? null
                  : () => unawaited(_preview(kind)),
            ),
        ],
      ),
      if (_busy) const Text('Preparing or copying customizations…'),
      if (_status case final status?) SelectableText(status),
    ],
  );
}

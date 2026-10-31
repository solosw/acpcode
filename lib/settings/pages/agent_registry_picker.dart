import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../ide/ide_input.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_registry.dart';
import '../../l10n/l10n.dart';
import '../../remote/remote_acp_registry.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'settings_widgets.dart';

class AgentRegistryPicker extends StatefulWidget {
  const AgentRegistryPicker({
    super.key,
    required this.registry,
    required this.onInstalled,
    required this.onBusy,
    this.host = '',
    this.connectRegistry = RemoteAcpRegistry.connect,
  });
  final AcpRegistry registry;
  final String host;
  final Future<AcpRegistry> Function(String, AcpRegistry, bool) connectRegistry;
  final ValueChanged<AcpAgentConfig> onInstalled;
  final ValueChanged<bool> onBusy;

  @override
  State<AgentRegistryPicker> createState() => _AgentRegistryPickerState();
}

class _AgentRegistryPickerState extends State<AgentRegistryPicker> {
  final _search = TextEditingController();
  List<AcpRegistryEntry>? _entries;
  AcpRegistryEntry? _selected;
  String? _error;
  bool _busy = false;
  bool _useNetworkSettings = true;
  String? _targetPlatform;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _entries = null;
    });
    try {
      final target = widget.host.isEmpty
          ? widget.registry
          : await widget.connectRegistry(
              widget.host,
              widget.registry,
              _useNetworkSettings,
            );
      final entries = await widget.registry.load();
      _targetPlatform = target.platform;
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _install() async {
    final entry = _selected;
    if (entry == null || _busy) return;
    final plan = entry.planFor(_targetPlatform ?? 'unsupported');
    if (plan == null) return;
    final l10n = context.l10n;
    final confirmed = await showIdeDialog(
      context,
      message: '${l10n.agentsInstall}: ${entry.name}',
      detail:
          '${l10n.agentsRegistryTrust}\n\n'
          '${l10n.agentsInstallTarget}: ${widget.host.isEmpty ? l10n.agentsLocalTarget : widget.host}\n'
          '${widget.host.isEmpty ? '' : '${_useNetworkSettings ? l10n.agentsUseNetworkSettings : l10n.agentsUseServerNetwork}\n'}'
          '${l10n.agentsSource}: ${plan.source}\n'
          '${l10n.agentsLaunch}: ${plan.launchPreview}\n'
          '${plan.environment.entries.map((e) => "${e.key}=${e.value}").join("\n")}',
      buttons: [l10n.agentsInstall],
    );
    if (!mounted || confirmed != 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusy(true);
    try {
      final target = widget.host.isEmpty
          ? widget.registry
          : await widget.connectRegistry(
              widget.host,
              widget.registry,
              _useNetworkSettings,
            );
      if (target.platform != _targetPlatform) {
        throw StateError('Remote platform changed; select the agent again.');
      }
      final config = await target.install(entry);
      if (mounted) {
        widget.onBusy(false);
        widget.onInstalled(config);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '${l10n.agentsInstallFailed}\n$error';
        });
        widget.onBusy(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = _entries;
    final query = _search.text.trim().toLowerCase();
    final filtered = entries
        ?.where(
          (entry) => '${entry.name} ${entry.id} ${entry.description}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final selected = _selected;
    final plan = selected?.planFor(_targetPlatform ?? 'unsupported');
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.host.isNotEmpty) ...[
            DropdownButton<bool>(
              key: const ValueKey('agent-install-network'),
              value: _useNetworkSettings,
              isExpanded: true,
              items: [
                DropdownMenuItem(
                  value: true,
                  child: Text(l10n.agentsUseNetworkSettings),
                ),
                DropdownMenuItem(
                  value: false,
                  child: Text(l10n.agentsUseServerNetwork),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) =>
                        setState(() => _useNetworkSettings = value ?? true),
            ),
            Text(l10n.agentsRemoteInstallHint, style: SettingsText.description),
            if (_targetPlatform case final target?)
              Text(target, style: SettingsText.path),
            const SizedBox(height: 8),
          ],
          Text(l10n.agentsRegistryDescription, style: SettingsText.description),
          const SizedBox(height: 12),
          IdeInputBox(
            controller: _search,
            placeholder: l10n.agentsSearch,
            semanticsLabel: l10n.agentsSearch,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (entries == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (filtered != null)
            SizedBox(
              height: 220,
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        l10n.agentsNoResults,
                        style: SettingsText.description,
                      ),
                    ),
                  for (final entry in filtered)
                    ListTile(
                      key: ValueKey('registry-${entry.id}'),
                      enabled: !_busy,
                      selected: selected == entry,
                      selectedTileColor: SettingsColors.hover,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      leading: Icon(
                        Codicons.hubot,
                        size: 20,
                        color: SettingsColors.iconTertiary,
                      ),
                      title: Text(entry.name, style: SettingsText.label),
                      subtitle: Text(
                        entry.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: SettingsText.description,
                      ),
                      trailing: Text(
                        entry.version,
                        style: SettingsText.description,
                      ),
                      onTap: () => setState(() {
                        _selected = entry;
                        _error = null;
                      }),
                    ),
                ],
              ),
            ),
          if (selected != null) ...[
            const Divider(),
            Text(
              '${selected.name} · ${selected.version}',
              style: SettingsText.heading,
            ),
            const SizedBox(height: 6),
            if (plan == null)
              Text(l10n.agentsUnsupported, style: SettingsText.description)
            else ...[
              SelectableText(
                '${l10n.agentsSource}: ${plan.source}',
                style: SettingsText.description,
              ),
              const SizedBox(height: 6),
              SelectableText(plan.launchPreview, style: SettingsText.path),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: IdeButton(
                label: _busy ? l10n.agentsInstalling : l10n.agentsInstall,
                spinning: _busy,
                onPressed: _busy || plan == null
                    ? null
                    : () => unawaited(_install()),
              ),
            ),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 100,
              child: SingleChildScrollView(
                child: Text(
                  entries == null
                      ? '${l10n.agentsRegistryUnavailable}\n$error'
                      : error,
                  style: TextStyle(
                    color: themeColors['errorForeground'],
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            if (entries == null)
              Align(
                alignment: Alignment.centerRight,
                child: IdeButton(
                  label: l10n.agentsRetry,
                  onPressed: () => unawaited(_load()),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

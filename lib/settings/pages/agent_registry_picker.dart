import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_registry.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'settings_widgets.dart';

class AgentRegistryPicker extends StatefulWidget {
  const AgentRegistryPicker({
    super.key,
    required this.registry,
    required this.onInstalled,
    required this.onBusy,
  });

  final AcpRegistry registry;
  final ValueChanged<AcpAgentConfig> onInstalled;
  final ValueChanged<bool> onBusy;

  @override
  State<AgentRegistryPicker> createState() => _AgentRegistryPickerState();
}

class _AgentRegistryPickerState extends State<AgentRegistryPicker> {
  final _search = TextEditingController();
  final _json = TextEditingController(text: _npmTemplate);
  String _template = _npmTemplate;
  List<AcpRegistryEntry>? _entries;
  List<AcpRegistryEntry>? _imported;
  AcpRegistryEntry? _selected;
  String? _loadError;
  String? _error;
  bool _importing = false;
  bool _busy = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    _json.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _entries = null;
    });
    try {
      final entries = await widget.registry.load();
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  void _switchSource() => setState(() {
    _importing = !_importing;
    _selected = _importing && _imported?.length == 1 ? _imported!.single : null;
    _search.clear();
    _error = null;
  });

  Future<void> _useTemplate(String template) async {
    if (_json.text == template) return;
    if (_json.text.trim().isNotEmpty && _json.text != _template) {
      final l10n = context.l10n;
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.agentsRegistryReplaceTemplate),
          actions: [
            IdeButton(
              label: l10n.commonCancel,
              secondary: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            IdeButton(
              label: l10n.agentsRegistryUseTemplate,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );
      if (!mounted || replace != true) return;
    }
    setState(() {
      _template = _json.text = template;
      _resetPreview();
    });
  }

  void _resetPreview() {
    _imported = null;
    _selected = null;
    _error = null;
  }

  void _previewImport() {
    final l10n = context.l10n;
    try {
      final imported = AcpRegistryEntry.parseImport(jsonDecode(_json.text));
      if (imported.isEmpty) throw FormatException(l10n.agentsRegistryJsonEmpty);
      setState(() {
        _imported = imported;
        _selected = imported.length == 1 ? imported.single : null;
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() {
        _imported = null;
        _selected = null;
        _error = '${l10n.agentsRegistryJsonInvalid}\n$error';
      });
    }
  }

  List<AcpInstallPlan> _plans(AcpRegistryEntry entry) {
    final runner = entry.runnerPlan;
    return [?runner, ...entry.binaryPlans];
  }

  Future<void> _install(
    AcpRegistryEntry entry,
    List<AcpInstallPlan> plans,
  ) async {
    if (_busy || _confirming) return;
    final l10n = context.l10n;
    _confirming = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(entry.name),
        content: SelectableText(
          [
            l10n.agentsRegistryTrust,
            if (plans.any((plan) => plan.kind == 'binary'))
              l10n.agentsRegistryPlatformDownloads
            else
              l10n.agentsRegistryRunner,
            for (final plan in plans)
              [
                '${l10n.agentsSource}: ${plan.source}',
                '${l10n.agentsLaunch}: ${plan.launchPreview}',
                for (final e in plan.environment.entries) '${e.key}=${e.value}',
              ].join('\n'),
          ].join('\n\n'),
        ),
        actions: [
          IdeButton(
            label: l10n.commonCancel,
            secondary: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          IdeButton(
            label: l10n.agentsInstall,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    _confirming = false;
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusy(true);
    try {
      final config = await widget.registry.cache(entry);
      if (mounted) {
        setState(() => _busy = false);
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
    final entries = _importing ? _imported : _entries;
    final query = _search.text.trim().toLowerCase();
    final filtered = entries
        ?.where(
          (entry) => '${entry.name} ${entry.id} ${entry.description}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final selected = _selected;
    final plans = selected == null
        ? const <AcpInstallPlan>[]
        : _plans(selected);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IdeButton(
              label: _importing
                  ? l10n.agentsRegistryBrowse
                  : l10n.agentsRegistryPasteJson,
              secondary: true,
              onPressed: _busy ? null : _switchSource,
            ),
          ),
          const SizedBox(height: 12),
          if (_importing) ...[
            Text(l10n.agentsRegistryJsonHint, style: SettingsText.description),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (label, template) in [
                  (l10n.agentsRegistryNpmTemplate, _npmTemplate),
                  (l10n.agentsRegistryUvTemplate, _uvTemplate),
                  (l10n.agentsRegistryBinaryTemplate, _binaryTemplate),
                ])
                  IdeButton(
                    label: label,
                    secondary: true,
                    onPressed: _busy
                        ? null
                        : () => unawaited(_useTemplate(template)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ExcludeFocus(
              excluding: _busy,
              child: IgnorePointer(
                ignoring: _busy,
                child: IdeInputBox(
                  key: const ValueKey('registry-json'),
                  controller: _json,
                  semanticsLabel: l10n.agentsRegistryPasteJson,
                  minLines: 5,
                  maxLines: 7,
                  onChanged: (_) => setState(_resetPreview),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: IdeButton(
                label: l10n.agentsRegistryPreviewJson,
                secondary: true,
                onPressed: _busy || _json.text.trim().isEmpty
                    ? null
                    : _previewImport,
              ),
            ),
          ] else ...[
            Text(
              l10n.agentsRegistryDescription,
              style: SettingsText.description,
            ),
            const SizedBox(height: 12),
            IdeInputBox(
              controller: _search,
              placeholder: l10n.agentsSearch,
              semanticsLabel: l10n.agentsSearch,
              onChanged: (_) => setState(() {}),
            ),
            if (entries == null && _loadError == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_loadError case final error?) ...[
              _errorText('${l10n.agentsRegistryUnavailable}\n$error'),
              Align(
                alignment: Alignment.centerRight,
                child: IdeButton(
                  label: l10n.agentsRetry,
                  onPressed: () => unawaited(_load()),
                ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          if (filtered != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                primary: false,
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
            if (plans.isEmpty)
              Text(l10n.agentsUnsupported, style: SettingsText.description),
            if (plans.any((plan) => plan.kind == 'binary'))
              Text(
                l10n.agentsRegistryPlatformDownloads,
                style: SettingsText.description,
              ),
            for (final plan in plans) ...[
              const SizedBox(height: 6),
              SelectableText(
                '${l10n.agentsSource}: ${plan.source}',
                style: SettingsText.description,
              ),
              SelectableText(plan.launchPreview, style: SettingsText.path),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: IdeButton(
                label: _busy ? l10n.agentsInstalling : l10n.agentsInstall,
                spinning: _busy,
                onPressed: _busy || plans.isEmpty
                    ? null
                    : () => unawaited(_install(selected, plans)),
              ),
            ),
          ],
          if (_error case final error?) _errorText(error),
        ],
      ),
    );
  }

  Widget _errorText(String error) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      error,
      style: TextStyle(color: themeColors['errorForeground'], fontSize: 12),
    ),
  );
}

final _npmTemplate = _registryTemplate({
  'npx': {'package': '<npm-package>@1.0.0', 'args': [], 'env': {}},
});

final _uvTemplate = _registryTemplate({
  'uvx': {'package': '<python-package>==1.0.0', 'args': [], 'env': {}},
});

final _binaryTemplate = _registryTemplate({
  'binary': {
    'linux-x86_64': {
      'archive': '<HTTPS link to the Linux .tar.gz>',
      'cmd': './my-agent',
      'args': [],
      'env': {},
    },
    'windows-x86_64': {
      'archive': '<HTTPS link to the Windows .zip>',
      'cmd': './my-agent.exe',
      'args': [],
      'env': {},
    },
  },
});

String _registryTemplate(Map<String, Object?> distribution) =>
    const JsonEncoder.withIndent('  ').convert({
      'id': 'my-agent',
      'name': 'My Agent',
      'description': 'My ACP agent',
      'version': '1.0.0',
      'distribution': distribution,
    });

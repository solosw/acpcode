import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../customize/customization_store.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_registry.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'agent_customization_copy.dart';
import 'agent_registry_picker.dart';
import 'agent_remote_folder_dialog.dart';
import 'settings_widgets.dart';

class AgentEditDialog extends StatefulWidget {
  const AgentEditDialog({
    super.key,
    this.agent,
    required this.onSave,
    this.hosts = const [],
    this.initialHost = '',
    this.pickRemoteDirectory = showAgentRemoteFolderDialog,
    required this.customizations,
    required this.registry,
  });

  final AcpAgentConfig? agent;
  final Future<void> Function(AcpAgentConfig) onSave;
  final List<String> hosts;
  final String initialHost;
  final Future<String?> Function(BuildContext, String) pickRemoteDirectory;
  final CustomizationStore customizations;
  final AcpRegistry registry;

  @override
  State<AgentEditDialog> createState() => _AgentEditDialogState();
}

enum _AgentEditMode { configuration, registry, update }

class _AgentEditDialogState extends State<AgentEditDialog> {
  final _label = TextEditingController();
  final _command = TextEditingController();
  final _arguments = TextEditingController(text: '[]');
  final _environment = TextEditingController();
  final _rules = TextEditingController();
  late AcpAgentConfig _config =
      widget.agent ?? const AcpAgentConfig(id: '', label: '', command: '');
  final _drafts = <String, AcpAgentConfig>{};
  late final String? _host;
  _AgentEditMode _mode = _AgentEditMode.configuration;
  bool _busy = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _drafts.addAll(_config.hostConfigurations);
    final current = widget.initialHost;
    _host = _drafts.containsKey(current)
        ? current
        : _drafts.keys.firstOrNull ??
              (current.isNotEmpty ? current : widget.hosts.firstOrNull);
    _label.text = _config.label;
    _fill(_drafts[_host]);
  }

  void _fill(AcpAgentConfig? agent) {
    _command.text = agent?.command ?? '';
    _arguments.text = jsonEncode(agent?.arguments ?? const []);
    _environment.text = formatEnvironment(agent?.environment ?? const {});
    _rules.text = agent?.rulesDirectory ?? '';
  }

  void _installed(AcpAgentConfig agent) => setState(() {
    if (_label.text.isEmpty) _label.text = agent.label;
    _config = _mode == _AgentEditMode.update
        ? _config.copyWith(
            registry: agent.registry,
            registryImported: agent.registryImported,
          )
        : agent.copyWith(id: _config.id);
    _mode = _AgentEditMode.configuration;
    _dirty = true;
    _error = null;
  });

  @override
  void dispose() {
    for (final controller in [
      _label,
      _command,
      _arguments,
      _environment,
      _rules,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed(String _) => setState(() {
    _dirty = true;
    _error = null;
  });

  Future<void> _pick(TextEditingController controller) async {
    final host = _host;
    if (host == null) return;
    try {
      final directory = await widget.pickRemoteDirectory(context, host);
      if (!mounted || directory == null) return;
      controller.text = directory;
      _changed(directory);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _saveDraft() {
    final host = _host;
    if (host == null) return;
    final l10n = context.l10n;
    final List<String> arguments;
    try {
      final parsed = jsonDecode(
        _arguments.text.trim().isEmpty ? '[]' : _arguments.text,
      );
      if (parsed is! List || parsed.any((item) => item is! String)) {
        throw const FormatException();
      }
      arguments = parsed.cast<String>();
    } on FormatException {
      throw FormatException(l10n.agentsInvalidArguments);
    }
    if (_environment.text
        .split('\n')
        .any(
          (line) =>
              line.trim().isNotEmpty &&
              (!line.contains('=') ||
                  line.substring(0, line.indexOf('=')).trim().isEmpty),
        )) {
      throw FormatException(l10n.agentsInvalidEnvironment);
    }
    final command = _command.text.trim();
    final rules = _rules.text.trim();
    final previous = _drafts[host];
    final environment =
        _environment.text ==
            formatEnvironment(previous?.environment ?? const {})
        ? previous?.environment ?? const <String, String>{}
        : parseEnvironment(_environment.text);
    final hasOptions =
        arguments.isNotEmpty || environment.isNotEmpty || rules.isNotEmpty;
    if (command.isEmpty && hasOptions && _config.registry == null) {
      throw FormatException(l10n.agentsRequired);
    }
    if (command.isEmpty && !hasOptions) {
      _drafts.remove(host);
      return;
    }
    _drafts[host] = AcpAgentConfig(
      id: _config.id,
      label: _label.text.trim(),
      command: command,
      arguments: arguments,
      environment: environment,
      rulesDirectory: rules,
      skillsDirectory: previous?.skillsDirectory ?? '',
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    try {
      if (_config.registry == null) _saveDraft();
      if (_label.text.trim().isEmpty ||
          (_config.command.isEmpty &&
              _config.registry == null &&
              _drafts.isEmpty)) {
        throw FormatException(context.l10n.agentsRequired);
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      await widget.onSave(
        _config.copyWith(
          label: _label.text.trim(),
          hostScoped: _config.hostScoped || _drafts.isNotEmpty,
          hostConfigurations: Map.of(_drafts),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is FormatException ? error.message : '$error';
        });
      }
    }
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String key, {
    String? hint,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SettingsText.label),
        const SizedBox(height: 6),
        IdeInputBox(
          key: ValueKey(key),
          controller: controller,
          semanticsLabel: label,
          placeholder: hint,
          minLines: lines,
          maxLines: lines == 1 ? 1 : 5,
          onChanged: _changed,
        ),
      ],
    ),
  );

  Widget _directory(
    String label,
    TextEditingController controller,
    String key,
  ) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SettingsText.label),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: IdeInputBox(
                key: ValueKey(key),
                controller: controller,
                semanticsLabel: label,
                onChanged: _changed,
              ),
            ),
            const SizedBox(width: 8),
            IdeButton(
              key: ValueKey('$key-browse'),
              label: l10n.agentsChooseFolder,
              icon: Codicons.folderOpened,
              secondary: true,
              onPressed: () => unawaited(_pick(controller)),
            ),
            if (controller.text.isNotEmpty) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: l10n.agentsClearFolder,
                icon: const Icon(Codicons.clearAll, size: 16),
                onPressed: () {
                  controller.clear();
                  _changed('');
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final configuring = _mode == _AgentEditMode.configuration;
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        backgroundColor: themeColors['editorWidget.background'],
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: SettingsColors.stroke),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 700,
            maxHeight: MediaQuery.sizeOf(context).height - 48,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Codicons.hubot,
                      size: 24,
                      color: SettingsColors.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.agent == null ? l10n.agentsAdd : l10n.agentsEdit,
                        style: SettingsText.title,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.commonClose,
                      icon: const Icon(Codicons.close, size: 18),
                      onPressed: _busy ? null : () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    IdeButton(
                      label: l10n.agentsCustom,
                      secondary: !configuring,
                      onPressed: _busy
                          ? null
                          : () => setState(
                              () => _mode = _AgentEditMode.configuration,
                            ),
                    ),
                    IdeButton(
                      label: l10n.agentsRegistry,
                      secondary: _mode != _AgentEditMode.registry,
                      onPressed: _busy
                          ? null
                          : () =>
                                setState(() => _mode = _AgentEditMode.registry),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Flexible(
                  child: !configuring
                      ? AgentRegistryPicker(
                          key: ValueKey(_mode),
                          registry: widget.registry,
                          currentEntry: _mode == _AgentEditMode.update
                              ? _config.registry
                              : null,
                          currentEntryImported:
                              _mode == _AgentEditMode.update &&
                              _config.registryImported,
                          onBusy: (busy) => setState(() => _busy = busy),
                          onInstalled: _installed,
                        )
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                l10n.agentsConnection,
                                style: SettingsText.heading,
                              ),
                              const SizedBox(height: 14),
                              _field(l10n.agentsName, _label, 'agent-name'),
                              if (_config.registry case final entry?) ...[
                                Text(
                                  '${l10n.agentsRegistry} · ${entry.name} ${entry.version}',
                                  style: SettingsText.label,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  entry.binaryPlans.isEmpty
                                      ? l10n.agentsRegistryRunner
                                      : l10n.agentsRegistryPlatformDownloads,
                                  style: SettingsText.description,
                                ),
                                if (widget.agent != null) ...[
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: IdeButton(
                                      label: l10n.agentsUpdate,
                                      secondary: true,
                                      onPressed: _busy
                                          ? null
                                          : () => setState(
                                              () =>
                                                  _mode = _AgentEditMode.update,
                                            ),
                                    ),
                                  ),
                                ],
                              ] else if (_host == null)
                                Text(
                                  l10n.agentsNoServers,
                                  style: SettingsText.description,
                                )
                              else ...[
                                _field(
                                  l10n.agentsCommand,
                                  _command,
                                  'agent-command',
                                ),
                                _field(
                                  l10n.agentsArguments,
                                  _arguments,
                                  'agent-arguments',
                                  hint: l10n.agentsArgumentsHint,
                                ),
                                _field(
                                  l10n.agentsEnvironment,
                                  _environment,
                                  'agent-environment',
                                  hint: l10n.agentsEnvironmentHint,
                                  lines: 2,
                                ),
                                const Divider(),
                                const SizedBox(height: 12),
                                Text(
                                  l10n.agentsCustomizations,
                                  style: SettingsText.heading,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  l10n.agentsFolderHint,
                                  style: SettingsText.description,
                                ),
                                const SizedBox(height: 14),
                                _directory(
                                  l10n.agentsRules,
                                  _rules,
                                  'agent-rules',
                                ),
                                if (widget.agent?.hostConfigurations[_host]
                                    case final agent?)
                                  AgentCustomizationCopy(
                                    key: ValueKey(_host),
                                    host: _host,
                                    agent: agent,
                                    store: widget.customizations,
                                    enabled: !_dirty && !_busy,
                                  ),
                              ],
                            ],
                          ),
                        ),
                ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      style: TextStyle(color: themeColors['errorForeground']),
                    ),
                  ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IdeButton(
                      label: l10n.commonCancel,
                      secondary: true,
                      onPressed: _busy ? null : () => Navigator.pop(context),
                    ),
                    if (configuring) ...[
                      const SizedBox(width: 8),
                      IdeButton(
                        label: l10n.commonSave,
                        spinning: _busy,
                        onPressed: _busy ? null : () => unawaited(_save()),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String formatEnvironment(Map<String, String> environment) =>
    [for (final entry in environment.entries) '${entry.key}=${entry.value}']
        .join('\n');

Map<String, String> parseEnvironment(String text) => {
  for (final line in text.split('\n'))
    if (line.contains('='))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../customize/customization_store.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_registry.dart';
import '../../l10n/l10n.dart';
import '../../remote/remote_acp_registry.dart';
import 'agent_remote_folder_dialog.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'agent_customization_copy.dart';
import 'agent_registry_picker.dart';
import 'settings_widgets.dart';

class AgentEditDialog extends StatefulWidget {
  const AgentEditDialog({
    super.key,
    this.agent,
    required this.onSave,
    required this.pickDirectory,
    required this.customizations,
    required this.registry,
    this.hosts = const [],
    this.initialHost = '',
    this.connectRegistry = RemoteAcpRegistry.connect,
    this.pickRemoteDirectory = showAgentRemoteFolderDialog,
  });

  final AcpAgentConfig? agent;
  final Future<void> Function(AcpAgentConfig) onSave;
  final Future<String?> Function() pickDirectory;
  final CustomizationStore customizations;
  final List<String> hosts;
  final AcpRegistry registry;
  final String initialHost;
  final Future<AcpRegistry> Function(String, AcpRegistry, bool) connectRegistry;
  final Future<String?> Function(BuildContext, String) pickRemoteDirectory;

  @override
  State<AgentEditDialog> createState() => _AgentEditDialogState();
}

class _AgentEditDialogState extends State<AgentEditDialog> {
  final _label = TextEditingController();
  final _command = TextEditingController();
  final _arguments = TextEditingController(text: '[]');
  final _environment = TextEditingController();
  final _skills = TextEditingController();
  final _rules = TextEditingController();
  final _drafts = <String, AcpAgentConfig>{};
  String _target = '';
  bool _registry = false;
  bool _busy = false;
  bool _dirty = false;
  String? _error;
  String _description = 'Agent Client Protocol agent';

  @override
  void initState() {
    super.initState();
    if (widget.agent case final agent?) {
      _drafts[''] = agent;
      _drafts.addAll(agent.hostConfigurations);
      _label.text = agent.label;
      _description = agent.description;
    }
    _target = widget.initialHost;
    _fill(
      _drafts[_target] ??
          AcpAgentConfig(
            id: '',
            label: '',
            command: '',
            description: _description,
          ),
    );
  }

  void _fill(AcpAgentConfig agent) {
    if (_label.text.isEmpty) _label.text = agent.label;
    _command.text = agent.command;
    _arguments.text = jsonEncode(agent.arguments);
    _environment.text = formatEnvironment(agent.environment);
    _skills.text = agent.skillsDirectory;
    _rules.text = agent.rulesDirectory;
    _description = agent.description;
  }

  @override
  void dispose() {
    for (final controller in [
      _label,
      _command,
      _arguments,
      _environment,
      _skills,
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
    try {
      final directory = _target.isEmpty
          ? await widget.pickDirectory()
          : await widget.pickRemoteDirectory(context, _target);
      if (!mounted || directory == null) return;
      controller.text = directory;
      _changed(directory);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (_label.text.trim().isEmpty ||
        (_command.text.trim().isEmpty &&
            !_drafts.entries.any(
              (e) => e.key != _target && e.value.command.isNotEmpty,
            ))) {
      setState(() => _error = l10n.agentsRequired);
      return;
    }
    final List<String> arguments;
    try {
      final parsed = jsonDecode(
        _arguments.text.trim().isEmpty ? '[]' : _arguments.text,
      );
      if (parsed is! List || parsed.any((item) => item is! String)) {
        throw const FormatException();
      }
      arguments = parsed.cast<String>();
    } catch (_) {
      setState(() => _error = l10n.agentsInvalidArguments);
      return;
    }
    if (_environment.text
        .split('\n')
        .any(
          (line) =>
              line.trim().isNotEmpty &&
              (!line.contains('=') ||
                  line.substring(0, line.indexOf('=')).trim().isEmpty),
        )) {
      setState(() => _error = l10n.agentsInvalidEnvironment);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(
        _assemble(
          AcpAgentConfig(
            id: widget.agent?.id ?? '',
            label: _label.text.trim(),
            command: _command.text.trim(),
            arguments: arguments,
            environment: parseEnvironment(_environment.text),
            description: _description,
            skillsDirectory: _skills.text.trim(),
            rulesDirectory: _rules.text.trim(),
          ),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  AcpAgentConfig _assemble(AcpAgentConfig current) {
    _drafts[_target] = current;
    for (final entry in _drafts.entries) {
      final config = entry.value;
      if (config.command.isEmpty &&
          (config.arguments.isNotEmpty ||
              config.environment.isNotEmpty ||
              config.skillsDirectory.isNotEmpty ||
              config.rulesDirectory.isNotEmpty)) {
        final host = entry.key.isEmpty
            ? context.l10n.agentsLocalTarget
            : entry.key;
        throw FormatException('$host: ${context.l10n.agentsRequired}');
      }
    }
    final local = _drafts[''];
    return AcpAgentConfig(
      id: widget.agent?.id ?? '',
      label: _label.text.trim(),
      description: _description,
      command: local?.command ?? '',
      arguments: local?.arguments ?? const [],
      environment: local?.environment ?? const {},
      skillsDirectory: local?.skillsDirectory ?? '',
      rulesDirectory: local?.rulesDirectory ?? '',
      hostScoped:
          widget.agent?.hostScoped == true ||
          widget.agent == null ||
          _drafts.entries.any(
            (e) => e.key.isNotEmpty && e.value.command.isNotEmpty,
          ),
      hostConfigurations: {
        for (final e in _drafts.entries)
          if (e.key.isNotEmpty && e.value.command.isNotEmpty) e.key: e.value,
      },
    );
  }

  void _selectTarget(String target) {
    try {
      final parsed = jsonDecode(
        _arguments.text.trim().isEmpty ? '[]' : _arguments.text,
      );
      if (parsed is! List || parsed.any((v) => v is! String)) {
        throw FormatException(context.l10n.agentsInvalidArguments);
      }
      if (_environment.text
          .split('\n')
          .any(
            (line) =>
                line.trim().isNotEmpty &&
                (!line.contains('=') ||
                    line.substring(0, line.indexOf('=')).trim().isEmpty),
          )) {
        throw FormatException(context.l10n.agentsInvalidEnvironment);
      }
      _drafts[_target] = AcpAgentConfig(
        id: widget.agent?.id ?? '',
        label: _label.text,
        command: _command.text.trim(),
        arguments: parsed.cast<String>(),
        environment: parseEnvironment(_environment.text),
        description: _description,
        skillsDirectory: _skills.text.trim(),
        rulesDirectory: _rules.text.trim(),
      );
      setState(() {
        _target = target;
        _fill(
          _drafts[target] ??
              AcpAgentConfig(
                id: '',
                label: _label.text,
                command: '',
                description: _description,
              ),
        );
        _error = null;
      });
    } catch (error) {
      setState(() => _error = '$error');
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
                if ({
                  ...widget.hosts,
                  ...?widget.agent?.hostConfigurations.keys,
                  widget.initialHost,
                }.any((h) => h.isNotEmpty)) ...[
                  const SizedBox(height: 12),
                  Text(l10n.agentsInstallTarget, style: SettingsText.label),
                  DropdownButton<String>(
                    key: const ValueKey('agent-target'),
                    value: _target,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(l10n.agentsLocalTarget),
                      ),
                      for (final host in {
                        ...widget.hosts,
                        ...?widget.agent?.hostConfigurations.keys,
                        widget.initialHost,
                      }.where((h) => h.isNotEmpty))
                        DropdownMenuItem(
                          value: host,
                          child: Text(
                            'SSH: $host',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (host) => _selectTarget(host ?? ''),
                  ),
                  Text(
                    l10n.agentsHostIsolation,
                    style: SettingsText.description,
                  ),
                ],
                ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      IdeButton(
                        label: l10n.agentsCustom,
                        secondary: _registry,
                        onPressed: _busy
                            ? null
                            : () => setState(() => _registry = false),
                      ),
                      IdeButton(
                        label: l10n.agentsRegistry,
                        secondary: !_registry,
                        onPressed: _busy
                            ? null
                            : () => setState(() => _registry = true),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                Flexible(
                  child: _registry
                      ? AgentRegistryPicker(
                          key: ValueKey(_target),
                          host: _target,
                          connectRegistry: widget.connectRegistry,
                          registry: widget.registry,
                          onBusy: (busy) => setState(() => _busy = busy),
                          onInstalled: (agent) => setState(() {
                            _fill(agent);
                            _drafts[_target] = agent;
                            _registry = false;
                            _dirty = true;
                            _error = null;
                          }),
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
                                l10n.agentsSkills,
                                _skills,
                                'agent-skills',
                              ),
                              _directory(
                                l10n.agentsRules,
                                _rules,
                                'agent-rules',
                              ),
                              if (widget.agent case final agent?)
                                AgentCustomizationCopy(
                                  agent: _target.isEmpty
                                      ? agent
                                      : (agent.hostConfigurations[_target] ??
                                            const AcpAgentConfig(
                                              id: '',
                                              label: '',
                                              command: '',
                                            )),
                                  fixedHost: _target,
                                  store: widget.customizations,
                                  hosts: widget.hosts,
                                  enabled: !_dirty && !_busy,
                                ),
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
                    if (!_registry) ...[
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

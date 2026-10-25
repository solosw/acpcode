import 'dart:async';

import 'package:flutter/material.dart';

import '../../customize/customization_store.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../kernel/acp/acp_agent.dart';
import '../../kernel/acp_agents.dart';
import '../../theme/codicons.dart';
import 'agent_customization_copy.dart';
import 'settings_widgets.dart';

class AgentsSettingsPage extends StatelessWidget {
  const AgentsSettingsPage({
    super.key,
    required this.agents,
    this.customizations,
    this.hosts = const [],
  });

  final AcpAgents agents;
  final CustomizationStore? customizations;
  final List<String> hosts;

  Future<void> _add(BuildContext context) async {
    final id = agents.newId('ACP Agent');
    await agents.add(
      AcpAgentConfig(id: id, label: 'ACP Agent', command: 'agent'),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: agents,
    builder: (context, _) => SettingsPage(
      title: 'Agents',
      description: 'Configure multiple Agent Client Protocol agents.',
      children: [
        SettingsGroup(
          title: 'ACP agents',
          children: [
            if (agents.agents.isEmpty)
              const SettingsRow(label: 'No ACP agents configured'),
            for (final agent in agents.agents)
              _AgentSettingsRow(
                key: ValueKey(agent.id),
                agent: agent,
                customizations: customizations ?? CustomizationStore(),
                hosts: hosts,
                onSave: (updated) => unawaited(
                  agents.save([
                    for (final item in agents.agents)
                      item.id == agent.id ? updated : item,
                  ]),
                ),
                onDelete: () => unawaited(agents.remove(agent.id)),
              ),
            SettingsRow(
              label: 'Add ACP agent',
              trailing: IdeButton(
                label: 'Add ACP agent',
                icon: Codicons.add,
                onPressed: () => unawaited(_add(context)),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _AgentSettingsRow extends StatefulWidget {
  const _AgentSettingsRow({
    super.key,
    required this.agent,
    required this.onSave,
    required this.onDelete,
    required this.customizations,
    required this.hosts,
  });

  final CustomizationStore customizations;
  final List<String> hosts;
  final AcpAgentConfig agent;
  final ValueChanged<AcpAgentConfig> onSave;
  final VoidCallback onDelete;

  @override
  State<_AgentSettingsRow> createState() => _AgentSettingsRowState();
}

class _AgentSettingsRowState extends State<_AgentSettingsRow> {
  late final TextEditingController _label = TextEditingController(
    text: widget.agent.label,
  );
  late final TextEditingController _command = TextEditingController(
    text: widget.agent.command,
  );
  late final TextEditingController _arguments = TextEditingController(
    text: widget.agent.arguments.join(' '),
  );
  late final TextEditingController _environment = TextEditingController(
    text: formatEnvironment(widget.agent.environment),
  );
  late final TextEditingController _skillsDirectory = TextEditingController(
    text: widget.agent.skillsDirectory,
  );
  late final TextEditingController _rulesDirectory = TextEditingController(
    text: widget.agent.rulesDirectory,
  );
  bool _dirty = false;

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    _arguments.dispose();
    _environment.dispose();
    _skillsDirectory.dispose();
    _rulesDirectory.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AgentSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty &&
        (oldWidget.agent.id != widget.agent.id ||
            oldWidget.agent.label != widget.agent.label ||
            oldWidget.agent.command != widget.agent.command ||
            oldWidget.agent.arguments != widget.agent.arguments ||
            oldWidget.agent.environment != widget.agent.environment ||
            oldWidget.agent.skillsDirectory != widget.agent.skillsDirectory ||
            oldWidget.agent.rulesDirectory != widget.agent.rulesDirectory)) {
      _label.text = widget.agent.label;
      _command.text = widget.agent.command;
      _arguments.text = widget.agent.arguments.join(' ');
      _environment.text = formatEnvironment(widget.agent.environment);
      _skillsDirectory.text = widget.agent.skillsDirectory;
      _rulesDirectory.text = widget.agent.rulesDirectory;
    }
  }

  void _markDirty([String? _]) {
    if (_dirty) return;
    setState(() => _dirty = true);
  }

  void _save() {
    final label = _label.text.trim();
    final command = _command.text.trim();
    if (label.isEmpty || command.isEmpty) return;
    widget.onSave(
      AcpAgentConfig(
        id: widget.agent.id,
        label: label,
        command: command,
        arguments: _arguments.text == widget.agent.arguments.join(' ')
            ? widget.agent.arguments
            : _arguments.text.trim().isEmpty
            ? const []
            : _arguments.text.trim().split(RegExp(r'\s+')),
        environment: parseEnvironment(_environment.text),
        description: widget.agent.description,
        skillsDirectory: _skillsDirectory.text.trim(),
        rulesDirectory: _rulesDirectory.text.trim(),
      ),
    );
    setState(() => _dirty = false);
  }

  @override
  Widget build(BuildContext context) => SettingsCard(
    children: [
      SettingsRow(label: 'Name', trailing: _field(_label, 'Agent name')),
      SettingsRow(
        label: 'Command',
        trailing: _field(_command, 'Executable on the project machine'),
      ),
      SettingsRow(
        label: 'Arguments',
        trailing: _field(_arguments, 'Arguments separated by spaces'),
      ),
      SettingsRow(
        label: 'Environment',
        below: [
          IdeInputBox(
            controller: _environment,
            semanticsLabel: 'Environment',
            minLines: 2,
            maxLines: 5,
            onChanged: _markDirty,
          ),
        ],
      ),
      SettingsRow(
        label: 'User skills directory',
        trailing: _field(
          _skillsDirectory,
          'Skills destination on selected host',
        ),
      ),
      SettingsRow(
        label: 'User rules directory',
        trailing: _field(_rulesDirectory, 'Rules destination on selected host'),
      ),
      AgentCustomizationCopy(
        agent: widget.agent,
        store: widget.customizations,
        hosts: widget.hosts,
        enabled: !_dirty,
      ),
      SettingsRow(
        label: 'Actions',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdeButton(
              label: 'Save',
              icon: Codicons.check,
              onPressed: _dirty ? _save : null,
            ),
            const SizedBox(width: 8),
            IdeButton(
              label: 'Remove agent',
              icon: Codicons.trash,
              secondary: true,
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _field(TextEditingController controller, String label) => SizedBox(
    width: 300,
    child: IdeInputBox(
      controller: controller,
      semanticsLabel: label,
      onChanged: _markDirty,
    ),
  );
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

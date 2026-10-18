import '../config/extensions.dart';
import '../config/settings.dart';
import '../engine/session.dart';
import '../permissions/decision.dart';
import '../util/json.dart';
import 'tool.dart';

/// Takes up a skill (or a command the model may run): its instructions
/// follow the call, for the model to carry out.
class SkillTool extends Tool {
  const SkillTool();

  @override
  String get name => 'Skill';

  @override
  String get description => 'Execute a skill within the main conversation.';

  /// The skills and commands the model may use.
  static List<PromptCommand> available(AgentSession session) => [
    for (final command in session.promptCommands)
      if (command.modelInvocable &&
          (command.isSkill || command.description.isNotEmpty))
        command,
  ];

  @override
  bool isEnabled(AgentSession session) => available(session).isNotEmpty;

  @override
  String promptFor(AgentSession session) {
    final listing = [
      for (final command in available(session))
        '- ${command.name}: ${command.description}'
            '${command.whenToUse == null ? '' : ' - ${command.whenToUse}'}',
    ].join('\n');
    return '''Execute a skill within the main conversation

When users ask you to perform tasks, check if any of the available skills below can help complete the task more effectively. Skills provide specialized capabilities and domain knowledge.

When users reference a "slash command" or "/<something>" (e.g., "/commit", "/review-pr"), they are referring to a skill. Use this tool to invoke it.

How to invoke:
- Use this tool with the skill name and optional arguments
- Examples:
  - `skill: "pdf"` - invoke the pdf skill
  - `skill: "commit", args: "-m 'Fix bug'"` - invoke with arguments
  - `skill: "ms-office-suite:pdf"` - invoke using fully qualified name

Important:
- Available skills are listed below
- When a skill matches the user's request, this is a BLOCKING REQUIREMENT: invoke the relevant Skill tool BEFORE generating any other response about the task
- NEVER mention a skill without actually calling this tool
- Do not invoke a skill that is already running
- If you see a <command-name> tag in the current conversation turn, the skill has ALREADY been loaded - follow the instructions directly instead of calling this tool again

Available skills:
$listing''';
  }

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'skill': {
        'type': 'string',
        'description': 'The skill name. E.g., "commit", "review-pr", or "pdf"',
      },
      'args': {
        'type': 'string',
        'description': 'Optional arguments for the skill',
      },
    },
    'required': ['skill'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  static PromptCommand? find(AgentSession session, String name) {
    final wanted = name.startsWith('/') ? name.substring(1) : name;
    for (final command in available(session)) {
      if (command.name == wanted) return command;
    }
    // A plugin's skill by its own name.
    for (final command in available(session)) {
      if (command.name.split(':').last == wanted) return command;
    }
    return null;
  }

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final name = '${input['skill'] ?? ''}'.trim();
    if (name.isEmpty) return 'Invalid skill format: $name';
    if (find(context.session, name) == null) return 'Unknown skill: $name';
    return null;
  }

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  String? ruleContent(Map<String, Object?> input) => asText(input['skill']);

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    final command = find(session, '${input['skill']}'.trim())!;
    final args = asString(input['args']) ?? '';
    // What it may use while it runs, without asking.
    if (command.allowedTools.isNotEmpty) {
      session.settings.addRules(
        command.allowedTools,
        'allow',
        SettingsSource.session,
      );
    }
    final body = command.expand(args);
    final text = command.isSkill
        ? 'Base directory for this skill: ${command.baseDir}\n\n$body'
        : body;
    return ToolOutput(
      'Launching skill: ${command.name}',
      result: {
        'success': true,
        'commandName': command.name,
        if (command.allowedTools.isNotEmpty)
          'allowedTools': command.allowedTools,
        'model': ?command.model,
      },
      followUp: [
        {
          'content': [
            {'type': 'text', 'text': text},
          ],
          'isMeta': true,
        },
      ],
    );
  }
}

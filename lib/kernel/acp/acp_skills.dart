import '../../customize/customizations.dart';
import '../agent_kernel.dart';
import '../extension_switches.dart';
import 'acp_skills_stub.dart' if (dart.library.io) 'acp_skills_io.dart'
    as platform;

/// What the ACP agent advertised for structured `skill` prompt content blocks
/// during `initialize` (ACP v2 `session.prompt.skill`, with defensive v1
/// fallback `promptCapabilities.skill`).
class AcpSkillPromptCapabilities {
  const AcpSkillPromptCapabilities({
    this.supported = false,
    this.inline = false,
  });

  /// Agent accepts `{"type": "skill", "name": ...}` content blocks in
  /// `session/prompt`.
  final bool supported;

  /// Agent accepts skill blocks anywhere in the prompt, not just leading.
  final bool inline;

  factory AcpSkillPromptCapabilities.parse(
    Map<String, Object?>? agentCapabilities,
  ) {
    if (agentCapabilities == null) return const AcpSkillPromptCapabilities();
    final v2Session = _asMap(agentCapabilities['session']);
    final v2Prompt = _asMap(v2Session?['prompt']);
    final v1Prompt = _asMap(agentCapabilities['promptCapabilities']);
    final raw = v2Prompt != null && v2Prompt.containsKey('skill')
        ? v2Prompt['skill']
        : v1Prompt != null && v1Prompt.containsKey('skill')
        ? v1Prompt['skill']
        : null;
    if (raw == null || raw == false) return const AcpSkillPromptCapabilities();
    if (raw == true) return const AcpSkillPromptCapabilities(supported: true);
    if (raw is! Map) return const AcpSkillPromptCapabilities();
    final supportsInline =
        raw.containsKey('inline') &&
        raw['inline'] != false &&
        raw['inline'] != null;
    return AcpSkillPromptCapabilities(
      supported: true,
      inline: supportsInline,
    );
  }

  static Map<String, Object?>? _asMap(Object? value) =>
      value is Map ? value.cast<String, Object?>() : null;
}

/// One command or skill advertised by the ACP agent in `availableCommands`
/// (supports both v1 plain commands and v2 `type: "skill"` entries).
class AcpAdvertisedCommand {
  const AcpAdvertisedCommand({
    required this.name,
    required this.description,
    this.isSkill = false,
    this.filePath,
    this.argumentHint = '',
  });

  final String name;
  final String description;
  final bool isSkill;
  final String? filePath;
  final String argumentHint;

  static List<AcpAdvertisedCommand> parseList(Object? raw) {
    if (raw is! List) return const [];
    final out = <AcpAdvertisedCommand>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final rawName = item['name'];
      if (rawName is! String) continue;
      final name = rawName.trim().replaceFirst(RegExp(r'^/'), '');
      if (name.isEmpty) continue;
      final type = item['type'];
      final isSkill = type == 'skill';
      final description = item['description'] as String? ??
          (isSkill ? 'ACP skill' : 'ACP command');
      final path = item['path'] is String && (item['path'] as String).isNotEmpty
          ? item['path'] as String
          : null;
      final input = item['input'];
      final hint = input is Map && input['hint'] is String
          ? input['hint'] as String
          : '';
      out.add(
        AcpAdvertisedCommand(
          name: name,
          description: description,
          isSkill: isSkill,
          filePath: path,
          argumentHint: hint,
        ),
      );
    }
    return out;
  }
}

/// One BaoCode skill loaded from the agent host's `CustomizationStore`
/// (`~/.claude/skills/` and `<project>/.claude/skills/`).
class AcpSkill {
  const AcpSkill({
    required this.name,
    required this.description,
    required this.path,
    required this.baseDir,
    required this.body,
    this.argumentHint = '',
    this.modelInvocable = true,
    this.userInvocable = true,
  });

  final String name;
  final String description;
  final String path;
  final String baseDir;
  final String body;
  final String argumentHint;
  final bool modelInvocable;
  final bool userInvocable;

  /// Builds a skill from raw `SKILL.md` contents, using the same frontmatter
  /// conventions as BaoCode's built-in core.
  factory AcpSkill.fromMarkdown({
    required String fallbackName,
    required String path,
    required String baseDir,
    required String markdown,
  }) {
    final front = parseFrontMatter(markdown);
    final name = switch (front['name']) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => fallbackName,
    };
    final description = describeMarkdown(markdown);
    final body = bodyOf(markdown).trim();
    return AcpSkill(
      name: name,
      description: description,
      path: path,
      baseDir: baseDir,
      body: body,
      argumentHint: front['argument-hint']?.trim() ?? '',
      modelInvocable: _parseFlag(front['disable-model-invocation']) != true,
      userInvocable: _parseFlag(front['user-invocable']) != false,
    );
  }

  /// Expands `$ARGUMENTS`, `$ARGUMENTS[n]`, `$1..$N`, and `${CLAUDE_SKILL_DIR}`
  /// just like BaoCode's built-in core `PromptCommand.expand`.
  String expand(String arguments) {
    var text = body
        .replaceAll(r'${CLAUDE_SKILL_DIR}', baseDir)
        .replaceAll(r'${CLAUDE_SESSION_ID}', '');
    final words = _splitArguments(arguments);
    final hadPlaceholder =
        text.contains(r'$ARGUMENTS') || RegExp(r'\$\d').hasMatch(text);
    text = text.replaceAllMapped(RegExp(r'\$ARGUMENTS\[(\d+)\]'), (m) {
      final i = int.parse(m[1]!);
      return i < words.length ? words[i] : '';
    });
    text = text.replaceAll(r'$ARGUMENTS', arguments);
    text = text.replaceAllMapped(RegExp(r'\$(\d+)'), (m) {
      final i = int.parse(m[1]!) - 1;
      return i >= 0 && i < words.length ? words[i] : '';
    });
    if (!hadPlaceholder && arguments.trim().isNotEmpty) {
      text = '$text\n\nARGUMENTS: $arguments';
    }
    return text;
  }

  /// Formats this skill for delivery via a standard ACP `text` content block
  /// (compatible with both ACP v1 and v2 agents).
  String toPromptText(String arguments) {
    final expanded = expand(arguments).trim();
    final header = baseDir.isEmpty
        ? 'Follow the instructions for the "$name" skill below.'
        : 'Follow the instructions for the "$name" skill below.\n'
              'Base directory for this skill: $baseDir';
    return expanded.isEmpty ? header : '$header\n\n$expanded';
  }

  static bool? _parseFlag(String? raw) => switch (raw?.trim().toLowerCase()) {
    'true' || 'yes' || '1' => true,
    'false' || 'no' || '0' => false,
    _ => null,
  };

  static List<String> _splitArguments(String text) {
    final out = <String>[];
    final pattern = RegExp(
      r'"([^"]*)"|'
      "'([^']*)'"
      r'|(\S+)',
    );
    for (final match in pattern.allMatches(text)) {
      out.add(match[1] ?? match[2] ?? match[3]!);
    }
    return out;
  }
}

/// Enabled BaoCode skills available to an ACP session on its host.
class AcpSkills {
  const AcpSkills({this.skills = const []});

  final List<AcpSkill> skills;

  bool get isEmpty => skills.isEmpty;

  AcpSkill? byName(String name) {
    for (final skill in skills) {
      if (skill.name == name) return skill;
    }
    return null;
  }

  /// Progressive-disclosure catalog of model-invocable skills for ACP
  /// `systemPrompt` injection.
  String? systemPromptSection({Set<String> excludeNames = const {}}) {
    final available = [
      for (final skill in skills)
        if (skill.modelInvocable && !excludeNames.contains(skill.name)) skill,
    ];
    if (available.isEmpty) return null;
    final lines = [
      for (final skill in available)
        '- ${skill.name}: '
            '${skill.description.isEmpty ? "Skill instructions" : skill.description} '
            '(SKILL.md: ${skill.path})',
    ];
    return '# Available Skills\n'
        'The following skills are available for this workspace. '
        'When a task matches a skill, read its `SKILL.md` file and follow its instructions:\n'
        '${lines.join("\n")}';
  }
}

typedef AcpSkillsLoader = Future<AcpSkills> Function(KernelContext context);

/// Loads enabled BaoCode skills on the agent's host (local or SSH remote).
Future<AcpSkills> loadAcpSkills(
  KernelContext context, {
  Map<String, String> environment = const {},
  ExtensionSwitches? switches,
}) => platform.loadAcpSkills(
  context,
  environment: environment,
  switches: switches,
);

/// Builds the ACP `session/prompt` `prompt` ContentBlock array from user [text].
///
/// - Agent-advertised skills use structured `{"type": "skill", "name": ...}`
///   blocks when the agent advertises `session.prompt.skill` (and inline when
///   `inline` is advertised), otherwise fall back to plain text for v1.
/// - BaoCode skills (not natively advertised by the agent) expand their
///   `SKILL.md` instructions into a standard `text` block, working across
///   both ACP v1 and v2 agents.
List<Map<String, Object?>> buildAcpPromptBlocks(
  String text, {
  required List<AcpAdvertisedCommand> agentCommands,
  required AcpSkills baocodeSkills,
  required AcpSkillPromptCapabilities capabilities,
}) {
  final agentByName = <String, AcpAdvertisedCommand>{
    for (final command in agentCommands) command.name: command,
  };
  final agentSkills = <String, AcpAdvertisedCommand>{
    for (final command in agentCommands)
      if (command.isSkill) command.name: command,
  };

  final leading = RegExp(r'^\s*/([^\s]+)(?:\s+([\s\S]*))?$').firstMatch(text);
  if (leading != null) {
    final name = leading[1]!;
    final args = (leading[2] ?? '').trim();
    if (agentByName[name] case final command?) {
      if (command.isSkill && capabilities.supported) {
        return [
          {'type': 'skill', 'name': command.name},
          if (args.isNotEmpty)
            ..._inlineSkillBlocks(args, agentSkills, capabilities),
        ];
      }
      return [
        {'type': 'text', 'text': text},
      ];
    }
    if (baocodeSkills.byName(name) case final skill? when skill.userInvocable) {
      return [
        {'type': 'text', 'text': skill.toPromptText(args)},
      ];
    }
  }

  if (capabilities.inline && agentSkills.isNotEmpty) {
    return _inlineSkillBlocks(text, agentSkills, capabilities);
  }
  return [
    {'type': 'text', 'text': text},
  ];
}

List<Map<String, Object?>> _inlineSkillBlocks(
  String text,
  Map<String, AcpAdvertisedCommand> agentSkills,
  AcpSkillPromptCapabilities capabilities,
) {
  if (!capabilities.inline || agentSkills.isEmpty) {
    return [
      {'type': 'text', 'text': text},
    ];
  }
  final blocks = <Map<String, Object?>>[];
  final pattern = RegExp(r'(^|\s)/([^\s]+)(?=$|\s)');
  var cursor = 0;
  var matchedAny = false;
  for (final match in pattern.allMatches(text)) {
    final name = match[2]!;
    final skill = agentSkills[name];
    if (skill == null) continue;
    matchedAny = true;
    final prefixEnd = match.start + (match[1]?.length ?? 0);
    if (prefixEnd > cursor) {
      final chunk = text.substring(cursor, prefixEnd);
      if (chunk.trim().isNotEmpty) {
        blocks.add({'type': 'text', 'text': chunk});
      }
    }
    blocks.add({'type': 'skill', 'name': skill.name});
    cursor = match.end;
  }
  if (!matchedAny) {
    return [
      {'type': 'text', 'text': text},
    ];
  }
  if (cursor < text.length) {
    final tail = text.substring(cursor);
    if (tail.trim().isNotEmpty) {
      blocks.add({'type': 'text', 'text': tail});
    }
  }
  return blocks;
}

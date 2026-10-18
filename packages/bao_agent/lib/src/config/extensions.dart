import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/json.dart';
import 'frontmatter.dart';
import 'paths.dart';
import 'settings.dart';

/// A plugin switched on: where it is installed and what it brings.
class Plugin {
  const Plugin({
    required this.id,
    required this.name,
    required this.root,
    required this.manifest,
  });

  /// `name@marketplace`.
  final String id;
  final String name;
  final String root;
  final Map<String, Object?> manifest;

  /// [text] with `${CLAUDE_PLUGIN_ROOT}` spelled out.
  String expand(String text) => text.replaceAll(r'${CLAUDE_PLUGIN_ROOT}', root);

  /// The folders a kind of thing it brings is in: the manifest's, else the
  /// usual one.
  List<String> folders(String key, String fallback) {
    final given = manifest[key];
    final list = switch (given) {
      final String path => [path],
      final List<Object?> paths => paths.whereType<String>().toList(),
      _ => const <String>[],
    };
    return [
      p.join(root, fallback),
      for (final path in list) p.normalize(p.join(root, path)),
    ];
  }

  /// Its MCP servers, as `.mcp.json` has them.
  Map<String, Object?> get mcpServers {
    final given = manifest['mcpServers'];
    Map<String, Object?> servers = {};
    if (given is Map) {
      servers = given.cast<String, Object?>();
    } else {
      final path = given is String
          ? p.join(root, given)
          : p.join(root, '.mcp.json');
      final json = AgentSettings.readJson(path);
      servers = asMap(json['mcpServers']).isNotEmpty
          ? asMap(json['mcpServers'])
          : json;
    }
    return {
      for (final MapEntry(:key, :value) in servers.entries)
        if (value is Map) key: _expandAll(value.cast<String, Object?>()),
    };
  }

  /// Its hooks, as settings have them.
  Map<String, Object?> get hooks {
    final given = manifest['hooks'];
    if (given is Map) return asMap(_expandAll(given.cast<String, Object?>()));
    final path = given is String
        ? p.join(root, given)
        : p.join(root, 'hooks', 'hooks.json');
    final json = AgentSettings.readJson(path);
    final hooks = asMap(json['hooks']).isNotEmpty ? asMap(json['hooks']) : json;
    return asMap(_expandAll(hooks));
  }

  Object? _expandAll(Object? value) => switch (value) {
    final String text => expand(text),
    final Map<Object?, Object?> map => <String, Object?>{
      for (final MapEntry(:key, :value) in map.entries)
        '$key': _expandAll(value),
    },
    final List<Object?> list => [for (final item in list) _expandAll(item)],
    _ => value,
  };
}

/// The plugins installed and switched on (`enabledPlugins`).
List<Plugin> loadPlugins(AgentPaths paths, AgentSettings settings) {
  final enabled = settings.enabledPlugins;
  if (enabled.isEmpty) return const [];
  final installed = AgentSettings.readJson(
    p.join(paths.pluginsDir, 'installed_plugins.json'),
  );
  final plugins = <Plugin>[];
  for (final MapEntry(key: id, value: raw) in asMap(
    installed['plugins'],
  ).entries) {
    if (enabled[id] != true) continue;
    // Version 2 keeps a list of installs; the first (the user's) is taken.
    final install = switch (raw) {
      final List<Object?> list when list.isNotEmpty => asMap(list.first),
      final Map<Object?, Object?> map => map.cast<String, Object?>(),
      _ => const <String, Object?>{},
    };
    final root = asString(install['installPath']);
    if (root == null || !Directory(root).existsSync()) continue;
    var manifest = AgentSettings.readJson(
      p.join(root, '.claude-plugin', 'plugin.json'),
    );
    if (manifest.isEmpty) {
      manifest = AgentSettings.readJson(p.join(root, 'plugin.json'));
    }
    plugins.add(
      Plugin(
        id: id,
        name: asString(manifest['name']) ?? id.split('@').first,
        root: root,
        manifest: manifest,
      ),
    );
  }
  return plugins;
}

/// A command the user can run by `/name` (a markdown file of commands), or
/// a skill (a folder with a SKILL.md) the model can use too.
class PromptCommand {
  const PromptCommand({
    required this.name,
    required this.description,
    required this.body,
    required this.path,
    required this.source,
    this.isSkill = false,
    this.argumentHint,
    this.allowedTools = const [],
    this.model,
    this.modelInvocable = true,
    this.userInvocable = true,
    this.whenToUse,
    this.plugin,
  });

  /// As it is run: `review`, `cloudflare:workers`.
  final String name;
  final String description;

  /// What it asks, `$ARGUMENTS` where what it is given goes.
  final String body;
  final String path;

  /// `user`, `project`, `plugin`.
  final String source;
  final bool isSkill;
  final String? argumentHint;

  /// The tools it may use without asking while it runs.
  final List<String> allowedTools;
  final String? model;

  /// Whether the model may use it (the Skill tool).
  final bool modelInvocable;

  /// Whether the user can run it by name.
  final bool userInvocable;
  final String? whenToUse;
  final Plugin? plugin;

  /// The folder it is in (a skill's own).
  String get baseDir => p.dirname(path);

  /// [body] with [arguments] put in: `$ARGUMENTS` for all of them, `$1`…
  /// for each; at the end when it names none.
  String expand(String arguments) {
    var text = body;
    if (plugin case final plugin?) text = plugin.expand(text);
    text = text
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

  /// As the `initialize` answer lists it.
  Map<String, Object?> toCommandJson() => {
    'name': name,
    'description': description,
    'argumentHint': argumentHint ?? '',
  };
}

/// The commands and skills of the user, the project and the plugins.
List<PromptCommand> loadPromptCommands({
  required AgentPaths paths,
  required String cwd,
  required List<Plugin> plugins,
  List<String> additional = const [],
}) {
  final found = <String, PromptCommand>{};
  void add(PromptCommand command) =>
      found.putIfAbsent(command.name, () => command);

  // The project's first: they win over the user's of the same name.
  final projectDirs = <String>[];
  for (var dir = p.normalize(cwd); ; dir = p.dirname(dir)) {
    projectDirs.add(p.join(dir, '.claude'));
    if (p.dirname(dir) == dir || p.equals(dir, paths.home)) break;
  }
  for (final dir in [
    ...projectDirs,
    for (final d in additional) p.join(d, '.claude'),
  ]) {
    if (p.equals(dir, paths.configDir)) continue;
    _skills(p.join(dir, 'skills'), 'project', null).forEach(add);
    _commands(p.join(dir, 'commands'), 'project', null).forEach(add);
  }
  _skills(p.join(paths.configDir, 'skills'), 'user', null).forEach(add);
  _commands(p.join(paths.configDir, 'commands'), 'user', null).forEach(add);
  for (final plugin in plugins) {
    for (final dir in plugin.folders('skills', 'skills')) {
      _skills(dir, 'plugin', plugin).forEach(add);
    }
    for (final dir in plugin.folders('commands', 'commands')) {
      _commands(dir, 'plugin', plugin).forEach(add);
    }
  }
  return found.values.toList();
}

List<PromptCommand> _commands(String folder, String source, Plugin? plugin) {
  final dir = Directory(folder);
  if (!dir.existsSync()) return const [];
  final out = <PromptCommand>[];
  final files =
      dir
          .listSync(recursive: true, followLinks: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    final front = Frontmatter.parse(text);
    final relative = p.relative(file.path, from: folder);
    final base = p.basenameWithoutExtension(file.path);
    final namespace = p.dirname(relative);
    final name = plugin == null ? base : '${plugin.name}:$base';
    final where = [
      switch (source) {
        'project' => 'project',
        'user' => 'user',
        _ => plugin?.name ?? source,
      },
      if (namespace != '.') namespace.replaceAll(p.separator, ':'),
    ].join(':');
    final description =
        front.string('description') ?? _firstLine(front.body) ?? name;
    out.add(
      PromptCommand(
        name: name,
        description: '$description ($where)',
        body: front.body,
        path: file.path,
        source: source,
        argumentHint: front.string('argument-hint'),
        allowedTools: front.list('allowed-tools') ?? const [],
        model: front.string('model'),
        modelInvocable:
            !(front.flag('disable-model-invocation') ?? false) &&
            front.string('description') != null,
        plugin: plugin,
      ),
    );
  }
  return out;
}

List<PromptCommand> _skills(String folder, String source, Plugin? plugin) {
  final dir = Directory(folder);
  if (!dir.existsSync()) return const [];
  final out = <PromptCommand>[];
  final entries =
      dir.listSync(followLinks: true).whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final skillDir in entries) {
    final file = File(p.join(skillDir.path, 'SKILL.md'));
    if (!file.existsSync()) continue;
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    final front = Frontmatter.parse(text);
    final base = front.string('name') ?? p.basename(skillDir.path);
    final name = plugin == null ? base : '${plugin.name}:$base';
    out.add(
      PromptCommand(
        name: name,
        description:
            front.string('description') ?? _firstLine(front.body) ?? name,
        body: front.body,
        path: file.path,
        source: source,
        isSkill: true,
        argumentHint: front.string('argument-hint'),
        allowedTools: front.list('allowed-tools') ?? const [],
        model: front.string('model'),
        modelInvocable: !(front.flag('disable-model-invocation') ?? false),
        userInvocable: front.flag('user-invocable') ?? true,
        whenToUse: front.string('when_to_use') ?? front.string('when-to-use'),
        plugin: plugin,
      ),
    );
  }
  return out;
}

String? _firstLine(String body) {
  for (final line in const LineSplitter().convert(body)) {
    final text = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (text.isNotEmpty) {
      return text.length > 100 ? '${text.substring(0, 100)}…' : text;
    }
  }
  return null;
}

/// A kind of subagent: what it is for, its instructions, its tools and
/// model.
class AgentDefinition {
  const AgentDefinition({
    required this.name,
    required this.description,
    required this.prompt,
    required this.source,
    this.tools,
    this.disallowedTools = const [],
    this.model,
    this.permissionMode,
    this.color,
    this.skills = const [],
  });

  /// `subagent_type`.
  final String name;

  /// When to use it, for the model choosing one.
  final String description;

  /// Its system prompt.
  final String prompt;

  /// `built-in`, `user`, `project`, `plugin`.
  final String source;

  /// The tools it has; all (but the Agent tool) when null.
  final List<String>? tools;
  final List<String> disallowedTools;

  /// `sonnet`, `opus`, `haiku`, `inherit`, or a model's id.
  final String? model;
  final String? permissionMode;
  final String? color;
  final List<String> skills;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'source': source,
    'model': ?model,
    'tools': ?tools,
  };
}

/// The subagents everyone has.
const builtInAgents = <AgentDefinition>[
  AgentDefinition(
    name: 'general-purpose',
    description:
        'General-purpose agent for researching complex questions, searching '
        'for code, and executing multi-step tasks. When you are searching for '
        'a keyword or file and are not confident that you will find the '
        'right match in the first few tries use this agent to perform the '
        'search for you.',
    source: 'built-in',
    prompt:
        'You are an agent for a coding assistant. Given the user\'s message, '
        'you should use the tools available to complete the task. Do what '
        'has been asked; nothing more, nothing less. When you complete the '
        'task simply respond with a detailed writeup.\n\n'
        'Your strengths:\n'
        '- Searching for code, configurations, and patterns across large '
        'codebases\n'
        '- Analyzing multiple files to understand system architecture\n'
        '- Investigating complex questions that require exploring many files\n'
        '- Performing multi-step research tasks\n\n'
        'Guidelines:\n'
        '- For file searches: Use Grep or Glob when you need to search '
        'broadly. Use Read when you know the specific file path.\n'
        '- For analysis: Start broad and narrow down. Use multiple search '
        'strategies if the first doesn\'t yield results.\n'
        '- Be thorough: Check multiple locations, consider different naming '
        'conventions, look for related files.\n'
        '- NEVER create files unless they\'re absolutely necessary for '
        'achieving your goal. ALWAYS prefer editing an existing file to '
        'creating a new one.\n'
        '- NEVER proactively create documentation files (*.md) or README '
        'files. Only create documentation files if explicitly requested.\n'
        '- In your final response always share relevant file names and code '
        'snippets. Any file paths you return in your response MUST be '
        'absolute. Do NOT use relative paths.\n'
        '- For clear communication, avoid using emojis.',
  ),
  AgentDefinition(
    name: 'Explore',
    description:
        'Fast agent specialized for exploring codebases. Use this when you '
        'need to quickly find files by patterns (eg. "src/components/**/*.tsx"), '
        'search code for keywords (eg. "API endpoints"), or answer questions '
        'about the codebase (eg. "how do API endpoints work?"). When calling '
        'this agent, specify the desired thoroughness level: "quick" for '
        'basic searches, "medium" for moderate exploration, or "very '
        'thorough" for comprehensive analysis across multiple locations and '
        'naming conventions.',
    source: 'built-in',
    model: 'haiku',
    tools: [
      'Glob',
      'Grep',
      'Read',
      'Bash',
      'WebFetch',
      'WebSearch',
      'TaskOutput',
    ],
    prompt:
        'You are a file search specialist for a coding assistant. You excel '
        'at thoroughly navigating and exploring codebases.\n\n'
        '=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===\n'
        'This is a READ-ONLY exploration task. You are STRICTLY PROHIBITED '
        'from creating, modifying, deleting, moving or copying files, from '
        'using redirect operators to write files, and from running any '
        'command that changes the system state.\n\n'
        'Your strengths:\n'
        '- Rapidly finding files using glob patterns\n'
        '- Searching code and text with powerful regex patterns\n'
        '- Reading and analyzing file contents\n\n'
        'Guidelines:\n'
        '- Use Glob for broad file pattern matching\n'
        '- Use Grep for searching file contents with regex\n'
        '- Use Read when you know the specific file path you need to read\n'
        '- Use Bash ONLY for read-only operations (ls, git status, git log, '
        'git diff, find, cat, head, tail)\n'
        '- Adapt your search approach based on the thoroughness level '
        'specified by the caller\n'
        '- Return file paths as absolute paths in your final response\n'
        '- For clear communication, avoid using emojis\n'
        '- Make efficient use of the tools: spawn multiple parallel tool '
        'calls for grepping and reading files wherever possible\n\n'
        'Complete the search request efficiently and report your findings '
        'clearly.',
  ),
  AgentDefinition(
    name: 'Plan',
    description:
        'Software architect agent for designing implementation plans. Use '
        'this when you need to plan the implementation strategy for a task. '
        'Returns step-by-step plans, identifies critical files, and '
        'considers architectural trade-offs.',
    source: 'built-in',
    model: 'inherit',
    tools: [
      'Glob',
      'Grep',
      'Read',
      'Bash',
      'WebFetch',
      'WebSearch',
      'TaskOutput',
    ],
    prompt:
        'You are a software architect and planning specialist for a coding '
        'assistant. Your role is to explore the codebase and design '
        'implementation plans.\n\n'
        '=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===\n'
        'This is a READ-ONLY planning task. You must not create, modify or '
        'delete files, nor run commands that change the system state.\n\n'
        'Your process:\n'
        '1. Understand the requirements given to you.\n'
        '2. Explore thoroughly: read the files named, find existing patterns '
        'and conventions with Glob, Grep and Read, understand the current '
        'architecture and trace the relevant code paths.\n'
        '3. Design the solution: consider trade-offs and follow existing '
        'patterns where appropriate.\n'
        '4. Detail the plan: a step-by-step implementation strategy, its '
        'dependencies and sequencing, and the challenges to anticipate.\n\n'
        'End your response with:\n\n'
        '### Critical Files for Implementation\n'
        'List the 3-5 files most critical for implementing this plan, each '
        'with a brief reason.',
  ),
];

/// The subagents: the built-in ones, then the user's, the project's and
/// the plugins' (a later one of a name over an earlier).
List<AgentDefinition> loadAgents({
  required AgentPaths paths,
  required String cwd,
  required List<Plugin> plugins,
}) {
  final found = <String, AgentDefinition>{
    for (final agent in builtInAgents) agent.name: agent,
  };
  void readFolder(String folder, String source, [Plugin? plugin]) {
    final dir = Directory(folder);
    if (!dir.existsSync()) return;
    final files =
        dir
            .listSync(recursive: true, followLinks: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final String text;
      try {
        text = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      final front = Frontmatter.parse(text);
      final base =
          front.string('name') ?? p.basenameWithoutExtension(file.path);
      final name = plugin == null ? base : '${plugin.name}:$base';
      final description = front.string('description');
      if (description == null) continue;
      final tools = front.list('tools');
      found[name] = AgentDefinition(
        name: name,
        description: description,
        prompt: plugin?.expand(front.body.trim()) ?? front.body.trim(),
        source: source,
        tools: tools == null || tools.contains('*') ? null : tools,
        disallowedTools: front.list('disallowedTools') ?? const [],
        model: front.string('model'),
        permissionMode: front.string('permissionMode'),
        color: front.string('color'),
        skills: front.list('skills') ?? const [],
      );
    }
  }

  for (final plugin in plugins) {
    for (final dir in plugin.folders('agents', 'agents')) {
      readFolder(dir, 'plugin', plugin);
    }
  }
  readFolder(p.join(paths.configDir, 'agents'), 'user');
  readFolder(p.join(cwd, '.claude', 'agents'), 'project');
  return found.values.toList();
}

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine/session.dart';
import '../engine/tasks.dart';
import '../permissions/decision.dart';
import '../permissions/shell_command.dart';
import '../util/ids.dart';
import '../util/json.dart';
import '../util/processes.dart';
import 'tool.dart';

/// Runs a shell command.
class BashTool extends Tool {
  const BashTool();

  static const defaultTimeout = Duration(minutes: 2);
  static const maxTimeout = Duration(minutes: 10);
  static const defaultMaxOutput = 30000;

  @override
  String get name => 'Bash';

  @override
  String get description =>
      'Executes a given shell command and returns its output.';

  /// What the model is told of it, with the session's commit trailer.
  @override
  String promptFor(AgentSession session) {
    final attribution = session.attribution;
    final trailer = attribution.commit.isEmpty
        ? ''
        : '\n\n   ${attribution.commit}';
    final prLine = attribution.pr.isEmpty ? '' : '\n\n${attribution.pr}';
    return '''Executes a given shell command and returns its output.

The working directory persists between commands, but shell state (variables, functions) does not. The shell environment is initialized from the user's login environment.

IMPORTANT: This tool is for terminal operations like git, npm, docker, builds and tests. DO NOT use it for file operations (reading, writing, editing, searching, finding files) - use the specialized tools for this instead.

Before executing the command, please follow these steps:

1. Directory Verification:
   - If the command will create new directories or files, first use `ls` to verify the parent directory exists and is the correct location

2. Command Execution:
   - Always quote file paths that contain spaces with double quotes (e.g., cd "path with spaces/file.txt")
   - After ensuring proper quoting, execute the command.
   - Capture the output of the command.

Usage notes:
  - The command argument is required.
  - You can specify an optional timeout in milliseconds (up to ${maxTimeout.inMilliseconds}ms / ${maxTimeout.inMinutes} minutes). If not specified, commands will timeout after ${defaultTimeout.inMilliseconds}ms (${defaultTimeout.inMinutes} minutes).
  - It is very helpful if you write a clear, concise description of what this command does in 5-10 words.
  - If the output exceeds $defaultMaxOutput characters, output will be truncated before being returned to you.
  - You can use the `run_in_background` parameter to run the command in the background. Only use this if you don't need the result immediately and are OK being notified when the command completes later. You do not need to check the output right away - you'll be notified when it finishes. You can read its output with the TaskOutput tool or by reading its output file. You do not need to use '&' at the end of the command when using this parameter.
  - Avoid using Bash with the `find`, `grep`, `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or when these commands are truly necessary for the task. Instead, always prefer using the dedicated tools for these commands:
    - File search: Use Glob (NOT find or ls)
    - Content search: Use Grep (NOT grep or rg)
    - Read files: Use Read (NOT cat/head/tail)
    - Edit files: Use Edit (NOT sed/awk)
    - Write files: Use Write (NOT echo >/cat <<EOF)
    - Communication: Output text directly (NOT echo/printf)
  - When issuing multiple commands:
    - If the commands are independent and can run in parallel, make multiple Bash tool calls in a single message.
    - If the commands depend on each other and must run sequentially, use a single Bash call with '&&' to chain them together.
    - Use ';' only when you need to run commands sequentially but don't care if earlier commands fail.
    - DO NOT use newlines to separate commands (newlines are ok in quoted strings).
  - Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`. You may use `cd` if the User explicitly requests it.

# Committing changes with git

Only create commits when requested by the user. If unclear, ask first. When the user asks you to create a new git commit, follow these steps carefully:

Git Safety Protocol:
- NEVER update the git config
- NEVER run destructive/irreversible git commands (like push --force, hard reset, etc) unless the user explicitly requests them
- NEVER skip hooks (--no-verify, --no-gpg-sign, etc) unless the user explicitly requests it
- NEVER run force push to main/master, warn the user if they request it
- Avoid git commit --amend. ONLY use --amend when the user explicitly requested it, or when adding edits from a pre-commit hook to the commit you just made
- NEVER commit changes unless the user explicitly asks you to.

1. Run these in parallel: `git status` to see all untracked files, `git diff` to see both staged and unstaged changes that will be committed, and `git log` to see recent commit messages so that you can follow this repository's commit message style.
2. Analyze all staged changes (both previously staged and newly added) and draft a commit message:
  - Summarize the nature of the changes (eg. new feature, enhancement to an existing feature, bug fix, refactoring, test, docs, etc.).
  - Do not commit files that likely contain secrets (.env, credentials.json, etc). Warn the user if they specifically request to commit those files
  - Draft a concise (1-2 sentences) commit message that focuses on the "why" rather than the "what"
3. Add relevant untracked files to the staging area, create the commit, then run git status to make sure the commit succeeded.
4. If the commit fails due to a pre-commit hook, fix the issue and create a NEW commit.

Important notes:
- NEVER use git commands with the -i flag (like git rebase -i or git add -i) since they require interactive input which is not supported.
- If there are no changes to commit (i.e., no untracked files and no modifications), do not create an empty commit
- In order to ensure good formatting, ALWAYS pass the commit message via a HEREDOC, a la this example:
<example>
git commit -m "\$(cat <<'EOF'
   Commit message here.$trailer
   EOF
   )"
</example>

# Creating pull requests
Use the gh command via the Bash tool for ALL GitHub-related tasks including working with issues, pull requests, checks, and releases. If given a Github URL use the gh command to get the information needed.

When the user asks you to create a pull request, first understand the current state of the branch (git status, git diff, whether it tracks a remote and is up to date, git log and `git diff [base-branch]...HEAD` for the full commit history since it diverged), then draft a title and summary covering all the commits that will be included, push the branch if needed, and create the PR with `gh pr create` passing the body via a HEREDOC:
<example>
gh pr create --title "the pr title" --body "\$(cat <<'EOF'
## Summary
<1-3 bullet points>

## Test plan
[Bulleted markdown checklist of TODOs for testing the pull request...]$prLine
EOF
)"
</example>

Return the PR URL when you're done, so the user can see it.''';
  }

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'The command to execute'},
      'timeout': {
        'type': 'number',
        'description': 'Optional timeout in milliseconds (max 600000)',
      },
      'description': {
        'type': 'string',
        'description': 'Clear, concise description of what this command does in 5-10 words, in active voice.',
      },
      'run_in_background': {
        'type': 'boolean',
        'description': 'Set to true to run this command in the background. Use TaskOutput to read the output later.',
      },
      'dangerouslyDisableSandbox': {
        'type': 'boolean',
        'description': 'Set this to true to dangerously override sandbox mode and run commands without sandboxing.',
      },
    },
    'required': ['command'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) =>
      isReadOnlyCommand('${input['command'] ?? ''}');

  @override
  String? describe(Map<String, Object?> input) =>
      asString(input['description']);

  @override
  String? ruleContent(Map<String, Object?> input) => asString(input['command']);

  /// How long a command runs in the foreground before it is shown as a
  /// task.
  static const foregroundTaskAfter = Duration(seconds: 1);

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => context.session.permissions.checkBash(
    '${input['command'] ?? ''}',
    context.cwd,
    context.run.permissionMode,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final command = '${input['command'] ?? ''}';
    if (command.trim().isEmpty) return 'command must not be empty';
    // A `sleep` alone, waited on, only wastes the user's time.
    final sleep = RegExp(r'^\s*sleep\s+(\d+)\s*$').firstMatch(command);
    if (sleep != null &&
        int.parse(sleep[1]!) > 120 &&
        input['run_in_background'] != true) {
      return 'Blocked: a long `sleep` on its own. Run what you are waiting '
          'for in the background and you will be told when it finishes.';
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    final command = '${input['command']}';
    final description =
        asText(input['description']) ??
        (command.length > 60 ? '${command.substring(0, 60)}…' : command);
    if (input['run_in_background'] == true) {
      final task = await session.tasks.startShell(
        command: command,
        description: description,
        cwd: context.cwd,
        toolUseId: context.toolUseId,
      );
      return _backgroundOutput(task);
    }
    final timeout = _timeout(input, session);
    final shell = session.shell;
    final cwdFile = p.join(
      Directory.systemTemp.path,
      'bao-cwd-${randomId(10)}',
    );
    final Process process;
    try {
      process = await Process.start(
        shell.executable,
        shell.arguments(command, cwdFile),
        workingDirectory: Directory(context.cwd).existsSync()
            ? context.cwd
            : session.cwd,
        environment: session.commandEnvironment,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      return ToolOutput.error(
        'Could not start ${shell.executable}: ${error.message}',
      );
    }
    unawaited(process.stdin.close().catchError((_) {}));
    final running = ForegroundCommand(
      process: process,
      command: command,
      description: description,
      toolUseId: context.toolUseId,
    );
    session.tasks.foreground[context.toolUseId] = running;
    // Shown as a task once it has gone on a while: one the user can send
    // to the background.
    final shown = Timer(foregroundTaskAfter, () {
      if (running.task == null) session.tasks.registerForeground(running);
    });
    final streams = Future.wait([
      process.stdout.listen(running.addStdout).asFuture<void>(),
      process.stderr.listen(running.addStderr).asFuture<void>(),
    ]);
    var timedOut = false;
    var interrupted = false;
    final ended = Completer<String>();
    unawaited(
      process.exitCode.then((_) {
        if (!ended.isCompleted) ended.complete('exit');
      }),
    );
    final timer = Timer(timeout, () {
      if (!ended.isCompleted) ended.complete('timeout');
    });
    unawaited(
      context.cancel.whenCancelled.then((_) {
        if (!ended.isCompleted) ended.complete('cancel');
      }),
    );
    unawaited(
      running.backgrounded.then((_) {
        if (!ended.isCompleted) ended.complete('background');
      }),
    );
    final how = await ended.future;
    timer.cancel();
    shown.cancel();
    switch (how) {
      case 'background':
        session.tasks.foreground.remove(context.toolUseId);
        final task = running.task!;
        unawaited(() async {
          final code = await process.exitCode;
          await streams.catchError((_) => <void>[]);
          await running.closeSink();
          task.exitCode = code;
          session.tasks.finish(
            task,
            task.status == TaskStatus.killed
                ? TaskStatus.killed
                : code == 0
                ? TaskStatus.completed
                : TaskStatus.failed,
          );
        }());
        return _backgroundOutput(task);
      case 'timeout':
        timedOut = true;
        await killTree(process.pid);
      case 'cancel':
        interrupted = true;
        await killTree(process.pid);
    }
    final code = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        Process.killPid(process.pid, ProcessSignal.sigkill);
        return -9;
      },
    );
    await streams
        .timeout(const Duration(seconds: 2), onTimeout: () => [])
        .catchError((_) => <void>[]);
    session.tasks.foreground.remove(context.toolUseId);
    if (running.registered case final task?) {
      task.exitCode = code;
      session.tasks.finish(
        task,
        interrupted || timedOut || task.status == TaskStatus.killed
            ? TaskStatus.killed
            : code == 0
            ? TaskStatus.completed
            : TaskStatus.failed,
      );
    }
    final cwdNote = _followCwd(cwdFile, context);
    final maxOutput =
        asInt(session.environment['BASH_MAX_OUTPUT_LENGTH']) ??
        defaultMaxOutput;
    final stdout = _truncate(_trimEnd(running.stdout.toString()), maxOutput);
    final stderr = _truncate(_trimEnd(running.stderr.toString()), maxOutput);
    final parts = <String>[
      if (stdout.isNotEmpty) stdout,
      if (stderr.isNotEmpty) stderr,
    ];
    var text = parts.join('\n');
    if (timedOut) {
      text = [
        if (text.isNotEmpty) text,
        'Command timed out after ${_seconds(timeout)}',
      ].join('\n');
    } else if (interrupted) {
      text = [if (text.isNotEmpty) text, 'Command was interrupted'].join('\n');
    } else if (code != 0) {
      text = ['Exit code $code', if (text.isNotEmpty) text].join('\n');
    }
    if (cwdNote != null) text = [if (text.isNotEmpty) text, cwdNote].join('\n');
    final isError = timedOut || interrupted || code != 0;
    return ToolOutput(
      text.isEmpty ? '(Bash completed with no output)' : text,
      isError: isError,
      result: {
        'stdout': stdout,
        'stderr': stderr,
        'interrupted': timedOut || interrupted,
        'isImage': false,
        'exitCode': code,
        if (timedOut) 'timedOut': true,
      },
    );
  }

  static ToolOutput _backgroundOutput(BackgroundTask task) => ToolOutput(
    'Command running in background with ID: ${task.id}. Output is being '
    'written to: ${task.outputFile}. You will be notified when it finishes; '
    'you can check on it with the TaskOutput tool.',
    result: {
      'stdout': '',
      'stderr': '',
      'interrupted': false,
      'isImage': false,
      'backgroundTaskId': task.id,
      'outputFile': task.outputFile,
    },
  );

  static Duration _timeout(Map<String, Object?> input, AgentSession session) {
    final env = session.environment;
    final defaultMs =
        asInt(env['BASH_DEFAULT_TIMEOUT_MS']) ?? defaultTimeout.inMilliseconds;
    final maxMs =
        asInt(env['BASH_MAX_TIMEOUT_MS']) ??
        (defaultMs > maxTimeout.inMilliseconds
            ? defaultMs
            : maxTimeout.inMilliseconds);
    final asked = asInt(input['timeout']) ?? defaultMs;
    return Duration(milliseconds: asked.clamp(1000, maxMs));
  }

  static String _seconds(Duration duration) =>
      duration.inMinutes >= 1 && duration.inSeconds % 60 == 0
      ? '${duration.inMinutes}m'
      : '${duration.inSeconds}s';

  /// Moves the agent's shell to where the command left it, inside the
  /// working folders; elsewhere, back to the project, and says so.
  static String? _followCwd(String cwdFile, ToolContext context) {
    final file = File(cwdFile);
    String? ended;
    try {
      if (file.existsSync()) ended = file.readAsStringSync().trim();
    } on FileSystemException {
      ended = null;
    }
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Left in the temp folder.
    }
    if (ended == null || ended.isEmpty) return null;
    final permissions = context.session.permissions;
    if (permissions.inWorkingDirectories(ended) ||
        _sameDirectory(ended, context.cwd)) {
      context.run.cwd = ended;
      return null;
    }
    final project = context.session.cwd;
    context.run.cwd = project;
    return 'Shell cwd was reset to $project';
  }

  static bool _sameDirectory(String a, String b) {
    try {
      return Directory(a).resolveSymbolicLinksSync() ==
          Directory(b).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
  }

  static String _trimEnd(String text) => text.replaceFirst(RegExp(r'\s+$'), '');

  /// [text] cut to [max] characters, from its middle.
  static String _truncate(String text, int max) {
    if (text.length <= max) return text;
    final head = text.substring(0, max ~/ 2);
    final tail = text.substring(text.length - max ~/ 2);
    final dropped = '\n'
        .allMatches(text.substring(max ~/ 2, text.length - max ~/ 2))
        .length;
    return '$head\n\n... [$dropped lines truncated] ...\n\n$tail';
  }
}

/// Reads what a background task has written.
class TaskOutputTool extends Tool {
  const TaskOutputTool();

  @override
  String get name => 'TaskOutput';

  @override
  List<String> get aliases => const ['BashOutput', 'AgentOutputTool'];

  @override
  String get description => '''- Retrieves output from a running or completed background task (a background shell or a background agent)
- Takes a task_id parameter identifying the task
- Returns the task's output and its status; for a shell, only the output written since the last check
- Use block=true (the default) to wait for the task to finish, up to timeout milliseconds
- Use block=false to check on it without waiting''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'task_id': {
        'type': 'string',
        'description': 'The task ID to get output from',
      },
      'bash_id': {
        'type': 'string',
        'description': 'The ID of the background shell (older name of task_id)',
      },
      'block': {
        'type': 'boolean',
        'description': 'Whether to wait for completion',
        'default': true,
      },
      'timeout': {
        'type': 'number',
        'description': 'Max wait time in ms',
        'default': 30000,
      },
      'filter': {
        'type': 'string',
        'description': 'Optional regular expression: only output lines matching it are shown.',
      },
    },
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['task_id']) ?? asText(input['bash_id']);
    if (id == null) return 'task_id is required';
    if (context.session.tasks[id] == null) return 'No task found with ID: $id';
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['task_id']) ?? asText(input['bash_id'])!;
    final task = context.session.tasks[id]!;
    if (input['block'] != false && task.status == TaskStatus.running) {
      final wait = Duration(
        milliseconds: (asInt(input['timeout']) ?? 30000).clamp(0, 600000),
      );
      await context.cancel.guard(task.done.timeout(wait, onTimeout: () {}));
    }
    final all = task.output();
    var fresh = task.isShell
        ? all.substring(task.readOffset.clamp(0, all.length))
        : all;
    task.readOffset = all.length;
    if (asText(input['filter']) case final filter?) {
      try {
        final regExp = RegExp(filter);
        fresh = fresh.split('\n').where(regExp.hasMatch).join('\n');
      } on FormatException catch (error) {
        return ToolOutput.error('Invalid filter: ${error.message}');
      }
    }
    if (!task.isShell && task.result != null) fresh = task.result!;
    final text = StringBuffer()
      ..writeln('<task_id>$id</task_id>')
      ..writeln('<task_type>${task.type}</task_type>')
      ..writeln('<status>${task.status.name}</status>');
    if (task.exitCode != null) {
      text.writeln('<exit_code>${task.exitCode}</exit_code>');
    }
    text.write(
      fresh.trim().isEmpty
          ? '<output>(no new output)</output>'
          : '<output>\n${fresh.trimRight()}\n</output>',
    );
    return ToolOutput(
      text.toString(),
      result: {
        'retrieval_status': task.status == TaskStatus.running
            ? 'timeout'
            : 'success',
        'task': {
          'task_id': id,
          'task_type': task.type,
          'status': task.status.name,
          'description': task.description,
          'output': fresh,
          'exitCode': task.exitCode,
        },
      },
    );
  }
}

/// Stops a background task.
class TaskStopTool extends Tool {
  const TaskStopTool();

  @override
  String get name => 'TaskStop';

  @override
  List<String> get aliases => const ['KillShell', 'KillBash'];

  @override
  String get description =>
      '''- Stops a running background task (a shell or an agent) by its ID
- Takes a task_id parameter identifying the task to stop
- Returns a success or failure status
- Use this tool when you need to terminate a long-running task''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'task_id': {
        'type': 'string',
        'description': 'The ID of the background task to stop',
      },
      'shell_id': {
        'type': 'string',
        'description': 'The ID of the background shell (older name of task_id)',
      },
    },
    'additionalProperties': false,
  };

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['task_id']) ?? asText(input['shell_id']);
    if (id == null) return ToolOutput.error('task_id is required');
    final task = context.session.tasks[id];
    if (task == null) return ToolOutput.error('No task found with ID: $id');
    if (task.status.done) {
      return ToolOutput.error(
        'Task $id is not running (it is ${task.status.name}).',
      );
    }
    await context.session.tasks.stop(id);
    return ToolOutput(
      'Successfully stopped task: $id (${task.description})',
      result: {
        'message': 'Successfully stopped task: $id',
        'task_id': id,
        'task_type': task.type,
        'command': task.command ?? task.description,
      },
    );
  }
}

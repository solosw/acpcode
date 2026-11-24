import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../chat/chat_session.dart';
import '../ide/git/git_service.dart';
import '../kernel/agent_kernel.dart';
import '../kernel/kernel_types.dart';
import '../remote/remote_location.dart';
import '../remote/remote_services.dart';
import '../remote/ssh_host.dart';
import '../workspace/workspace.dart';
import 'scheduled_task.dart';

/// The same Git services the IDE uses, including the host's path syntax.
IdeGitService taskGitService(String location) {
  final host = RemoteLocation.hostOf(location);
  return host == null
      ? IdeGitService(location)
      : remoteGitService(
          SshHosts.instance[host],
          RemoteLocation.pathOf(location),
        );
}

/// Waits for a kernel report, not merely for a picker callback to return:
/// ACP choices are asynchronous and model changes can replace effort options.
Future<void> waitForTaskSession(
  ChatSession session,
  bool Function() done, {
  Duration? timeout = const Duration(seconds: 90),
  Future<void>? cancelled,
}) async {
  final result = Completer<void>();
  void check() {
    if (result.isCompleted) return;
    if (session.health.status == KernelHealthStatus.failed) {
      result.completeError(
        StateError(session.health.message ?? 'Agent failed'),
      );
    } else if (done()) {
      result.complete();
    }
  }

  cancelled?.then((_) {
    if (!result.isCompleted) {
      result.completeError(StateError('Configuration closed'));
    }
  });
  session.addListener(check);
  final timer = timeout == null
      ? null
      : Timer(timeout, () {
          if (!result.isCompleted) {
            result.completeError(
              TimeoutException('Agent did not become ready'),
            );
          }
        });
  try {
    check();
    await result.future;
  } finally {
    timer?.cancel();
    session.removeListener(check);
  }
}

/// Applies only options the conversation itself currently declares. Never
/// silently run with a different model or permission mode than was saved.
Future<void> applyTaskSettings(
  ChatSession session,
  Map<String, String> settings, {
  Future<void>? cancelled,
}) async {
  await waitForTaskSession(
    session,
    () => session.health.status == KernelHealthStatus.ready,
    cancelled: cancelled,
  );
  for (final kind in [
    KernelChoiceKind.model,
    KernelChoiceKind.mode,
    KernelChoiceKind.permission,
  ]) {
    final value = settings[kind.name];
    if (value == null) continue;
    final choice = switch (kind) {
      KernelChoiceKind.model => session.models,
      KernelChoiceKind.mode => session.modes,
      _ => session.permissions,
    };
    final option = choice?.options.where((o) => o.id == value).firstOrNull;
    if (choice == null || option == null) {
      throw StateError('Option unavailable: ${kind.name}=$value');
    }
    if (choice.selected.id != value) {
      choice.onSelected(option);
      await waitForTaskSession(
        session,
        () => session.selected(kind) == value,
        cancelled: cancelled,
      );
    }
  }
  final model = session.models?.selected.id ?? '';
  for (final kind in [
    KernelChoiceKind.context,
    KernelChoiceKind.effort,
    KernelChoiceKind.fast,
  ]) {
    final value = settings[kind.name];
    if (value == null) continue;
    final choice = session
        .modelSettings(model)
        .where((s) => s.kind == kind)
        .firstOrNull;
    if (choice == null) {
      throw StateError('Option unavailable: ${kind.name}=$value');
    }
    if (choice.toggle) {
      final enabled = value == choice.options.first.id;
      if ((choice.selected != null) != enabled) {
        choice.onSelected(choice.options.first);
        await waitForTaskSession(
          session,
          () =>
              (session
                      .modelSettings(model)
                      .where((s) => s.kind == kind)
                      .firstOrNull
                      ?.selected !=
                  null) ==
              enabled,
          cancelled: cancelled,
        );
      }
      continue;
    }
    final option = choice.options.where((o) => o.id == value).firstOrNull;
    if (option == null) {
      throw StateError('Option unavailable: ${kind.name}=$value');
    }
    if (choice.selected?.id != value) {
      choice.onSelected(option);
      await waitForTaskSession(
        session,
        () => session.selected(kind) == value,
        cancelled: cancelled,
      );
    }
  }
}

/// What a task's start script printed and how it ended.
typedef TaskScriptResult = ({int exitCode, String stdout, String stderr});

typedef TaskScriptRunner = Future<TaskScriptResult> Function(
  String script,
  String location,
);

/// Runs [script] with the shell of [location]'s host, in that folder.
Future<TaskScriptResult> runTaskScript(String script, String location) async {
  final host = RemoteLocation.hostOf(location);
  final cwd = RemoteLocation.pathOf(location);
  if (host != null) {
    final client = await SshHosts.instance[host].ready;
    final windows = client.hello?.platform.os == 'win';
    final result = await client
        .run(
          windows ? 'cmd.exe' : 'sh',
          windows ? ['/d', '/s', '/c', script] : ['-c', script],
          cwd: cwd,
        )
        .timeout(const Duration(minutes: 10));
    return (
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }
  final process = await Process.start(
    Platform.isWindows ? 'cmd.exe' : '/bin/sh',
    Platform.isWindows ? ['/d', '/s', '/c', script] : ['-c', script],
    workingDirectory: cwd,
  );
  await process.stdin.close();
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final code = await process.exitCode.timeout(const Duration(minutes: 10));
    return (exitCode: code, stdout: await stdout, stderr: await stderr);
  } on TimeoutException {
    process.kill();
    throw StateError('Task script timed out after 10 minutes');
  }
}

/// An adapter to Workspace/ChatSession, not another execution engine.
class ScheduledExecutor {
  ScheduledExecutor(this.workspace, {this.runScript = runTaskScript});
  final Workspace workspace;
  final TaskScriptRunner runScript;
  final Set<AgentThread> _claimed = {};

  Future<void> execute(ScheduledTask task, VoidCallback checkpoint) async {
    if (!workspace.kernels.any((kernel) => kernel.id == task.kernel)) {
      throw StateError('Agent unavailable: ${task.kernel}');
    }
    // Reuse retains the worktree from the first run as well as the session.
    var location = task.reuse && task.sessionId != null
        ? task.sessionLocation ?? task.worktree ?? task.project
        : task.worktree ?? task.project;
    if (RemoteLocation.hostOf(location) !=
        RemoteLocation.hostOf(task.project)) {
      throw StateError('Task workspace belongs to a different host');
    }
    if (task.newWorktree && !(task.reuse && task.sessionId != null)) {
      final git = taskGitService(task.project);
      final paths = git.pathContext;
      final branch = 'scheduled/${ChatSession.newTurnId()}';
      final root = RemoteLocation.pathOf(task.project);
      final path = paths.join(
        paths.dirname(root),
        '${paths.basename(root)}-${branch.replaceAll('/', '-')}',
      );
      await git.addWorktree(path, newBranch: branch);
      location = RemoteLocation.of(RemoteLocation.hostOf(task.project), path);
    }
    final prompt = await _message(task, location);
    if (prompt == null) return;
    final thread = await workspace.scheduledAgent(
      location: location,
      kernelId: task.kernel,
      settings: task.settings,
      resumeId: task.reuse ? task.sessionId : null,
    );
    final session = thread.session;
    if (_claimed.contains(thread) ||
        session.isStreaming ||
        session.pendingInteraction != null ||
        thread.runsInBackground) {
      throw StateError('Conversation is busy; this occurrence was skipped');
    }
    _claimed.add(thread);
    void remember() {
      final id = thread.id;
      if (id != null &&
          (task.sessionId != id || task.sessionLocation != location)) {
        task.sessionId = id;
        task.sessionLocation = location;
        checkpoint();
      }
    }

    session.addListener(remember);
    session.attach();
    try {
      await applyTaskSettings(session, task.settings);
      remember();
      if (session.isStreaming || !session.canSend) {
        throw StateError('Conversation is busy');
      }
      final ended = session.lastTurnEndSeq;
      // Listen before send: a mock/local command can finish synchronously.
      final finished = waitForTaskSession(
        session,
        () => session.lastTurnEndSeq > ended,
        timeout: null,
      );
      session.send(ComposerMessage(text: prompt));
      await finished;
      remember();
    } finally {
      session.removeListener(remember);
      session.detach();
      _claimed.remove(thread);
    }
  }

  /// The script runs where the agent will. No output: nothing to do now.
  Future<String?> _message(ScheduledTask task, String location) async {
    if (task.script.trim().isEmpty) return task.prompt;
    final result = await runScript(task.script, location);
    if (result.exitCode != 0) {
      var detail =
          (result.stderr.trim().isEmpty ? result.stdout : result.stderr).trim();
      if (detail.length > 2000) detail = detail.substring(0, 2000);
      throw StateError(
        'Task script exited ${result.exitCode}'
        '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    final output = result.stdout.trim();
    if (output.isEmpty) return null;
    final prompt = task.prompt.trim();
    return prompt.isEmpty ? output : '$prompt\n\n$output';
  }
}

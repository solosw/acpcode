import 'dart:convert';

import '../chat/chat_session.dart';
import '../kernel/claude_code/claude_sdk_tools.dart';
import '../workspace/session_tools.dart';
import '../workspace/workspace.dart';
import 'scheduled_task.dart';
import 'task_scheduler.dart';

/// Exposes the main window's scheduler through the built-in BaoCode MCP.
class ScheduledTools {
  static const name = 'scheduled_task_create';

  static void register(Workspace workspace, TaskScheduler scheduler) {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: name,
        description:
            'Create an enabled recurring task only when the user asks '
            'for one. An optional shell script runs first in the project folder '
            'on the project host. Empty stdout skips the conversation; '
            'nonempty stdout is sent with the optional prompt. '
            'Uses the default agent and model. Does not start a run now. '
            'Times are in the BaoCode computer’s local time zone.',
        offeredIn: (cwd) =>
            SessionToolsSetting.current() && !workspace.isAppFolder(cwd),
        inputSchema: const {
          'type': 'object',
          'additionalProperties': false,
          'required': ['schedule'],
          'anyOf': [
            {
              'required': ['prompt'],
            },
            {
              'required': ['script'],
            },
          ],
          'properties': {
            'name': {'type': 'string', 'description': 'Optional task name.'},
            'project': {
              'type': 'string',
              'description': 'Open project name or exact path (including ssh://). Defaults to the calling project.',
            },
            'prompt': {
              'type': 'string',
              'description':
                  'Message to send to the agent. Optional with a script.',
            },
            'script': {
              'type': 'string',
              'description':
                  'Shell script to run at each occurrence before starting the '
                  'agent. Exit 0 with empty stdout to skip the agent, or print '
                  'text to start it. A nonzero exit records an error. Only '
                  'include code the user authorized to run on that host.',
            },
            'schedule': {
              'type': 'object',
              'oneOf': [
                {
                  'properties': {
                    'type': {'const': 'calendar'},
                    'hour': {'type': 'integer', 'minimum': 0, 'maximum': 23},
                    'minute': {'type': 'integer', 'minimum': 0, 'maximum': 59},
                    'days': {
                      'type': 'array',
                      'minItems': 1,
                      'items': {'type': 'integer', 'minimum': 1, 'maximum': 7},
                      'description': 'Monday is 1, Sunday is 7.',
                    },
                  },
                  'required': ['type', 'hour', 'minute', 'days'],
                  'additionalProperties': false,
                },
                {
                  'properties': {
                    'type': {'const': 'interval'},
                    'minutes': {
                      'type': 'integer',
                      'minimum': 1,
                      'maximum': 525600,
                    },
                  },
                  'required': ['type', 'minutes'],
                  'additionalProperties': false,
                },
                {
                  'properties': {
                    'type': {'const': 'cron'},
                    'expression': {
                      'type': 'string',
                      'description': 'Five-field numeric Cron.',
                    },
                  },
                  'required': ['type', 'expression'],
                  'additionalProperties': false,
                },
              ],
            },
          },
        },
        run: (input, call) async {
          if (!scheduler.ready) {
            throw StateError('Scheduled tasks are not ready');
          }
          if (input.keys.any(
            (key) => !const {
              'name',
              'project',
              'prompt',
              'script',
              'schedule',
            }.contains(key),
          )) {
            throw ArgumentError(
              'Only name, project, prompt, script and schedule are accepted',
            );
          }
          final prompt = _text(input, 'prompt') ?? '';
          final script = _text(input, 'script', trim: false) ?? '';
          if (prompt.isEmpty && script.trim().isEmpty) {
            throw ArgumentError('Provide a prompt or a script');
          }
          final schedule = _schedule(input['schedule']);
          final requested = _text(input, 'project');
          final projects = workspace.projects.where(
            (p) => !workspace.isAppFolder(p.path),
          );
          final path = requested ?? call.cwd;
          final exact = projects.where((p) => p.path == path).firstOrNull;
          final named = requested == null
              ? const <Project>[]
              : projects.where((p) => p.name == requested).toList();
          final project = exact ?? named.singleOrNull;
          if (project == null) {
            throw ArgumentError(
              named.length > 1
                  ? 'Project name is ambiguous; use its exact path'
                  : 'Select an open project by name or exact path',
            );
          }
          final name = _text(input, 'name');
          final task = ScheduledTask(
            id: ChatSession.newTurnId(),
            name: name == null || name.isEmpty
                ? (prompt.isEmpty
                      ? 'Scheduled script'
                      : prompt.split('\n').first)
                : name,
            prompt: prompt,
            script: script,
            kernel: workspace.preferredKernel.id,
            project: project.path,
            schedule: schedule,
          );
          await scheduler.save(task);
          return jsonEncode({
            'id': task.id,
            'name': task.name,
            'project': task.project,
            'nextRun': task.nextRun?.toIso8601String(),
            'timeZone': task.nextRun?.timeZoneName,
          });
        },
      ),
    );
  }

  static String? _text(
    Map<String, Object?> input,
    String key, {
    bool trim = true,
  }) {
    if (!input.containsKey(key)) return null;
    final value = input[key];
    if (value is! String) throw ArgumentError('$key must be a string');
    return trim ? value.trim() : value;
  }

  static TaskSchedule _schedule(Object? input) {
    return switch (input) {
      {
        'type': 'calendar',
        'hour': final int hour,
        'minute': final int minute,
        'days': final List days,
      }
          when input.length == 4 && days.every((day) => day is int) =>
        TaskSchedule(
          hour: hour,
          minute: minute,
          days: days.cast<int>().toSet(),
        ),
      {'type': 'interval', 'minutes': final int minutes}
          when input.length == 2 =>
        TaskSchedule.interval(minutes: minutes),
      {'type': 'cron', 'expression': final String expression}
          when input.length == 2 =>
        TaskSchedule.cron(expression),
      _ => throw ArgumentError(
        'Invalid schedule; use calendar, interval, or cron',
      ),
    };
  }

  static void unregister() => ClaudeSdkTools.unregister(name);
}

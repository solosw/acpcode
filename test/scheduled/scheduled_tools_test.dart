import 'dart:convert';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/scheduled/scheduled_tools.dart';
import 'package:baocode/scheduled/task_scheduler.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cwd = '/projects/local';
  const remote = 'ssh://dev/home/work';
  const calendar = {
    'type': 'calendar',
    'hour': 9,
    'minute': 0,
    'days': [1],
  };
  const request = {'prompt': 'Summarize changes', 'schedule': calendar};
  late Workspace workspace;
  late TaskScheduler scheduler;
  late MemoryPreferenceStore store;

  KernelDescriptor kernel(String id) => KernelDescriptor(
    id: id,
    label: id,
    icon: Icons.hub_rounded,
    description: '',
    create: (_) =>
        throw StateError('Creating a schedule must not start an agent'),
  );

  setUp(() async {
    workspace = Workspace(
      kernels: [kernel('default-acp'), kernel('other')],
      projects: [Project('Local', cwd), Project('Remote', remote)],
    );
    store = MemoryPreferenceStore();
    scheduler = TaskScheduler(
      store: store,
      execute: (_, _) async => fail('Creating a schedule must not execute it'),
      clock: () => DateTime(2026, 5, 18, 8),
    );
    await scheduler.load(startTimer: false);
    ScheduledTools.register(workspace, scheduler);
    final setting = SessionToolsSetting.current;
    addTearDown(() => SessionToolsSetting.current = setting);
    SessionToolsSetting.current = () => true;
    addTearDown(workspace.dispose);
    addTearDown(scheduler.dispose);
    addTearDown(ScheduledTools.unregister);
  });

  Future<Map> call(Map<String, Object?> arguments, {String from = cwd}) async {
    final answer = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': ScheduledTools.name, 'arguments': arguments},
    }, ClaudeSdkCall(cwd: from));
    return answer['result'] as Map;
  }

  test('creates and saves in calling project with default agent and no model override', () async {
    final result = await call(request);
    expect(result['isError'], isNull);
    final task = scheduler.tasks.single;
    expect(task.project, cwd);
    expect(task.kernel, 'default-acp');
    expect(task.settings, isEmpty);
    expect(task.lastRun, isNull);
    expect(task.nextRun, DateTime(2026, 5, 18, 9));
    expect((store.preferences['tasks'] as List).single, task.toJson());
    final response =
        jsonDecode((result['content'] as List).single['text'] as String) as Map;
    expect(response['id'], task.id);
    expect(response['nextRun'], '2026-05-18T09:00:00.000');
  });

  test('accepts a named SSH project with interval or cron schedules', () async {
    expect(
      (await call({
        ...request,
        'project': 'Remote',
        'schedule': {'type': 'interval', 'minutes': 30},
      }))['isError'],
      isNull,
    );
    expect(
      (await call({
        ...request,
        'schedule': {'type': 'cron', 'expression': '15 9 * * 1'},
      }, from: remote))['isError'],
      isNull,
    );
    expect(scheduler.tasks.map((task) => task.project), [remote, remote]);
    expect(scheduler.tasks.map((task) => task.nextRun), [
      DateTime(2026, 5, 18, 8, 30),
      DateTime(2026, 5, 18, 9, 15),
    ]);
  });

  test('stores the complete script without running it at creation', () async {
    const script = '  printf "new commit\\n"\n';
    final response = await call({
      'schedule': calendar,
      'script': script,
    }, from: remote);
    expect(response['isError'], isNull);
    final task = scheduler.tasks.single;
    expect(task.project, remote);
    expect(task.kernel, 'default-acp');
    expect(task.settings, isEmpty);
    expect(task.script, script);
    expect(task.prompt, isEmpty);
    expect(task.lastRun, isNull);
    expect((store.preferences['tasks'] as List).single, task.toJson());
  });

  test('can combine a script with a prompt', () async {
    const script = 'printf updated';
    final response = await call({...request, 'script': script});
    expect(response['isError'], isNull);
    expect(scheduler.tasks.single.script, script);
    expect(scheduler.tasks.single.prompt, request['prompt']);
  });

  test(
    'rejects invalid schedules, unknown projects and default overrides',
    () async {
      for (final input in [
        {...request, 'agent': 'other'},
        {...request, 'model': 'other'},
        {...request, 'script': 123},
        {'schedule': calendar, 'script': '  '},
        {'schedule': calendar},
        {...request, 'project': '/unknown'},
        {
          ...request,
          'schedule': {
            ...calendar,
            'days': [8],
          },
        },
        {
          ...request,
          'schedule': {'type': 'interval', 'minutes': 0},
        },
      ]) {
        expect((await call(input))['isError'], true);
      }
      expect(scheduler.tasks, isEmpty);
    },
  );

  test(
    'unavailable when conversation tools are off or to app agents',
    () async {
      workspace.appFolderRoot = '/bots';
      expect((await call(request, from: '/bots/example'))['isError'], true);
      SessionToolsSetting.current = () => false;
      expect((await call(request))['isError'], true);
      expect(scheduler.tasks, isEmpty);
    },
  );
}

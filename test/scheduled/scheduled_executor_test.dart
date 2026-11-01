import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/scheduled/scheduled_executor.dart';
import 'package:baocode/scheduled/scheduled_task.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_test_support.dart';

ScheduledTask task({
  bool reuse = false,
  String kernel = 'claude-code',
  String location = '/tmp/scheduled-project',
}) => ScheduledTask(
  id: 'task',
  name: 'Audit',
  prompt: 'Run audit',
  kernel: kernel,
  project: location,
  settings: {'model': 'second', 'mode': 'second'},
  reuse: reuse,
  schedule: TaskSchedule(hour: 9, minute: 0, days: {1}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'toggle settings restore both on and off without inventing an off option',
    () async {
      final created = <TaskTestKernel>[];
      final session = ChatSession(
        kernel: taskDescriptor(created),
        historyCount: 0,
      );
      addTearDown(session.dispose);
      session.attach();
      await applyTaskSettings(session, {'fast': 'standard'});
      expect(created.single.fast.enabled, isFalse);
      await applyTaskSettings(session, {'fast': 'fast'});
      expect(created.single.fast.enabled, isTrue);
      await applyTaskSettings(session, {'fast': 'standard'});
      expect(created.single.fast.enabled, isFalse);
      session.detach();
    },
  );

  test('new-run worktree uses existing Git service and reuse retains its directory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'scheduled-worktree-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final root = Directory('${directory.path}/project')..createSync();
    Future<void> git(List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: root.path,
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
    }

    await git(['init']);
    await git([
      '-c',
      'user.name=Task Test',
      '-c',
      'user.email=task@example.invalid',
      'commit',
      '--allow-empty',
      '-m',
      'initial',
    ]);
    final created = <TaskTestKernel>[];
    final workspace = Workspace(kernels: [taskDescriptor(created)]);
    addTearDown(workspace.dispose);
    final t = ScheduledTask(
      id: 'tree',
      name: 'Audit',
      prompt: 'Run audit',
      kernel: 'claude-code',
      project: root.path,
      schedule: task().schedule,
      newWorktree: true,
      reuse: true,
    );
    final executor = ScheduledExecutor(workspace);
    await executor.execute(t, () {});
    final location = t.sessionLocation!;
    expect(location, isNot(root.path));
    expect(Directory(location).existsSync(), isTrue);
    expect(created.single.context.cwd, location);
    await executor.execute(t, () {});
    expect(t.sessionLocation, location);
    expect(created, hasLength(1));
    final trees = await taskGitService(root.path).worktrees();
    expect(trees, hasLength(2));
    expect(trees.last.branch, startsWith('scheduled/'));
  });
  test('background creation uses selected agent/settings without changing focused conversation', () async {
    final created = <TaskTestKernel>[];
    final claude = taskDescriptor(created);
    final acp = taskDescriptor(created, id: 'custom-acp');
    final workspace = Workspace(
      projects: const [Project('Project', '/tmp/scheduled-project')],
      kernels: [claude, acp],
    );
    addTearDown(workspace.dispose);
    final focused = workspace.create();
    final t = task(kernel: acp.id);
    var checkpoints = 0;
    await ScheduledExecutor(workspace).execute(t, () => checkpoints++);
    expect(workspace.current, same(focused));
    expect(workspace.threads, hasLength(2));
    expect(created.last.descriptor.id, 'custom-acp');
    expect(created.last.model.selected, 'second');
    expect(created.last.mode.selected, 'second');
    expect(created.last.sent.single.text, 'Run audit');
    expect(t.sessionId, created.last.sessionId);
    expect(t.sessionLocation, '/tmp/scheduled-project');
    expect(checkpoints, 1);
  });

  test(
    'fresh runs create conversations; reuse loads same conversation',
    () async {
      final created = <TaskTestKernel>[];
      final workspace = Workspace(kernels: [taskDescriptor(created)]);
      addTearDown(workspace.dispose);
      final executor = ScheduledExecutor(workspace);
      final t = task(reuse: true);
      await executor.execute(t, () {});
      final firstId = t.sessionId;
      await executor.execute(t, () {});
      expect(created, hasLength(1));
      expect(created.single.sent, hasLength(2));
      expect(t.sessionId, firstId);
      await executor.execute(task(), () {});
      await executor.execute(task(), () {});
      expect(created, hasLength(3));
    },
  );

  test('resume reads catalog record and keeps SSH location; missing record never falls back', () async {
    const location = 'ssh://dev/home/user/project';
    final catalog = TaskTestCatalog()
      ..records.add(
        SessionRecord(
          id: 'kept',
          title: 'Audit',
          updatedAt: DateTime(2026),
          cwd: location,
        ),
      );
    final created = <TaskTestKernel>[];
    final workspace = Workspace(
      kernels: [taskDescriptor(created, catalog: catalog)],
    );
    addTearDown(workspace.dispose);
    final executor = ScheduledExecutor(workspace);
    final t = task(reuse: true, location: location)
      ..sessionId = 'kept'
      ..sessionLocation = location;
    await executor.execute(t, () {});
    expect(created.single.context.cwd, location);
    expect(created.single.context.resume?.id, 'kept');
    expect(created.single.sent, hasLength(1));
    final missing = task(reuse: true, location: location)
      ..sessionId = 'missing';
    await expectLater(executor.execute(missing, () {}), throwsStateError);
    expect(created, hasLength(1));
    final wrongHost = task(reuse: true, location: location)
      ..sessionId = 'kept'
      ..sessionLocation = '/home/user/project';
    await expectLater(executor.execute(wrongHost, () {}), throwsStateError);
    expect(created, hasLength(1));
  });

  test(
    'running conversations cannot overlap or queue another scheduled prompt',
    () async {
      final created = <TaskTestKernel>[];
      final workspace = Workspace(kernels: [taskDescriptor(created)]);
      addTearDown(workspace.dispose);
      final t = task(reuse: true);
      final executor = ScheduledExecutor(workspace);
      await executor.execute(t, () {});
      created.single.autoFinish = false;
      final running = executor.execute(t, () {});
      await Future<void>.delayed(Duration.zero);
      await expectLater(executor.execute(t, () {}), throwsStateError);
      expect(created.single.sent, hasLength(2));
      created.single.finish();
      await running;
    },
  );

  test(
    'unavailable agent or saved model fails instead of running defaults',
    () async {
      final created = <TaskTestKernel>[];
      final workspace = Workspace(kernels: [taskDescriptor(created)]);
      addTearDown(workspace.dispose);
      await expectLater(
        ScheduledExecutor(workspace).execute(task(kernel: 'removed'), () {}),
        throwsStateError,
      );
      final session = ChatSession(
        kernel: workspace.kernels.first,
        historyCount: 0,
      );
      addTearDown(session.dispose);
      session.attach();
      await expectLater(
        applyTaskSettings(session, {'model': 'removed'}),
        throwsStateError,
      );
      expect(created.single.sent, isEmpty);
      session.detach();
    },
  );
}

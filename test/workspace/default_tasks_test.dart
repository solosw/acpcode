import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/l10n/app_localizations_zh.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/platform/default_task_dir_io.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Catalog implements SessionCatalog {
  _Catalog(this.path);
  final String path;

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: path, sessions: await sessionsIn(path)),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [
    if (cwd == path)
      SessionRecord(
        id: 'everyday-kept',
        title: 'Earlier research',
        updatedAt: DateTime(2026, 11, 5),
        cwd: path,
      ),
  ];

  @override
  Future<void> delete(String id) async {}
}

void main() {
  late Directory temp;
  late DataDirectory previous;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bao-default-tasks-');
    previous = DataDirectory.current;
    DataDirectory.current = DataDirectory(p.join(temp.path, 'data'));
  });

  tearDown(() {
    DataDirectory.current = previous;
    temp.deleteSync(recursive: true);
  });

  Workspace workspace({
    PreferenceStore? preferences,
    List<Project> projects = const [],
    SessionCatalog? catalog,
  }) {
    final mock = MockKernels.claudeCode;
    final value = Workspace(
      projects: projects,
      preferences: preferences,
      kernels: [
        KernelDescriptor(
          id: mock.id,
          label: mock.label,
          icon: mock.icon,
          description: mock.description,
          create: mock.create,
          catalog: catalog,
        ),
      ],
      defaultTaskDirectory: prepareDefaultTaskDirectory(),
      l10n: () => AppLocalizationsZh(),
    );
    addTearDown(value.dispose);
    return value;
  }

  test('creates a persistent directory and never clears existing output', () {
    final path = prepareDefaultTaskDirectory()!;
    expect(path, DataDirectory.current.tasksDir);
    expect(Directory(path).existsSync(), isTrue);
    final file = File(p.join(path, 'notes.md'))..writeAsStringSync('keep me');
    expect(prepareDefaultTaskDirectory(), path);
    expect(file.readAsStringSync(), 'keep me');
    expect(DataDirectory.items, contains('tasks'));
  });

  test(
    'an unavailable default directory does not block opening projects',
    () async {
      final root = Directory(DataDirectory.current.path)..createSync();
      File(p.join(root.path, 'tasks')).writeAsStringSync('not a directory');
      expect(prepareDefaultTaskDirectory(), isNull);
      final value = workspace();
      await value.load();
      expect(value.current, isNull);
      final thread = await value.openFolder(temp.path);
      expect(thread.project.path, temp.path);
    },
  );

  test(
    'first launch starts a chat without choosing any project folder',
    () async {
      final value = workspace();
      await value.load();
      expect(value.selected.project.name, '日常任务');
      expect(value.selected.project.path, DataDirectory.current.tasksDir);
      expect(
        value.selected.session.kernelContext.cwd,
        DataDirectory.current.tasksDir,
      );
      expect(value.sidebarProjects, [value.selected.project]);
      expect(value.canRelocate(value.selected.project), isFalse);
      expect(value.create(), same(value.selected));
    },
  );

  test('adding the default folder leaves existing projects selected', () async {
    final value = workspace(projects: [Project('project', temp.path)]);
    await value.load();
    expect(value.selected.project.path, temp.path);
    expect(value.projects.last.path, DataDirectory.current.tasksDir);
    expect(value.canRelocate(value.selected.project), isTrue);
  });

  test('the default path and output remain available after restart', () async {
    final store = MemoryPreferenceStore();
    final first = workspace(preferences: store);
    await first.load();
    final path = first.selected.project.path;
    File(p.join(path, 'report.md')).writeAsStringSync('saved report');

    final next = workspace(preferences: store);
    await next.load();
    expect(next.selected.project.path, path);
    expect(File(p.join(path, 'report.md')).readAsStringSync(), 'saved report');
    expect(
      next.projects.where((project) => project.path == path),
      hasLength(1),
    );
  });

  test(
    'past everyday conversations are restored in the same project',
    () async {
      final value = workspace(
        catalog: _Catalog(DataDirectory.current.tasksDir),
      );
      await value.load();
      final kept = value.threads.singleWhere(
        (thread) => thread.id == 'everyday-kept',
      );
      expect(kept.project.path, value.defaultTaskDirectory);
      expect(kept.project.name, '日常任务');
      expect(kept.title, 'Earlier research');
      expect(value.projects, hasLength(1));
    },
  );

  test('the everyday entry can reopen a hidden default folder', () async {
    final value = workspace();
    await value.load();
    final project = value.selected.project;
    value.hideProject(project);
    expect(value.isHidden(project), isTrue);
    final reopened = value.create(project: value.openDefaultTaskProject());
    expect(value.isHidden(reopened.project), isFalse);
    expect(reopened.project.path, value.defaultTaskDirectory);
  });
}

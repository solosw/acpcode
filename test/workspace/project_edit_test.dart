// A project named as the user likes, and had in another folder (its own
// moved, say): its conversations, and what is kept of it, go along.

import 'package:baocode/chat/chat_session.dart' show ComposerMessage;
import 'package:baocode/icons/project_icon.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/main.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:baocode/workspace/workspace_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

/// Sessions kept by folder, moved as Claude Code's are.
class _MovingCatalog implements SessionCatalog, MovesSessions {
  final Map<String, List<SessionRecord>> byCwd = {};
  final List<(String, String)> moves = [];

  void keep(String cwd, String id, String title) => (byCwd[cwd] ??= []).add(
    SessionRecord(
      id: id,
      title: title,
      updatedAt: DateTime(2026, 10, 20),
      cwd: cwd,
      path: '$cwd/$id.jsonl',
    ),
  );

  @override
  Future<List<ProjectRecord>> projects() async => [
    for (final MapEntry(key: path, value: sessions) in byCwd.entries)
      ProjectRecord(path: path, sessions: [...sessions]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [...?byCwd[cwd]];

  @override
  Future<void> delete(String id) async {}

  @override
  Future<int> moveSessions(String from, String to) async {
    moves.add((from, to));
    final moved = byCwd.remove(from) ?? const [];
    for (final session in moved) {
      keep(to, session.id, session.title);
    }
    return moved.length;
  }
}

void main() {
  late _MovingCatalog catalog;
  late KernelDescriptor kernel;

  setUp(() {
    catalog = _MovingCatalog()
      ..keep('/code/old', 's1', 'Fix the tests')
      ..keep('/code/old', 's2', 'Write the docs')
      ..keep('/code/other', 's3', 'Elsewhere');
    late final KernelDescriptor descriptor;
    descriptor = kernel = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      catalog: catalog,
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (_) async => FakeCli(),
        readHistory: (_) async => const [],
      ),
    );
  });

  Future<Workspace> loaded({PreferenceStore? preferences}) async {
    final workspace = Workspace(kernels: [kernel], preferences: preferences);
    addTearDown(workspace.dispose);
    await workspace.load();
    return workspace;
  }

  AgentThread thread(Workspace workspace, String id) =>
      workspace.threads.firstWhere((thread) => thread.id == id);

  test('a project is named as the user likes, kept so; named nothing, '
      'after its folder again', () async {
    final preferences = MemoryPreferenceStore();
    final workspace = await loaded(preferences: preferences);
    final old = workspace.projectAt('/code/old');
    expect(old.name, 'old');

    workspace.renameProject(old, '  客户 A 后台  ');
    expect(workspace.projectAt('/code/old').name, '客户 A 后台');
    expect(thread(workspace, 's1').project.name, '客户 A 后台');
    expect(
      workspace.sidebarProjects.map((project) => project.name),
      contains('客户 A 后台'),
    );

    final again = await loaded(preferences: preferences);
    expect(again.projectAt('/code/old').name, '客户 A 后台');
    expect(thread(again, 's2').project.name, '客户 A 后台');

    again.renameProject(again.projectAt('/code/old'), '');
    expect(again.projectAt('/code/old').name, 'old');
  });

  test('moved to another folder, a project keeps its conversations, '
      'name, icon, pin and the agent shown', () async {
    final workspace = await loaded();
    final old = workspace.projectAt('/code/old');
    workspace
      ..renameProject(old, 'Shop')
      ..setIcon(old, const EmojiIcon('🛒'))
      ..setPinnedProject(old, true)
      ..setPinned(thread(workspace, 's1'), true)
      ..select(thread(workspace, 's1'));
    final shown = thread(workspace, 's1')..session;
    expect(shown.isOpen, isTrue);

    final moved = await workspace.relocateProject(
      workspace.projectAt('/code/old'),
      '/code/new',
    );

    expect(moved, ProjectRelocation.moved);
    expect(catalog.moves, [('/code/old', '/code/new')]);
    final paths = workspace.projects.map((project) => project.path);
    expect(paths, contains('/code/new'));
    expect(paths, isNot(contains('/code/old')));
    final project = workspace.projectAt('/code/new');
    expect(project.name, 'Shop');
    expect(workspace.iconOf(project), const EmojiIcon('🛒'));
    expect(workspace.isPinnedProject(project), isTrue);
    for (final id in ['s1', 's2']) {
      expect(thread(workspace, id).project.path, '/code/new');
      expect(thread(workspace, id).record!.cwd, '/code/new');
    }
    expect(thread(workspace, 's1').pinned, isTrue);
    // The agent shown is the one listed again, opened from there.
    expect(workspace.selected.id, 's1');
    expect(identical(workspace.selected, shown), isFalse);
    expect(workspace.grid.panes, [workspace.selected]);
    expect(
      workspace.threads.where((thread) => thread.project.path == '/code/old'),
      isEmpty,
    );
    // Another project's as it was.
    expect(thread(workspace, 's3').project.path, '/code/other');
  });

  test('a new agent nothing was sent to moves with its draft', () async {
    final workspace = await loaded();
    final fresh = workspace.create(project: workspace.projectAt('/code/old'));
    fresh.session.draft.save(
      'half a thought',
      const TextSelection.collapsed(offset: 0),
      const [],
    );

    await workspace.relocateProject(
      workspace.projectAt('/code/old'),
      '/code/new',
    );

    final heir = workspace.selected;
    expect(heir.project.path, '/code/new');
    expect(heir.untouched, isTrue);
    expect(heir.session.draft.content, 'half a thought');
    expect(fresh.isOpen, isTrue);
    expect(workspace.threads, isNot(contains(fresh)));
  });

  test('moved into a project listed already, the two are one', () async {
    final workspace = await loaded();

    await workspace.relocateProject(
      workspace.projectAt('/code/old'),
      '/code/other',
    );

    final listed = workspace.projects
        .where((project) => project.path == '/code/other')
        .toList();
    expect(listed, hasLength(1));
    expect(
      {
        for (final thread in workspace.threads)
          if (thread.id != null) thread.id!: thread.project.path,
      },
      {'s1': '/code/other', 's2': '/code/other', 's3': '/code/other'},
    );
  });

  test('not while one of its agents works', () async {
    final workspace = await loaded();
    final working = thread(workspace, 's1');
    workspace.select(working);
    working.session.send(const ComposerMessage(text: 'go on'));
    expect(working.status, ThreadStatus.running);

    final moved = await workspace.relocateProject(
      workspace.projectAt('/code/old'),
      '/code/new',
    );

    expect(moved, ProjectRelocation.busy);
    expect(catalog.moves, isEmpty);
    expect(working.project.path, '/code/old');
  });

  testWidgets('Edit Project… renames it, and moves it to the folder '
      'typed', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final isFolder = ProjectDialog.isFolder;
    ProjectDialog.isFolder = (path) => path == '/code/site-v2';
    addTearDown(() => ProjectDialog.isFolder = isFolder);
    final workspace = Workspace(
      projects: const [Project('site', '/code/site')],
      kernels: [MockKernels.claudeCode],
    );
    await tester.pumpWidget(BaoCodeApp(workspace: workspace));
    workspace.create(project: workspace.projects.first);
    await tester.pump();

    Future<void> open() async {
      final context = tester.element(find.byType(Sidebar));
      showProjectDialog(
        context,
        workspace: workspace,
        project: workspace.projectAt(workspace.projects.first.path),
      );
      await tester.pumpAndSettle();
    }

    await open();
    final fields = find.descendant(
      of: find.byType(ProjectDialog),
      matching: find.byType(EditableText),
    );
    await tester.enterText(fields.first, 'Marketing site');
    await tester.enterText(fields.last, '/code/nowhere');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('There is no folder at this path.'), findsOneWidget);
    expect(workspace.projects.single.path, '/code/site');

    await tester.enterText(fields.last, '/code/site-v2/');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectDialog), findsNothing);
    expect(workspace.projects.single.path, '/code/site-v2');
    expect(workspace.projects.single.name, 'Marketing site');
    expect(workspace.selected.project.path, '/code/site-v2');
  });
}

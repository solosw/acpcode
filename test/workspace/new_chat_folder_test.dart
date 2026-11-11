// Over a new chat's input, the folder it is to work in: a project, none
// (the default task directory), or one picked in Finder; it goes once a message is sent.

import 'dart:async';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/ide/ide_quick_input.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/main.dart';
import 'package:baocode/remote/open_remote.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/workspace/new_chat_folder_bar.dart';
import 'package:baocode/workspace/workspace.dart';

const _window = MethodChannel('baocode/window');
const _tasks = '/data/baocode/tasks';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// The app on the mock workspace, a new agent open in its first project.
Future<Workspace> _pumpNew(WidgetTester tester, {bool empty = false}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _window,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _window,
      null,
    ),
  );
  final pick = NewChatFolderBar.pickDirectory;
  addTearDown(() {
    NewChatFolderBar.pickDirectory = pick;
  });
  final workspace = Workspace(
    projects: empty
        ? const []
        : const [
            Project('baocode', '~/code/baocode'),
            Project('cursor-docs', '~/code/cursor-docs'),
            Project('api-gateway', '~/work/api-gateway'),
          ],
    kernels: [MockKernels.claudeCode],
    defaultTaskDirectory: _tasks,
  );
  if (empty) await tester.runAsync(workspace.load);
  await tester.pumpWidget(BaoCodeApp(workspace: workspace));
  if (!empty) workspace.create();
  await tester.pump();
  return workspace;
}

Finder get _bar => find.byType(NewChatFolderBar);

/// Kept sessions found only once [found] completes, as Claude Code's are
/// after all of them are read.
class _SlowCatalog implements SessionCatalog {
  final found = Completer<List<SessionRecord>>();

  @override
  Future<List<ProjectRecord>> projects() async => const [];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) => found.future;

  @override
  Future<void> delete(String id) async {}
}

/// A real remote file RPC over streams, with an isolated home directory.
Future<String> _remoteTasks(WidgetTester tester) async {
  final harness = (await tester.runAsync(RemoteHarness.start))!;
  final home = harness.dataDir.resolveSymbolicLinksSync();
  final hello = harness.client.hello!;
  harness.client.hello = RemoteHello(
    protocol: hello.protocol,
    version: hello.version,
    platform: hello.platform,
    pid: hello.pid,
    home: home,
    dataDir: hello.dataDir,
  );
  final previous = SshHosts.instance;
  final hosts = SshHosts.instance = SshHosts(
    connect: (target, {onProgress}) async =>
        SshConnection.over(target, harness.client),
  );
  addTearDown(() async {
    await hosts.closeAll();
    SshHosts.instance = previous;
    await harness.close();
  });
  await tester.runAsync(() => hosts['dev'].ready);
  return home;
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
      if (ready()) return;
    }
    fail('Remote everyday tasks did not finish');
  });
}

void main() {
  testWidgets('a new chat waits in the middle, under where it works', (
    tester,
  ) async {
    final workspace = await _pumpNew(tester);
    expect(workspace.selected.project.name, 'baocode');
    expect(_bar, findsOneWidget);
    expect(
      find.descendant(of: _bar, matching: find.text('baocode')),
      findsOneWidget,
    );
    expect(find.text('Open from Finder'), findsOneWidget);
    // Its input is halfway down, not at the bottom.
    final bar = tester.getTopLeft(_bar).dy;
    expect(bar, lessThan(900 / 2));
    expect(bar, greaterThan(900 / 4));
  }, variant: _mac);

  testWidgets('an empty workspace opens directly into everyday tasks', (
    tester,
  ) async {
    final workspace = await _pumpNew(tester, empty: true);
    expect(_bar, findsOneWidget);
    expect(workspace.selected.session.kernelContext.cwd, _tasks);
    expect(find.text('Open a project folder'), findsNothing);
    expect(
      find.descendant(of: _bar, matching: find.text('Everyday Tasks')),
      findsOneWidget,
    );
  }, variant: _mac);

  testWidgets('a hidden project is not offered for a new chat', (tester) async {
    final workspace = await _pumpNew(tester);
    final hidden = workspace.projects.firstWhere(
      (project) => project.path == '~/code/cursor-docs',
    );
    workspace.hideProject(hidden);
    await tester.pump();

    await tester.tap(find.descendant(of: _bar, matching: find.text('baocode')));
    await tester.pumpAndSettle();
    expect(find.text('cursor-docs'), findsNothing);
  }, variant: _mac);

  testWidgets('everyday tasks use the default directory, in its place', (
    tester,
  ) async {
    final workspace = await _pumpNew(tester);
    final was = workspace.selected;
    await tester.tap(find.descendant(of: _bar, matching: find.text('baocode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday Tasks').last);
    await tester.pumpAndSettle();

    final moved = workspace.selected;
    expect(moved.project.path, _tasks);
    expect(moved.session.kernelContext.cwd, _tasks);
    // The untouched one is gone, not left behind in the sidebar.
    expect(workspace.threads, isNot(contains(was)));
    expect(
      find.descendant(of: _bar, matching: find.text('Everyday Tasks')),
      findsOneWidget,
    );
  }, variant: _mac);

  testWidgets('the sidebar keeps everyday tasks on the selected host', (
    tester,
  ) async {
    final home = await _remoteTasks(tester);
    final tasks = p.join(home, '.baocode', 'tasks');
    final workspace = await _pumpNew(tester);
    await workspace.openFolder('ssh://dev/home/me/app');
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(Sidebar),
            matching: find.text('Everyday Tasks'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await _waitFor(tester, () => workspace.selected.project.root == tasks);
    await tester.pumpAndSettle();
    expect(workspace.selected.project.path, RemoteLocation.of('dev', tasks));
    expect(workspace.selected.project.name, 'Everyday Tasks');
    expect(
      workspace.selected.session.kernelContext.cwd,
      RemoteLocation.of('dev', tasks),
    );
    expect(workspace.sidebarHost, 'dev');
    expect(Directory(tasks).existsSync(), isTrue);
    expect(_bar, findsOneWidget);
    await tester.tap(
      find.descendant(of: _bar, matching: find.text('Everyday Tasks')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('dev: ~/.baocode/tasks'), findsOneWidget);
  }, variant: _mac);

  testWidgets('the sidebar host wins over a focused local conversation', (
    tester,
  ) async {
    final home = await _remoteTasks(tester);
    final workspace = await _pumpNew(tester);
    expect(workspace.selected.project.host, isNull);
    workspace.addSshHost('dev');
    workspace.sidebarHost = 'dev';
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(Sidebar),
            matching: find.text('Everyday Tasks'),
          )
          .first,
    );
    await _waitFor(tester, () => workspace.selected.project.host == 'dev');
    expect(workspace.selected.project.root, p.join(home, '.baocode', 'tasks'));
    expect(workspace.sidebarHost, 'dev');
  }, variant: _mac);

  testWidgets('the working folder menu keeps everyday tasks on its host', (
    tester,
  ) async {
    final home = await _remoteTasks(tester);
    final tasks = p.join(home, '.baocode', 'tasks');
    final workspace = await _pumpNew(tester);
    await workspace.openFolder('ssh://dev/home/me/app');
    final was = workspace.selected;
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: _bar, matching: find.text('app')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday Tasks').last);
    await _waitFor(tester, () => workspace.selected.project.root == tasks);
    await tester.pumpAndSettle();
    expect(workspace.selected.project.host, 'dev');
    expect(workspace.sidebarHost, 'dev');
    expect(workspace.threads, isNot(contains(was)));
    final output = File(p.join(tasks, 'report.md'))..writeAsStringSync('keep');
    await tester.runAsync(() => workspace.openDefaultTaskProjectOn('dev'));
    expect(output.readAsStringSync(), 'keep');
    workspace.hideProject(workspace.selected.project);
    final reopened = (await tester.runAsync(
      () => workspace.openDefaultTaskProjectOn('dev'),
    ))!;
    expect(workspace.isHidden(reopened), isFalse);
    expect(reopened.path, RemoteLocation.of('dev', tasks));
  }, variant: _mac);

  testWidgets(
    'a failed remote task directory stays remote and shows the error',
    (tester) async {
      final home = await _remoteTasks(tester);
      File(p.join(home, '.baocode')).writeAsStringSync('not a folder');
      final workspace = await _pumpNew(tester);
      await workspace.openFolder('ssh://dev/home/me/app');
      final was = workspace.selected;
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(
          find
              .descendant(
                of: find.byType(Sidebar),
                matching: find.text('Everyday Tasks'),
              )
              .first,
        );
      });
      await _waitFor(
        tester,
        () => find.textContaining('is not a directory').evaluate().isNotEmpty,
      );
      await tester.pump();
      expect(workspace.selected, same(was));
      expect(workspace.sidebarHost, 'dev');
      expect(find.textContaining('is not a directory'), findsOneWidget);
    },
    variant: _mac,
  );

  testWidgets('the local sidebar still opens the local task directory', (
    tester,
  ) async {
    final workspace = await _pumpNew(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(Sidebar),
            matching: find.text('Everyday Tasks'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(workspace.selected.project.path, _tasks);
    expect(workspace.sidebarHost, isNull);
  }, variant: _mac);

  testWidgets('a folder picked in Finder becomes its project', (tester) async {
    final workspace = await _pumpNew(tester);
    NewChatFolderBar.pickDirectory = () async => '/tmp/picked';
    await tester.tap(find.text('Open from Finder'));
    await tester.pumpAndSettle();

    expect(workspace.selected.project.path, '/tmp/picked');
    expect(workspace.projects.first.path, '/tmp/picked');
    expect(
      find.descendant(of: _bar, matching: find.text('picked')),
      findsOneWidget,
    );
  }, variant: _mac);

  testWidgets('it goes once a message is sent, the input to the bottom', (
    tester,
  ) async {
    final workspace = await _pumpNew(tester);
    workspace.selected.session.send(const ComposerMessage(text: 'hello'));
    await tester.pump();
    expect(_bar, findsNothing);
    // An agent with a conversation has none either.
    workspace.select(workspace.threads.first);
    await tester.pump();
    expect(_bar, findsNothing);
    // The mock's reply played out.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Closed, its kernel keeps the conversation's calls in the ledger, which
    // writes them a moment later.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }, variant: _mac);

  test(
    'a new folder is moved to at once, its kept sessions listed after',
    () async {
      final catalog = _SlowCatalog();
      final mock = MockKernels.claudeCode;
      final kernel = KernelDescriptor(
        id: mock.id,
        label: mock.label,
        icon: mock.icon,
        description: mock.description,
        create: mock.create,
        catalog: catalog,
      );
      final workspace = Workspace(
        projects: const [Project('a', '/tmp/a')],
        kernels: [kernel],
      );
      addTearDown(workspace.dispose);
      final was = workspace.create();

      final moved = workspace.moveNew(was, _tasks);
      expect(workspace.selected, same(moved));
      expect(moved.project.path, _tasks);
      expect(workspace.threads, [moved]);

      catalog.found.complete([
        SessionRecord(
          id: 'kept',
          title: 'Earlier everyday task',
          updatedAt: DateTime(2026, 9, 30),
          cwd: _tasks,
        ),
      ]);
      await pumpEventQueue();
      expect(workspace.threads.map((thread) => thread.title), [
        'New Chat',
        'Earlier everyday task',
      ]);
      expect(workspace.selected, same(moved));
    },
  );

  testWidgets('SSH hosts are under Remote, their projects at their side '
      'under Choose Folder…, with Open Remote Project…, which asks for a '
      'host', (tester) async {
    final workspace = await _pumpNew(tester);
    await workspace.openFolder('ssh://dev/home/me/app');
    await workspace.openFolder('ssh://dev/home/me/api');
    await workspace.openFolder('ssh://prod/srv/web');
    await tester.pumpAndSettle();
    expect(workspace.selected.project.host, 'prod');
    await workspace.openFolder('ssh://dev/home/me/app');
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: _bar, matching: find.text('app')));
    await tester.pumpAndSettle();
    final remote = tester.getTopLeft(find.text('Remote')).dy;
    // This machine's first, without a heading; a row for each host under
    // Remote, not one for each project.
    expect(
      tester.getTopLeft(find.text('Everyday Tasks').last).dy,
      lessThan(remote),
    );
    expect(tester.getTopLeft(find.text('2 projects')).dy, greaterThan(remote));
    expect(find.text('1 project'), findsOneWidget);
    expect(find.text('/home/me/app'), findsNothing);

    // Picked, a host shows its projects at its side, under a folder there
    // to pick; one picked there is moved to.
    await tester.tap(find.text('2 projects'));
    await tester.pumpAndSettle();
    expect(find.text('/home/me/app'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Choose Folder…')).dy,
      lessThan(
        tester
            .getTopLeft(
              find.descendant(of: _bar, matching: find.text('app')).last,
            )
            .dy,
      ),
    );
    expect(
      tester.getTopLeft(find.text('/home/me/api')).dx,
      greaterThan(tester.getTopRight(find.text('2 projects')).dx),
    );
    await tester.tap(find.text('/home/me/api'));
    await tester.pumpAndSettle();
    expect(workspace.selected.project.path, 'ssh://dev/home/me/api');
    expect(find.text('/home/me/api'), findsNothing);

    await tester.tap(find.descendant(of: _bar, matching: find.text('api')));
    await tester.pumpAndSettle();
    expect(find.text('Open Remote Project...'), findsOneWidget);

    // Picking it walks to a host; nothing is connected to yet.
    final configHosts = OpenRemoteFlow.defaultConfigHosts;
    OpenRemoteFlow.defaultConfigHosts = () async => ['dev', 'prod'];
    addTearDown(() => OpenRemoteFlow.defaultConfigHosts = configHosts);
    await tester.tap(find.text('Open Remote Project...'));
    await tester.pumpAndSettle();
    expect(find.byType(IdeQuickInput), findsOneWidget);
    expect(
      tester
          .widget<IdeQuickInput>(find.byType(IdeQuickInput))
          .pick
          ?.placeholder,
      'Select a host, add one, or type user@host[:port]',
    );
  }, variant: _mac);
}

// Over a new chat's input, multi-folder workspaces under their own heading,
// with Create Workspace…, whose dialog takes a name and folders: from the
// projects listed, or picked in Finder.

import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:baocode/settings/pages/agent_remote_folder_dialog.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/main.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/workspace/new_chat_folder_bar.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:baocode/workspace/workspace_dialog.dart';

import 'project_workspace_test.dart' show FakeWorkspaceDirectories;

const _window = MethodChannel('baocode/window');
const _tasks = '/data/baocode/tasks';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// The app, a new agent open in its first project, `site`.
Future<Workspace> _pumpNew(WidgetTester tester) async {
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
  final pick = WorkspaceDialog.pickDirectory;
  final canPick = WorkspaceDialog.canPickDirectory;
  final remotePick = WorkspaceDialog.pickRemoteDirectory;
  WorkspaceDialog.canPickDirectory = () => true;
  addTearDown(() {
    WorkspaceDialog.pickDirectory = pick;
    WorkspaceDialog.canPickDirectory = canPick;
    WorkspaceDialog.pickRemoteDirectory = remotePick;
  });
  final workspace = Workspace(
    projects: const [
      Project('site', '/code/site'),
      Project('api', '/code/api'),
      Project('docs', '/code/docs'),
    ],
    kernels: [MockKernels.claudeCode],
    workspaceDirectories: FakeWorkspaceDirectories(),
    defaultTaskDirectory: _tasks,
  );
  await tester.pumpWidget(BaoCodeApp(workspace: workspace));
  workspace.create(project: workspace.projects.first);
  await tester.pump();
  return workspace;
}

Finder get _bar => find.byType(NewChatFolderBar);

Future<void> _openMenu(WidgetTester tester, String current) async {
  await tester.tap(find.descendant(of: _bar, matching: find.text(current)));
  await tester.pumpAndSettle();
}

Future<String> _remoteHome(WidgetTester tester) async {
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
  Directory(p.join(home, 'site')).createSync();
  Directory(p.join(home, 'api')).createSync();
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
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
      if (ready()) return;
    }
    fail(
      'Remote workspace operation did not finish: '
      '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
    );
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SSH workspace creation browses and creates on the same host', (
    tester,
  ) async {
    final home = await _remoteHome(tester);
    final workspace = await _pumpNew(tester);
    final site = RemoteLocation.of('dev', p.join(home, 'site'));
    final api = RemoteLocation.of('dev', p.join(home, 'api'));
    await workspace.openFolder(site);
    await tester.pumpAndSettle();
    await _openMenu(tester, 'site');
    await tester.tap(find.text('Create Workspace…'));
    await tester.pumpAndSettle();
    expect(find.text(site), findsOneWidget);
    expect(find.text('Add from Finder…'), findsNothing);
    WorkspaceDialog.pickDirectory = () async {
      fail('A remote workspace must never open the local file picker');
    };
    WorkspaceDialog.canPickDirectory = () => false;
    await tester.pump();
    await tester.tap(find.text('Add from dev…'));
    await _waitFor(
      tester,
      () =>
          find.byType(AgentRemoteFolderDialog).evaluate().isNotEmpty &&
          find.text('api').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('api'));
    await _waitFor(
      tester,
      () => find.text(p.join(home, 'api')).evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Select this folder'));
    await tester.pumpAndSettle();
    expect(find.text(api), findsOneWidget);
    final dialog = find.byType(WorkspaceDialog);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(EditableText)),
      'remote web',
    );
    await tester.tap(find.text('Create'));
    await _waitFor(tester, () => workspace.workspaces.isNotEmpty);
    final made = workspace.workspaces.single;
    expect(made.host, 'dev');
    expect(made.folders, [site, api]);
    expect(Directory(RemoteLocation.pathOf(made.path)).existsSync(), isTrue);
    expect(workspace.selected.project.path, made.path);
    expect(workspace.sidebarHost, 'dev');
    expect(workspace.selected.session.kernelContext.workspace!()!.folders, [
      p.join(home, 'site'),
      p.join(home, 'api'),
    ]);
  }, variant: _mac);

  testWidgets('new workspace only offers projects on the chosen host', (
    tester,
  ) async {
    final home = await _remoteHome(tester);
    final workspace = await _pumpNew(tester);
    final site = RemoteLocation.of('dev', p.join(home, 'site'));
    final api = RemoteLocation.of('dev', p.join(home, 'api'));
    await workspace.openFolder(site);
    await workspace.openFolder(api);
    await workspace.openFolder('ssh://prod/srv/other');
    workspace.sidebarHost = 'dev';
    await tester.pumpAndSettle();
    final shown = showWorkspaceDialog(
      tester.element(_bar),
      workspace: workspace,
      host: workspace.sidebarHost,
    );
    await tester.pumpAndSettle();
    expect(find.text('Add from dev…'), findsOneWidget);
    await tester.tap(find.text('Add from Projects'));
    await tester.pumpAndSettle();
    expect(find.text('other').hitTestable(), findsNothing);
    expect(find.text('docs').hitTestable(), findsNothing);
    await tester.tap(find.text('api').last);
    await tester.pumpAndSettle();
    expect(find.text(api), findsOneWidget);
    await tester.tap(find.text('Create'));
    await _waitFor(tester, () => workspace.workspaces.isNotEmpty);
    expect((await shown)!.host, 'dev');
  }, variant: _mac);

  testWidgets(
    'editing a local workspace uses local folders with an SSH sidebar selected',
    (tester) async {
      final workspace = await _pumpNew(tester);
      final local = workspace.createWorkspace('local', ['/code/site'])!;
      workspace.addSshHost('dev');
      workspace.sidebarHost = 'dev';
      final shown = showWorkspaceDialog(
        tester.element(_bar),
        workspace: workspace,
        editing: local,
      );
      await tester.pumpAndSettle();
      WorkspaceDialog.pickDirectory = () async => '/code/api';
      WorkspaceDialog.pickRemoteDirectory = (_, _) async {
        fail('Local editing opened the remote picker');
      };
      await tester.tap(find.text('Add from Finder…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((await shown)!.folders, ['/code/site', '/code/api']);
    },
    variant: _mac,
  );

  testWidgets('remote creation errors keep the dialog and server selected', (
    tester,
  ) async {
    final home = await _remoteHome(tester);
    File(p.join(home, '.baocode')).writeAsStringSync('blocked');
    final workspace = await _pumpNew(tester);
    final site = RemoteLocation.of('dev', p.join(home, 'site'));
    await workspace.openFolder(site);
    final was = workspace.selected;
    await tester.pumpAndSettle();
    await _openMenu(tester, 'site');
    await tester.tap(find.text('Create Workspace…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await _waitFor(
      tester,
      () => find.textContaining('is not a directory').evaluate().isNotEmpty,
    );
    expect(find.byType(WorkspaceDialog), findsOneWidget);
    expect(workspace.workspaces, isEmpty);
    expect(workspace.selected, same(was));
    expect(workspace.sidebarHost, 'dev');
  }, variant: _mac);

  testWidgets('workspaces are under their own heading, with Create '
      'Workspace…; one picked has the agent work there', (tester) async {
    final workspace = await _pumpNew(tester);
    final web = workspace.createWorkspace('web', ['/code/site', '/code/api'])!;
    workspace.create(project: workspace.projectAt('/code/site'));
    await tester.pumpAndSettle();

    await _openMenu(tester, 'site');
    final heading = tester.getTopLeft(find.text('Workspaces')).dy;
    expect(tester.getTopLeft(find.text('docs').last).dy, lessThan(heading));
    expect(tester.getTopLeft(find.text('web').last).dy, greaterThan(heading));
    expect(find.text('2 folders · site, api'), findsOneWidget);
    expect(find.text('Create Workspace…'), findsOneWidget);

    await tester.tap(find.text('2 folders · site, api'));
    await tester.pumpAndSettle();
    final moved = workspace.selected;
    expect(moved.project.path, web.path);
    expect(moved.session.kernelContext.cwd, web.path);
    expect(moved.session.kernelContext.workspace!()!.folders, [
      '/code/site',
      '/code/api',
    ]);
    // The pill shows its name, with the workspace's glyph.
    expect(find.descendant(of: _bar, matching: find.text('web')), findsOne);
    expect(
      find.descendant(of: _bar, matching: find.byIcon(Codicons.folderLibrary)),
      findsOneWidget,
    );
  }, variant: _mac);

  testWidgets('Create Workspace… starts with the folder the agent was to '
      'work in, adds projects and folders from Finder, and has the agent '
      'work in the workspace made', (tester) async {
    final workspace = await _pumpNew(tester);
    await _openMenu(tester, 'site');
    await tester.tap(find.text('Create Workspace…'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceDialog), findsOneWidget);
    final dialog = find.byType(WorkspaceDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('/code/site')),
      findsOneWidget,
    );

    // From the projects listed: those not in it yet, checked once added.
    await tester.tap(find.text('Add from Projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('docs').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialog, matching: find.text('/code/docs')),
      findsOneWidget,
    );

    WorkspaceDialog.pickDirectory = () async => '/tmp/picked';
    await tester.tap(find.text('Add from Finder…'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialog, matching: find.text('/tmp/picked')),
      findsOneWidget,
    );

    // Taken out again with its ×.
    await tester.tap(find.byTooltip('Remove docs'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(EditableText)),
      'full stack',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceDialog), findsNothing);
    final made = workspace.workspaces.single;
    expect(made.name, 'full stack');
    expect(made.folders, ['/code/site', '/tmp/picked']);
    expect(workspace.selected.project.path, made.path);
  }, variant: _mac);

  testWidgets('a workspace needs a folder; unnamed, it is named after its '
      'folders', (tester) async {
    final workspace = await _pumpNew(tester);
    final context = tester.element(_bar);
    final shown = showWorkspaceDialog(context, workspace: workspace);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Add at least one folder.'), findsOneWidget);
    expect(workspace.workspaces, isEmpty);

    WorkspaceDialog.pickDirectory = () async => '/code/api';
    await tester.tap(find.text('Add from Finder…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect((await shown)!.name, 'api');
  }, variant: _mac);

  testWidgets('the sidebar marks a workspace, and edits it from its menu', (
    tester,
  ) async {
    final workspace = await _pumpNew(tester);
    final web = workspace.createWorkspace('web', ['/code/site', '/code/api'])!;
    await tester.pumpAndSettle();

    final sidebar = find.byType(Sidebar);
    final header = find.descendant(of: sidebar, matching: find.text('web'));
    expect(header, findsOneWidget);
    // Its glyph and how many folders, beside its name.
    expect(
      find.descendant(
        of: sidebar,
        matching: find.byIcon(Codicons.folderLibrary),
      ),
      findsWidgets,
    );
    expect(find.descendant(of: sidebar, matching: find.text('2')), findsOne);

    await tester.tap(header, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Workspace…'));
    await tester.pumpAndSettle();
    final dialog = find.byType(WorkspaceDialog);
    expect(find.text('Edit Workspace'), findsOneWidget);
    await tester.tap(
      find.descendant(of: dialog, matching: find.byTooltip('Remove site')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(workspace.workspaceAt(web.path)!.folders, ['/code/api']);
  }, variant: _mac);
}

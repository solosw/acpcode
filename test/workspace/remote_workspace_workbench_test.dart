import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/search/text_search.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/main.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:baocode/workspace/chat_terminal.dart';
import 'package:baocode/workspace/project_workspace.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ide/git/fake_git.dart';
import '../ide/terminal/fake_terminal.dart';
import '../remote/remote_harness.dart';
import 'project_workspace_test.dart' show FakeWorkspaceDirectories;

const _window = MethodChannel('baocode/window');
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

Future<
  ({Workspace workspace, ProjectWorkspace multi, List<String> gitLocations})
>
_pumpRemoteWorkspace(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _window,
    (_) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _window,
      null,
    ),
  );
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
  final rawFolders = [p.join(home, 'site'), p.join(home, 'api')];
  for (final folder in rawFolders) {
    Directory(folder).createSync();
    File(p.join(folder, 'source.txt')).writeAsStringSync('needle in $folder');
  }
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
  final workspace = Workspace(
    kernels: [MockKernels.claudeCode],
    workspaceDirectories: FakeWorkspaceDirectories(),
  );
  final multi = (await tester.runAsync(
    () => workspace.createWorkspaceOn('remote web', [
      for (final folder in rawFolders) RemoteLocation.of('dev', folder),
    ], host: 'dev'),
  ))!;
  workspace.create(project: workspace.projectAt(multi.path));
  final gitLocations = <String>[];
  await tester.pumpWidget(
    BaoCodeApp(
      workspace: workspace,
      terminalBackend: fakeTerminalBackend([]),
      gitFor: (location) {
        gitLocations.add(location);
        return FakeGit(RemoteLocation.pathOf(location)).repository();
      },
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  return (workspace: workspace, multi: multi, gitLocations: gitLocations);
}

Future<void> _settleRemote(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'remote workspace side panel lists and searches actual roots and removes by location',
    (tester) async {
      final (:workspace, :multi, :gitLocations) = await _pumpRemoteWorkspace(
        tester,
      );
      final session = workspace.selected.session;
      final panel = tester
          .widget<AgentSidePanelArea>(find.byType(AgentSidePanelArea).first)
          .panel;
      panel.showSection(session, SidePanelSection.files);
      await _settleRemote(tester);
      var view = tester.widget<AgentSidePanelView>(
        find.byType(AgentSidePanelView).first,
      );
      expect(view.roots, multi.rawFolders);
      expect(view.repositories.map((entry) => entry.$1), multi.rawFolders);
      expect(gitLocations, containsAll(multi.folders));
      for (final root in view.roots) {
        final files = await tester.runAsync(() => view.files.list(root));
        expect(files!.map((file) => file.path), [p.join(root, 'source.txt')]);
      }
      final found = await tester.runAsync(
        () => view
            .searchEngine(
              RemoteLocation.pathOf(multi.path),
              const IdeTextQuery('needle'),
            )
            .toList(),
      );
      expect(
        found!.whereType<IdeFileMatches>().map((file) => file.path),
        unorderedEquals([
          for (final root in multi.rawFolders) p.join(root, 'source.txt'),
        ]),
      );
      final explorer = panel.explorerOf(
        session.root!,
        view.files,
        roots: view.roots,
        multiRoot: true,
      );
      view.onRemoveFolder!(multi.rawFolders.first);
      await _settleRemote(tester);
      expect(workspace.workspaceAt(multi.path)!.folders, [multi.folders.last]);
      view = tester.widget<AgentSidePanelView>(
        find.byType(AgentSidePanelView).first,
      );
      expect(view.roots, [multi.rawFolders.last]);
      expect(explorer.roots, [multi.rawFolders.last]);
    },
    variant: _mac,
  );

  testWidgets(
    'remote workspace IDE uses raw roots and maps Git and folder removal to SSH locations',
    (tester) async {
      final (:workspace, :multi, :gitLocations) = await _pumpRemoteWorkspace(
        tester,
      );
      workspace.openIdeFolder(multi.path);
      workspace.layout = WorkspaceLayout.ide;
      await _settleRemote(tester);
      final ide = tester.widget<IdeWorkbench>(find.byType(IdeWorkbench).first);
      final space = ide.workspace;
      expect(space.roots, multi.rawFolders);
      expect(space.repositories.map((entry) => entry.$1), multi.rawFolders);
      expect(gitLocations, containsAll(multi.folders));
      expect(gitLocations.every(RemoteLocation.isRemote), isTrue);
      for (final root in space.roots) {
        final files = await tester.runAsync(() => space.files.list(root));
        expect(files!.map((file) => file.path), [p.join(root, 'source.txt')]);
      }
      ide.onRemoveFolder!(multi.rawFolders.first);
      await _settleRemote(tester);
      expect(workspace.workspaceAt(multi.path)!.folders, [multi.folders.last]);
      expect(space.roots, [multi.rawFolders.last]);
      workspace.addWorkspaceFolder(
        workspace.workspaceAt(multi.path)!,
        multi.folders.first,
      );
      await _settleRemote(tester);
      expect(space.roots, [multi.rawFolders.last, multi.rawFolders.first]);
    },
    variant: _mac,
  );

  testWidgets(
    'remote workspace terminals start in a raw folder and use raw cwd for an empty workspace',
    (tester) async {
      final (:workspace, :multi, gitLocations: _) = await _pumpRemoteWorkspace(
        tester,
      );
      final terminals = tester
          .widget<ChatTerminalArea>(find.byType(ChatTerminalArea).first)
          .terminals;
      final service = terminals.terminalsOf(multi.path);
      expect(service.root, multi.rawFolders.first);
      final launch = await service.backend.launch(service.root);
      expect(launch.workingDirectory, multi.rawFolders.first);
      final empty = (await tester.runAsync(
        () => workspace.createWorkspaceOn('empty', [], host: 'dev'),
      ))!;
      expect(
        terminals.terminalsOf(empty.path).root,
        RemoteLocation.pathOf(empty.path),
      );
    },
    variant: _mac,
  );
}

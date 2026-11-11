// Multi-folder workspaces: made, kept between runs, renamed and deleted;
// and what an agent started in one is given of its folders.

import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/client.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/project_workspace.dart';
import 'package:baocode/workspace/workspace.dart';

/// Workspaces' folders under [root], nothing written.
class FakeWorkspaceDirectories extends ProjectWorkspaceDirectories {
  FakeWorkspaceDirectories([this.root = '/data/workspaces']);

  @override
  final String? root;

  @override
  ProjectWorkspace restore(
    ProjectWorkspace workspace, {
    List<String> previousPaths = const [],
  }) => workspace;

  final List<ProjectWorkspace> written = [];

  @override
  void write(ProjectWorkspace workspace) => written.add(workspace);
}

Workspace _workspace({
  PreferenceStore? preferences,
  ProjectWorkspaceDirectories? directories,
}) => Workspace(
  kernels: [MockKernels.claudeCode],
  preferences: preferences,
  workspaceDirectories: directories ?? FakeWorkspaceDirectories(),
);

void main() {
  group('Workspace', () {
    test('makes one in a folder of its own, listed first', () async {
      final directories = FakeWorkspaceDirectories();
      final workspace = _workspace(directories: directories);
      await workspace.load();
      final made = workspace.createWorkspace('  web  ', [
        '/code/site',
        '/code/api',
        '/code/site',
      ])!;
      expect(made.name, 'web');
      expect(made.folders, ['/code/site', '/code/api']);
      expect(made.path, startsWith('/data/workspaces/'));
      expect(directories.written, [made]);
      final project = workspace.sidebarProjects.first;
      expect(project.path, made.path);
      expect(project.name, 'web');
      expect(workspace.workspaceOf(project), made);
      expect(workspace.projectAt(made.path).name, 'web');
    });

    test('none where workspaces cannot be kept', () async {
      final workspace = _workspace(directories: FakeWorkspaceDirectories(null));
      await workspace.load();
      expect(workspace.createWorkspace('web', ['/code/site']), isNull);
    });

    test('is kept between runs, listed though nothing was asked there '
        '(its folder in the data directory as it is then)', () async {
      final store = MemoryPreferenceStore();
      final first = _workspace(preferences: store);
      await first.load();
      final made = first.createWorkspace('web', ['/code/site', '/code/api'])!;
      first.dispose();

      final next = _workspace(
        preferences: store,
        directories: FakeWorkspaceDirectories('/moved/workspaces'),
      );
      await next.load();
      final kept = next.workspaces.single;
      expect(kept.id, made.id);
      expect(kept.name, 'web');
      expect(kept.folders, ['/code/site', '/code/api']);
      expect(kept.path, '/moved/workspaces/${made.id}');
      expect(
        next.sidebarProjects.map((project) => (project.name, project.path)),
        contains(('web', kept.path)),
      );
    });

    test('renamed, its agents are listed under the new name', () async {
      final workspace = _workspace();
      await workspace.load();
      final made = workspace.createWorkspace('web', ['/code/site'])!;
      final thread = workspace.create(project: workspace.projectAt(made.path));
      workspace.updateWorkspace(made, name: 'frontend');
      expect(workspace.workspaceAt(made.path)!.name, 'frontend');
      expect(thread.project.name, 'frontend');
      expect(workspace.sidebarProjects.first.name, 'frontend');
    });

    test('folders are added and taken out', () async {
      final workspace = _workspace();
      await workspace.load();
      final made = workspace.createWorkspace('web', ['/code/site'])!;
      workspace.addWorkspaceFolder(made, '/code/api');
      workspace.addWorkspaceFolder(made, '/code/api');
      expect(workspace.workspaceAt(made.path)!.folders, [
        '/code/site',
        '/code/api',
      ]);
      workspace.removeWorkspaceFolder(made, '/code/site');
      expect(workspace.workspaceAt(made.path)!.folders, ['/code/api']);
    });

    test('deleted, it is forgotten and off the sidebar', () async {
      final store = MemoryPreferenceStore();
      final workspace = _workspace(preferences: store);
      await workspace.load();
      final made = workspace.createWorkspace('web', ['/code/site'])!;
      workspace.deleteWorkspace(made);
      expect(workspace.workspaces, isEmpty);
      expect(
        workspace.sidebarProjects.where((p) => p.path == made.path),
        isEmpty,
      );
      expect(store.preferences['workspaces'], isEmpty);
    });

    test('an agent there is given its folders as they are when it starts, '
        'and what it is told of them', () async {
      final workspace = _workspace();
      await workspace.load();
      final made = workspace.createWorkspace('web', ['/code/site'])!;
      final thread = workspace.create(project: workspace.projectAt(made.path));
      final context = thread.session.kernelContext;
      expect(context.cwd, made.path);
      expect(context.workspace!()!.folders, ['/code/site']);
      workspace.addWorkspaceFolder(made, '/code/api');
      final given = context.workspace!()!;
      expect(given.folders, ['/code/site', '/code/api']);
      expect(given.instructions, contains('"web"'));
      expect(given.instructions, contains('- api: /code/api'));

      final folder = workspace.create(
        project: workspace.projectAt('/code/site'),
      );
      expect(folder.session.kernelContext.workspace!(), isNull);
    });
  });

  group('Remote workspaces', () {
    for (final (host, home, paths, platform) in [
      ('dev', '/home/me', p.posix, const RemotePlatform('linux', 'x64')),
      ('win', r'C:\Users\me', p.windows, const RemotePlatform('win', 'x64')),
    ]) {
      test(
        'creates on $host, passes raw folders and restores offline',
        () async {
          final toServer = StreamController<String>();
          final toClient = StreamController<String>();
          final server = RpcPeer(toServer.stream, toClient.add);
          final client = RemoteClient(RpcPeer(toClient.stream, toServer.add));
          client.hello = RemoteHello(
            protocol: RemoteProtocol.version,
            version: 'test',
            platform: platform,
            pid: 1,
            home: home,
            dataDir: paths.join(home, '.baocode-server', 'data'),
          );
          final made = <String>[];
          final files = <String, String>{};
          final snapshots = <String, String>{};
          final fileOperations = <(String, String)>[];
          final writes = <String, String>{};
          server.handlers[RemoteProtocol.fsList] = (params, _) {
            final args = params! as Map;
            expect(args['root'], home);
            return [
              for (final path in made)
                if (paths.dirname(path) == args['path'])
                  [path, paths.basename(path), true],
            ];
          };
          server.handlers[RemoteProtocol.fsCreate] = (params, _) {
            final args = params! as Map;
            expect(args['root'], home);
            final path = args['path'] as String;
            if (args['directory'] == true) {
              made.add(path);
            } else {
              expect(made, contains(paths.dirname(path)));
              expect(files.containsKey(path), isFalse);
              files[path] = '';
              fileOperations.add(('create', path));
            }
            return null;
          };
          server.handlers[RemoteProtocol.fsRead] = (params, _) {
            final args = params! as Map;
            expect(args['root'], home);
            final path = args['path'] as String;
            if (!files.containsKey(path)) throw StateError('File not found');
            snapshots[path] = files[path]!;
            fileOperations.add(('read', path));
            return files[path];
          };
          server.handlers[RemoteProtocol.fsWrite] = (params, _) {
            final args = params! as Map;
            expect(args['root'], home);
            final path = args['path'] as String;
            if (!snapshots.containsKey(path)) {
              throw StateError('Read the file before saving it: $path');
            }
            expect(files[path], snapshots[path]);
            expect(args['expectedText'], snapshots[path]);
            writes[path] = files[path] = args['text'] as String;
            fileOperations.add(('write', path));
            return null;
          };
          final previous = SshHosts.instance;
          final hosts = SshHosts.instance = SshHosts(
            connect: (target, {onProgress}) async =>
                SshConnection.over(target, client),
          );
          addTearDown(() async {
            client.peer.close();
            server.close();
            await hosts.closeAll();
            SshHosts.instance = previous;
            await toServer.close();
            await toClient.close();
          });
          final store = MemoryPreferenceStore();
          final directories = FakeWorkspaceDirectories();
          final workspace = _workspace(
            preferences: store,
            directories: directories,
          );
          await workspace.load();
          final folders = [
            for (final name in ['site', 'api'])
              RemoteLocation.of(host, paths.join(home, name)),
          ];
          final multi = (await workspace.createWorkspaceOn(
            'full stack',
            folders,
            host: host,
          ))!;
          final directory = paths.join(
            home,
            '.baocode',
            'workspaces',
            multi.id,
          );
          expect(multi.path, RemoteLocation.of(host, directory));
          final manifest = paths.join(directory, 'workspace.code-workspace');
          expect(fileOperations, [
            ('create', manifest),
            ('read', manifest),
            ('write', manifest),
          ]);
          expect(made, [
            paths.join(home, '.baocode'),
            paths.join(home, '.baocode', 'workspaces'),
            directory,
          ]);
          expect(directories.written, isEmpty);
          expect(multi.folders, folders);
          expect(multi.rawFolders, [
            paths.join(home, 'site'),
            paths.join(home, 'api'),
          ]);
          expect(jsonDecode(writes.values.single), {
            'folders': [
              for (final folder in multi.rawFolders) {'path': folder},
            ],
          });
          final thread = workspace.create(
            project: workspace.projectAt(multi.path),
          );
          expect(thread.project.host, host);
          expect(workspace.sidebarHost, host);
          final given = thread.session.kernelContext.workspace!()!;
          expect(given.folders, multi.rawFolders);
          expect(
            given.instructions,
            contains('- site: ${paths.join(home, 'site')}'),
          );
          expect(given.instructions, isNot(contains('ssh://')));
          final third = RemoteLocation.of(host, paths.join(home, 'docs'));
          expect(
            () => workspace.addWorkspaceFolder(multi, '/local'),
            throwsArgumentError,
          );
          expect(
            () => workspace.updateWorkspace(
              multi,
              folders: ['ssh://other/home/me/site'],
            ),
            throwsArgumentError,
          );
          workspace.addWorkspaceFolder(multi, third);
          workspace.removeWorkspaceFolder(multi, folders.first);
          workspace.updateWorkspace(multi, name: 'renamed');
          expect(directories.written, isEmpty);
          workspace.dispose();
          await hosts.closeAll();
          // Restore from preferences without reconnecting or moving the remote
          // path into a changed local data directory.
          final restored = _workspace(
            preferences: store,
            directories: FakeWorkspaceDirectories('/moved/workspaces'),
          );
          await restored.load();
          addTearDown(restored.dispose);
          final kept = restored.workspaces.single;
          expect(kept.path, multi.path);
          expect(kept.host, host);
          expect(kept.name, 'renamed');
          expect(kept.folders, [folders.last, third]);
          expect(restored.projectAt(multi.path).name, 'renamed');
        },
      );
    }

    test('creation and edits reject folders on another machine', () async {
      final workspace = _workspace();
      await workspace.load();
      addTearDown(workspace.dispose);
      expect(
        () => workspace.createWorkspace('mixed', ['ssh://dev/home/me']),
        throwsArgumentError,
      );
      await expectLater(
        workspace.createWorkspaceOn('mixed', [
          '/local',
          'ssh://dev/home/me',
        ], host: 'dev'),
        throwsArgumentError,
      );
      await expectLater(
        workspace.createWorkspaceOn('mixed', [
          'ssh://other/home/me',
        ], host: 'dev'),
        throwsArgumentError,
      );
      final local = workspace.createWorkspace('local', ['/code/site'])!;
      expect(
        () => workspace.addWorkspaceFolder(local, 'ssh://dev/home/me'),
        throwsArgumentError,
      );
      expect(
        () => workspace.updateWorkspace(local, folders: ['ssh://dev/home/me']),
        throwsArgumentError,
      );
      expect(workspace.workspaceAt(local.path)!.folders, ['/code/site']);
    });

    test(
      'a failed connection cannot create a local workspace instead',
      () async {
        final previous = SshHosts.instance;
        final hosts = SshHosts.instance = SshHosts(
          connect: (target, {onProgress}) async =>
              throw const SshConnectException(
                SshFailure.authentication,
                'Connection refused',
              ),
        );
        addTearDown(() async {
          await hosts.closeAll();
          SshHosts.instance = previous;
        });
        final workspace = _workspace();
        await workspace.load();
        addTearDown(workspace.dispose);
        await workspace.openFolder('ssh://dev/home/me/site');
        final was = workspace.selected;
        await expectLater(
          workspace.createWorkspaceOn('remote', [
            'ssh://dev/home/me/site',
          ], host: 'dev'),
          throwsA(isA<SshConnectException>()),
        );
        expect(workspace.workspaces, isEmpty);
        expect(workspace.selected, same(was));
        expect(workspace.sidebarHost, 'dev');
      },
    );
  });

  group('Claude Code in a workspace', () {
    test('each folder is an --add-dir, their CLAUDE.md read, and the agent '
        'told of them after the chat\'s own prompt', () {
      const launch = ClaudeLaunch(
        cwd: '/data/workspaces/w1',
        directories: ['/code/site', '/code/api'],
        instructions: '<workspace>web</workspace>',
      );
      final arguments = launch.arguments;
      expect(
        [
          for (var i = 0; i < arguments.length - 1; i++)
            if (arguments[i] == '--add-dir') arguments[i + 1],
        ],
        ['/code/site', '/code/api'],
      );
      final prompt = arguments[arguments.indexOf('--append-system-prompt') + 1];
      expect(
        prompt,
        '${ClaudeLaunch.appendedSystemPrompt}\n\n<workspace>web</workspace>',
      );
      expect(launch.settings['env'], {
        ...ClaudeLaunch.unsetEnvironment,
        'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD': '1',
      });
      expect(launch.copyWith(cwd: '/remote').directories, [
        '/code/site',
        '/code/api',
      ]);
    });

    test('a folder\'s project has none of them', () {
      const launch = ClaudeLaunch(cwd: '/code/site');
      expect(launch.arguments, isNot(contains('--add-dir')));
      expect(
        launch.arguments[launch.arguments.indexOf('--append-system-prompt') +
            1],
        ClaudeLaunch.appendedSystemPrompt,
      );
      expect(launch.settings['env'], ClaudeLaunch.unsetEnvironment);
    });

    test('the kernel launches with the workspace as it is then', () async {
      final launches = <ClaudeLaunch>[];
      var folders = ['/code/site'];
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/data/workspaces/w1',
          workspace: () =>
              KernelWorkspace(folders: folders, instructions: 'told'),
        ),
        start: (launch) async {
          launches.add(launch);
          return MockClaudeCodeTransport.start(launch);
        },
      );
      folders = ['/code/site', '/code/api'];
      kernel.prepare();
      await pumpEventQueue();
      expect(launches.single.directories, ['/code/site', '/code/api']);
      expect(launches.single.instructions, 'told');
      kernel.dispose();
    });
  });
}

@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/project_workspace.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Directories extends ProjectWorkspaceDirectories {
  _Directories(this.root);
  @override
  final String root;
}

void main() {
  late Directory temp;
  late String oldRoot;
  late String newRoot;
  late String oldPath;
  late String newPath;
  late ProjectWorkspace original;
  const directories = ProjectWorkspaceDirectories();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('workspace-data-move-');
    oldRoot = p.join(temp.path, 'old', 'workspaces');
    newRoot = p.join(temp.path, 'new', 'workspaces');
    oldPath = p.join(oldRoot, 'paper-id');
    newPath = p.join(newRoot, 'paper-id');
    original = ProjectWorkspace(
      id: 'paper-id',
      name: 'paper',
      path: oldPath,
      folders: const ['/old/project'],
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File workspaceFile(String directory, String content) {
    final file = File(p.join(directory, 'paper.code-workspace'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  ProjectWorkspace moved() =>
      ProjectWorkspace.fromJson(original.toJson(), root: newRoot)!;

  test('workspace file folder edits override stale persisted folders, preserving comments and settings', () {
    const content = '''{
      // Updated in the editor after moving projects to an external volume.
      "folders": [
        {"name": "API", "path": "/external/projects/api"},
        {"path": "../../relative"},
        {"path": "/external/projects/api"},
      ],
      "settings": {"editor.tabSize": 4},
    }''';
    final file = workspaceFile(newPath, content);
    final restored = directories.restore(moved());
    expect(restored.folders, [
      '/external/projects/api',
      p.normalize(p.join(newPath, '../../relative')),
    ]);
    expect(file.readAsStringSync(), content);
    expect(restored.id, original.id);
    expect(restored.path, newPath);
  });

  test('missing migrated file recovers edited old roots and preserves relative targets and settings', () {
    const content =
        '{"folders":[{"name":"Source","path":"../../source"}],"settings":{"editor.tabSize":4}}';
    final oldFile = workspaceFile(oldPath, content);
    final restored = directories.restore(moved(), previousPaths: [oldPath]);
    final source = p.normalize(p.join(oldPath, '../../source'));
    expect(restored.folders, [source]);
    expect(oldFile.readAsStringSync(), content);
    final json = jsonDecode(
      File(p.join(newPath, 'paper.code-workspace')).readAsStringSync(),
    ) as Map;
    expect(json['folders'], [
      {'name': 'Source', 'path': source},
    ]);
    expect(json['settings'], {'editor.tabSize': 4});
  });

  test(
    'current workspace file wins over a stale old copy, including empty roots',
    () {
      workspaceFile(oldPath, '{"folders":[{"path":"/old/copy"}]}');
      final current = workspaceFile(newPath, '{"folders":[]}');
      final restored = directories.restore(moved(), previousPaths: [oldPath]);
      expect(restored.folders, isEmpty);
      expect(current.readAsStringSync(), '{"folders":[]}');
    },
  );

  for (final content in [
    '{',
    '{"folders":[',
    '{"folders":"bad"}',
    '{"folders":[{}]}',
    '{"folders":[{"path":""}]}',
  ]) {
    test(
      'invalid file does not wipe saved roots or fall back to stale copies: $content',
      () {
        workspaceFile(oldPath, '{"folders":[{"path":"/stale/copy"}]}');
        final current = workspaceFile(newPath, content);
        expect(
          directories.restore(moved(), previousPaths: [oldPath]).folders,
          original.folders,
        );
        expect(current.readAsStringSync(), content);
      },
    );
  }

  test('missing workspace file is recreated without deleting other files', () {
    final other = File(p.join(newPath, 'other.code-workspace'));
    other.parent.createSync(recursive: true);
    other.writeAsStringSync('{"folders":[]}');
    final restored = directories.restore(moved());
    expect(restored.folders, original.folders);
    expect(other.readAsStringSync(), '{"folders":[]}');
    final json = jsonDecode(
      File(p.join(newPath, 'paper.code-workspace')).readAsStringSync(),
    ) as Map;
    expect(json['folders'], [
      {'path': '/old/project'},
    ]);
  });

  test('old roots are restored even when the new file cannot be written', () {
    workspaceFile(oldPath, '{"folders":[{"path":"/external/source"}]}');
    final obstruction = File(newPath);
    obstruction.parent.createSync(recursive: true);
    obstruction.writeAsStringSync('not a directory');
    final restored = directories.restore(moved(), previousPaths: [oldPath]);
    expect(restored.folders, ['/external/source']);
    expect(obstruction.readAsStringSync(), 'not a directory');
  });

  for (final alreadySaved in [false, true]) {
    test(
      'data move restores explorer, tabs and workspace roots (workspace path already saved: $alreadySaved)',
      () async {
        workspaceFile(
          oldPath,
          '{"folders":[{"path":"/external/projects/api"},{"path":"/external/projects/web"}]}',
        );
        final oldFile = p.join(oldPath, 'notes.txt');
        final store = MemoryPreferenceStore({
          'layout': 'ide',
          'workspaces': [(alreadySaved ? moved() : original).toJson()],
          'sidebar': {
            'folders': [oldPath, '/unrelated/project'],
            'projectOrder': [oldPath],
            'pinnedProjects': [oldPath],
            'projectNames': {oldPath: 'My paper'},
            'collapsed': [Workspace.projectGroup(oldPath)],
          },
          'ide': {
            'folder': oldPath,
            'recentFolders': [oldPath, '/unrelated/project'],
            'recentFiles': [oldFile, '/unrelated/notes.txt'],
            'views': {
              oldPath: {
                'opened': [oldFile],
                'selected': oldFile,
              },
            },
            'chats': {
              oldPath: {
                'tabs': ['session-id'],
                'shown': 'session-id',
              },
            },
          },
          'sidePanel': {'folder': oldPath},
        });
        final workspace = Workspace(
          kernels: [MockKernels.claudeCode],
          preferences: store,
          workspaceDirectories: _Directories(newRoot),
        );
        addTearDown(workspace.dispose);
        await workspace.load();
        final restored = workspace.workspaces.single;
        expect(workspace.ideFolder, newPath);
        expect(restored.folders, [
          '/external/projects/api',
          '/external/projects/web',
        ]);
        expect(workspace.workspaceAt(workspace.ideFolder!), restored);
        expect(workspace.recentFolders, contains(newPath));
        expect(workspace.recentFolders, isNot(contains(oldPath)));
        expect(workspace.recentFiles, [
          p.join(newPath, 'notes.txt'),
          '/unrelated/notes.txt',
        ]);
        expect(workspace.ideView(newPath), {
          'opened': [p.join(newPath, 'notes.txt')],
          'selected': p.join(newPath, 'notes.txt'),
        });
        expect(workspace.ideView(oldPath), isNull);
        expect(workspace.sidePanelView, {'folder': newPath});
        final context = workspace
            .create(project: workspace.projectAt(newPath))
            .session
            .kernelContext;
        expect(context.workspace!()!.folders, restored.folders);
        expect(store.preferences['workspaces'], [restored.toJson()]);
        final ide = store.preferences['ide'] as Map;
        expect(ide['folder'], newPath);
        expect((ide['chats'] as Map).containsKey(oldPath), isFalse);
        expect(
          File(p.join(newPath, 'paper.code-workspace')).existsSync(),
          isTrue,
        );
      },
    );
  }

  test(
    'current location view wins if old and new view keys both exist',
    () async {
      workspaceFile(newPath, '{"folders":[{"path":"/external/source"}]}');
      final workspace = Workspace(
        kernels: [MockKernels.claudeCode],
        workspaceDirectories: _Directories(newRoot),
        preferences: MemoryPreferenceStore({
          'workspaces': [original.toJson()],
          'ide': {
            'folder': oldPath,
            'views': {
              newPath: {'width': 400},
              oldPath: {'width': 200},
            },
          },
        }),
      );
      addTearDown(workspace.dispose);
      await workspace.load();
      expect(workspace.ideView(newPath), {'width': 400});
      expect(workspace.workspaces.single.folders, ['/external/source']);
    },
  );
}

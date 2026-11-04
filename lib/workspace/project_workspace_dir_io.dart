import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import '../settings/jsonc.dart';
import 'project_workspace.dart';

String? workspacesRoot() => DataDirectory.current.workspacesDir;

ProjectWorkspace restoreWorkspaceDirectory(
  ProjectWorkspace workspace, {
  List<String> previousPaths = const [],
}) {
  final name = '${_fileName(workspace.name)}.code-workspace';
  final target = File(p.join(workspace.path, name));
  for (final path in [workspace.path, ...previousPaths]) {
    final file = File(p.join(path, name));
    try {
      if (!file.existsSync()) continue;
      final errors = <JsoncParseError>[];
      final json = parseJsonc(file.readAsStringSync(), errors: errors);
      if (errors.isNotEmpty || json is! Map || json['folders'] is! List) {
        return workspace;
      }
      final folders = <String>[];
      for (final entry in json['folders'] as List) {
        if (entry is! Map ||
            entry['path'] is! String ||
            (entry['path'] as String).isEmpty) {
          return workspace;
        }
        final folder = entry['path'] as String;
        folders.add(
          p.normalize(
            p.isAbsolute(folder) ? folder : p.join(file.parent.path, folder),
          ),
        );
      }
      final restored = workspace.copyWith(folders: folders.toSet().toList());
      if (file.path != target.path && !target.existsSync()) {
        // Relative paths must keep pointing to the original resources after
        // migration. Copy settings too, without touching either existing file.
        try {
          target.parent.createSync(recursive: true);
          target.writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert({
              ...json,
              'folders': [
                for (final (i, entry) in (json['folders'] as List).indexed) {...entry as Map, 'path': folders[i]},
              ],
            })}\n',
          );
        } on FileSystemException {
          // The resources can still be listed if the new directory is read-only.
        }
      }
      return restored;
    } on FileSystemException {
      // Keep persisted folders when the configured volume is unavailable.
      return workspace;
    }
  }
  // Recreate a missing generated file, but never remove a differently named
  // file on restore (the user may have renamed or edited it independently).
  try {
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'folders': [
          for (final folder in workspace.folders) {'path': folder},
        ],
      })}\n',
    );
  } on FileSystemException {
    // Kept folders remain usable even when the data directory is read-only.
  }
  return workspace;
}

void writeWorkspaceDirectory(ProjectWorkspace workspace) {
  try {
    final directory = Directory(workspace.path)..createSync(recursive: true);
    // Its name is the file's: one file, renamed with the workspace.
    final name = '${_fileName(workspace.name)}.code-workspace';
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is File &&
          entity.path.endsWith('.code-workspace') &&
          p.basename(entity.path) != name) {
        entity.deleteSync();
      }
    }
    File(p.join(directory.path, name)).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'folders': [
          for (final folder in workspace.folders) {'path': folder},
        ],
      })}\n',
    );
  } on FileSystemException {
    // Listed all the same; made again when next changed.
  }
}

/// [name] as a file's name: what no file system takes, replaced.
String _fileName(String name) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-').trim();
  return safe.isEmpty || safe.startsWith('.') ? 'workspace' : safe;
}

bool isFolder(String path) => Directory(path).existsSync();

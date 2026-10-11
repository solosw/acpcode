import 'dart:io';

import 'package:bao_remote/local.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import 'file_service.dart';

export 'package:bao_remote/local.dart'
    show readFileBytes, walkProjectFiles, watchDirectory;

class LocalIdeFileService extends LocalFiles implements IdeFileService {
  LocalIdeFileService(super.root);
}

Future<void> uploadTo(
  IdeFileService files,
  List<({String from, String to})> items, {
  TransferProgress? onProgress,
}) async {
  final folders = <String>[];
  final copies = <({String from, String to})>[];
  Future<void> walk(String from, String to) async {
    switch (await FileSystemEntity.type(from)) {
      case FileSystemEntityType.directory:
        folders.add(to);
        await for (final entry in Directory(from).list(followLinks: false)) {
          // A link to a folder is left out: it may lead back up.
          if (entry is Link && await FileSystemEntity.isDirectory(entry.path)) {
            continue;
          }
          await walk(entry.path, p.posix.join(to, p.basename(entry.path)));
        }
      case FileSystemEntityType.file:
        copies.add((from: from, to: to));
      default:
        throw IdeFileNotFoundException(from);
    }
  }

  for (final (:from, :to) in items) {
    await walk(from, to);
  }
  for (final folder in folders) {
    await files.create(folder, directory: true);
  }
  onProgress?.call(0, copies.length);
  for (final (i, (:from, :to)) in copies.indexed) {
    await files.writeBytes(to, await File(from).readAsBytes());
    onProgress?.call(i + 1, copies.length);
  }
}

Future<void> downloadFrom(
  IdeHostFiles files,
  List<({String from, String to, bool directory})> items, {
  TransferProgress? onProgress,
}) async {
  final folders = <String>[];
  final copies = <({String from, String to})>[];
  Future<void> walk(String from, String to, {required bool directory}) async {
    if (!directory) {
      copies.add((from: from, to: to));
      return;
    }
    folders.add(to);
    for (final entry in await files.list(from)) {
      await walk(
        entry.path,
        p.join(to, entry.name),
        directory: entry.isDirectory,
      );
    }
  }

  for (final (:from, :to, :directory) in items) {
    await walk(from, to, directory: directory);
  }
  for (final folder in folders) {
    await Directory(folder).create(recursive: true);
  }
  onProgress?.call(0, copies.length);
  for (final (i, (:from, :to)) in copies.indexed) {
    final file = File(to);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await files.readBytes(from));
    onProgress?.call(i + 1, copies.length);
  }
}

/// How long downloads for other apps are kept: pasted or dropped, they
/// were copied from there.
const _downloadsKept = Duration(days: 1);

Future<String> newDownloadFolder() async {
  final downloads = Directory(
    p.join(DataDirectory.current.cacheDir, 'remote-files'),
  );
  final now = DateTime.now();
  if (await downloads.exists()) {
    await for (final old in downloads.list()) {
      try {
        if (now.difference((await old.stat()).modified) > _downloadsKept) {
          await old.delete(recursive: true);
        }
      } on FileSystemException {
        // In use, or gone: left for another time.
      }
    }
  }
  final folder = Directory(
    p.join(downloads.path, '${now.microsecondsSinceEpoch}'),
  );
  await folder.create(recursive: true);
  return folder.path;
}

Future<void> saveCopyTo(
  IdeFileService files,
  String from,
  String to, {
  String? text,
}) async {
  final file = File(to);
  if (text != null) {
    await file.writeAsString(text);
  } else if (files is IdeHostFiles) {
    await file.writeAsBytes(await files.readBytes(from));
  } else if (!p.equals(from, to)) {
    await File(from).copy(to);
  }
}

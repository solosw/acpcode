import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show BlobReviewStore;

import '../../kernel/kernel_event.dart';

FileSnapshot snapshotFile(String path) {
  try {
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return FileSnapshot(null);
      case FileSystemEntityType.link:
        return FileSnapshot(
          utf8.encode(Link(path).targetSync()),
          mode: '120000',
        );
      case FileSystemEntityType.file:
        final file = File(path);
        final stat = file.statSync();
        if (stat.size > BlobReviewStore.maxFileBytes) {
          return const FileSnapshot.unknown();
        }
        return FileSnapshot(
          file.readAsBytesSync(),
          mode: !Platform.isWindows && stat.mode & 0x49 != 0
              ? '100755'
              : '100644',
        );
      default:
        return const FileSnapshot.unknown();
    }
  } on FileSystemException {
    return const FileSnapshot.unknown();
  }
}

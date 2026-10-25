import 'dart:io';

import 'package:path/path.dart' as p;

import '../kernel/claude_code/claude_environment.dart';
import '../platform/local_paths_io.dart';
import 'customization_disk.dart';

CustomizationDisk? localCustomizationDisk() => const _LocalDisk();

/// This machine's files.
class _LocalDisk implements AtomicCustomizationDisk, CustomizationCopyDisk {
  const _LocalDisk();

  @override
  bool get isLocal => true;

  @override
  p.Context get paths => p.context;

  @override
  Future<String> configDir() => ClaudeEnvironment.configDir();

  @override
  Future<String?> homeDir() async => homeDirectory;

  @override
  Future<String?> read(String path) async {
    try {
      return await File(path).readAsString();
    } on Object {
      return null;
    }
  }

  @override
  Future<List<({String path, bool directory})>> children(
    String directory,
  ) async {
    try {
      return [
        await for (final entry in Directory(directory).list())
          if (entry is Directory || entry is File)
            (path: entry.path, directory: entry is Directory),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  @override
  Future<bool?> isDirectory(String path) async =>
      switch (await FileSystemEntity.type(path)) {
        FileSystemEntityType.directory => true,
        FileSystemEntityType.file => false,
        _ => null,
      };

  @override
  Future<void> write(String path, String text) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  @override
  Future<void> writeAtomically(String path, String text) async {
    var file = File(path);
    final exists = await file.exists();
    final isLink = await FileSystemEntity.isLink(path);
    if (exists || isLink) file = File(await file.resolveSymbolicLinks());
    final mode = exists ? (await file.stat()).mode & 0x1ff : 0x180;
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.mcp-config-');
    try {
      final staged = File(p.join(temporary.path, 'config'));
      await staged.writeAsString(text, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', [
          mode.toRadixString(8),
          staged.path,
        ]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Could not preserve MCP config permissions',
            path,
          );
        }
      }
      await staged.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  @override
  Future<CustomizationFileInfo?> inspect(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    return (
      type: switch (type) {
        FileSystemEntityType.file => CustomizationFileType.file,
        FileSystemEntityType.directory => CustomizationFileType.directory,
        FileSystemEntityType.link => CustomizationFileType.link,
        _ => CustomizationFileType.other,
      },
      executable:
          !Platform.isWindows &&
          type == FileSystemEntityType.file &&
          (await File(path).stat()).mode & 0x49 != 0,
    );
  }

  @override
  Future<List<String>> copyEntries(String directory) async => [
    await for (final entry in Directory(directory).list(followLinks: false))
      entry.path,
  ];

  @override
  Future<String> resolveCopyPath(String path) async {
    if (await inspect(path) != null) return File(path).resolveSymbolicLinks();
    final parent = p.dirname(path);
    if (parent == path) throw FileSystemException('Cannot resolve path', path);
    return p.join(await resolveCopyPath(parent), p.basename(path));
  }

  @override
  Future<List<int>> readCopyBytes(String path) => File(path).readAsBytes();

  @override
  Future<void> createCopyDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> writeCopyBytes(
    String path,
    List<int> bytes, {
    required bool executable,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.baocode-copy-');
    try {
      final staged = File(p.join(temporary.path, 'content'));
      await staged.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', [
          executable ? '700' : '600',
          staged.path,
        ]);
        if (result.exitCode != 0) {
          throw FileSystemException('Cannot set copy permissions', path);
        }
      }
      await staged.rename(path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  @override
  Future<void> delete(String path) async {
    switch (await isDirectory(path)) {
      case true:
        await Directory(path).delete(recursive: true);
      case false:
        await File(path).delete();
      case null:
    }
  }
}

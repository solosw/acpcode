import 'dart:convert';

import 'package:bao_remote/client.dart';
import 'package:path/path.dart' as p;

import '../customize/customization_disk.dart';
import 'ssh_host.dart';

/// The files of [host], where its agents run and read their
/// customizations: through its server, on the connection already made.
class RemoteCustomizationDisk implements CustomizationCopyDisk {
  RemoteCustomizationDisk(this.host);

  final SshHost host;

  /// The root the server's file calls are made under: what they keep of a
  /// file read, to write it back, kept once for all of these.
  static const _root = '/';

  Future<RemoteClient> get _client => host.ready;

  Future<String>? _configDir;

  @override
  bool get isLocal => false;

  @override
  p.Context get paths => p.posix;

  /// `CLAUDE_CONFIG_DIR` in the login shell's environment there, else
  /// `~/.claude`; looked up again after a failure.
  @override
  Future<String> configDir() async {
    final found = _configDir ??= _findConfigDir();
    try {
      return await found;
    } on Object {
      _configDir = null;
      rethrow;
    }
  }

  Future<String> _findConfigDir() async {
    final client = await _client;
    try {
      final output = await client.run('printenv', const ['CLAUDE_CONFIG_DIR']);
      final dir = output.stdout.trim();
      if (output.exitCode == 0 && dir.isNotEmpty) return dir;
    } on RemoteException {
      // No printenv there: the default.
    }
    return p.posix.join(client.hello?.home ?? '', '.claude');
  }

  @override
  Future<String?> homeDir() async {
    final home = (await _client).hello?.home;
    return home == null || home.isEmpty ? null : home;
  }

  @override
  Future<String?> read(String path) async {
    final client = await _client;
    try {
      return utf8.decode(await client.readBytes(path), allowMalformed: true);
    } on RpcClosed {
      rethrow;
    } on Object {
      // Not there, or not to be read.
      return null;
    }
  }

  @override
  Future<List<({String path, bool directory})>> children(
    String directory,
  ) async {
    final client = await _client;
    final names = await client.entries(directory);
    final paths = [for (final name in names) p.posix.join(directory, name)];
    final types = await Future.wait(paths.map(client.stat));
    return [
      for (final (i, path) in paths.indexed)
        if (types[i] case 'file' || 'directory')
          (path: path, directory: types[i] == 'directory'),
    ];
  }

  @override
  Future<bool?> isDirectory(String path) async =>
      switch (await (await _client).stat(path)) {
        'directory' => true,
        'file' => false,
        _ => null,
      };

  @override
  Future<void> write(String path, String text) async {
    final client = await _client;
    if (await client.stat(path) == 'file') {
      // Read first: the server writes back only a file it has read.
      await client.read(_root, path, force: true);
      await client.write(_root, path, text);
      return;
    }
    await _makeFolders(client, p.posix.dirname(path));
    await client.writeBytes(_root, path, utf8.encode(text));
  }

  /// Makes [folder] and those it is in that are not there yet.
  Future<void> _makeFolders(RemoteClient client, String folder) async {
    final missing = <String>[];
    var dir = folder;
    while (await client.stat(dir) == null) {
      missing.add(dir);
      final parent = p.posix.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    for (final dir in missing.reversed) {
      await client.create(_root, dir, directory: true);
    }
  }

  @override
  Future<CustomizationFileInfo?> inspect(String path) async {
    // The path is a positional argument, never interpolated into shell code.
    final result = await (await _client).run('sh', [
      '-c',
      r'''if [ -L "$1" ]; then echo link
elif [ -d "$1" ]; then echo directory
elif [ -f "$1" ]; then
  if [ -x "$1" ]; then echo executable; else echo file; fi
elif [ -e "$1" ]; then echo other
else
  parent=$(dirname "$1")
  while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
    next=$(dirname "$parent")
    [ "$next" != "$parent" ] || exit 1
    parent=$next
  done
  [ -d "$parent" ] && [ -x "$parent" ] || exit 1
  echo missing
fi''',
      'baocode-copy',
      path,
    ], login: false);
    if (result.exitCode != 0) throw StateError('Cannot inspect $path');
    final type = result.stdout.trim();
    if (type == 'missing') return null;
    return (
      type: switch (type) {
        'directory' => CustomizationFileType.directory,
        'file' || 'executable' => CustomizationFileType.file,
        'link' => CustomizationFileType.link,
        _ => CustomizationFileType.other,
      },
      executable: type == 'executable',
    );
  }

  @override
  Future<List<String>> copyEntries(String directory) async => [
    for (final name in await (await _client).entries(directory))
      p.posix.join(directory, name),
  ];

  @override
  Future<String> resolveCopyPath(String path) async {
    if (await inspect(path) != null) return (await _client).realPath(path);
    final parent = p.posix.dirname(path);
    if (parent == path) throw StateError('Cannot resolve $path');
    return p.posix.join(await resolveCopyPath(parent), p.posix.basename(path));
  }

  @override
  Future<List<int>> readCopyBytes(String path) async =>
      (await _client).readBytes(path);

  @override
  Future<void> createCopyDirectory(String path) async {
    final result = await (await _client).run('mkdir', [
      '-p',
      path,
    ], login: false);
    if (result.exitCode != 0) throw StateError('Cannot create $path');
  }

  @override
  Future<void> writeCopyBytes(
    String path,
    List<int> bytes, {
    required bool executable,
  }) async {
    final client = await _client;
    await createCopyDirectory(p.posix.dirname(path));
    final result = await client.run('mktemp', [
      '-d',
      p.posix.join(p.posix.dirname(path), '.baocode-copy-XXXXXX'),
    ], login: false);
    if (result.exitCode != 0) throw StateError('Cannot stage $path');
    final temporary = result.stdout.trim();
    final staged = p.posix.join(temporary, 'content');
    try {
      await client.writeBytes(_root, staged, bytes);
      final mode = await client.run('chmod', [
        executable ? '700' : '600',
        staged,
      ], login: false);
      if (mode.exitCode != 0) throw StateError('Cannot set permissions: $path');
      final moved = await client.run('sh', [
        '-c',
        r'if [ -d "$2" ] || [ -L "$2" ]; then exit 1; fi; mv -f "$1" "$2"',
        'baocode-copy',
        staged,
        path,
      ], login: false);
      if (moved.exitCode != 0) throw StateError('Cannot replace $path');
    } finally {
      await client.delete(_root, temporary);
    }
  }

  @override
  Future<void> delete(String path) async {
    final client = await _client;
    if (await client.stat(path) != null) await client.delete(_root, path);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'line_counts.dart';
import 'review_store.dart';

/// [ReviewStore] in folders of this machine, a session's
/// `checkpoints/<project>/<session>/`: its `review.json` and its blobs
/// (compressed, by hash).
/// Only what the agents edited is kept, never the rest of the project;
/// the project's `.git` (if it has one) is never read or written.
class LocalReviewStore implements ReviewStore, ScanningReviewStore {
  LocalReviewStore._(this.root, this.folder, this._legacy);

  final bool _legacy;

  /// The store for [root], its folder under [checkpoints]; null when
  /// [root] is not a folder. [checkpoints] is tidied from then on
  /// ([scheduleTidy]).
  static Future<LocalReviewStore?> open(
    String root, {
    required String checkpoints,
  }) async {
    root = p.normalize(p.absolute(root));
    checkpoints = p.normalize(p.absolute(checkpoints));
    if (!await Directory(root).exists()) return null;
    final folder = p.join(checkpoints, _folderName(root));
    scheduleTidy(checkpoints);
    return LocalReviewStore._(
      root,
      folder,
      await File(p.join(folder, 'HEAD')).exists(),
    );
  }

  @override
  final String root;

  /// The project's folder: `checkpoints/<folder name>-<hash of its path>`.
  final String folder;

  /// Past this size a file is not kept: its edits are listed, not undone.
  static int maxFileBytes = 10 * 1024 * 1024;

  /// `<name>-<FNV-1a of the path>`: readable, and one per path.
  static String _folderName(String root) {
    // The offset basis in halves: one 64-bit literal is not a JS number, and
    // the web build must compile.
    var hash = 0xcbf29ce4 << 32 | 0x84222325;
    for (final byte in utf8.encode(root)) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
    // Ints are signed: the two halves, unsigned.
    String half(int bits) => bits.toRadixString(16).padLeft(8, '0');
    final name = p.basename(root).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${name.isEmpty ? 'root' : name}-'
        '${half(hash >>> 32)}${half(hash & 0xFFFFFFFF)}';
  }

  // --- Sessions' folders --------------------------------------------------

  static final _safeName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

  String _sessionFolder(String session) {
    if (!_safeName.hasMatch(session) || session.startsWith('.')) {
      session = 'h${_folderName(session).split('-').last}';
    }
    // Do not let a legacy session named objects/refs/etc. overwrite or
    // delete part of its source repository. New sessions stay separate.
    final path = p.join(
      _legacy ? p.join(folder, 'sessions-v2') : folder,
      session,
    );
    _live.add(path);
    return path;
  }

  String _blobPath(String session, String oid) =>
      p.join(_sessionFolder(session), 'blobs', oid);

  /// The sessions' folders used in this process: never tidied away from
  /// under them.
  static final Set<String> _live = {};

  // --- Files ----------------------------------------------------------------

  String _full(String path) => p.join(root, path);

  @override
  Future<bool> exists(String path) async =>
      FileSystemEntity.typeSync(_full(path), followLinks: false) !=
      FileSystemEntityType.notFound;

  /// What is at [path]: its mode and bytes; null for nothing or a folder,
  /// or a file too large.
  Future<(String, Uint8List)?> _contentOf(String path) async {
    final full = _full(path);
    switch (FileSystemEntity.typeSync(full, followLinks: false)) {
      case FileSystemEntityType.notFound || FileSystemEntityType.directory:
        return null;
      case FileSystemEntityType.link:
        return ('120000', utf8.encode(await Link(full).target()));
      default:
        final file = File(full);
        final stat = await file.stat();
        if (stat.size > maxFileBytes) return null;
        final executable = !Platform.isWindows && stat.mode & 0x49 != 0;
        return (executable ? '100755' : '100644', await file.readAsBytes());
    }
  }

  static String _hash(Uint8List bytes) => sha1.convert(bytes).toString();

  @override
  Future<ReviewBlob?> current(String path) async {
    final content = await _contentOf(path);
    if (content == null) return null;
    return ReviewBlob(content.$1, _hash(content.$2));
  }

  @override
  Future<ReviewBlob?> take(String session, String path) async {
    final content = await _contentOf(path);
    if (content == null) return null;
    return store(session, content.$2, mode: content.$1);
  }

  @override
  Future<ReviewBlob> store(
    String session,
    Uint8List bytes, {
    required String mode,
  }) async {
    final blob = ReviewBlob(mode, _hash(bytes));
    final file = File(_blobPath(session, blob.oid));
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      // Whole or not at all.
      final partial = File('${file.path}.$pid.part');
      await partial.writeAsBytes(zlib.encode(bytes), flush: true);
      await partial.rename(file.path);
    }
    return blob;
  }

  @override
  Future<Uint8List> read(String session, ReviewBlob blob) async {
    final file = File(_blobPath(session, blob.oid));
    try {
      return Uint8List.fromList(zlib.decode(await file.readAsBytes()));
    } on FileSystemException {
      throw ReviewUnavailable('What the session kept of a file is gone.');
    }
  }

  @override
  Future<void> restore(String session, String path, ReviewBlob? blob) async {
    final full = _full(path);
    final type = FileSystemEntity.typeSync(full, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      throw ReviewUnavailable('$path is a folder now.');
    }
    if (blob == null) {
      if (type != FileSystemEntityType.notFound) await File(full).delete();
      await _removeEmpty(p.dirname(full));
      return;
    }
    final bytes = await read(session, blob);
    if (type == FileSystemEntityType.link ||
        (blob.isLink && type != FileSystemEntityType.notFound)) {
      await File(full).delete();
    }
    await Directory(p.dirname(full)).create(recursive: true);
    if (blob.isLink) {
      await Link(full).create(utf8.decode(bytes, allowMalformed: true));
      return;
    }
    await File(full).writeAsBytes(bytes, flush: true);
    if (blob.mode == '100755' && !Platform.isWindows) {
      await Process.run('chmod', ['+x', full]);
    }
  }

  /// Deletes [directory] and those above it while empty, up to the root.
  Future<void> _removeEmpty(String directory) async {
    while (p.isWithin(root, directory)) {
      final folder = Directory(directory);
      try {
        if (!await folder.exists() || !await folder.list().isEmpty) return;
        await folder.delete();
      } on FileSystemException {
        return;
      }
      directory = p.dirname(directory);
    }
  }

  @override
  Future<Uint8List?> merge(
    String session,
    String path,
    ReviewBlob from,
    ReviewBlob to,
  ) async {
    final temp = await Directory.systemTemp.createTemp('baocode-review-');
    try {
      final ours = p.join(temp.path, 'current');
      final base = p.join(temp.path, 'base');
      final theirs = p.join(temp.path, 'other');
      await File(_full(path)).copy(ours);
      await File(base).writeAsBytes(await read(session, from));
      await File(theirs).writeAsBytes(await read(session, to));
      final merged = await Process.run('git', [
        'merge-file',
        '-p',
        '-q',
        ours,
        base,
        theirs,
      ], stdoutEncoding: null);
      // The number of conflicts, or an error (a binary file).
      return merged.exitCode == 0
          ? Uint8List.fromList(merged.stdout as List<int>)
          : null;
    } on ProcessException {
      // No Git.
      return null;
    } finally {
      await temp.delete(recursive: true);
    }
  }

  @override
  Future<void> write(String path, Uint8List bytes) =>
      File(_full(path)).writeAsBytes(bytes, flush: true);

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String session,
    Map<String, ReviewBlob?> bases,
  ) async => {
    for (final MapEntry(key: path, value: base) in bases.entries)
      path: countLines(
        base == null ? null : await read(session, base),
        (await _contentOf(path))?.$2,
      ),
  };

  /// ACP alone needs discovery. A temporary, empty Git index lists files
  /// using the project's ignores without touching its repository or index.
  /// Nested repositories are visited as folders, never followed through links.
  @override
  Future<Map<String, ReviewBlob?>> scan(String session) async {
    final temp = await Directory.systemTemp.createTemp('baocode-scan-');
    try {
      final initialized = await Process.run('git', [
        'init',
        '-q',
        '--bare',
        '--template=',
        temp.path,
      ]);
      if (initialized.exitCode != 0) {
        throw const ReviewUnavailable('Could not prepare ACP file discovery.');
      }
      await Directory(p.join(temp.path, 'info')).create();
      await File(p.join(temp.path, 'info', 'exclude')).writeAsString(
        '.DS_Store\nnode_modules/\n.venv/\n__pycache__/\n.dart_tool/\n'
        '.gradle/\n.next/\n.nuxt/\nPods/\nDerivedData/\n',
      );
      final found = <String, ReviewBlob?>{};
      final own = p.isWithin(root, folder)
          ? p.relative(folder, from: root)
          : null;
      var files = 0;
      Future<void> visit(String directory) async {
        final listed = await Process.run('git', [
          '--git-dir=${temp.path}',
          '--work-tree=$directory',
          'ls-files',
          '--others',
          '--exclude-standard',
          '-z',
          '--',
          '.',
        ], workingDirectory: directory);
        if (listed.exitCode != 0) {
          throw const ReviewUnavailable('Could not discover ACP files.');
        }
        // Remember ignored paths as existing-but-unknown. --directory
        // collapses ignored trees such as node_modules without reading them.
        final ignored = await Process.run('git', [
          '--git-dir=${temp.path}',
          '--work-tree=$directory',
          'ls-files',
          '--others',
          '--ignored',
          '--exclude-standard',
          '--directory',
          '-z',
          '--',
          '.',
        ], workingDirectory: directory);
        if (ignored.exitCode != 0) {
          throw const ReviewUnavailable(
            'Could not discover ignored ACP paths.',
          );
        }
        for (final name in (ignored.stdout as String).split('\x00')) {
          if (name.isEmpty) continue;
          final relative = p.relative(p.join(directory, name), from: root);
          if (own != null && (relative == own || p.isWithin(own, relative))) {
            continue;
          }
          final path = p.split(relative).join('/');
          found[name.endsWith('/') ? '$path/' : path] = null;
        }
        for (final name in (listed.stdout as String).split('\x00')) {
          if (name.isEmpty) continue;
          final full = p.join(directory, name);
          final relative = p.relative(full, from: root);
          if (own != null && (relative == own || p.isWithin(own, relative))) {
            continue;
          }
          if (FileSystemEntity.typeSync(full, followLinks: false) ==
              FileSystemEntityType.directory) {
            await visit(full);
            continue;
          }
          if (++files > 100000) {
            throw const ReviewUnavailable(
              'Too many files to discover ACP edits.',
            );
          }
          final path = p.split(relative).join('/');
          // Files may disappear as a command works. Do not fail the review.
          try {
            final blob = await take(session, path);
            if (blob != null || await exists(path)) found[path] = blob;
          } on FileSystemException {
            if (await exists(path)) rethrow;
          }
        }
      }

      await visit(root);
      return found;
    } on ProcessException {
      throw const ReviewUnavailable('Git is required to discover ACP edits.');
    } finally {
      await temp.delete(recursive: true);
    }
  }

  // --- Sessions ---------------------------------------------------------------

  static const _dataFile = 'review.json';

  // Reconnected stores and simultaneous views may resume the same session.
  static final Map<String, Future<String?>> _loading = {};

  File _legacyDone(String session) =>
      File(p.join(folder, '.migrated-${p.basename(_sessionFolder(session))}'));

  Future<void> _markLegacyDone(String session) async {
    if (!_legacy) return;
    await _legacyDone(session).writeAsString('2\n');
  }

  @override
  Future<String?> load(String session) {
    final directory = _sessionFolder(session);
    return _loading.putIfAbsent(directory, () async {
      try {
        final file = File(p.join(directory, _dataFile));
        if (await file.exists()) {
          final data = await file.readAsString();
          // Also finish a migration interrupted after save but before its
          // marker was written. Keep/Undo must never revive the old ref.
          await _markLegacyDone(session);
          return data;
        }
        if (await _legacyDone(session).exists() || !_legacy) {
          return null;
        }
        try {
          return await _migrateLegacy(session);
        } on Object catch (error) {
          throw ReviewUnavailable('Could not migrate the saved review: $error');
        }
      } finally {
        _loading.remove(directory);
      }
    });
  }

  /// Reads only the old session's commit message and pending file blobs.
  /// The legacy repository stays intact for unopened sessions and retries;
  /// none of its whole-project snapshot trees is copied into the new store.
  Future<String?> _migrateLegacy(String session) async {
    var name = session;
    if (!_safeName.hasMatch(name) || name.endsWith('.lock')) {
      name = 'h${_folderName(name).split('-').last}';
    }
    final ref = 'refs/baocode/sessions/$name';
    final resolved = await _legacyGit(['show-ref', '--verify', '--hash', ref]);
    if (resolved.exitCode == 1) return null;
    if (resolved.exitCode != 0) {
      throw const ReviewUnavailable('Invalid legacy repository.');
    }
    final commit = utf8.decode(
      await _legacyObject(
        'commit',
        utf8.decode(resolved.stdout as List<int>).trim(),
      ),
    );
    final body = commit.indexOf('\n\n');
    final json = body < 0 ? null : jsonDecode(commit.substring(body + 2));
    if (json is! Map<String, Object?> ||
        json['version'] != 1 ||
        json['entries'] is! Map<String, Object?> ||
        (json['unseen'] != null && json['unseen'] is! List)) {
      throw const ReviewUnavailable('Invalid legacy review.');
    }
    final blobs = <ReviewBlob, ReviewBlob>{};
    ReviewBlob? parse(Object? value) {
      if (value == null) return null;
      final blob = ReviewBlob.fromJson(value);
      if (blob == null ||
          !['100644', '100755', '120000'].contains(blob.mode) ||
          !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(blob.oid)) {
        throw const ReviewUnavailable('Invalid legacy blob.');
      }
      return blob;
    }

    Future<ReviewBlob?> migrate(ReviewBlob? blob) async {
      if (blob == null) return null;
      return blobs[blob] ??= await store(
        session,
        await _legacyObject('blob', blob.oid),
        mode: blob.mode,
      );
    }

    final entries = <String, Object?>{};
    for (final MapEntry(:key, :value)
        in (json['entries'] as Map<String, Object?>).entries) {
      if (value is! Map<String, Object?> ||
          !value.keys.toSet().containsAll(['base', 'after', 'current']) ||
          p.posix.isAbsolute(key) ||
          key.isEmpty ||
          key == '..' ||
          key.startsWith('../') ||
          p.posix.normalize(key) != key ||
          !p.isWithin(root, p.normalize(_full(key)))) {
        throw const ReviewUnavailable('Invalid legacy file entry.');
      }
      final base = parse(value['base']);
      final after = parse(value['after']);
      final before = parse(value['current']);
      if (base == null ? before == null : base.sameContent(before)) continue;
      entries[key] = {
        'base': (await migrate(base))?.toJson(),
        'after': (await migrate(after))?.toJson(),
        // Current is only a fingerprint, not another stored copy. User edits
        // since the old snapshot must still be carried over by Undo.
        'current': (await current(key))?.toJson(),
        'conflict': value['conflict'] == true,
      };
    }
    final data = jsonEncode({
      'version': 2,
      'entries': entries,
      'unseen': json['unseen'] ?? [],
    });
    // Publish only after every required blob has been imported. Failed or
    // partial migrations leave the old ref and objects untouched.
    await save(session, data, blobs: blobs.values);
    return data;
  }

  Future<ProcessResult> _legacyGit(List<String> arguments) => Process.run(
    'git',
    ['--git-dir=$folder', ...arguments],
    workingDirectory: root,
    environment: Map<String, String>.of(Platform.environment)
      ..removeWhere((key, _) => key.startsWith('GIT_')),
    includeParentEnvironment: false,
    stdoutEncoding: null,
  );

  Future<Uint8List> _legacyObject(String type, String oid) async {
    final result = await _legacyGit(['cat-file', type, oid]);
    if (result.exitCode != 0) {
      throw const ReviewUnavailable('A legacy review object is missing.');
    }
    return Uint8List.fromList(result.stdout as List<int>);
  }

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) async {
    final folder = Directory(_sessionFolder(session));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, _dataFile));
    final partial = File('${file.path}.$pid.part');
    await partial.writeAsString(data, flush: true);
    await partial.rename(file.path);
    await _markLegacyDone(session);
    // What it no longer needs (a change kept, a part of one).
    final kept = {for (final blob in blobs) blob.oid};
    final stored = Directory(p.join(folder.path, 'blobs'));
    if (!await stored.exists()) return;
    await for (final entry in stored.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is File && !name.endsWith('.part') && !kept.contains(name)) {
        try {
          await entry.delete();
        } on FileSystemException {
          // Next time.
        }
      }
    }
  }

  @override
  Future<void> forget(String session) async {
    await _markLegacyDone(session);
    final folder = Directory(_sessionFolder(session));
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } on FileSystemException {
      // Tidied later.
    }
    try {
      // The project's, with no session left.
      await Directory(this.folder).delete();
    } on FileSystemException {
      // Others there.
    }
  }

  // --- Tidying ---------------------------------------------------------------

  /// How long a session's edits are kept after it last saved them: past
  /// it, they can no longer be reviewed or undone.
  static Duration keepFor = const Duration(days: 30);

  /// Where [tidy] notes when it last ran, in the checkpoints folder.
  static const _tidiedFile = '.tidied';

  /// Clears out [checkpoints] (the folder [open] keeps the projects' in),
  /// at most once a [every]: the sessions not saved for [keepFor] go, and
  /// a project's folder with none left. Legacy repositories are kept for
  /// migration. Never throws; what it cannot read or delete is left.
  static Future<void> tidy(
    String checkpoints, {
    Duration every = const Duration(days: 1),
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    checkpoints = p.normalize(p.absolute(checkpoints));
    try {
      final folder = Directory(checkpoints);
      if (!await folder.exists()) return;
      final tidied = File(p.join(checkpoints, _tidiedFile));
      if (await tidied.exists() &&
          at.difference(await tidied.lastModified()) < every) {
        return;
      }
      await tidied.writeAsString('${at.toIso8601String()}\n');
      final cutoff = at.subtract(keepFor);
      await for (final project in folder.list(followLinks: false)) {
        if (project is! Directory) continue;
        try {
          await _tidyProject(project, cutoff);
        } on FileSystemException {
          // Next time.
        }
      }
    } on Object {
      // Tried again next time.
    }
  }

  static Future<void> _tidyProject(Directory project, DateTime cutoff) async {
    // A legacy repository may still hold sessions not opened (or whose
    // migration failed). It remains a read-only source, never aged out.
    if (await File(p.join(project.path, 'HEAD')).exists()) return;
    if (p.basename(project.path).contains('.old-')) {
      // One of an earlier build, out of the way.
      await project.delete(recursive: true);
      return;
    }
    await for (final session in project.list(followLinks: false)) {
      if (session is! Directory || _live.contains(session.path)) continue;
      final data = File(p.join(session.path, _dataFile));
      final saved = await data.exists()
          ? await data.lastModified()
          : (await session.stat()).modified;
      if (saved.isBefore(cutoff)) await session.delete(recursive: true);
    }
    if (await project.list().isEmpty) await project.delete();
  }

  static final Map<String, Timer> _tidying = {};

  /// Has [tidy] run on [checkpoints] a minute from now, then every few
  /// hours (it does its work once a day), for as long as the process runs.
  static void scheduleTidy(String checkpoints) {
    checkpoints = p.normalize(p.absolute(checkpoints));
    if (_tidying.containsKey(checkpoints)) return;
    _tidying[checkpoints] = Timer(const Duration(minutes: 1), () {
      unawaited(tidy(checkpoints));
      _tidying[checkpoints] = Timer.periodic(
        const Duration(hours: 6),
        (_) => unawaited(tidy(checkpoints)),
      );
    });
  }
}

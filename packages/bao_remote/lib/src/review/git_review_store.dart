import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'review_store.dart';

/// A Git command that failed.
class GitReviewError implements Exception {
  const GitReviewError(this.arguments, this.exitCode, this.stderr);

  final List<String> arguments;
  final int exitCode;
  final String stderr;

  @override
  String toString() =>
      'git ${arguments.first} failed ($exitCode): ${stderr.trim()}';
}

/// The project has too many files to snapshot, or too many bytes.
class _TooLarge implements Exception {
  const _TooLarge();
}

class _Output {
  const _Output(this.exitCode, this.bytes);

  final int exitCode;
  final Uint8List bytes;

  String get text => utf8.decode(bytes, allowMalformed: true);

  /// The NUL-separated records of a `-z` listing.
  List<String> get records => [
    for (final record in text.split('\x00'))
      if (record.isNotEmpty) record,
  ];
}

/// [ReviewStore] over a bare repository of the app's own, whose work tree
/// is the project: the project's `.git` (if it has one) is never read or
/// written, nor its index, HEAD or refs. Its `.gitignore` files are
/// followed. Line endings, filters and encodings are left as they are on
/// disk (`info/attributes`), so that what is put back is byte for byte
/// what was there.
class GitReviewStore implements ReviewStore, ReviewSnapshotOmissions {
  GitReviewStore._(this.root, this.gitDir, this._own, this._legacy);

  /// Migration source: its refs, review metadata and blobs stay intact.
  final String? _legacy;

  /// The store for [root], its repository under [checkpoints] (made the
  /// first time); null when Git cannot run or [root] is not a folder.
  /// [checkpoints] is tidied from then on ([scheduleTidy]).
  static Future<GitReviewStore?> open(
    String root, {
    required String checkpoints,
  }) async {
    root = p.normalize(p.absolute(root));
    checkpoints = p.normalize(p.absolute(checkpoints));
    if (!await Directory(root).exists() || !await _gitUsable) return null;
    final source = p.join(checkpoints, _folderName(root));
    final legacy = await _hasLegacy(source);
    final redirected =
        legacy || await File(p.join('$source.v3', 'HEAD')).exists();
    final gitDir = redirected ? '$source.v3' : source;
    final own = p.isWithin(root, checkpoints)
        ? p.relative(checkpoints, from: root)
        : null;
    final store = GitReviewStore._(root, gitDir, own, legacy ? source : null);
    _opened.add(gitDir);
    try {
      await store._locked(() async {
        if (!await File(p.join(gitDir, 'HEAD')).exists()) {
          await _dropFolder(gitDir);
          await _initialize(gitDir, root);
        } else {
          // What an earlier build left out may have grown since.
          await _writeInfo(gitDir);
        }
        if (own != null) {
          // Taken by snapshots before they left it out.
          await store._git([
            'rm',
            '--cached',
            // Whatever is staged there: only the index changes.
            '-f',
            '-r',
            '-q',
            '--ignore-unmatch',
            '--',
            ':(literal)$own',
          ]);
        }
      });
    } on Object catch (error) {
      final resource = _resourceFailure(error);
      if (resource != null) throw resource;
      return null;
    }
    scheduleTidy(checkpoints);
    return store;
  }

  @override
  final String root;

  /// The repository: `checkpoints/<folder name>-<hash of its path>`.
  final String gitDir;

  /// The checkpoints folder relative to the root, where the project holds
  /// it (a home folder, say): left out of the snapshots, which would
  /// otherwise take in what they write there.
  final String? _own;

  bool _isOwn(String path) {
    final own = _own;
    return own != null && (path == own || p.isWithin(own, path));
  }

  /// Past this size a file is left out of the snapshots (an edit the agent
  /// reports to it can still be undone, see `ChangeReview`).
  static int maxFileBytes = 5 * 1024 * 1024;

  /// Past this many new or changed files at once, the project is too large
  /// to snapshot (a first snapshot of a home folder, say).
  static int maxFiles = 100000;

  /// Past this many bytes of new or changed files at once, too.
  static int maxBytes = 1024 * 1024 * 1024;

  /// Folders left out even where no `.gitignore` says so: what tools
  /// download, build or cache, not what an agent edits.
  static const _excluded = [
    '.DS_Store',
    'node_modules/',
    '.venv/',
    '__pycache__/',
    '.dart_tool/',
    '.gradle/',
    '.next/',
    '.nuxt/',
    '.svelte-kit/',
    '.turbo/',
    '.parcel-cache/',
    '.angular/',
    '.cache/',
    '.pnpm-store/',
    '.yarn/cache/',
    '.mypy_cache/',
    '.pytest_cache/',
    '.ruff_cache/',
    '.tox/',
    'Pods/',
    'DerivedData/',
  ];

  static Future<void> _initialize(String gitDir, String root) async {
    await Directory(gitDir).create(recursive: true);
    final result = await Process.run('git', [
      'init',
      '-q',
      '--bare',
      // No hooks or other files from the user's template.
      '--template=',
      gitDir,
    ]);
    if (result.exitCode != 0) {
      throw GitReviewError(const ['init'], result.exitCode, '${result.stderr}');
    }
    await _writeInfo(gitDir);
    await File(p.join(gitDir, 'description'))
        .writeAsString('Snapshots of $root, for reviewing agents\' changes.\n');
  }

  static Future<void> _writeInfo(String gitDir) async {
    final info = await Directory(p.join(gitDir, 'info')).create();
    // Above the project's own `.gitattributes`: no conversions.
    await File(p.join(info.path, 'attributes'))
        .writeAsString('* -text !eol -filter -ident !working-tree-encoding\n');
    await File(p.join(info.path, 'exclude'))
        .writeAsString('${_excluded.join('\n')}\n');
  }

  /// Legacy sources stay at their original path. New objects go beside
  /// them, so packed objects, failed imports and unopened sessions survive.
  static Future<bool> _hasLegacy(String folder) => _resources(() async {
    if (!await Directory(folder).exists()) return false;
    for (final session in await _legacyFolders(folder)) {
      final data = File(p.join(session.path, 'review.json'));
      if (!await data.exists()) continue;
      // An empty placeholder has never kept a review. Corrupt metadata or
      // any saved blobs, however, must remain available for recovery.
      try {
        final json = jsonDecode(await data.readAsString());
        if (json is Map &&
            json.isEmpty &&
            !await Directory(p.join(session.path, 'blobs')).exists()) {
          continue;
        }
      } on FormatException {
        return true;
      }
      return true;
    }
    if (!await File(p.join(folder, 'HEAD')).exists()) return false;
    final listed = await _sourceGit(folder, [
      'for-each-ref',
      '--format=%(objectname)',
      'refs/baocode/sessions/',
    ]);
    if (listed.exitCode != 0) return true;
    for (final oid in utf8.decode(listed.stdout as List<int>).split('\n')) {
      if (oid.isEmpty) continue;
      final result = await _sourceGit(folder, ['cat-file', 'commit', oid]);
      if (result.exitCode != 0) return true;
      final commit = utf8.decode(result.stdout as List<int>);
      final body = commit.indexOf('\n\n');
      if (body < 0) continue;
      final data = commit.substring(body + 2).trim();
      try {
        final json = jsonDecode(data);
        if (json is Map && json['version'] != 3) return true;
      } on FormatException {
        if (data.startsWith('{')) return true;
      }
    }
    return false;
  });

  static Future<List<Directory>> _legacyFolders(String folder) async {
    final sessions = <Directory>[];
    await for (final entry in Directory(folder).list(followLinks: false)) {
      if (entry is! Directory) continue;
      // A direct session can itself be named sessions-v2. Check its own
      // metadata as well as the nested layout's children.
      sessions.add(entry);
      if (p.basename(entry.path) == 'sessions-v2') {
        await for (final session in entry.list(followLinks: false)) {
          if (session is Directory) sessions.add(session);
        }
      }
    }
    return sessions;
  }

  static Future<ProcessResult> _sourceGit(
    String folder,
    List<String> arguments,
  ) => _resources(() async {
    final result = await Process.run(
      'git',
      ['--git-dir=$folder', ...arguments],
      environment: Map<String, String>.of(Platform.environment)
        ..removeWhere((key, _) => key.startsWith('GIT_')),
      includeParentEnvironment: false,
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) {
      final resource = _resourceFailure(
        GitReviewError(arguments, result.exitCode, '${result.stderr}'),
      );
      if (resource != null) throw resource;
    }
    return result;
  });

  static Future<String?> _sessionData(String folder, String ref) async {
    final exists = await _sourceGit(folder, [
      'show-ref',
      '--verify',
      '--quiet',
      ref,
    ]);
    if (exists.exitCode == 1) return null;
    if (exists.exitCode != 0) {
      throw const ReviewUnavailable('Invalid saved review repository.');
    }
    final resolved = await _sourceGit(folder, [
      'show-ref',
      '--verify',
      '--hash',
      ref,
    ]);
    if (resolved.exitCode != 0) {
      throw const ReviewUnavailable('Invalid saved review ref.');
    }
    final oid = utf8.decode(resolved.stdout as List<int>).trim();
    final result = await _sourceGit(folder, ['cat-file', 'commit', oid]);
    if (result.exitCode != 0) {
      throw const ReviewUnavailable('A saved review commit is missing.');
    }
    final commit = utf8.decode(result.stdout as List<int>);
    final body = commit.indexOf('\n\n');
    return body < 0 ? '' : commit.substring(body + 2);
  }

  /// A folder there that is not a repository (one of a build that kept
  /// each session's files in a folder of its own) goes, out of the way at
  /// once and deleted after.
  static Future<void> _dropFolder(String folder) async {
    if (!await Directory(folder).exists()) return;
    final gone = '$folder.old-$pid-${DateTime.now().microsecondsSinceEpoch}';
    await Directory(folder).rename(gone);
    unawaited(
      Directory(gone).delete(recursive: true).then((_) {}, onError: (_) {}),
    );
  }

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

  /// Whether `git` runs. On macOS, where `/usr/bin/git` without the
  /// command line tools would ask the user to install them, only once they
  /// are (or another Git comes first on the PATH).
  static Future<bool>? _checkingGit;
  static Future<bool> get _gitUsable =>
      _checkingGit ??= _checkGit().catchError((Object error) {
        _checkingGit = null;
        throw error;
      });

  static Future<bool> _checkGit() => _resources(() async {
    try {
      if (Platform.isMacOS && _onPath('git') == '/usr/bin/git') {
        final tools = await Process.run('xcode-select', ['-p']);
        if (tools.exitCode != 0) return false;
      }
      return (await Process.run('git', ['--version'])).exitCode == 0;
    } on ProcessException catch (error) {
      final resource = _resourceFailure(error);
      if (resource != null) throw resource;
      return false;
    }
  });

  static String? _onPath(String name) {
    final path = Platform.environment['PATH'] ?? '';
    for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
      if (directory.isEmpty) continue;
      final candidate = p.join(directory, name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  // --- Running Git -----------------------------------------------------------

  /// Operations on the repository's own index, one at a time (conversations
  /// in the same project share it).
  static final Map<String, Future<void>> _locks = {};

  Future<T> _locked<T>(Future<T> Function() body) {
    final result = (_locks[gitDir] ?? Future.value()).then((_) => body());
    _locks[gitDir] = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  static int _scratch = 0;

  /// Runs `git` on the repository and the project, with the index at
  /// [index] (by default its own); fails unless the exit code is in [ok]
  /// (null: any). With [repo], on that repository inside the project (see
  /// [snapshot]) as the work tree, and by default its index.
  Future<_Output> _git(
    List<String> arguments, {
    List<int>? input,
    String? index,
    String repo = '',
    Map<String, String> environment = const {},
    Set<int>? ok = const {0},
    Duration timeout = const Duration(seconds: 60),
  }) => _resources(() async {
    final workTree = repo.isEmpty ? root : _full(repo);
    final Process process;
    try {
      process = await Process.start(
        'git',
        [
          '--git-dir=$gitDir',
          '--work-tree=$workTree',
          for (final setting in const [
            'core.autocrlf=false',
            'core.safecrlf=false',
            'core.fsmonitor=false',
            'core.quotePath=false',
            'core.longpaths=true',
          ]) ...['-c', setting],
          ...arguments,
        ],
        workingDirectory: workTree,
        environment: {
          'GIT_TERMINAL_PROMPT': '0',
          'GIT_OPTIONAL_LOCKS': '0',
          'GIT_INDEX_FILE': index ?? _indexOf(repo),
          ...environment,
        },
      );
    } on ProcessException catch (error) {
      throw ReviewUnavailable(
        'Git could not be started: ${error.message}',
        retryable: _descriptorExhausted(error.errorCode),
      );
    }
    final stdout = BytesBuilder(copy: false);
    final stderr = StringBuffer();
    final reading = Future.wait([
      process.stdout.listen(stdout.add).asFuture<void>(),
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(stderr.write)
          .asFuture<void>(),
    ]);
    // Git may be done before it read it all.
    unawaited(process.stdin.done.catchError((Object _) {}));
    if (input != null) process.stdin.add(input);
    unawaited(process.stdin.close().catchError((Object _) {}));
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await reading;
    if (code != 0) {
      final resource = _resourceFailure(
        GitReviewError(arguments, code, stderr.toString()),
      );
      if (resource != null) throw resource;
    }
    if (ok != null && !ok.contains(code)) {
      throw GitReviewError(arguments, code, stderr.toString());
    }
    return _Output(code, stdout.takeBytes());
  });

  String _full(String path) => p.join(root, path);

  bool _exists(String path) =>
      FileSystemEntity.typeSync(_full(path), followLinks: false) !=
      FileSystemEntityType.notFound;

  bool _tooLarge(String path) => _isLarge(_full(path), maxFileBytes);

  /// Whether [full] is a file of more than [maxBytes].
  static bool _isLarge(String full, int maxBytes) {
    try {
      return FileSystemEntity.typeSync(full, followLinks: false) ==
              FileSystemEntityType.file &&
          File(full).lengthSync() > maxBytes;
    } on FileSystemException catch (error) {
      if (_descriptorExhausted(error.osError?.errorCode)) rethrow;
      return false;
    }
  }

  /// Those of [paths] (relative to [root]) that are files of more than
  /// [maxBytes], and the size of the others, looked at on an isolate of
  /// their own: a first snapshot lists every file of the project, and a
  /// look at each, here, would hold up the app (the UI, in the app) for
  /// seconds.
  static Future<({Set<String> large, int bytes})> _measure(
    String root,
    List<String> paths,
    int maxBytes,
  ) => Isolate.run(() {
    final large = <String>{};
    var bytes = 0;
    for (final path in paths) {
      final full = p.join(root, path);
      try {
        if (FileSystemEntity.typeSync(full, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final length = File(full).lengthSync();
        if (length > maxBytes) {
          large.add(path);
        } else {
          bytes += length;
        }
      } on FileSystemException catch (error) {
        if (_descriptorExhausted(error.osError?.errorCode)) rethrow;
        // Gone, or not to be read: left to Git.
      }
    }
    return (large: large, bytes: bytes);
  });

  /// Whether [root] is too large to snapshot whatever is in it: a home
  /// folder, the top of a drive.
  static bool _tooWide(String root) {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home != null && home.isNotEmpty && p.equals(p.normalize(home), root)) {
      return true;
    }
    return p.dirname(root) == root;
  }

  static bool _descriptorExhausted(int? code) =>
      Platform.isWindows ? code == 4 : code == 23 || code == 24;

  static ReviewUnavailable? _resourceFailure(Object error) {
    final exhausted = switch (error) {
      ProcessException(:final errorCode) => _descriptorExhausted(errorCode),
      FileSystemException(:final osError) => _descriptorExhausted(
        osError?.errorCode,
      ),
      GitReviewError(:final stderr) =>
        stderr.toLowerCase().contains('too many open files') ||
            stderr.contains('EMFILE') ||
            stderr.contains('ENFILE'),
      _ => false,
    };
    return exhausted
        ? ReviewUnavailable(
            'Review temporarily unavailable: $error',
            retryable: true,
          )
        : null;
  }

  static Future<T> _resources<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error) {
      final resource = _resourceFailure(error);
      if (resource != null) throw resource;
      rethrow;
    }
  }

  /// The repositories of projects found too large to snapshot in this
  /// process: not listed again.
  static final Set<String> _oversized = {};

  // --- Snapshots -------------------------------------------------------------

  /// The repositories inside the project the last snapshot looked into, by
  /// path relative to the root, per repository of snapshots; null until
  /// one did.
  static final Map<String, Set<String>> _nested = {};

  /// The index of [repo] (relative to the root; empty for the project).
  String _indexOf(String repo) => repo.isEmpty
      ? p.join(gitDir, 'index')
      : p.join(gitDir, 'nested', _folderName(repo));

  /// A repository inside the project (a package cloned into it, a folder
  /// of projects opened as one) is a gitlink to Git, its files out of
  /// sight. Each is snapshotted on its own, with its own index (its
  /// `.gitignore` files followed, its `.git` never read), and its tree put
  /// in place of the gitlink: the snapshot has its files as any others.
  @override
  Future<String?> snapshot({Iterable<String>? paths}) => _locked(
    () => _resources(() async {
      if (_oversized.contains(gitDir)) return null;
      if (_tooWide(root)) {
        _oversized.add(gitDir);
        return null;
      }
      try {
        final tree = await _snapshot(paths);
        // The latest is kept: what the indexes have is in it (theirs are not
        // all of Git's, and would otherwise go with the rest).
        await _git(['update-ref', _latest, tree]);
        return tree;
      } on _TooLarge {
        _oversized.add(gitDir);
        // A partial index would make a later snapshot take the rest for
        // deleted.
        await _deleteIndexes();
        return null;
      }
    }),
  );

  static const _latest = 'refs/baocode/latest';

  Future<void> _deleteIndexes() async {
    await _deleteIndex(_indexOf(''));
    try {
      await Directory(p.join(gitDir, 'nested')).delete(recursive: true);
    } on FileSystemException {
      // None.
    }
    _nested.remove(gitDir);
    _links.removeWhere((index, _) => p.isWithin(gitDir, index));
  }

  Set<String> _omitted = {};

  @override
  Future<Set<String>> omitted() async => Set.of(_omitted);

  Future<String> _snapshot(Iterable<String>? paths) async {
    final omitted = <String>{if (paths != null) ..._omitted};
    if (paths != null) omitted.removeAll(paths);
    Map<String, List<String>>? wanted;
    if (paths != null) {
      final nested = _nested[gitDir] ?? await _look();
      wanted = {};
      for (final path in paths) {
        if (_isOwn(path)) continue;
        final repo = _repoOf(path, nested);
        wanted
            .putIfAbsent(repo, () => [])
            .add(repo.isEmpty ? path : path.substring(repo.length + 1));
      }
    }
    final trees = <String, String>{};
    var files = 0;
    var size = 0;
    Future<void> take(String repo) async {
      // One not snapshotted before is, whole: else its other files would
      // look deleted.
      final indexed = File(_indexOf(repo)).existsSync();
      final whole = wanted == null || !indexed;
      final (:specs, :changed, :bytes, :nested) = await _specs(
        repo,
        whole ? null : wanted[repo] ?? const [],
        omitted,
      );
      files += changed;
      size += bytes;
      if (files > maxFiles || size > maxBytes) throw const _TooLarge();
      if (specs.isNotEmpty) await _add(repo, specs);
      final tree = trees[repo] = (await _git([
        'write-tree',
      ], repo: repo)).text.trim();
      for (final link in {...await _gitlinks(repo, tree), ...nested}) {
        await take(repo.isEmpty ? link : '$repo/$link');
      }
    }

    await take('');
    if (paths != null) {
      // Unborn repositories have no gitlink in their parent's index, but
      // their existing snapshot must also survive a reported-files look.
      for (final repo in _nested[gitDir] ?? const <String>{}) {
        if (!trees.containsKey(repo) && _exists('$repo/.git')) await take(repo);
      }
    }
    _omitted = omitted;
    _nested[gitDir] = {
      for (final repo in trees.keys)
        if (repo.isNotEmpty) repo,
    };
    return _compose(trees);
  }

  /// The repositories inside the project as its indexes have them, for a
  /// first snapshot of only some paths.
  Future<Set<String>> _look() async {
    final found = <String>{};
    Future<void> visit(String repo) async {
      if (!File(_indexOf(repo)).existsSync()) return;
      final tree = (await _git(['write-tree'], repo: repo)).text.trim();
      for (final link in await _gitlinks(repo, tree)) {
        final nested = repo.isEmpty ? link : '$repo/$link';
        found.add(nested);
        await visit(nested);
      }
    }

    await visit('');
    return found;
  }

  /// The innermost of [nested] that [path] is in; empty for none.
  static String _repoOf(String path, Set<String> nested) {
    var repo = '';
    for (final candidate in nested) {
      if (path.startsWith('$candidate/') && candidate.length > repo.length) {
        repo = candidate;
      }
    }
    return repo;
  }

  /// What to add to [repo]'s index: [paths] (relative to it), or
  /// everything; and how many files changed, and their bytes, for
  /// everything.
  Future<({List<String> specs, int changed, int bytes, Set<String> nested})>
  _specs(String repo, List<String>? paths, Set<String> omitted) async {
    String inRoot(String path) => repo.isEmpty ? path : '$repo/$path';
    final specs = <String>[];
    if (paths == null) {
      final own = switch (_own) {
        final own? when repo.isEmpty => own,
        final own? when p.isWithin(repo, own) => p.relative(own, from: repo),
        _ => null,
      };
      final everything = ['.', if (own != null) ':(exclude,literal)$own'];
      final changed = (await _git(
        [
          'ls-files',
          '-z',
          '--others',
          '--modified',
          '--exclude-standard',
          '--',
          ...everything,
        ],
        repo: repo,
        timeout: const Duration(minutes: 5),
      )).records;
      final nested = <String>{
        for (final path in changed)
          if (path.endsWith('/') && _exists('${inRoot(path)}.git'))
            path.substring(0, path.length - 1),
      };
      specs.addAll(everything);
      if (changed.length > maxFiles) {
        return (
          specs: specs,
          changed: changed.length,
          bytes: 0,
          nested: nested,
        );
      }
      var bytes = 0;
      if (changed.isNotEmpty) {
        final measured = await _measure(root, [
          for (final path in changed) inRoot(path),
        ], maxFileBytes);
        bytes = measured.bytes;
        omitted.addAll(measured.large);
        for (final path in changed) {
          if (measured.large.contains(inRoot(path))) {
            specs.add(':(exclude,literal)$path');
          }
        }
      }
      return (
        specs: specs,
        changed: changed.length,
        bytes: bytes,
        nested: nested,
      );
    }
    final missing = [
      for (final path in paths)
        if (!_exists(inRoot(path))) path,
    ];
    // A file gone counts where the snapshot had it.
    final tracked = missing.isEmpty
        ? const <String>{}
        : (await _git([
            'ls-files',
            '-z',
            '--',
            for (final path in missing) ':(literal)$path',
          ], repo: repo)).records.toSet();
    for (final path in {...paths}) {
      final exists = _exists(inRoot(path));
      final large = exists && _tooLarge(inRoot(path));
      if (large) omitted.add(inRoot(path));
      if (exists ? !large : tracked.contains(path)) {
        specs.add(':(literal)$path');
      }
    }
    return (specs: specs, changed: 0, bytes: 0, nested: <String>{});
  }

  /// The gitlinks of each index, as its last tree has them.
  static final Map<String, ({String tree, Set<String> links})> _links = {};

  /// The gitlinks in [tree], [repo]'s: what changed since its last tree,
  /// rather than the whole of it again.
  Future<Set<String>> _gitlinks(String repo, String tree) async {
    final index = _indexOf(repo);
    Set<String>? links;
    switch (_links[index]) {
      case (tree: final last, links: final known) when last == tree:
        return known;
      case (tree: final last, links: final known):
        try {
          final changed = {...known};
          for (final change in await diff(last, tree)) {
            if (change.after?.mode == _gitlink) {
              changed.add(change.path);
            } else if (change.before?.mode == _gitlink) {
              changed.remove(change.path);
            }
          }
          links = changed;
        } on GitReviewError {
          // The last tree was collected since (no snapshot for days, or
          // the checkpoints were cleared): the whole of it.
        }
      case null:
    }
    links ??= {
      for (final record in (await _git(['ls-tree', '-r', '-z', tree])).records)
        if (record.startsWith('$_gitlink '))
          record.substring(record.indexOf('\t') + 1),
    };
    _links[index] = (tree: tree, links: links);
    return links;
  }

  static const _gitlink = '160000';

  /// The project's tree with each repository inside it in place of its
  /// gitlink, outer ones first.
  Future<String> _compose(Map<String, String> trees) async {
    if (trees.length == 1) return trees['']!;
    final index = p.join(gitDir, 'compose-$pid-${_scratch++}');
    try {
      await _git(['read-tree', trees['']!], index: index);
      for (final repo
          in trees.keys.where((repo) => repo.isNotEmpty).toList()
            ..sort((a, b) => a.length.compareTo(b.length))) {
        await _git([
          'update-index',
          '--force-remove',
          '--',
          repo,
        ], index: index);
        await _git([
          'read-tree',
          '--prefix=$repo/',
          trees[repo]!,
        ], index: index);
      }
      return (await _git(['write-tree'], index: index)).text.trim();
    } finally {
      await _deleteIndex(index);
    }
  }

  Future<void> _deleteIndex(String index) async {
    for (final file in [index, '$index.lock']) {
      try {
        await File(file).delete();
      } on FileSystemException {
        // Not there.
      }
    }
  }

  Future<void> _add(String repo, List<String> specs) async {
    final index = _indexOf(repo);
    await Directory(p.dirname(index)).create(recursive: true);
    Future<void> add() => _git(
      [
        'add',
        '-A',
        // A file that cannot be read is left as it was, not the rest.
        '--ignore-errors',
        '--pathspec-from-file=-',
        '--pathspec-file-nul',
      ],
      repo: repo,
      input: utf8.encode(specs.join('\x00')),
      ok: const {0, 1},
      timeout: const Duration(minutes: 5),
    );
    try {
      await add();
    } on GitReviewError catch (error) {
      // Left by a Git that was killed (one here would have finished; one
      // of another run of the app, long since).
      final lock = File('$index.lock');
      if (!error.stderr.contains('index.lock') ||
          !await lock.exists() ||
          DateTime.now().difference(await lock.lastModified()) <
              const Duration(minutes: 5)) {
        rethrow;
      }
      await lock.delete();
      await add();
    }
  }

  static final _rawRecord = RegExp(
    r'^:(\d{6}) (\d{6}) ([0-9a-f]+) ([0-9a-f]+) ',
  );

  @override
  Future<List<ReviewTreeChange>> diff(String from, String to) async {
    if (from == to) return const [];
    final records = (await _git([
      'diff-tree',
      '-r',
      '-z',
      '--no-renames',
      from,
      to,
    ])).records;
    ReviewBlob? blob(String mode, String oid) =>
        mode == '000000' ? null : ReviewBlob(mode, oid);
    return [
      for (var i = 0; i + 1 < records.length; i += 2)
        if (_rawRecord.firstMatch(records[i]) case final match?)
          ReviewTreeChange(
            records[i + 1],
            blob(match[1]!, match[3]!),
            blob(match[2]!, match[4]!),
          ),
    ];
  }

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String from,
    String to,
  ) async {
    if (from == to) return const {};
    final records = (await _git([
      'diff-tree',
      '-r',
      '-z',
      '--numstat',
      '--no-renames',
      from,
      to,
    ])).records;
    return {
      for (final record in records)
        if (record.split('\t') case [final added, final removed, ...final path])
          path.join('\t'): switch ((
            int.tryParse(added),
            int.tryParse(removed),
          )) {
            (final added?, final removed?) => (added: added, removed: removed),
            _ => null,
          },
    };
  }

  @override
  Future<String> overlay(String tree, Map<String, ReviewBlob?> entries) async {
    if (entries.isEmpty && tree.isNotEmpty) return tree;
    final index = p.join(gitDir, 'overlay-$pid-${_scratch++}');
    try {
      if (tree.isNotEmpty) await _git(['read-tree', tree], index: index);
      final none = '0' * 40;
      await _git(
        ['update-index', '-z', '--add', '--replace', '--index-info'],
        index: index,
        input: utf8.encode(
          [
            for (final MapEntry(key: path, value: blob) in entries.entries)
              blob == null
                  ? '0 $none\t$path\x00'
                  : '${blob.mode} ${blob.oid}\t$path\x00',
          ].join(),
        ),
      );
      return (await _git(['write-tree'], index: index)).text.trim();
    } finally {
      await _deleteIndex(index);
    }
  }

  @override
  Future<bool> contains(String tree, String path) async =>
      (await _git(['cat-file', '-e', '$tree:$path'], ok: null)).exitCode == 0;

  // --- Files -----------------------------------------------------------------

  @override
  Future<bool> exists(String path) async => _exists(path);

  @override
  Future<ReviewBlob?> current(String path) => _hash(path, write: false);

  @override
  Future<ReviewBlob?> take(String path) => _hash(path, write: true);

  Future<ReviewBlob?> _hash(String path, {required bool write}) =>
      _resources(() async {
        final full = _full(path);
        switch (FileSystemEntity.typeSync(full, followLinks: false)) {
          case FileSystemEntityType.notFound || FileSystemEntityType.directory:
            return null;
          case FileSystemEntityType.link:
            final target = await Link(full).target();
            final hashed = await _git([
              'hash-object',
              if (write) '-w',
              '--stdin',
            ], input: utf8.encode(target));
            return ReviewBlob('120000', hashed.text.trim());
          default:
            final hashed = await _git([
              'hash-object',
              if (write) '-w',
              '--no-filters',
              '--',
              path,
            ]);
            final executable =
                !Platform.isWindows && File(full).statSync().mode & 0x49 != 0;
            return ReviewBlob(
              executable ? '100755' : '100644',
              hashed.text.trim(),
            );
        }
      });

  @override
  Future<Uint8List> read(ReviewBlob blob) async =>
      (await _git(['cat-file', 'blob', blob.oid])).bytes;

  @override
  Future<ReviewBlob> store(Uint8List bytes, {required String mode}) async {
    final hashed = await _git([
      'hash-object',
      '-w',
      '--no-filters',
      '--stdin',
    ], input: bytes);
    return ReviewBlob(mode, hashed.text.trim());
  }

  @override
  Future<void> restore(String path, ReviewBlob? blob) async {
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
    final bytes = await read(blob);
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
  Future<Uint8List?> merge(String path, ReviewBlob from, ReviewBlob to) async {
    final temp = await Directory.systemTemp.createTemp('baocode-review-');
    try {
      final ours = p.join(temp.path, 'current');
      final base = p.join(temp.path, 'base');
      final theirs = p.join(temp.path, 'other');
      await File(_full(path)).copy(ours);
      await File(base).writeAsBytes(await read(from));
      await File(theirs).writeAsBytes(await read(to));
      final merged = await _git([
        'merge-file',
        '-p',
        '-q',
        ours,
        base,
        theirs,
      ], ok: null);
      // The number of conflicts, or an error (a binary file).
      return merged.exitCode == 0 ? merged.bytes : null;
    } finally {
      await temp.delete(recursive: true);
    }
  }

  @override
  Future<void> write(String path, Uint8List bytes) =>
      File(_full(path)).writeAsBytes(bytes, flush: true);

  // --- Sessions --------------------------------------------------------------

  static final _safeName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

  String _ref(String session) {
    if (!_safeName.hasMatch(session) || session.endsWith('.lock')) {
      session = 'h${_folderName(session).split('-').last}';
    }
    return 'refs/baocode/sessions/$session';
  }

  int _saves = 0;

  /// The sessions of each repository loaded or saved in this process:
  /// conversations that may be open, which [clear] leaves.
  static final Map<String, Set<String>> _sessions = {};

  void _hold(String session) =>
      _sessions.putIfAbsent(gitDir, () => {}).add(_ref(session));

  @override
  Future<String?> load(String session) {
    _hold(session);
    final key = '$gitDir/${_ref(session)}';
    return _loading.putIfAbsent(key, () async {
      try {
        final data = await _sessionData(gitDir, _ref(session));
        if (data != null) {
          await _markLegacyDone(session);
          return data;
        }
        if (_legacy == null || await _legacyDone(session)!.exists()) {
          return null;
        }
        return await _resources(() => _migrateLegacy(session));
      } on ReviewUnavailable {
        rethrow;
      } on Object catch (error) {
        throw ReviewUnavailable('Could not migrate the saved review: $error');
      } finally {
        _loading.remove(key);
      }
    });
  }

  static final Map<String, Future<String?>> _loading = {};

  String _folderSession(String session) =>
      _safeName.hasMatch(session) && !session.startsWith('.')
      ? session
      : 'h${_folderName(session).split('-').last}';

  File? _legacyDone(String session) => _legacy == null
      ? null
      : File(p.join(_legacy, '.migrated-v3-${_folderSession(session)}'));

  Future<void> _markLegacyDone(String session) => _resources(() async {
    final marker = _legacyDone(session);
    if (marker == null ||
        !await Directory(_legacy!).exists() ||
        await marker.exists()) {
      return;
    }
    // Kept beside the source, not its new repository: expiring the new
    // session or collecting that repository must never revive an old ref.
    final partial = File('${marker.path}.$pid-${_scratch++}.part');
    await partial.writeAsString('3\n', flush: true);
    await partial.rename(marker.path);
  });

  Future<String?> _migrateLegacy(String session) async {
    final source = _legacy!;
    final name = _folderSession(session);
    String? data;
    String? blobsFolder;
    for (final folder in [
      p.join(source, 'sessions-v2', name),
      p.join(source, name),
    ]) {
      final file = File(p.join(folder, 'review.json'));
      if (await file.exists()) {
        data = await file.readAsString();
        blobsFolder = p.join(folder, 'blobs');
        break;
      }
    }
    if (data == null) {
      // A v1 review already kept/undone by the fork must not be resurrected.
      if (await File(p.join(source, '.migrated-$name')).exists() ||
          !await File(p.join(source, 'HEAD')).exists()) {
        return null;
      }
      data = await _sessionData(source, _ref(session));
      if (data == null) return null;
    }
    final json = jsonDecode(data);
    if (json is! Map<String, Object?> ||
        ![1, 2, 3].contains(json['version']) ||
        json['entries'] is! Map<String, Object?> ||
        (json['unseen'] != null && json['unseen'] is! List)) {
      throw const ReviewUnavailable('Invalid legacy review.');
    }
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

    final imported = <ReviewBlob, ReviewBlob>{};
    Future<ReviewBlob?> migrate(ReviewBlob? blob) async {
      if (blob == null) return null;
      if (imported[blob] case final kept?) return kept;
      final Uint8List bytes;
      if (blobsFolder != null) {
        bytes = Uint8List.fromList(
          zlib.decode(await File(p.join(blobsFolder, blob.oid)).readAsBytes()),
        );
        if (sha1.convert(bytes).toString() != blob.oid) {
          throw const ReviewUnavailable('A legacy review blob is corrupt.');
        }
      } else {
        final result = await _sourceGit(source, ['cat-file', 'blob', blob.oid]);
        if (result.exitCode != 0) {
          throw const ReviewUnavailable('A legacy review object is missing.');
        }
        bytes = Uint8List.fromList(result.stdout as List<int>);
      }
      return imported[blob] = await store(bytes, mode: blob.mode);
    }

    final entries = <String, Object?>{};
    for (final MapEntry(:key, :value)
        in (json['entries'] as Map<String, Object?>).entries) {
      if (value is! Map<String, Object?> ||
          !value.keys.toSet().containsAll(['base', 'after', 'current']) ||
          key.isEmpty ||
          key == '.' ||
          key == '..' ||
          key.startsWith('../') ||
          p.posix.normalize(key) != key ||
          (json['version'] == 1 &&
              (p.posix.isAbsolute(key) || p.isAbsolute(key))) ||
          (!p.isAbsolute(key) && !p.isWithin(root, p.normalize(_full(key))))) {
        throw const ReviewUnavailable('Invalid legacy file entry.');
      }
      final base = parse(value['base']);
      final after = parse(value['after']);
      final current = parse(value['current']);
      if (base == null ? current == null : base.sameContent(current)) continue;
      entries[key] = {
        ...value,
        'base': (await migrate(base))?.toJson(),
        'after': (await migrate(after))?.toJson(),
        'current': (await this.current(key))?.toJson(),
        'loose': true,
      };
    }
    final migrated = jsonEncode({
      'version': 3,
      'entries': entries,
      'unseen': json['unseen'] ?? [],
    });
    // Only publish once every pending base/after is safely in the new repo.
    // Failed imports leave the source, its refs and its markers untouched.
    await save(session, migrated, blobs: imported.values);
    return migrated;
  }

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) async {
    _hold(session);
    final entries = [
      for (final (i, oid) in {for (final blob in blobs) blob.oid}.indexed)
        '100644 blob $oid\tb$i\x00',
    ];
    final tree = (await _git([
      'mktree',
      '-z',
    ], input: utf8.encode(entries.join()))).text.trim();
    const identity = {
      'GIT_AUTHOR_NAME': 'baocode',
      'GIT_AUTHOR_EMAIL': 'baocode@localhost',
      'GIT_COMMITTER_NAME': 'baocode',
      'GIT_COMMITTER_EMAIL': 'baocode@localhost',
    };
    final commit = (await _git(
      ['commit-tree', '--no-gpg-sign', '-F', '-', tree],
      input: utf8.encode(data),
      environment: identity,
    )).text.trim();
    await _git(['update-ref', _ref(session), commit]);
    await _markLegacyDone(session);
    // Snapshots no session keeps go after Git's grace period.
    if (++_saves % 50 == 0) {
      unawaited(
        _git([
          '-c',
          'gc.pruneExpire=${_grace.inDays}.days.ago',
          'gc',
          '--auto',
          '--quiet',
        ], ok: null).then((_) {}, onError: (Object _) {}),
      );
    }
  }

  @override
  Future<void> forget(String session) async {
    await _markLegacyDone(session);
    _sessions[gitDir]?.remove(_ref(session));
    await _git(['update-ref', '-d', _ref(session)], ok: null);
  }

  // --- Tidying ---------------------------------------------------------------

  /// How long a session's changes are kept after it last saved them: past
  /// it, they can no longer be reviewed or undone.
  static Duration keepFor = const Duration(days: 30);

  /// How long objects nothing keeps stay, for a conversation at work that
  /// has taken snapshots but not saved them yet.
  static const _grace = Duration(days: 2);

  /// The repositories of the stores [open] gave in this process: never
  /// deleted from under them.
  static final Set<String> _opened = {};

  /// Where [tidy] notes when it last ran, in the checkpoints folder.
  static const _tidiedFile = '.tidied';

  /// Clears out [checkpoints] (the folder [open] keeps the projects'
  /// repositories in), at most once a [every]: the sessions not saved for
  /// [keepFor] go, a repository with none left and unused as long is
  /// deleted, and one that lost some, or was used since, is repacked
  /// without the objects nothing keeps (the snapshots, but for the
  /// latest). What is not a repository (left by another build) goes.
  /// Never throws; what it cannot read or delete is left.
  static Future<void> tidy(
    String checkpoints, {
    Duration every = const Duration(days: 1),
    DateTime? now,
  }) async {
    now ??= DateTime.now();
    checkpoints = p.normalize(p.absolute(checkpoints));
    try {
      final folder = Directory(checkpoints);
      if (!await folder.exists() || !await _gitUsable) return;
      final tidied = File(p.join(checkpoints, _tidiedFile));
      DateTime? last;
      if (await tidied.exists()) {
        last = await tidied.lastModified();
        if (now.difference(last) < every) return;
      }
      await tidied.writeAsString('${now.toIso8601String()}\n');
      final cutoff = now.subtract(keepFor);
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final gitDir = entry.path;
        if (await _hasLegacy(gitDir)) continue;
        if (!await File(p.join(gitDir, 'HEAD')).exists()) {
          if (!_opened.contains(gitDir)) await _delete(entry);
          continue;
        }
        await _withLock(
          gitDir,
          () => _tidyRepository(gitDir, cutoff, since: last),
        );
      }
    } on Object {
      // Tried again next time.
    }
  }

  /// Deletes what [checkpoints] keeps: the repositories of the projects
  /// not open in this process and, in those that are, the sessions not
  /// loaded or saved in it and the snapshots but for the latest. Their
  /// changes can no longer be reviewed or undone. Never throws; what it
  /// cannot delete is left.
  static Future<void> clear(String checkpoints) async {
    checkpoints = p.normalize(p.absolute(checkpoints));
    try {
      final folder = Directory(checkpoints);
      if (!await folder.exists()) return;
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final gitDir = entry.path;
        if (!_opened.contains(gitDir) ||
            !await File(p.join(gitDir, 'HEAD')).exists()) {
          await _delete(entry);
          continue;
        }
        await _withLock(gitDir, () => _clearRepository(gitDir));
      }
    } on Object {
      // What is left stays.
    }
  }

  /// The bytes [checkpoints] takes up.
  static Future<int> sizeOf(String checkpoints) => Isolate.run(() {
    var bytes = 0;
    final folder = Directory(checkpoints);
    if (!folder.existsSync()) return 0;
    try {
      for (final entry in folder.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File) {
          try {
            bytes += entry.lengthSync();
          } on FileSystemException {
            // Gone since.
          }
        }
      }
    } on FileSystemException {
      // What could be listed.
    }
    return bytes;
  });

  static Future<void> _delete(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Next time.
    }
  }

  /// [body] after whatever a store open on [gitDir] does in this process.
  static Future<void> _withLock(
    String gitDir,
    Future<void> Function() body,
  ) async {
    final done = (_locks[gitDir] ?? Future.value()).then((_) => body());
    _locks[gitDir] = done.then((_) {}, onError: (Object _) {});
    await done.catchError((Object _) {});
  }

  static Future<ProcessResult> _gitOn(
    String gitDir,
    List<String> arguments, {
    String? input,
  }) async {
    if (input == null) {
      return Process.run('git', ['--git-dir=$gitDir', ...arguments]);
    }
    final process = await Process.start('git', [
      '--git-dir=$gitDir',
      ...arguments,
    ]);
    final out = process.stdout.drain<void>();
    final err = process.stderr.drain<void>();
    process.stdin.write(input);
    await process.stdin.close();
    final code = await process.exitCode;
    await Future.wait([out, err]);
    return ProcessResult(process.pid, code, '', '');
  }

  static Future<bool> _deleteRefs(String gitDir, Iterable<String> refs) async {
    if (refs.isEmpty) return true;
    final deleted = await _gitOn(gitDir, [
      'update-ref',
      '--stdin',
    ], input: refs.map((ref) => 'delete $ref\n').join());
    return deleted.exitCode == 0;
  }

  static Future<void> _tidyRepository(
    String gitDir,
    DateTime cutoff, {
    DateTime? since,
  }) async {
    final listed = await _gitOn(gitDir, [
      'for-each-ref',
      '--format=%(committerdate:unix) %(refname)',
      'refs/baocode/sessions/',
    ]);
    if (listed.exitCode != 0) return;
    final stale = <String>[];
    var kept = 0;
    for (final line in LineSplitter.split('${listed.stdout}')) {
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final saved = int.tryParse(line.substring(0, space));
      if (saved == null) continue;
      if (DateTime.fromMillisecondsSinceEpoch(saved * 1000).isBefore(cutoff)) {
        stale.add(line.substring(space + 1));
      } else {
        kept++;
      }
    }
    // Its index is written with each snapshot: one as old is of a project
    // no agent has worked in since (one at work may not have saved yet).
    final index = File(p.join(gitDir, 'index'));
    final used = await index.exists()
        ? await index.lastModified()
        : await Directory(gitDir).stat().then((stat) => stat.modified);
    if (kept == 0 && used.isBefore(cutoff) && !_opened.contains(gitDir)) {
      await Directory(gitDir).delete(recursive: true);
      return;
    }
    if (!await _deleteRefs(gitDir, stale)) return;
    if (stale.isEmpty && since != null && used.isBefore(since)) return;
    await _collect(gitDir, prune: '${_grace.inDays}.days.ago');
  }

  static Future<void> _clearRepository(String gitDir) async {
    final listed = await _gitOn(gitDir, [
      'for-each-ref',
      '--format=%(refname)',
      'refs/baocode/sessions/',
    ]);
    if (listed.exitCode != 0) return;
    final held = _sessions[gitDir] ?? const <String>{};
    final refs = [
      for (final ref in LineSplitter.split('${listed.stdout}'))
        if (ref.isNotEmpty && !held.contains(ref)) ref,
    ];
    if (!await _deleteRefs(gitDir, refs)) return;
    // What a conversation at work took within the hour stays.
    await _collect(gitDir, prune: '1.hour.ago');
  }

  /// Repacks [gitDir] without the objects nothing keeps from before
  /// [prune].
  static Future<void> _collect(String gitDir, {required String prune}) async {
    // Kept by an earlier build's sessions alone, the indexes of the
    // repositories inside the project may lose their files: those are
    // snapshotted whole again.
    final latest = await _gitOn(gitDir, [
      'rev-parse',
      '-q',
      '--verify',
      _latest,
    ]);
    if (latest.exitCode != 0) {
      try {
        await Directory(p.join(gitDir, 'nested')).delete(recursive: true);
      } on FileSystemException {
        // None.
      }
      _nested.remove(gitDir);
      _links.removeWhere((index, _) => p.isWithin(gitDir, index));
    }
    await _gitOn(gitDir, ['gc', '--quiet', '--prune=$prune']);
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

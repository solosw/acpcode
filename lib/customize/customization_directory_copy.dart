import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'customization_disk.dart';
import 'customization_store.dart';
import 'customizations.dart';

enum CustomizationCopyAction { create, update, unchanged, conflict, stale }

class CustomizationCopyEntry {
  const CustomizationCopyEntry._({
    required this.relativePath,
    required this.action,
    this.directory = false,
    this.reason = '',
    this._source,
    this._fingerprint,
    this._targetFingerprint,
  });

  final String relativePath;
  final CustomizationCopyAction action;
  final bool directory;
  final String reason;
  final String? _source;
  final String? _fingerprint;
  final String? _targetFingerprint;
}

/// A read-only preview, valid only while both sides remain unchanged.
class CustomizationCopyPlan {
  CustomizationCopyPlan._({
    required this._owner,
    required this.kind,
    required this.sourceRoot,
    required this.targetRoot,
    required this._typedTarget,
    required this.entries,
    required this._managed,
    required this._manifestFingerprint,
  });

  final CustomizationDirectoryCopy _owner;
  final CustomizationKind kind;
  final String sourceRoot;
  final String targetRoot;
  final String _typedTarget;
  final List<CustomizationCopyEntry> entries;
  final Map<String, String> _managed;
  final String? _manifestFingerprint;

  bool get hasConflicts =>
      entries.any((entry) => entry.action == CustomizationCopyAction.conflict);
  int count(CustomizationCopyAction action) =>
      entries.where((entry) => entry.action == action).length;
  bool get hasChanges =>
      count(CustomizationCopyAction.create) +
          count(CustomizationCopyAction.update) >
      0;

  String get _signature => jsonEncode([
    sourceRoot,
    targetRoot,
    _manifestFingerprint,
    for (final entry in entries)
      [
        entry.relativePath,
        entry.action.name,
        entry.directory,
        entry._source,
        entry._fingerprint,
        entry._targetFingerprint,
      ],
  ]);
}

/// Copies user-owned skills and rules on a single host. No shell expansion,
/// format conversion, deletion, or prompt injection is performed.
class CustomizationDirectoryCopy {
  CustomizationDirectoryCopy(this.store);

  final CustomizationStore store;
  static const manifestName = '.baocode-customizations.json';
  // Serialize previews' application, including different agents sharing a root.
  static Future<void> _pending = Future.value();

  CustomizationCopyDisk get _disk =>
      store.copyDisk ??
      (throw UnsupportedError('Directory copying is unavailable on this host'));

  Future<CustomizationCopyPlan> preview(
    CustomizationKind kind,
    String target,
  ) async {
    if (kind != CustomizationKind.skills && kind != CustomizationKind.rules) {
      throw ArgumentError('Only skills and rules can be copied');
    }
    final disk = _disk;
    final paths = disk.paths;
    var typed = target.trim();
    if (typed == '~' || typed.startsWith('~/') || typed.startsWith('~\\')) {
      final home = store.homeDir ?? await disk.homeDir();
      if (home == null) {
        throw StateError('The host has no known home directory');
      }
      typed = typed.length == 1 ? home : paths.join(home, typed.substring(2));
    }
    if (!paths.isAbsolute(typed) ||
        typed.codeUnits.any((unit) => unit == 0 || unit == 10 || unit == 13)) {
      throw ArgumentError(
        'Use an absolute directory or ~/ on the selected host',
      );
    }
    typed = paths.normalize(typed);
    final targetInfo = await disk.inspect(typed);
    if (targetInfo != null &&
        targetInfo.type != CustomizationFileType.directory) {
      throw StateError(
        'The target must be a directory, not a file or link: $typed',
      );
    }
    final config = await disk.resolveCopyPath(await store.config());
    final destination = await disk.resolveCopyPath(typed);
    if (paths.equals(config, destination) ||
        paths.isWithin(config, destination) ||
        paths.isWithin(destination, config)) {
      throw StateError('Source and target directories must not overlap');
    }
    final manifestPath = paths.join(destination, manifestName);
    await _checkTarget(destination, manifestPath);
    final manifestInfo = await disk.inspect(manifestPath);
    String? manifestFingerprint;
    final managed = <String, String>{};
    if (manifestInfo != null) {
      if (manifestInfo.type != CustomizationFileType.file) {
        throw StateError('The copy manifest is not a regular file');
      }
      final bytes = await disk.readCopyBytes(manifestPath);
      manifestFingerprint = _fingerprint(bytes, manifestInfo.executable);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map ||
          json['version'] != 1 ||
          json['source'] != config ||
          json['kind'] != kind.name ||
          json['files'] is! Map) {
        throw StateError('This target has an incompatible copy manifest');
      }
      for (final entry in (json['files'] as Map).entries) {
        if (entry.key is! String ||
            entry.value is! String ||
            !_safeRelative(entry.key as String)) {
          throw StateError('Invalid path in copy manifest');
        }
        managed[entry.key as String] = entry.value as String;
      }
    }

    final sources = <String, ({String path, bool directory})>{};
    void add(String relative, String source, bool directory) {
      if (!_safeRelative(relative) || sources.containsKey(relative)) {
        throw StateError('Duplicate or reserved copy path: $relative');
      }
      sources[relative] = (path: source, directory: directory);
    }

    Future<void> walk(String source, String relative, int depth) async {
      if (depth > 64) throw StateError('Customization directory is too deep');
      final info = await disk.inspect(source);
      if (info == null) throw StateError('Source disappeared: $source');
      switch (info.type) {
        case CustomizationFileType.file:
          add(relative, source, false);
        case CustomizationFileType.directory:
          if (relative.isNotEmpty) add(relative, source, true);
          final children = await disk.copyEntries(source)
            ..sort();
          for (final child in children) {
            await walk(
              child,
              paths.join(relative, paths.basename(child)),
              depth + 1,
            );
          }
        case CustomizationFileType.link:
        case CustomizationFileType.other:
          throw StateError('Links and special files cannot be copied: $source');
      }
    }

    final root = paths.join(config, kind.name);
    final rootInfo = await disk.inspect(root);
    if (rootInfo != null) {
      if (rootInfo.type != CustomizationFileType.directory) {
        throw StateError('Source is not a regular directory: $root');
      }
      if (kind == CustomizationKind.skills) {
        final children = await disk.copyEntries(root)
          ..sort();
        for (final child in children) {
          final name = paths.basename(child);
          if (name.startsWith('.') || name == 'synced') continue;
          final info = await disk.inspect(child);
          if (info?.type == CustomizationFileType.link) {
            throw StateError('Linked skills cannot be copied: $child');
          }
          if (info?.type != CustomizationFileType.directory) continue;
          final marker = await disk.inspect(paths.join(child, 'SKILL.md'));
          if (marker?.type == CustomizationFileType.link) {
            throw StateError('Linked skill markers cannot be copied: $child');
          }
          if (marker?.type == CustomizationFileType.file) {
            await walk(child, name, 0);
          }
        }
      } else {
        await walk(root, '', 0);
      }
    }
    if (kind == CustomizationKind.rules) {
      final memory = paths.join(config, 'CLAUDE.md');
      final memoryInfo = await disk.inspect(memory);
      if (memoryInfo != null) {
        if (memoryInfo.type != CustomizationFileType.file) {
          throw StateError('User CLAUDE.md is not a regular file: $memory');
        }
        await walk(memory, 'CLAUDE.md', 0);
      }
    }

    final entries = <CustomizationCopyEntry>[];
    final names = sources.keys.toList()..sort();
    for (final relative in names) {
      final source = sources[relative]!;
      final targetPath = paths.join(destination, relative);
      String? blocked;
      try {
        await _checkTarget(destination, targetPath);
      } on StateError catch (error) {
        blocked = error.message;
      }
      final info = blocked == null ? await disk.inspect(targetPath) : null;
      if (!paths.equals(await disk.resolveCopyPath(source.path), source.path)) {
        throw StateError('Source changed or contains a link: ${source.path}');
      }
      final sourceInfo = await disk.inspect(source.path);
      if (sourceInfo == null) {
        throw StateError('Source disappeared: ${source.path}');
      }
      final fingerprint = source.directory
          ? null
          : _fingerprint(
              await disk.readCopyBytes(source.path),
              sourceInfo.executable,
            );
      final targetFingerprint = info?.type == CustomizationFileType.file
          ? _fingerprint(await disk.readCopyBytes(targetPath), info!.executable)
          : info?.type.name;
      late CustomizationCopyAction action;
      var reason = blocked ?? '';
      if (blocked != null ||
          (info != null &&
              info.type !=
                  (source.directory
                      ? CustomizationFileType.directory
                      : CustomizationFileType.file))) {
        action = CustomizationCopyAction.conflict;
        if (reason.isEmpty) reason = 'The target has a different file type';
      } else if (info == null) {
        action = CustomizationCopyAction.create;
      } else if (source.directory) {
        action = CustomizationCopyAction.unchanged;
      } else if (managed[relative] == null) {
        action = CustomizationCopyAction.conflict;
        reason = 'An existing file is not managed by BaoCode';
      } else if (managed[relative] != targetFingerprint) {
        action = CustomizationCopyAction.conflict;
        reason = 'The copied file was modified outside BaoCode';
      } else {
        action = fingerprint == targetFingerprint
            ? CustomizationCopyAction.unchanged
            : CustomizationCopyAction.update;
      }
      entries.add(
        CustomizationCopyEntry._(
          relativePath: relative,
          action: action,
          directory: source.directory,
          reason: reason,
          source: source.path,
          fingerprint: fingerprint,
          targetFingerprint: targetFingerprint,
        ),
      );
    }
    for (final relative in managed.keys.toList()..sort()) {
      if (!sources.containsKey(relative)) {
        entries.add(
          CustomizationCopyEntry._(
            relativePath: relative,
            action: CustomizationCopyAction.stale,
            reason: 'Source removed; the target will be kept',
          ),
        );
      }
    }
    return CustomizationCopyPlan._(
      owner: this,
      kind: kind,
      sourceRoot: config,
      targetRoot: destination,
      typedTarget: typed,
      entries: List.unmodifiable(entries),
      managed: managed,
      manifestFingerprint: manifestFingerprint,
    );
  }

  bool _safeRelative(String relative) {
    final paths = _disk.paths;
    return relative.isNotEmpty &&
        !relative.codeUnits.any(
          (unit) => unit == 0 || unit == 10 || unit == 13,
        ) &&
        !paths.isAbsolute(relative) &&
        !paths.split(relative).any((part) => part == '..' || part == '.') &&
        paths.split(relative).first != manifestName &&
        paths.normalize(relative) == relative;
  }

  Future<void> _checkTarget(String root, String path) async {
    final disk = _disk;
    final paths = disk.paths;
    if (!paths.equals(root, path) && !paths.isWithin(root, path)) {
      throw StateError('Copy path escapes its target: $path');
    }
    if (!paths.equals(await disk.resolveCopyPath(root), root)) {
      throw StateError('Target directory changed or contains a link: $root');
    }
    var current = root;
    for (final component in [
      '',
      ...paths.split(paths.relative(path, from: root)),
    ]) {
      if (component != '' && component != '.') {
        current = paths.join(current, component);
      }
      final info = await disk.inspect(current);
      if (info == null) continue;
      if (info.type == CustomizationFileType.link ||
          info.type == CustomizationFileType.other ||
          (current != path && info.type != CustomizationFileType.directory)) {
        throw StateError('Unsafe target path: $current');
      }
    }
  }

  static String _fingerprint(List<int> bytes, bool executable) =>
      '${sha256.convert(bytes)}:${executable ? 1 : 0}';

  Future<void> apply(CustomizationCopyPlan plan) async {
    if (!identical(plan._owner, this)) {
      throw ArgumentError('Foreign copy preview');
    }
    final before = _pending;
    final done = Completer<void>();
    _pending = done.future;
    await before;
    try {
      if (plan.hasConflicts) {
        throw StateError('Resolve conflicts before copying');
      }
      final fresh = await preview(plan.kind, plan._typedTarget);
      if (fresh._signature != plan._signature) {
        throw StateError(
          'Files changed after preview; preview again before copying',
        );
      }
      if (!plan.hasChanges) return;
      final disk = _disk;
      final managed = {...plan._managed};
      final manifest = disk.paths.join(plan.targetRoot, manifestName);
      var manifestFingerprint = plan._manifestFingerprint;
      Future<void> checkpoint() async {
        await _checkTarget(plan.targetRoot, manifest);
        final info = await disk.inspect(manifest);
        final current = info == null
            ? null
            : _fingerprint(await disk.readCopyBytes(manifest), info.executable);
        if (current != manifestFingerprint) {
          throw StateError('Copy manifest changed; preview again');
        }
        final bytes = utf8.encode(
          const JsonEncoder.withIndent('  ').convert({
            'version': 1,
            'source': plan.sourceRoot,
            'kind': plan.kind.name,
            'files': managed,
          }),
        );
        await disk.writeCopyBytes(manifest, bytes, executable: false);
        manifestFingerprint = _fingerprint(bytes, false);
      }

      for (final entry in plan.entries) {
        if (entry.action != CustomizationCopyAction.create &&
            entry.action != CustomizationCopyAction.update) {
          continue;
        }
        final target = disk.paths.join(plan.targetRoot, entry.relativePath);
        await _checkTarget(plan.targetRoot, target);
        final info = await disk.inspect(target);
        final current = info?.type == CustomizationFileType.file
            ? _fingerprint(await disk.readCopyBytes(target), info!.executable)
            : info?.type.name;
        if (current != entry._targetFingerprint) {
          throw StateError('Target changed during copying: $target');
        }
        if (entry.directory) {
          await disk.createCopyDirectory(target);
          continue;
        }
        final source = entry._source!;
        if (!disk.paths.equals(await disk.resolveCopyPath(source), source)) {
          throw StateError('Source changed or contains a link: $source');
        }
        final sourceInfo = await disk.inspect(source);
        final bytes = await disk.readCopyBytes(source);
        if (sourceInfo?.type != CustomizationFileType.file ||
            _fingerprint(bytes, sourceInfo!.executable) != entry._fingerprint) {
          throw StateError('Source changed during copying: $source');
        }
        await disk.writeCopyBytes(
          target,
          bytes,
          executable: sourceInfo.executable,
        );
        managed[entry.relativePath] = entry._fingerprint!;
        await checkpoint();
      }
      // Also keep a manifest when the only new entries were empty folders.
      await checkpoint();
    } finally {
      done.complete();
    }
  }
}

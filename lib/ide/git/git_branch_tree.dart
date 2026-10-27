// The Git log's branch tree, as JetBrains IDEs have it beside their log:
// HEAD, then the local branches, the remote ones by remote, and the tags,
// each a tree by the branches' prefixes (`feature/…`), favorites first.
// Typed, it narrows to the branches that match, their folders open.

import 'package:flutter/foundation.dart';

import 'git_model.dart';

/// A group of the tree.
enum IdeGitBranchGroup { head, local, remote, tags }

/// One row of the tree: a group, a folder (a remote, a prefix) or a ref.
class IdeGitBranchRow {
  const IdeGitBranchRow({
    required this.key,
    required this.label,
    required this.depth,
    this.group,
    this.ref,
    this.expanded,
    this.favorite = false,
  });

  /// What it is kept by while folded: `local/feature` for a folder.
  final String key;
  final String label;
  final int depth;

  /// A group's header: its group.
  final IdeGitBranchGroup? group;

  /// A ref's row: its ref.
  final IdeGitRef? ref;

  /// A group's or a folder's: whether it is open; null for a ref.
  final bool? expanded;

  final bool favorite;
}

/// The keys of what is folded when nothing has been: the tags.
const ideGitBranchTreeFolded = {'tags'};

/// [refs]' tree as rows, HEAD's branch [current] first; [favorites] by
/// ref id, first in their folders; [folded] by key. With [filter], the
/// refs whose names have it (case ignored), with their folders all open.
List<IdeGitBranchRow> ideGitBranchRows(
  List<IdeGitRef> refs, {
  String? current,
  Set<String> favorites = const {},
  Set<String> folded = ideGitBranchTreeFolded,
  String filter = '',
}) {
  final needle = filter.trim().toLowerCase();
  bool matches(IdeGitRef ref) =>
      needle.isEmpty || ref.name.toLowerCase().contains(needle);
  final rows = <IdeGitBranchRow>[];
  bool open(String key) => needle.isNotEmpty || !folded.contains(key);

  IdeGitRef? head;
  for (final ref in refs) {
    if (ref.kind == IdeGitRefKind.branch && ref.name == current) head = ref;
  }
  if (head != null && matches(head)) {
    rows.add(
      IdeGitBranchRow(
        key: 'head',
        label: 'HEAD',
        depth: 0,
        group: IdeGitBranchGroup.head,
        expanded: open('head'),
      ),
    );
    if (open('head')) {
      rows.add(
        IdeGitBranchRow(
          key: 'head/${head.id}',
          label: head.name,
          depth: 1,
          ref: head,
          favorite: favorites.contains(head.id),
        ),
      );
    }
  }

  /// [entries] (a ref and its name past the folders above) under [key],
  /// at [depth]: folders, then refs, each by name; favorites first.
  void tree(String key, List<(String, IdeGitRef)> entries, int depth) {
    final folders = <String, List<(String, IdeGitRef)>>{};
    final leaves = <(String, IdeGitRef)>[];
    for (final (name, ref) in entries) {
      final slash = name.indexOf('/');
      if (slash > 0 && slash < name.length - 1) {
        (folders[name.substring(0, slash)] ??= []).add((
          name.substring(slash + 1),
          ref,
        ));
      } else {
        leaves.add((name, ref));
      }
    }
    int byName(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    for (final folder in folders.keys.toList()..sort(byName)) {
      final folderKey = '$key/$folder';
      rows.add(
        IdeGitBranchRow(
          key: folderKey,
          label: folder,
          depth: depth,
          expanded: open(folderKey),
        ),
      );
      if (open(folderKey)) tree(folderKey, folders[folder]!, depth + 1);
    }
    leaves.sort((a, b) {
      final favorite =
          (favorites.contains(a.$2.id) ? 0 : 1) -
          (favorites.contains(b.$2.id) ? 0 : 1);
      return favorite != 0 ? favorite : byName(a.$1, b.$1);
    });
    for (final (name, ref) in leaves) {
      rows.add(
        IdeGitBranchRow(
          key: '$key/${ref.id}',
          label: name,
          depth: depth,
          ref: ref,
          favorite: favorites.contains(ref.id),
        ),
      );
    }
  }

  void group(
    IdeGitBranchGroup group,
    String key,
    List<(String, IdeGitRef)> entries,
    void Function() children,
  ) {
    if (entries.isEmpty) return;
    rows.add(
      IdeGitBranchRow(
        key: key,
        label: key,
        depth: 0,
        group: group,
        expanded: open(key),
      ),
    );
    if (open(key)) children();
  }

  final local = [
    for (final ref in refs)
      if (ref.kind == IdeGitRefKind.branch && matches(ref)) (ref.name, ref),
  ];
  group(IdeGitBranchGroup.local, 'local', local, () => tree('local', local, 1));

  final remotes = <String, List<(String, IdeGitRef)>>{};
  for (final ref in refs) {
    if (ref.kind != IdeGitRefKind.remote || !matches(ref)) continue;
    final remote = ref.remote ?? ref.name.split('/').first;
    final name = ref.name.startsWith('$remote/')
        ? ref.name.substring(remote.length + 1)
        : ref.name;
    if (name == 'HEAD') continue;
    (remotes[remote] ??= []).add((name, ref));
  }
  group(
    IdeGitBranchGroup.remote,
    'remote',
    [for (final entries in remotes.values) ...entries],
    () {
      final names = remotes.keys.toList()..sort();
      for (final remote in names) {
        final key = 'remote/$remote';
        rows.add(
          IdeGitBranchRow(
            key: key,
            label: remote,
            depth: 1,
            expanded: open(key),
          ),
        );
        if (open(key)) tree(key, remotes[remote]!, 2);
      }
    },
  );

  final tags = [
    for (final ref in refs)
      if (ref.kind == IdeGitRefKind.tag && matches(ref)) (ref.name, ref),
  ];
  group(IdeGitBranchGroup.tags, 'tags', tags, () => tree('tags', tags, 1));
  return rows;
}

/// The favorite refs (ids) of each repository, by its folder; the window
/// keeps them with its state ([toJson]).
class IdeGitFavoriteBranches extends ChangeNotifier {
  IdeGitFavoriteBranches([Map<String, Set<String>>? favorites])
    : _favorites = favorites ?? {};

  /// Read from [toJson]'s.
  factory IdeGitFavoriteBranches.fromJson(Object? json) =>
      IdeGitFavoriteBranches({
        if (json is Map)
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is List)
              key: {...value.whereType<String>()},
      });

  final Map<String, Set<String>> _favorites;

  /// [root]'s favorites.
  Set<String> of(String root) => _favorites[root] ?? const {};

  void toggle(String root, String ref) {
    final favorites = _favorites[root] ??= {};
    if (!favorites.remove(ref)) favorites.add(ref);
    if (favorites.isEmpty) _favorites.remove(root);
    notifyListeners();
  }

  bool get isEmpty => _favorites.isEmpty;

  /// [other]'s favorites in place of these.
  void restore(IdeGitFavoriteBranches other) {
    _favorites
      ..clear()
      ..addAll({
        for (final MapEntry(:key, :value) in other._favorites.entries)
          key: {...value},
      });
    notifyListeners();
  }

  Map<String, List<String>> toJson() => {
    for (final MapEntry(:key, :value) in _favorites.entries)
      key: value.toList()..sort(),
  };
}

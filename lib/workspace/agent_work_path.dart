// Where a conversation's agent works: the file it last edited, or the
// folder it last moved into (`cd <path> && …`). Matched against a
// repository's worktrees (see `ideWorktreeOf`), it tells which one the
// agent works in, and so which branch: the side panel's changes and the
// branch under the composer show that one, not the project's own checkout.

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_feed.dart';
import '../chat/chat_models.dart';
import '../ide/git/git_model.dart';

/// How far back a conversation is looked through: the newest items say
/// where the agent is now.
const _lookBack = 400;

/// The path [feed]'s agent last worked at, newest first; null while it
/// has edited nothing and moved nowhere.
String? agentWorkPathOf(ChatFeed feed) {
  final count = feed.itemCount;
  for (
    var index = count - 1;
    index >= 0 && index >= count - _lookBack;
    index--
  ) {
    if (_pathOf(feed.itemAt(index)) case final path?) return path;
  }
  return null;
}

String? _pathOf(ChatItem item) => switch (item) {
  ToolCallItem(kind: ToolKind.edit, :final path?) when _absolute(path) => path,
  CodeDiffItem(:final path) when _absolute(path) => path,
  TerminalItem(:final command) => agentCdTarget(command),
  _ => null,
};

final _cd = RegExp(
  r'''^\s*cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))\s*(?:&&|;|$)''',
);

/// The folder [command] starts by moving into (`cd /x && …`), when it is
/// an absolute one.
@visibleForTesting
String? agentCdTarget(String command) {
  final match = _cd.firstMatch(command);
  if (match == null) return null;
  final target = match.group(1) ?? match.group(2) ?? match.group(3)!;
  return _absolute(target) ? target : null;
}

/// `/x`, `C:\x`, `C:/x` or `\\server\x`.
bool _absolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// [feed]'s agent's [path] ([agentWorkPathOf]), told when it changes: not
/// on each word of a reply, only when it moves.
class AgentWorkPath extends ChangeNotifier {
  AgentWorkPath(this.feed) {
    feed.addListener(_changed);
    _changed();
  }

  final ChatFeed feed;

  String? get path => _path;
  String? _path;

  /// The items last looked through: their count and the newest.
  int _count = -1;
  ChatItem? _last;

  void _changed() {
    final count = feed.itemCount;
    final last = count == 0 ? null : feed.itemAt(count - 1);
    if (count == _count && identical(last, _last)) return;
    _count = count;
    _last = last;
    final path = agentWorkPathOf(feed);
    if (path == _path) return;
    _path = path;
    notifyListeners();
  }

  @override
  void dispose() {
    feed.removeListener(_changed);
    super.dispose();
  }
}

/// The worktree a conversation shows of the repository at [root], of its
/// [worktrees]: the one [chosen] on its changes page, else the one its
/// agent works in ([agentPath]); null for the repository's own.
String? agentShownWorktree({
  required String root,
  required List<IdeGitWorktree> worktrees,
  required p.Context paths,
  String? chosen,
  String? agentPath,
}) {
  final target =
      chosen ??
      switch (agentPath) {
        final path? => ideWorktreeOf(path, worktrees, paths)?.path,
        null => null,
      };
  return target == null || paths.equals(target, root) ? null : target;
}

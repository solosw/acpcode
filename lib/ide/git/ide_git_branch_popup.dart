// JetBrains IDEs' branch popup, which their status bar's branch opens: a
// search over the repository's actions (Update Project, Commit, Push, New
// Branch, Checkout Tag or Revision) and its branches, the recent ones
// first, then the local and the remote ones, favorites first in each. A
// branch opens its actions (see git_branch_actions.dart); typed, the list
// narrows to what matches, tags too.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../ide_hover.dart';
import '../ide_input.dart';
import '../ide_list.dart';
import '../ide_menu.dart';
import 'git_branch_actions.dart';
import 'git_model.dart';
import 'git_repository.dart';

/// One of the popup's actions above the branches.
class IdeGitBranchPopupAction {
  const IdeGitBranchPopupAction(
    this.label,
    this.run, {
    this.icon,
    this.keybinding,
  });

  final String label;
  final VoidCallback run;
  final IconData? icon;
  final String? keybinding;
}

/// Shows [git]'s branch popup by [anchor] (above it near the window's
/// bottom, below it elsewhere): [actions], then the branches, whose
/// actions [host] shows from [context].
Future<void> showIdeGitBranchPopup(
  BuildContext context, {
  required IdeGitRepository git,
  required Rect anchor,
  required IdeGitBranchHost host,
  List<IdeGitBranchPopupAction> actions = const [],
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final origin = Rect.fromPoints(
    overlay.globalToLocal(anchor.topLeft),
    overlay.globalToLocal(anchor.bottomRight),
  );
  final branchActions = IdeGitBranchActions(context, git, host);
  return navigator.push(
    _BranchPopupRoute(
      origin: origin,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: context.l10n.commonDismiss,
      builder: (close) => IdeGitBranchPopup(
        git: git,
        actions: actions,
        branchActions: branchActions,
        onClose: close,
      ),
    ),
  );
}

class _BranchPopupRoute extends PopupRoute<void> {
  _BranchPopupRoute({
    required this.origin,
    required this.capturedThemes,
    required this.barrierLabel,
    required this.builder,
  });

  final Rect origin;
  final CapturedThemes capturedThemes;
  final Widget Function(VoidCallback close) builder;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  final String barrierLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 83);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    void close() {
      if (isCurrent) Navigator.of(context).pop();
    }

    return capturedThemes.wrap(
      FadeTransition(
        opacity: animation,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const margin = 8.0;
            final width = (constraints.maxWidth - 2 * margin).clamp(
              0.0,
              IdeGitBranchPopup.width,
            );
            final below = constraints.maxHeight - origin.bottom - margin;
            final above = origin.top - margin;
            final up = below < 320 && above > below;
            final height = (up ? above : below).clamp(
              0.0,
              IdeGitBranchPopup.maxHeight,
            );
            final left = origin.left.clamp(
              margin,
              constraints.maxWidth - margin - width,
            );
            return Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  top: up ? null : origin.bottom + 2,
                  bottom: up ? constraints.maxHeight - origin.top + 2 : null,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height),
                    child: builder(close),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The popup's rows: a section's header, an action, or a ref.
sealed class _Item {
  const _Item();
}

class _Header extends _Item {
  const _Header(this.label);
  final String label;
}

class _Action extends _Item {
  const _Action(this.action);
  final IdeGitBranchPopupAction action;
}

class _Ref extends _Item {
  const _Ref(this.ref, {this.recent = false});
  final IdeGitRef ref;
  final bool recent;
}

/// The popup itself: what [showIdeGitBranchPopup] shows.
class IdeGitBranchPopup extends StatefulWidget {
  const IdeGitBranchPopup({
    super.key,
    required this.git,
    required this.branchActions,
    required this.onClose,
    this.actions = const [],
  });

  static const width = 380.0;
  static const maxHeight = 520.0;
  static const rowHeight = 24.0;

  final IdeGitRepository git;
  final List<IdeGitBranchPopupAction> actions;
  final IdeGitBranchActions branchActions;
  final VoidCallback onClose;

  @override
  State<IdeGitBranchPopup> createState() => _IdeGitBranchPopupState();
}

class _IdeGitBranchPopupState extends State<IdeGitBranchPopup> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'branch popup');
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};

  List<IdeGitRef>? _refs;
  List<String> _recent = const [];
  int _active = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    final git = widget.git;
    List<IdeGitRef> refs;
    try {
      refs = await git.refs();
    } catch (_) {
      refs = const [];
    }
    final recent = await git.service.recentBranches().catchError(
      (Object _) => const <String>[],
    );
    if (!mounted) return;
    setState(() {
      _refs = refs;
      _recent = recent;
      _active = _firstSelectable(_items());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Set<String> get _favorites =>
      widget.branchActions.host.favoriteBranches.of(widget.git.service.root);

  List<_Item> _items() {
    final l10n = context.l10n;
    final needle = _search.text.trim().toLowerCase();
    bool matches(String text) =>
        needle.isEmpty || text.toLowerCase().contains(needle);
    final refs = _refs ?? const <IdeGitRef>[];
    final current = widget.git.state?.head.branch;
    final favorites = _favorites;
    List<IdeGitRef> sorted(Iterable<IdeGitRef> refs) => refs.toList()
      ..sort((a, b) {
        final favorite =
            (favorites.contains(a.id) ? 0 : 1) -
            (favorites.contains(b.id) ? 0 : 1);
        if (favorite != 0) return favorite;
        // The current branch first among the rest.
        final head = (a.name == current ? 0 : 1) - (b.name == current ? 0 : 1);
        if (head != 0) return head;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final local = {
      for (final ref in refs)
        if (ref.kind == IdeGitRefKind.branch) ref.name: ref,
    };
    final recent = [
      for (final name in _recent)
        if (name != current && matches(name)) ?local[name],
    ].take(5).toList();
    final locals = sorted(local.values.where((ref) => matches(ref.name)));
    final remotes = sorted(
      refs.where(
        (ref) =>
            ref.kind == IdeGitRefKind.remote &&
            !ref.name.endsWith('/HEAD') &&
            matches(ref.name),
      ),
    );
    final tags = needle.isEmpty
        ? const <IdeGitRef>[]
        : sorted(
            refs.where(
              (ref) => ref.kind == IdeGitRefKind.tag && matches(ref.name),
            ),
          );
    return [
      for (final action in widget.actions)
        if (matches(action.label)) _Action(action),
      if (recent.isNotEmpty) ...[
        _Header(l10n.gitBranchesRecent),
        for (final ref in recent) _Ref(ref, recent: true),
      ],
      if (locals.isNotEmpty) ...[
        _Header(l10n.gitLogLocalBranches),
        for (final ref in locals) _Ref(ref),
      ],
      if (remotes.isNotEmpty) ...[
        _Header(l10n.gitLogRemoteBranches),
        for (final ref in remotes) _Ref(ref),
      ],
      if (tags.isNotEmpty) ...[
        _Header(l10n.gitLogTags),
        for (final ref in tags) _Ref(ref),
      ],
    ];
  }

  static int _firstSelectable(List<_Item> items) {
    final index = items.indexWhere((item) => item is! _Header);
    return index < 0 ? 0 : index;
  }

  void _move(List<_Item> items, int delta) {
    if (items.isEmpty) return;
    var index = _active;
    for (var i = 0; i < items.length; i++) {
      index = (index + delta) % items.length;
      if (index < 0) index += items.length;
      if (items[index] is! _Header) break;
    }
    setState(() => _active = index);
    _reveal(index);
  }

  void _reveal(int index) {
    final top = index * IdeGitBranchPopup.rowHeight;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (top < position.pixels) {
      _scroll.jumpTo(top);
    } else if (top + IdeGitBranchPopup.rowHeight >
        position.pixels + position.viewportDimension) {
      _scroll.jumpTo(
        top + IdeGitBranchPopup.rowHeight - position.viewportDimension,
      );
    }
  }

  /// [item] chosen: an action run, the popup closed; a ref's actions
  /// opened beside its row.
  void _choose(List<_Item> items, int index) {
    if (index < 0 || index >= items.length) return;
    switch (items[index]) {
      case _Header():
        return;
      case _Action(:final action):
        widget.onClose();
        action.run();
      case _Ref(:final ref):
        setState(() => _active = index);
        unawaited(_openRef(index, ref));
    }
  }

  Future<void> _openRef(int index, IdeGitRef ref) async {
    final box =
        _rowKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final entries = _closing(widget.branchActions.menu(ref, _refs ?? const []));
    await showIdeMenu(
      context,
      anchor: rect == null
          ? null
          : Rect.fromLTWH(rect.right - 4, rect.top, 0, rect.height),
      position: rect == null ? Offset.zero : null,
      entries: entries,
    );
    if (mounted) _focus.requestFocus();
  }

  /// [entries], each closing the popup before it runs.
  List<IdeMenuEntry> _closing(List<IdeMenuEntry> entries) => [
    for (final entry in entries)
      switch (entry) {
        IdeMenuAction(:final submenu?) => IdeMenuAction(
          entry.label,
          icon: entry.icon,
          keybinding: entry.keybinding,
          enabled: entry.enabled,
          checked: entry.checked,
          submenu: _closing(submenu),
        ),
        IdeMenuAction(:final onSelected?) when !entry.keepOpen => IdeMenuAction(
          entry.label,
          icon: entry.icon,
          keybinding: entry.keybinding,
          enabled: entry.enabled,
          checked: entry.checked,
          onSelected: () {
            widget.onClose();
            onSelected();
          },
        ),
        _ => entry,
      },
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items();
    if (_active >= items.length) _active = _firstSelectable(items);
    return Container(
      decoration: BoxDecoration(
        color: IdeMenuColors.background,
        border: Border.all(color: IdeMenuColors.border),
        borderRadius: BorderRadius.circular(8),
        boxShadow: themeColors.highContrast ? null : IdeHoverColors.shadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 13,
              color: IdeMenuColors.foreground,
              decoration: TextDecoration.none,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: IdeInputBox(
                    controller: _search,
                    focusNode: _focus,
                    autofocus: true,
                    placeholder: l10n.gitBranchesSearch,
                    onChanged: (_) => setState(() {
                      _active = _firstSelectable(_items());
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                    }),
                    shortcuts: {
                      const SingleActivator(LogicalKeyboardKey.enter): () =>
                          _choose(items, _active),
                      const SingleActivator(
                        LogicalKeyboardKey.numpadEnter,
                      ): () =>
                          _choose(items, _active),
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                          _move(items, 1),
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                          _move(items, -1),
                      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
                        if (items.elementAtOrNull(_active) is _Ref) {
                          _choose(items, _active);
                        }
                      },
                      const SingleActivator(LogicalKeyboardKey.escape):
                          widget.onClose,
                    },
                  ),
                ),
                if (_refs == null)
                  const SizedBox(height: 8)
                else
                  Flexible(
                    child: ListView.builder(
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 4),
                      itemExtent: IdeGitBranchPopup.rowHeight,
                      itemCount: items.length,
                      itemBuilder: (context, index) =>
                          _row(items, index, items[index]),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(List<_Item> items, int index, _Item item) {
    final key = _rowKeys[index] ??= GlobalKey();
    if (item is _Header) {
      return Padding(
        key: key,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        child: Text(
          item.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: IdeListColors.description,
          ),
        ),
      );
    }
    final active = index == _active;
    final current = widget.git.state?.head.branch;
    final Widget content;
    switch (item) {
      case _Action(:final action):
        content = Row(
          children: [
            SizedBox(
              width: 20,
              child: action.icon == null
                  ? null
                  : Icon(
                      action.icon,
                      size: 14,
                      color: IdeMenuColors.foreground,
                    ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (action.keybinding case final keys?)
              Text(
                keys,
                style: TextStyle(
                  fontSize: 12,
                  color: IdeListColors.description,
                ),
              ),
          ],
        );
      case _Ref(:final ref):
        final isCurrent =
            ref.kind == IdeGitRefKind.branch && ref.name == current;
        final favorite = _favorites.contains(ref.id);
        final track = [
          if ((ref.ahead ?? 0) > 0) '↑${ref.ahead}',
          if ((ref.behind ?? 0) > 0) '↓${ref.behind}',
        ].join(' ');
        content = Row(
          children: [
            SizedBox(
              width: 20,
              child: Icon(
                favorite
                    ? Codicons.starFull
                    : ref.kind == IdeGitRefKind.tag
                    ? Codicons.tag
                    : Codicons.gitBranch,
                size: 14,
                color: favorite
                    ? themeColors.get('charts.yellow') ??
                          IdeMenuColors.foreground
                    : isCurrent
                    ? themeColors['gitDecoration.addedResourceForeground']
                    : IdeListColors.description,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ref.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (track.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                track,
                style: TextStyle(
                  fontSize: 12,
                  color: IdeListColors.description,
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(
              Codicons.chevronRight,
              size: 14,
              color: IdeListColors.description,
            ),
          ],
        );
      case _Header():
        content = const SizedBox.shrink();
    }
    return MouseRegion(
      key: key,
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (_active != index) setState(() => _active = index);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _choose(items, index),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: active ? IdeMenuColors.selectionBackground : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: content,
        ),
      ),
    );
  }
}

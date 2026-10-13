import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show SliverConstraints, SliverGridLayout, SliverGridRegularTileLayout;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../chat/composer/composer_files.dart';
import '../chat/widgets/hover_builder.dart';
import '../ide/file_views.dart';
import '../ide/ide_button.dart';
import '../ide/ide_dialog.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_menu.dart';
import '../ide/ide_modern_ui.dart';
import '../ide/ide_quick_input.dart' show IdeKeycap;
import '../ide/ide_spinning.dart';
import '../l10n/l10n.dart';
import '../models/auxiliary_model_menu.dart';
import '../models/model_providers.dart';
import '../platform/app_platform.dart';
import '../sidebar/sidebar.dart' show SidebarIconButton;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/title_bar_double_click.dart';
import '../workspace/window_controls.dart';
import '../workspace/workspace.dart';
import 'stash_actions.dart';
import 'stash_ai.dart';
import 'stash_controller.dart';
import 'stash_editor.dart' show StashRefs, isRemoteStashPicture;
import 'stash_io_stub.dart' if (dart.library.io) 'stash_io.dart' as io;
import 'stash_note.dart';
import 'stash_note_editor.dart';
import 'stash_settings.dart';

/// The stashes, in place of the conversations (see docs/stash.md): cards
/// by when they were written, the newest first, those done last and faded;
/// searched by their words (and the text in their pictures), or by what
/// they mean (AI, when asked: it costs); filtered by time, project and
/// status. Picked, one shows beside them to be read and edited, made a
/// requirement and carried out in a conversation.
class StashView extends StatefulWidget {
  const StashView({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onOpenAgent,
    this.leading,
    this.titleBarInset = 12,
    this.initial,
    this.onHotkeySettings,
  });

  final StashController controller;
  final VoidCallback onClose;

  /// Settings → Stash, where its shortcut is changed: the title bar shows
  /// the shortcut, a click away from it.
  final VoidCallback? onHotkeySettings;

  /// Shows [thread] (a stash carried out in it, or about to be).
  final ValueChanged<AgentThread> onOpenAgent;

  /// Before the title, by the traffic lights: the sidebar's toggle.
  final Widget? leading;
  final double titleBarInset;

  /// The stash shown first.
  final int? initial;

  @override
  State<StashView> createState() => StashViewState();
}

enum _Time { all, today, week, month }

enum _Status { all, open, collected, requirement, implementing, done }

class StashViewState extends State<StashView> with _StashActions {
  final TextEditingController _query = TextEditingController();

  @override
  StashController get _controller => widget.controller;

  /// The one shown beside the cards.
  int? _open;

  /// Those picked with ⌘ (Ctrl), for what is done to several at once.
  final Set<int> _picked = {};

  _Time _time = _Time.all;

  /// A project's path, '' for none; null for all.
  String? _project;
  _Status _status = _Status.all;

  /// The AI's answer to the query: the stashes by what they mean.
  List<int>? _aiResults;
  String? _aiQuery;
  bool _aiSearching = false;

  /// Why the AI found nothing for [_aiQuery], when it could not answer.
  String? _aiError;

  /// The width of the stash shown beside the cards, as dragged; null for
  /// its own.
  late double? _detailWidth = _controller.detailWidth;

  /// Where a drag of the line between the cards and the stash began.
  ({double x, double width})? _dragStart;

  @override
  void initState() {
    super.initState();
    _open = widget.initial;
    _query.addListener(() => setState(() {}));
    _controller.addListener(_changed);
    _controller.store.addListener(_changed);
    unawaited(_controller.store.load());
    unawaited(_controller.suggestMerges());
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.store.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Shows [id]'s stash.
  void show(int id) => setState(() {
    _open = _controller.store.byId(id)?.id;
    _picked.clear();
  });

  // --- What shows ---------------------------------------------------------------

  List<StashNote> get _filtered {
    final store = _controller.store;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    bool timeOk(StashNote note) => switch (_time) {
      _Time.all => true,
      _Time.today => !note.updated.isBefore(today),
      _Time.week => now.difference(note.updated) < const Duration(days: 7),
      _Time.month => now.difference(note.updated) < const Duration(days: 30),
    };
    bool statusOk(StashNote note) => switch (_status) {
      _Status.all => true,
      _Status.open => note.status != StashStatus.done,
      _Status.collected => note.status == StashStatus.collected,
      _Status.requirement => note.status == StashStatus.requirement,
      _Status.implementing => note.status == StashStatus.implementing,
      _Status.done => note.status == StashStatus.done,
    };
    bool projectOk(StashNote note) => switch (_project) {
      null => true,
      '' => note.project == null,
      final project => note.project == project,
    };
    final among = store.notes.where(
      (note) =>
          !note.isBlank && timeOk(note) && statusOk(note) && projectOk(note),
    );
    final ai = _aiResults;
    if (ai != null && _aiQuery == _query.text.trim()) {
      final byId = {for (final note in among) note.id: note};
      return [for (final id in ai) ?byId[id]];
    }
    return store.search(_query.text, among: among);
  }

  bool get _searching => _query.text.trim().isNotEmpty;

  /// [notes] under their headings: pinned first, then by when they were
  /// last written, those done at the end.
  List<(String, List<StashNote>)> _grouped(
    List<StashNote> notes,
    AppLocalizations l10n,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final groups = <String, List<StashNote>>{};
    final pinned = <StashNote>[];
    final done = <StashNote>[];
    final sorted = [...notes]..sort((a, b) => b.updated.compareTo(a.updated));
    for (final note in sorted) {
      if (note.pinned) {
        pinned.add(note);
        continue;
      }
      if (note.status == StashStatus.done) {
        done.add(note);
        continue;
      }
      final at = note.updated;
      final heading = !at.isBefore(today)
          ? l10n.stashGroupToday
          : !at.isBefore(yesterday)
          ? l10n.stashGroupYesterday
          : now.difference(at) < const Duration(days: 7)
          ? l10n.stashGroupWeek
          : now.difference(at) < const Duration(days: 30)
          ? l10n.stashGroupMonth
          : l10n.stashGroupEarlier;
      (groups[heading] ??= []).add(note);
    }
    return [
      if (pinned.isNotEmpty) (l10n.stashGroupPinned, pinned),
      for (final MapEntry(:key, :value) in groups.entries) (key, value),
      if (done.isNotEmpty) (l10n.stashGroupDone, done),
    ];
  }

  // --- Doing --------------------------------------------------------------------

  Future<void> _aiSearch() async {
    final query = _query.text.trim();
    if (query.isEmpty || _aiSearching) return;
    setState(() => _aiSearching = true);
    final l10n = context.l10n;
    final store = _controller.store;
    List<int> results;
    String? error;
    try {
      results = await searchStashes(
        query,
        store.notes.where((note) => !note.isBlank).toList(),
        extra: (note) => [
          for (final image in note.images)
            ?store.pictureText[store.absolute(image)],
        ].join('\n'),
      );
    } on StashAiException catch (failure) {
      results = const [];
      error = failure.message ?? l10n.stashAiNoAnswer;
    }
    if (!mounted) return;
    setState(() {
      _aiSearching = false;
      _aiResults = results;
      _aiError = error;
      _aiQuery = query;
    });
  }

  void _tap(StashNote note) {
    final keyboard = HardwareKeyboard.instance;
    final toggle = AppPlatform.isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    setState(() {
      if (toggle) {
        // The one open is among those picked.
        if (_picked.isEmpty && _open != null) _picked.add(_open!);
        if (!_picked.remove(note.id)) _picked.add(note.id);
        if (_picked.length == 1) {
          _open = _picked.single;
          _picked.clear();
        }
      } else {
        _picked.clear();
        _open = _open == note.id ? null : note.id;
      }
    });
  }

  @override
  List<int> _idsFor(StashNote note) =>
      _picked.contains(note.id) ? [..._picked] : [note.id];

  @override
  void _deleted(List<int> ids) => setState(() {
    _picked.removeAll(ids);
    if (ids.contains(_open)) _open = null;
  });

  @override
  Future<void> _merge(List<int> ids) async {
    final l10n = context.l10n;
    final sorted = [...ids]..sort();
    final choice = await showIdeDialog(
      context,
      message: l10n.stashMergeTitle(sorted.map((id) => '#$id').join(', ')),
      detail: l10n.stashMergeDetail('#${sorted.first}'),
      buttons: [l10n.stashMerge],
      type: IdeDialogType.question,
    );
    if (choice != 0) return;
    final kept = await _controller.store.merge(sorted);
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _open = kept?.id;
    });
  }

  void _openLink(String href) {
    if (StashRefs.stashOf(href) case final id?) {
      show(id);
    } else if (StashRefs.projectOf(href) case final project?) {
      setState(() => _project = project);
    }
  }

  // --- Building -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final open = _open == null ? null : _controller.store.byId(_open!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTitleBar(l10n),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final room = constraints.maxWidth;
              final wide = room >= 760;
              final list = _buildList(l10n);
              if (open == null) return list;
              final detail = StashDetail(
                controller: _controller,
                id: open.id,
                onOpenAgent: widget.onOpenAgent,
                onOpenLink: _openLink,
                onClose: () => setState(() => _open = null),
              );
              if (!wide) return detail;
              final width = _widthOfDetail(room);
              final dragging = _dragStart != null;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: list),
                      _sash(room, dragging: dragging),
                      SizedBox(width: width, child: detail),
                    ],
                  ),
                  // The resize cursor wherever the pointer goes while
                  // dragging; a press there (a drag whose end was lost)
                  // ends it.
                  if (dragging)
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) => _endDrag(),
                        child: const MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// The least the cards keep beside the stash shown, and the least it is.
  static const _minList = 320.0;
  static const _minDetail = 380.0;

  /// The stash's width beside the cards in [room]: as dragged, else about
  /// half; the cards keep [_minList].
  double _widthOfDetail(double room) {
    final most = math.max(_minDetail, room - _minList - _sashWidth);
    final width = _detailWidth ?? (room * .48).clamp(_minDetail, 720.0);
    return width.clamp(_minDetail, most);
  }

  /// The strip between the cards and the stash that takes the drag, as the
  /// side panel's edge: its line at rest, as thick as the IDE's sashes
  /// while dragged. A double click puts it back where it was at first.
  static const _sashWidth = 5.0;

  Widget _sash(double room, {required bool dragging}) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      key: const ValueKey('stash-sash'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (details) => setState(
        () => _dragStart = (
          x: details.globalPosition.dx,
          width: _widthOfDetail(room),
        ),
      ),
      onHorizontalDragUpdate: (details) {
        final start = _dragStart;
        if (start == null) return;
        setState(
          () => _detailWidth = math.max(
            _minDetail,
            start.width - (details.globalPosition.dx - start.x),
          ),
        );
      },
      onHorizontalDragEnd: (_) => _endDrag(),
      onHorizontalDragCancel: _endDrag,
      onDoubleTap: () {
        setState(() => _detailWidth = null);
        _controller.detailWidth = null;
      },
      child: Container(
        width: _sashWidth,
        alignment: Alignment.centerRight,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: dragging ? IdeModernUI.gap : 1,
          color: dragging ? IdeModernUI.sashHover : AppColors.partBorder,
        ),
      ),
    ),
  );

  void _endDrag() {
    if (!mounted || _dragStart == null) return;
    setState(() => _dragStart = null);
    _controller.detailWidth = _detailWidth;
  }

  Widget _buildTitleBar(AppLocalizations l10n) {
    final store = _controller.store;
    final count = store.notes.where((note) => !note.isBlank).length;
    return TitleBarDoubleClick(
      child: SizedBox(
        height: AppMetrics.titleBarHeight,
        child: Row(
          children: [
            SizedBox(width: widget.leading == null ? widget.titleBarInset : 0),
            if (widget.leading case final leading?) ...[
              SizedBox(width: widget.titleBarInset - 34),
              leading,
              const SizedBox(width: 10),
            ],
            Text(
              l10n.stashTitle,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(color: AppColors.textFaint, fontSize: 12),
            ),
            const Spacer(),
            if (widget.onHotkeySettings case final onTap?) ...[
              IdeHover(
                message: l10n.stashHotkeyTooltip,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onTap,
                    child: _hotkeyLabel().isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(5),
                            child: Icon(
                              Codicons.keyboard,
                              size: 16,
                              color: AppColors.textMuted,
                            ),
                          )
                        : IdeKeycap(_hotkeyLabel()),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            SidebarIconButton(
              icon: Codicons.add,
              tooltip: l10n.stashNewTooltip,
              onTap: () => unawaited(_controller.present()),
            ),
            SidebarIconButton(
              icon: Codicons.folderOpened,
              tooltip: l10n.stashReveal,
              onTap: () => unawaited(openExternal(store.root)),
            ),
            SidebarIconButton(
              icon: Codicons.close,
              tooltip: l10n.stashClose,
              onTap: widget.onClose,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildList(AppLocalizations l10n) {
    final notes = _filtered;
    final ai = _aiResults != null && _aiQuery == _query.text.trim();
    final merges = _controller.mergeSuggestions;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          sliver: SliverList.list(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _SearchField(controller: _query, onSubmit: () {}),
                  ),
                  if (_searching) ...[
                    const SizedBox(width: 8),
                    Builder(
                      builder: (context) => IdeHover(
                        message: l10n.stashAiSearchHint,
                        child: IdeButton(
                          label: l10n.stashAiSearch,
                          icon: Codicons.sparkle,
                          spinning: _aiSearching,
                          secondary: true,
                          onPressed: _aiSearching
                              ? null
                              : () => _withModel(context, _aiSearch),
                          onDropdown: (anchor) =>
                              unawaited(pickActionsModel(context, anchor)),
                          dropdownTooltip: _modelTooltip(l10n),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              _buildFilters(l10n),
              for (final group in merges)
                _Banner(
                  icon: Codicons.merge,
                  text: l10n.stashMergeSuggestion(
                    group.map((id) => '#$id').join(', '),
                  ),
                  actions: [
                    (l10n.stashMerge, () => unawaited(_merge(group))),
                    (l10n.stashDismiss, () => _controller.dismissMerge(group)),
                  ],
                ),
              if (_picked.length > 1) _buildPickedBar(l10n),
              if (ai)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Icon(
                        Codicons.sparkle,
                        size: 13,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          switch (_aiError) {
                            final error? => l10n.stashAiSearchFailed(error),
                            null => l10n.stashAiResults(notes.length),
                          },
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _aiError == null
                                ? AppColors.textMuted
                                : themeColors['errorForeground'],
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _LinkText(
                        l10n.stashAiClear,
                        onTap: () => setState(() => _aiResults = null),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (notes.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                _controller.store.notes.isEmpty
                    ? l10n.stashEmpty(_hotkeyLabel())
                    : l10n.stashNoMatch,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textFaint, fontSize: 13),
              ),
            ),
          )
        else if (_searching || ai)
          ..._section(null, notes)
        else
          for (final (heading, group) in _grouped(notes, l10n))
            ..._section(heading, group),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  String _hotkeyLabel() => StashSettings.label(
    _controller.settings.hotkey,
    mac: AppPlatform.isMacOS,
  );

  List<Widget> _section(String? heading, List<StashNote> notes) => [
    if (heading != null)
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(24, 18, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text(
            heading,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      )
    else
      const SliverToBoxAdapter(child: SizedBox(height: 14)),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: const _StashCardGrid(),
        itemCount: notes.length,
        itemBuilder: (context, i) {
          final note = notes[i];
          return _StashCard(
            note: note,
            store: _controller,
            selected: _open == note.id || _picked.contains(note.id),
            projectName: _projectName(note.project),
            onTap: () => _tap(note),
            onMenu: (position) => unawaited(_cardMenu(note, position)),
          );
        },
      ),
    ),
  ];

  Widget _buildFilters(AppLocalizations l10n) {
    final timeLabel = switch (_time) {
      _Time.all => l10n.stashFilterAnyTime,
      _Time.today => l10n.stashGroupToday,
      _Time.week => l10n.stashGroupWeek,
      _Time.month => l10n.stashGroupMonth,
    };
    final projectLabel = switch (_project) {
      null => l10n.stashFilterAnyProject,
      '' => l10n.stashNoProject,
      final path => _projectName(path) ?? path,
    };
    final statusLabel = switch (_status) {
      _Status.all => l10n.stashFilterAnyStatus,
      _Status.open => l10n.stashFilterOpen,
      _Status.collected => stashStatusLabel(l10n, StashStatus.collected),
      _Status.requirement => stashStatusLabel(l10n, StashStatus.requirement),
      _Status.implementing => stashStatusLabel(l10n, StashStatus.implementing),
      _Status.done => stashStatusLabel(l10n, StashStatus.done),
    };
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _FilterChip(
          icon: Codicons.history,
          label: timeLabel,
          active: _time != _Time.all,
          onTap: (anchor) => unawaited(
            _filterMenu(anchor, [
              for (final (time, label) in [
                (_Time.all, l10n.stashFilterAnyTime),
                (_Time.today, l10n.stashGroupToday),
                (_Time.week, l10n.stashGroupWeek),
                (_Time.month, l10n.stashGroupMonth),
              ])
                IdeMenuAction(
                  label,
                  checked: _time == time,
                  onSelected: () => setState(() => _time = time),
                ),
            ]),
          ),
        ),
        _FilterChip(
          icon: Codicons.folder,
          label: projectLabel,
          active: _project != null,
          onTap: (anchor) => unawaited(
            _filterMenu(anchor, [
              IdeMenuAction(
                l10n.stashFilterAnyProject,
                checked: _project == null,
                onSelected: () => setState(() => _project = null),
              ),
              ..._projectEntries(
                (project) => setState(() => _project = project ?? ''),
                current: _project == '' ? null : (_project ?? '\u0000'),
              ),
            ]),
          ),
        ),
        _FilterChip(
          icon: Codicons.filter,
          label: statusLabel,
          active: _status != _Status.all,
          onTap: (anchor) => unawaited(
            _filterMenu(anchor, [
              for (final (status, label) in [
                (_Status.all, l10n.stashFilterAnyStatus),
                (_Status.open, l10n.stashFilterOpen),
                for (final status in StashStatus.values)
                  (
                    _Status.values.byName(status.name),
                    stashStatusLabel(l10n, status),
                  ),
              ])
                IdeMenuAction(
                  label,
                  checked: _status == status,
                  onSelected: () => setState(() => _status = status),
                ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildPickedBar(AppLocalizations l10n) {
    final ids = [..._picked];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: themeColors['list.inactiveSelectionBackground'],
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Text(
              l10n.stashPicked(ids.length),
              style: TextStyle(color: AppColors.text, fontSize: 12.5),
            ),
            const Spacer(),
            IdeButton(
              label: l10n.stashMerge,
              icon: Codicons.merge,
              secondary: true,
              onPressed: () => unawaited(_merge(ids)),
            ),
            const SizedBox(width: 6),
            Builder(
              builder: (context) => IdeButton(
                label: l10n.stashLinkProject,
                icon: Codicons.folder,
                secondary: true,
                onPressed: () {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  unawaited(
                    _filterMenu(
                      box.localToGlobal(Offset.zero) & box.size,
                      _projectEntries(
                        (project) => unawaited(_setProject(ids, project)),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 6),
            IdeButton(
              label: l10n.stashMarkDone,
              icon: Codicons.check,
              secondary: true,
              onPressed: () => unawaited(_setStatus(ids, StashStatus.done)),
            ),
            const SizedBox(width: 6),
            IdeButton(
              label: l10n.stashDelete,
              icon: Codicons.trash,
              secondary: true,
              onPressed: () => unawaited(_delete(ids)),
            ),
            const SizedBox(width: 6),
            SidebarIconButton(
              icon: Codicons.close,
              tooltip: l10n.stashClearPicked,
              onTap: () => setState(_picked.clear),
            ),
          ],
        ),
      ),
    );
  }
}

/// What is done to stashes, on the page and where one shows whole
/// ([StashDetail]).
mixin _StashActions<T extends StatefulWidget> on State<T> {
  StashController get _controller;

  Future<void> _setStatus(Iterable<int> ids, StashStatus status) async {
    for (final id in [...ids]) {
      await _controller.store.update(id, (note) => note.status = status);
    }
  }

  Future<void> _togglePin(StashNote note) => _controller.store.update(
    note.id,
    (note) => note.pinned = !note.pinned,
    touch: false,
  );

  Future<void> _setProject(Iterable<int> ids, String? project) async {
    for (final id in [...ids]) {
      await _controller.store.update(id, (note) {
        note.project = project;
        note.suggestedProject = '';
      }, touch: false);
    }
  }

  Future<void> _delete(List<int> ids) async {
    final l10n = context.l10n;
    final choice = await showIdeDialog(
      context,
      message: ids.length == 1
          ? l10n.stashDeleteOne('#${ids.single}')
          : l10n.stashDeleteMany(ids.length),
      detail: l10n.stashDeleteDetail,
      buttons: [l10n.stashDelete],
    );
    if (choice != 0) return;
    for (final id in ids) {
      await _controller.store.delete(id);
    }
    if (mounted) _deleted(ids);
  }

  /// [ids]' stashes are deleted.
  void _deleted(List<int> ids) {}

  /// Puts [ids]' stashes into one (several picked on the page).
  Future<void> _merge(List<int> ids) async {}

  /// Those a menu for [note] acts on: it, or all those picked with it.
  List<int> _idsFor(StashNote note) => [note.id];

  List<IdeMenuEntry> _projectEntries(
    void Function(String? project) pick, {
    String? current,
  }) {
    final l10n = context.l10n;
    return [
      IdeMenuAction(
        l10n.stashNoProject,
        checked: current == null,
        onSelected: () => pick(null),
      ),
      const IdeMenuSeparator(),
      for (final project in _controller.workspace.projects)
        IdeMenuAction(
          project.name,
          icon: stashProjectIcon(_controller.workspace, project),
          checked: project.path == current,
          onSelected: () => pick(project.path),
        ),
    ];
  }

  List<IdeMenuEntry> _statusEntries(Iterable<int> ids, {StashStatus? current}) {
    final l10n = context.l10n;
    return [
      for (final status in StashStatus.values)
        IdeMenuAction(
          stashStatusLabel(l10n, status),
          checked: status == current,
          onSelected: () => unawaited(_setStatus(ids, status)),
        ),
    ];
  }

  Future<void> _cardMenu(StashNote note, Offset position) async {
    final l10n = context.l10n;
    final ids = _idsFor(note);
    final several = ids.length > 1;
    await showIdeMenu(
      context,
      position: position,
      entries: [
        if (!several) ...[
          IdeMenuAction(
            note.pinned ? l10n.stashUnpin : l10n.stashPin,
            onSelected: () => unawaited(_togglePin(note)),
          ),
          IdeMenuAction(
            l10n.stashOpenInPanel,
            onSelected: () => unawaited(_controller.open(note.id)),
          ),
        ],
        IdeMenuAction(
          l10n.stashStatus,
          submenu: _statusEntries(ids, current: several ? null : note.status),
        ),
        IdeMenuAction(
          l10n.stashLinkProject,
          submenu: _projectEntries(
            (project) => unawaited(_setProject(ids, project)),
            current: several ? null : note.project,
          ),
        ),
        if (several)
          IdeMenuAction(
            l10n.stashMerge,
            onSelected: () => unawaited(_merge(ids)),
          ),
        const IdeMenuSeparator(),
        if (!several && WindowControls.canRevealInFileManager)
          IdeMenuAction(
            l10n.stashReveal,
            onSelected: () => unawaited(
              WindowControls.revealInFileManager(
                p.join(_controller.store.root, '${note.id}.md'),
              ),
            ),
          ),
        IdeMenuAction(
          l10n.stashDelete,
          onSelected: () => unawaited(_delete(ids)),
        ),
      ],
    );
  }

  Future<void> _filterMenu(Rect anchor, List<IdeMenuEntry> entries) =>
      showIdeMenu(context, anchor: anchor, entries: entries);

  String? _projectName(String? path) {
    if (path == null || path.isEmpty) return null;
    for (final project in _controller.workspace.projects) {
      if (project.path == path) return project.name;
    }
    return p.basename(path);
  }

  /// Runs [action], an AI action, once a model is picked for it (see
  /// [withActionsModel]): the menu that picks one by [context]'s button.
  void _withModel(BuildContext context, Future<void> Function() action) {
    final anchor = anchorOf(context);
    if (anchor == null) return;
    unawaited(withActionsModel(context, anchor, action));
  }

  String _modelTooltip(AppLocalizations l10n) => l10n.aiModelTooltip(
    actionsModelName(l10n, ModelProviders.current) ?? l10n.aiModelNone,
  );

  String _sourceText(StashNote note) {
    final source = note.source;
    final when = _dateText(note.created);
    return switch (source.branch) {
      final branch? => '$when · ⎇ $branch',
      null => when,
    };
  }
}

/// A stash's file (`<root>/12.md`) where it opens, in the side panel or
/// the IDE: as the Stash page shows it ([StashDetail]), not its text.
/// [onOpenAgent] shows a conversation it is carried out in.
FileView stashFileView(
  StashController controller, {
  ValueChanged<AgentThread>? onOpenAgent,
}) => FileView(
  id: 'stash',
  matches: (path) => controller.store.idOfFile(path) != null,
  build: (context, path) => switch (controller.store.idOfFile(path)) {
    final id? => StashDetail(
      controller: controller,
      id: id,
      onOpenAgent: onOpenAgent,
    ),
    null => const SizedBox.shrink(),
  },
);

/// A stash whole, to read, edit, say clearly and carry out: on the Stash
/// page beside the cards, and wherever its file opens (the side panel's
/// tabs, the IDE's editor: see [stashFileView]).
class StashDetail extends StatefulWidget {
  const StashDetail({
    super.key,
    required this.controller,
    required this.id,
    this.onOpenAgent,
    this.onOpenLink,
    this.onClose,
  });

  final StashController controller;
  final int id;

  /// Shows a conversation it is carried out in; none where there is none
  /// to show it in.
  final ValueChanged<AgentThread>? onOpenAgent;

  /// What a link in it does (`[[#3]]`, `@project`); by default another
  /// stash shows on the Stash page.
  final ValueChanged<String>? onOpenLink;

  /// Its close button's; none where it closes otherwise (a tab).
  final VoidCallback? onClose;

  @override
  State<StashDetail> createState() => _StashDetailState();
}

class _StashDetailState extends State<StashDetail> with _StashActions {
  final GlobalKey<StashNoteEditorState> _editor = GlobalKey();

  @override
  StashController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _controller.store.addListener(_changed);
  }

  @override
  void didUpdateWidget(StashDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.store.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.store.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openLink(String href) {
    if (widget.onOpenLink case final open?) return open(href);
    if (StashRefs.stashOf(href) case final id?) _controller.showPage?.call(id);
  }

  /// Says [note] clearly, in the background (see
  /// [StashController.clarify]): what it has written first.
  Future<void> _clarify(StashNote note) async {
    await _editor.currentState?.flush();
    await _controller.clarify(note.id);
  }

  Future<void> _implement(StashNote note, Rect anchor) async {
    await _editor.currentState?.flush();
    if (!mounted) return;
    final thread = await implementStash(
      context,
      _controller,
      note.id,
      anchor: anchor,
    );
    if (thread != null) widget.onOpenAgent?.call(thread);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final note = _controller.store.byId(widget.id);
    if (note == null) return const SizedBox.shrink();
    final thread = _controller.threadOf(note);
    final suggested = note.suggestedProject;
    final clarifying = _controller.clarifying(note.id);
    final failure = _controller.clarifyFailure(note.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
          child: Row(
            children: [
              Text(
                note.tag,
                style: TextStyle(
                  color: AppColors.textFaint,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TitleField(
                  key: ValueKey(('title', note.id)),
                  title: note.title,
                  placeholder: note.displayTitle,
                  onChanged: (title) => unawaited(
                    _controller.store.update(
                      note.id,
                      (note) => note.title = title,
                      touch: false,
                    ),
                  ),
                ),
              ),
              SidebarIconButton(
                icon: note.pinned ? Codicons.pinned : Codicons.pin,
                tooltip: note.pinned ? l10n.stashUnpin : l10n.stashPin,
                onTap: () => unawaited(_togglePin(note)),
              ),
              Builder(
                builder: (context) => SidebarIconButton(
                  icon: Codicons.ellipsis,
                  tooltip: l10n.stashMore,
                  onTap: () {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    unawaited(
                      _cardMenu(
                        note,
                        box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                      ),
                    );
                  },
                ),
              ),
              if (widget.onClose case final close?)
                SidebarIconButton(
                  icon: Codicons.close,
                  tooltip: l10n.stashCloseDetail,
                  onTap: close,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _FilterChip(
                icon: _statusIcon(note.status),
                label: stashStatusLabel(l10n, note.status),
                active: true,
                onTap: (anchor) => unawaited(
                  _filterMenu(
                    anchor,
                    _statusEntries([note.id], current: note.status),
                  ),
                ),
              ),
              _FilterChip(
                icon: Codicons.folder,
                label: _projectName(note.project) ?? l10n.stashNoProject,
                active: note.project != null,
                onTap: (anchor) => unawaited(
                  _filterMenu(
                    anchor,
                    _projectEntries(
                      (project) => unawaited(_setProject([note.id], project)),
                      current: note.project,
                    ),
                  ),
                ),
              ),
              Text(
                _sourceText(note),
                style: TextStyle(color: AppColors.textFaint, fontSize: 11.5),
              ),
            ],
          ),
        ),
        if (note.project == null && suggested != null && suggested.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _Banner(
              icon: Codicons.sparkle,
              text: l10n.stashProjectSuggestion(
                _projectName(suggested) ?? suggested,
              ),
              actions: [
                (
                  l10n.stashLinkIt,
                  () => unawaited(
                    _controller.answerProject(note.id, accept: true),
                  ),
                ),
                (
                  l10n.stashDismiss,
                  () => unawaited(
                    _controller.answerProject(note.id, accept: false),
                  ),
                ),
              ],
            ),
          ),
        if (note.thread case final link?)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _Banner(
              icon: Codicons.commentDiscussion,
              text: link.session == null
                  ? l10n.stashThreadStarting
                  : l10n.stashThreadLinked(
                      thread?.title ??
                          link.title ??
                          link.session!.substring(0, 8),
                    ),
              actions: [
                if (thread != null)
                  if (widget.onOpenAgent case final open?)
                    (l10n.stashOpenThread, () => open(thread)),
              ],
            ),
          ),
        if (failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _Banner(
              icon: Codicons.error,
              iconColor: themeColors['errorForeground'],
              text: failure.changed
                  ? l10n.stashClarifyChanged
                  : l10n.stashExpandFailed(
                      failure.message ?? l10n.stashAiNoAnswer,
                    ),
              actions: [
                (l10n.stashRetry, () => unawaited(_clarify(note))),
                (
                  l10n.stashDismiss,
                  () => _controller.dismissClarifyFailure(note.id),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Builder(
                builder: (context) => IdeHover(
                  message: l10n.stashExpandHint,
                  child: IdeButton(
                    label: clarifying ? l10n.stashClarifying : l10n.stashExpand,
                    icon: Codicons.sparkle,
                    spinning: clarifying,
                    secondary: true,
                    onPressed: clarifying
                        ? null
                        : () => _withModel(context, () => _clarify(note)),
                    onDropdown: (anchor) =>
                        unawaited(pickActionsModel(context, anchor)),
                    dropdownTooltip: _modelTooltip(l10n),
                  ),
                ),
              ),
              Builder(
                builder: (context) => IdeButton(
                  label: l10n.stashImplement,
                  icon: Codicons.rocket,
                  onPressed: () {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    unawaited(
                      _implement(
                        note,
                        box.localToGlobal(Offset.zero) & box.size,
                      ),
                    );
                  },
                ),
              ),
              if (note.status != StashStatus.done)
                IdeButton(
                  label: l10n.stashMarkDone,
                  icon: Codicons.check,
                  secondary: true,
                  onPressed: () =>
                      unawaited(_setStatus([note.id], StashStatus.done)),
                )
              else
                IdeButton(
                  label: l10n.stashReopen,
                  icon: Codicons.discard,
                  secondary: true,
                  onPressed: () => unawaited(
                    _setStatus(
                      [note.id],
                      note.thread?.session != null
                          ? StashStatus.implementing
                          : note.requirement != null
                          ? StashStatus.requirement
                          : StashStatus.collected,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: StashNoteEditor(
            key: _editor,
            store: _controller.store,
            id: note.id,
            create: (body) async => note.id,
            refs: _controller.refs(_openLink),
            placeholder: context.l10n.stashPlaceholder,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          ),
        ),
      ],
    );
  }
}

String _dateText(DateTime at) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return time;
  }
  if (at.year == now.year) return '${at.month}/${at.day} $time';
  return '${at.year}/${at.month}/${at.day}';
}

/// A status's name, as the cards and menus show it.
String stashStatusLabel(AppLocalizations l10n, StashStatus status) =>
    switch (status) {
      StashStatus.collected => l10n.stashStatusCollected,
      StashStatus.requirement => l10n.stashStatusRequirement,
      StashStatus.implementing => l10n.stashStatusImplementing,
      StashStatus.done => l10n.stashStatusDone,
    };

IconData _statusIcon(StashStatus status) => switch (status) {
  StashStatus.collected => Codicons.inbox,
  StashStatus.requirement => Codicons.checklist,
  StashStatus.implementing => Codicons.play,
  StashStatus.done => Codicons.check,
};

/// A stash's card: its title, the start of its text, its first picture,
/// its project and status. Dragged, it goes into a composer.
class _StashCard extends StatelessWidget {
  const _StashCard({
    required this.note,
    required this.store,
    required this.selected,
    required this.projectName,
    required this.onTap,
    required this.onMenu,
  });

  final StashNote note;
  final StashController store;
  final bool selected;
  final String? projectName;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final picture = note.images.firstOrNull;
    final done = note.status == StashStatus.done;
    final card = HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        onSecondaryTapUp: (details) => onMenu(details.globalPosition),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? themeColors['list.inactiveSelectionBackground']
                : hovered
                ? AppColors.hover
                : AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? themeColors['focusBorder'] : AppColors.border,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.pinned) ...[
                          Icon(
                            Codicons.pinned,
                            size: 12,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            note.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                              decorationColor: AppColors.textFaint,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Text(
                        note.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          note.tag,
                          style: TextStyle(
                            color: AppColors.textFaint,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _dateText(note.updated),
                          style: TextStyle(
                            color: AppColors.textFaint,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (projectName case final name?)
                          Flexible(
                            child: _Badge(icon: Codicons.folder, label: name),
                          ),
                        if (store.clarifying(note.id)) ...[
                          const SizedBox(width: 4),
                          Flexible(
                            child: _Badge(
                              icon: Codicons.sync,
                              label: l10n.stashClarifying,
                              spinning: true,
                            ),
                          ),
                        ] else if (store.clarifyFailure(note.id) != null) ...[
                          const SizedBox(width: 4),
                          Flexible(
                            child: _Badge(
                              icon: Codicons.error,
                              label: l10n.stashClarifyFailedShort,
                              color: themeColors['errorForeground'],
                            ),
                          ),
                        ],
                        if (note.status != StashStatus.collected) ...[
                          const SizedBox(width: 4),
                          Flexible(
                            child: _Badge(
                              icon: _statusIcon(note.status),
                              label: stashStatusLabel(l10n, note.status),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (picture != null) ...[
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Image(
                    image: isRemoteStashPicture(picture)
                        ? NetworkImage(picture)
                        : io.stashImageProvider(store.store.absolute(picture)),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (context, _, _) => const SizedBox(width: 64),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    final reference = stashReferenceOf(store.store, note);
    return Opacity(
      opacity: done ? .55 : 1,
      child: Draggable<StashDragData>(
        data: StashDragData([reference]),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _DragFeedback(label: '${note.tag} ${note.displayTitle}'),
        child: card,
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Codicons.note, size: 13, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.text, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.label,
    this.spinning = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final bool spinning;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: themeColors['badge.background'].withValues(alpha: .35),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spinning)
          IdeSpinning(Icon(icon, size: 10, color: color ?? AppColors.textMuted))
        else
          Icon(icon, size: 10, color: color ?? AppColors.textMuted),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color ?? AppColors.textMuted,
              fontSize: 10.5,
            ),
          ),
        ),
      ],
    ),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final void Function(Rect anchor) onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        onTap(box.localToGlobal(Offset.zero) & box.size);
      },
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: hovered ? AppColors.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: active ? AppColors.borderStrong : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: AppColors.textMuted),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? AppColors.text : AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 3),
            Icon(Codicons.chevronDown, size: 11, color: AppColors.textFaint),
          ],
        ),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.actions,
    this.iconColor,
  });

  final IconData icon;
  final Color? iconColor;
  final String text;
  final List<(String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      children: [
        Icon(icon, size: 13, color: iconColor ?? AppColors.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: AppColors.text, fontSize: 12),
          ),
        ),
        for (final (label, onTap) in actions) ...[
          const SizedBox(width: 10),
          _LinkText(label, onTap: onTap),
        ],
      ],
    ),
  );
}

class _LinkText extends StatelessWidget {
  const _LinkText(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: themeColors['textLink.foreground'],
          fontSize: 12,
          decoration: hovered ? TextDecoration.underline : null,
          decorationColor: themeColors['textLink.foreground'],
        ),
      ),
    ),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return SizedBox(
      height: 32,
      child: TextField(
        controller: controller,
        onSubmitted: (_) => onSubmit(),
        style: TextStyle(color: colors['input.foreground'], fontSize: 13),
        cursorColor: AppColors.text,
        cursorHeight: 15,
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.stashSearchPlaceholder,
          hintStyle: TextStyle(
            color: colors['input.placeholderForeground'],
            fontSize: 13,
          ),
          prefixIcon: Icon(
            Codicons.search,
            size: 14,
            color: AppColors.textFaint,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 32),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          filled: true,
          fillColor: colors['input.background'],
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: AppColors.borderStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: colors['focusBorder']),
          ),
        ),
      ),
    );
  }
}

/// A stash's title, edited in place; its first line shows faint without
/// one.
class _TitleField extends StatefulWidget {
  const _TitleField({
    super.key,
    required this.title,
    required this.placeholder,
    required this.onChanged,
  });

  final String title;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  State<_TitleField> createState() => _TitleFieldState();
}

class _TitleFieldState extends State<_TitleField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.title,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_TitleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Titled by the model meanwhile.
    if (!_focus.hasFocus && widget.title != _text.text) {
      _text.text = widget.title;
    }
  }

  void _commit() {
    final title = _text.text.trim();
    if (title != widget.title) widget.onChanged(title);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    onSubmitted: (_) => _commit(),
    cursorColor: AppColors.text,
    style: TextStyle(
      color: AppColors.textPrimary,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
    decoration: InputDecoration.collapsed(
      hintText: widget.placeholder,
      hintStyle: TextStyle(
        color: AppColors.textFaint,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// The cards in as many columns as fit cards at least [minWidth] wide (a
/// thumbnail, the title and summary beside it, the badges under them), one
/// at the least.
class _StashCardGrid extends SliverGridDelegate {
  const _StashCardGrid();

  static const minWidth = 250.0;
  static const height = 132.0;
  static const spacing = 10.0;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    final columns = math.max(
      1,
      ((width + spacing) / (minWidth + spacing)).floor(),
    );
    final cardWidth = math.max(
      0.0,
      (width - spacing * (columns - 1)) / columns,
    );
    return SliverGridRegularTileLayout(
      crossAxisCount: columns,
      mainAxisStride: height + spacing,
      crossAxisStride: cardWidth + spacing,
      childMainAxisExtent: height,
      childCrossAxisExtent: cardWidth,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(_StashCardGrid oldDelegate) => false;
}

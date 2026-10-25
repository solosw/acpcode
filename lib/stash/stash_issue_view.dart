import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../forge/forge_api.dart';
import '../forge/forge_ref.dart';
import '../forge/forge_view.dart';
import '../ide/ide_button.dart';
import '../ide/ide_menu.dart';
import '../ide/ide_spinning.dart';
import '../l10n/l10n.dart';
import '../settings/pages/model_dialogs.dart' show ModelDialogFrame;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/editor_launcher.dart' show openExternal;
import 'stash_forge.dart';
import 'stash_note.dart';
import 'stash_thread_view.dart' show stashDateText;
import 'stash_view.dart' show StashBanner, StashChip;

// A stash and the issue it is (docs/stash.md): a stash of a project that
// is a Git repository is one of its issues, kept in step with it, or kept
// here alone if the user says so; one of a project that is none, here.

/// What a stash can be as an issue, as [StashIssueChip] and
/// [StashIssueButton] offer it.
enum _Can {
  /// Its project's repositories still being looked for.
  checking,

  /// It is one.
  own,

  /// It can be published.
  publish,

  /// Kept here, by the user.
  local,

  /// Nothing: its project no repository (or none).
  nothing,
}

_Can _canOf(StashForge forge, StashNote note) {
  if (note.ownIssue != null) return _Can.own;
  final project = note.project;
  if (project == null) return _Can.nothing;
  final repos = forge.knownReposOf(project);
  if (repos == null) return _Can.checking;
  if (repos.isEmpty) return _Can.nothing;
  return note.local ? _Can.local : _Can.publish;
}

/// Publishes [note] in its project's repository: at once where there is
/// one, else in the one picked under [anchor].
Future<void> _publish(
  BuildContext context,
  StashForge forge,
  StashNote note,
  Rect anchor,
) async {
  final l10n = context.l10n;
  final repos = forge.knownReposOf(note.project ?? '') ?? const [];
  if (repos.length == 1) {
    return showStashIssueDialog(
      context,
      forge: forge,
      note: note,
      repo: repos.single,
    );
  }
  await showIdeMenu(
    context,
    anchor: anchor,
    entries: [
      for (final repo in repos)
        IdeMenuAction(
          l10n.stashIssuePublishTo(repo.path),
          enabled: forge.accounts.apiFor(repo.host) != null,
          onSelected: () => unawaited(
            showStashIssueDialog(context, forge: forge, note: note, repo: repo),
          ),
        ),
    ],
  );
}

/// In a stash's detail, beside its status and project: the issue it is
/// (its state and number; opened, asked again, its changes sent or let
/// go, or let go itself, from its menu), else where it can be one
/// (published, once the user confirms what goes; or kept here), else
/// nothing (its project no repository); its project's repositories
/// looked for meanwhile.
class StashIssueChip extends StatelessWidget {
  const StashIssueChip({super.key, required this.forge, required this.note});

  final StashForge forge;
  final StashNote note;

  /// How it stands with its issue: the same, or which side changed; when
  /// last synced.
  String _syncHint(AppLocalizations l10n, String tag) {
    final here = note.changedHere;
    final there = forge.remoteChanged(note);
    return [
      switch ((here, there)) {
        (true, true) => l10n.stashIssueBothChanged,
        (true, false) => l10n.stashIssueNotPushed,
        (false, true) => l10n.stashIssueRemoteNewer,
        (false, false) => l10n.stashIssueInSync(tag),
      },
      if (forge.lastSynced case final at?)
        l10n.stashIssueSyncedAt(stashDateText(at)),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: forge,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    switch (_canOf(forge, note)) {
      case _Can.nothing:
        return const SizedBox.shrink();
      case _Can.checking:
        return StashChip(
          icon: Codicons.sync,
          leading: IdeSpinning(
            Icon(Codicons.sync, size: 12, color: AppColors.textFaint),
          ),
          label: l10n.stashIssueChecking,
          onTap: (_) {},
        );
      case _Can.own:
        final url = note.ownIssue!;
        final ref = forge.refOf(url);
        final link = note.issueOf(url);
        final state = link == null ? null : forge.stateOf(link);
        return StashChip(
          icon: Codicons.issues,
          leading: forge.asking(url)
              ? IdeSpinning(
                  Icon(Codicons.sync, size: 12, color: AppColors.textFaint),
                )
              : ref == null
              ? null
              : ForgeStateIcon(ref.kind, state, size: 12),
          label: [ref?.fullTag ?? url, if (note.changedHere) '•'].join(' '),
          tooltip: _syncHint(l10n, ref?.fullTag ?? url),
          active: true,
          onTap: (anchor) => unawaited(
            showIdeMenu(
              context,
              anchor: anchor,
              entries: _ownEntries(context, l10n, url),
            ),
          ),
        );
      case _Can.local:
        return StashChip(
          icon: Codicons.lock,
          label: l10n.stashIssueLocal,
          onTap: (anchor) => unawaited(
            showIdeMenu(
              context,
              anchor: anchor,
              entries: [
                IdeMenuAction(
                  l10n.stashIssueAllow,
                  onSelected: () => unawaited(forge.allowIssue(note.id)),
                ),
              ],
            ),
          ),
        );
      case _Can.publish:
        final repos = forge.knownReposOf(note.project!)!;
        return StashChip(
          icon: Codicons.cloudUpload,
          label: l10n.stashIssueNotPublished,
          onTap: (anchor) => unawaited(
            showIdeMenu(
              context,
              anchor: anchor,
              entries: ideMenuGroups([
                [
                  for (final repo in repos)
                    IdeMenuAction(
                      l10n.stashIssuePublishTo(repo.path),
                      enabled: forge.accounts.apiFor(repo.host) != null,
                      onSelected: () => unawaited(
                        showStashIssueDialog(
                          context,
                          forge: forge,
                          note: note,
                          repo: repo,
                        ),
                      ),
                    ),
                ],
                [
                  IdeMenuAction(
                    l10n.stashIssueKeepLocal,
                    onSelected: () => unawaited(forge.keepLocal(note.id)),
                  ),
                ],
              ]),
            ),
          ),
        );
    }
  }

  List<IdeMenuEntry> _ownEntries(
    BuildContext context,
    AppLocalizations l10n,
    String url,
  ) {
    final signedIn = forge.canAsk(url);
    return ideMenuGroups([
      [
        IdeMenuAction(
          l10n.stashIssueOpen,
          onSelected: () => unawaited(openExternal(url)),
        ),
        IdeMenuAction(
          l10n.stashIssueCopy,
          onSelected: () =>
              unawaited(Clipboard.setData(ClipboardData(text: url))),
        ),
        IdeMenuAction(
          l10n.stashIssueRefresh,
          enabled: signedIn,
          onSelected: () => unawaited(forge.refreshNote(note.id, force: true)),
        ),
      ],
      [
        IdeMenuAction(
          l10n.stashIssuePush,
          enabled: note.changedHere && signedIn,
          onSelected: () => unawaited(
            showStashIssueDialog(context, forge: forge, note: note),
          ),
        ),
        IdeMenuAction(
          l10n.stashIssueTakeRemote,
          enabled: note.changedHere && signedIn,
          onSelected: () => unawaited(forge.takeRemote(note.id)),
        ),
      ],
      [
        IdeMenuAction(
          l10n.stashIssueUnlinkOwn,
          onSelected: () => unawaited(forge.keepLocal(note.id)),
        ),
      ],
    ]);
  }
}

/// Among a stash's detail's actions: Publish as Issue where it can be one,
/// Push to Issue where it was changed here; nothing otherwise.
class StashIssueButton extends StatelessWidget {
  const StashIssueButton({super.key, required this.forge, required this.note});

  final StashForge forge;
  final StashNote note;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: forge,
    builder: (context, _) {
      final l10n = context.l10n;
      switch (_canOf(forge, note)) {
        case _Can.publish:
          return Builder(
            builder: (context) => IdeButton(
              label: l10n.stashIssuePublishButton,
              icon: Codicons.cloudUpload,
              secondary: true,
              onPressed: () {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null) return;
                unawaited(
                  _publish(
                    context,
                    forge,
                    note,
                    box.localToGlobal(Offset.zero) & box.size,
                  ),
                );
              },
            ),
          );
        case _Can.own when note.changedHere && forge.canAsk(note.ownIssue!):
          return IdeButton(
            label: l10n.stashIssuePushButton,
            icon: Codicons.cloudUpload,
            secondary: true,
            onPressed: () => unawaited(
              showStashIssueDialog(context, forge: forge, note: note),
            ),
          );
        default:
          return const SizedBox.shrink();
      }
    },
  );
}

/// In a stash's detail, over its text: what was changed here is not on
/// its issue yet (send it? let it go?), or both were changed (which?).
class StashIssueSyncBanner extends StatelessWidget {
  const StashIssueSyncBanner({
    super.key,
    required this.forge,
    required this.note,
  });

  final StashForge forge;
  final StashNote note;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: forge,
    builder: (context, _) {
      final url = note.ownIssue;
      if (url == null || !note.changedHere || !forge.canAsk(url)) {
        return const SizedBox.shrink();
      }
      final l10n = context.l10n;
      final tag = forge.refOf(url)?.fullTag ?? url;
      void push() =>
          unawaited(showStashIssueDialog(context, forge: forge, note: note));
      void take() => unawaited(forge.takeRemote(note.id));
      return forge.remoteChanged(note)
          ? StashBanner(
              icon: Codicons.warning,
              iconColor: themeColors['charts.yellow'],
              text: l10n.stashIssueConflict(tag),
              actions: [
                (l10n.stashIssueKeepMine, push),
                (l10n.stashIssueKeepTheirs, take),
              ],
            )
          : StashBanner(
              icon: Codicons.cloudUpload,
              text: l10n.stashIssueChangedHere(tag),
              actions: [
                (l10n.stashIssuePushShort, push),
                (l10n.stashIssueDiscard, take),
              ],
            );
    },
  );
}

/// Publishes [note] as an issue of [repo], or (without) sends its changes
/// to the issue it is: its title and text shown as they go, what should
/// not go out (a path on this machine, a secret) pointed out, the
/// pictures that go with it counted; sent only by the user's click.
Future<void> showStashIssueDialog(
  BuildContext context, {
  required StashForge forge,
  required StashNote note,
  ForgeRepo? repo,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x80000000),
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) =>
      StashIssueDialog(forge: forge, note: note, repo: repo),
);

class StashIssueDialog extends StatefulWidget {
  const StashIssueDialog({
    super.key,
    required this.forge,
    required this.note,
    this.repo,
  });

  final StashForge forge;
  final StashNote note;

  /// Where it is published; null: its changes go to its issue.
  final ForgeRepo? repo;

  @override
  State<StashIssueDialog> createState() => _StashIssueDialogState();
}

class _StashIssueDialogState extends State<StashIssueDialog> {
  var _sending = false;
  String? _error;

  ForgeRepo? get _repo =>
      widget.repo ??
      switch (widget.note.ownIssue) {
        final url? => widget.forge.refOf(url)?.repo,
        null => null,
      };

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (widget.repo case final repo?) {
        await widget.forge.publish(widget.note.id, repo);
      } else {
        await widget.forge.pushEdits(widget.note.id);
      }
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error is ForgeException ? error.message : '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final note = widget.note;
    final repo = _repo;
    final text = note.issueText;
    final title = note.displayTitle;
    final sensitive = StashForge.sensitive('$title\n$text');
    final pictures = StashForge.localPictures(text);
    final account = repo == null
        ? null
        : widget.forge.accounts.accountFor(repo.host);
    final muted = TextStyle(color: AppColors.textMuted, fontSize: 12);
    final publishing = widget.repo != null;
    return ModelDialogFrame(
      title: publishing
          ? l10n.stashIssuePublishTitle(repo?.path ?? '')
          : l10n.stashIssuePushTitle(
              widget.forge.refOf(note.ownIssue ?? '')?.fullTag ?? '',
            ),
      actions: [
        IdeButton(
          label: sensitive.isNotEmpty
              ? l10n.stashWriteSendAnyway
              : publishing
              ? l10n.stashIssuePublish
              : l10n.stashIssuePushShort,
          spinning: _sending,
          onPressed: _sending ? null : () => unawaited(_send()),
        ),
        IdeButton(
          label: l10n.commonCancel,
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                text.isEmpty ? l10n.stashIssueNoText : text,
                style: AppFonts.uiCodeStyle(12).copyWith(
                  color: text.isEmpty ? AppColors.textFaint : AppColors.text,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (pictures > 0) ...[
            const SizedBox(height: 10),
            Text(
              repo?.kind == ForgeKind.gitlab
                  ? l10n.stashIssuePicturesGitLab(pictures)
                  : l10n.stashIssuePicturesGitHub(
                      pictures,
                      GitHubApi.assetsBranch,
                    ),
              style: muted,
            ),
          ],
          if (sensitive.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              l10n.stashWriteSensitive,
              style: muted.copyWith(color: themeColors['charts.yellow']),
            ),
            for (final found in sensitive.toSet())
              Text(
                '  $found',
                style: muted.copyWith(fontFamily: AppFonts.mono),
              ),
          ],
          const SizedBox(height: 10),
          Text(
            l10n.stashWriteAs(account?.login ?? '-', repo?.host ?? ''),
            style: muted,
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 10),
            SelectableText(
              l10n.stashWriteFailed(error),
              style: muted.copyWith(color: themeColors['errorForeground']),
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/widgets.dart';

import '../ide/ide_dialog.dart';
import '../l10n/l10n.dart';
import 'chat_session.dart';

/// Stops [session]'s turn, once asked when tasks run in the background:
/// Claude Code's interrupt ends those too.
Future<void> stopTurn(BuildContext context, ChatSession session) async {
  final background = session.tasks?.length ?? 0;
  if (background > 0) {
    final l10n = context.l10n;
    final choice = await showIdeDialog(
      context,
      message: l10n.stopConfirmMessage,
      detail: l10n.stopConfirmDetail(background),
      buttons: [l10n.stopConfirmStop],
      type: IdeDialogType.question,
    );
    if (choice != 0) return;
  }
  session.stop();
}

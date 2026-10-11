import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../chat_models.dart';
import '../widgets/hover_builder.dart';

/// The messages sent while the agent works, docked above the composer
/// until their turn: each to be taken back to edit, sent at once (the turn
/// running stopped for it), or taken back.
class QueuePanel extends StatelessWidget {
  const QueuePanel({
    super.key,
    required this.messages,
    required this.onEdit,
    required this.onSendNow,
    required this.onRemove,
  });

  /// With their ids, the next first.
  final List<(String, UserMessageItem)> messages;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onSendNow;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 13,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.queuedMessages(messages.length),
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              children: [
                for (final (id, message) in messages)
                  _QueuedRow(
                    key: ValueKey(id),
                    message: message,
                    onEdit: () => onEdit(id),
                    onSendNow: () => onSendNow(id),
                    onRemove: () => onRemove(id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueuedRow extends StatelessWidget {
  const _QueuedRow({
    super.key,
    required this.message,
    required this.onEdit,
    required this.onSendNow,
    required this.onRemove,
  });

  final UserMessageItem message;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return HoverBuilder(
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.fromLTRB(6, 3, 4, 3),
        decoration: BoxDecoration(
          color: hovered ? AppColors.hover : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            Expanded(
              // A click takes it back to edit, as the pencil does.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onEdit,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Text(
                    [
                      if (text.isNotEmpty) text,
                      if (message.images.isNotEmpty)
                        l10n.queuedImages(message.images.length),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.text, fontSize: 12.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _Action(
              icon: Codicons.edit,
              tooltip: l10n.queuedEdit,
              onTap: onEdit,
            ),
            _Action(
              icon: Codicons.arrowUp,
              tooltip: l10n.queuedSendNow,
              onTap: onSendNow,
            ),
            _Action(
              icon: Codicons.trash,
              tooltip: l10n.queuedRemove,
              onTap: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: tooltip,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => Semantics(
          button: true,
          label: tooltip,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(3),
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                color: hovered ? AppColors.hover : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(icon, size: 14, color: AppColors.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}

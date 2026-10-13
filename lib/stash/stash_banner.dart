import 'package:flutter/material.dart';

import '../chat/widgets/hover_builder.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'stash_controller.dart';

/// Atop a conversation a stash is carried out in: where it came from,
/// `Stash #12 · title`, which shows the stash. Nothing for another.
class StashSourceBanner extends StatelessWidget {
  const StashSourceBanner({super.key, required this.session});

  /// The conversation's session id (none before its first message).
  final String? session;

  @override
  Widget build(BuildContext context) {
    final controller = StashController.current;
    if (controller == null || session == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.store]),
      builder: (context, _) {
        final note = controller.stashOfThread(session);
        if (note == null) return const SizedBox.shrink();
        final show = controller.showPage;
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: HoverBuilder(
              cursor: show == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              builder: (context, hovered) => GestureDetector(
                onTap: show == null ? null : () => show(note.id),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: hovered ? AppColors.hover : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Codicons.note, size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          context.l10n.stashSourceBanner(
                            note.tag,
                            note.displayTitle,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

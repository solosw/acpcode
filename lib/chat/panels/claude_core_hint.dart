import 'dart:async';

import 'package:flutter/material.dart';

import '../../kernel/claude_code/claude_core_setting.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import 'interaction_panel.dart';

/// Over the composer of a Claude Code chat while the core picked is
/// BaoCode's own: the Claude Code CLI suggested, with a way to switch to
/// it ([onSwitched] once picked, for the session to move to it). Not
/// shown again in this run once put off. Nothing otherwise.
class ClaudeCoreHint extends StatefulWidget {
  const ClaudeCoreHint({super.key, required this.onSwitched});

  final VoidCallback onSwitched;

  /// Put off with "Not now", in every chat until the app starts again.
  @visibleForTesting
  static final putOff = ValueNotifier(false);

  @override
  State<ClaudeCoreHint> createState() => _ClaudeCoreHintState();
}

class _ClaudeCoreHintState extends State<ClaudeCoreHint> {
  void _switch() {
    unawaited(
      ClaudeCore.pick(ClaudeCore.cli).then(
        (_) {
          if (mounted) widget.onSwitched();
        },
        onError: (Object error) {
          // A settings file that does not parse is left as it is; its
          // error is shown.
          debugPrint('${ClaudeCore.settingKey} not kept: $error');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ClaudeCore.changes, ClaudeCoreHint.putOff]),
      builder: (context, _) {
        if (ClaudeCoreHint.putOff.value ||
            ClaudeCore.current() != ClaudeCore.builtin) {
          return const SizedBox.shrink();
        }
        final accent = AppColors.accent;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: .35)),
            ),
            child: Row(
              children: [
                Icon(Codicons.sparkle, size: 15, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.claudeCoreHint,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PanelButton(
                  label: context.l10n.claudeCoreHintLater,
                  onTap: () => ClaudeCoreHint.putOff.value = true,
                ),
                const SizedBox(width: 6),
                PanelButton(
                  label: context.l10n.claudeCoreHintSwitch,
                  primary: true,
                  onTap: _switch,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

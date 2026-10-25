import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;

/// A task's box (`- [ ]`), as the app draws checkboxes (not Material's).
class MarkdownTaskBox extends StatelessWidget {
  const MarkdownTaskBox({
    super.key,
    required this.checked,
    required this.onChanged,
  });

  static const size = 14.0;

  final bool checked;

  /// Null where it may not be ticked.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final onChanged = this.onChanged;
    return Semantics(
      checked: checked,
      child: MouseRegion(
        cursor: onChanged == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onChanged == null ? null : () => onChanged(!checked),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: checked ? AppColors.accent : colors['checkbox.background'],
              border: Border.all(
                color: checked ? AppColors.accent : colors['checkbox.border'],
              ),
              borderRadius: BorderRadius.circular(3.5),
            ),
            child: checked
                ? Icon(
                    Codicons.check,
                    size: 12,
                    color: colors['button.foreground'],
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../floating/hover_tooltip.dart';
import '../widgets/image_thumbnails.dart' show PreviewClick;

/// What a conversation knows of its `/commands`, for the composer's menu
/// and the tags of them: a command's whole description, and its file (a
/// skill's SKILL.md, a command's markdown) to open, as a markdown file
/// opens: shown as it reads, edited in place, or as its source.
class CommandDetails extends InheritedWidget {
  const CommandDetails({
    super.key,
    required this.describe,
    required this.fileOf,
    required this.open,
    required super.child,
  });

  /// The description of the command [name] (no `/`); null for none.
  final String? Function(String name) describe;

  /// The file of the command [name], if it has one (not one built in).
  final Future<String?> Function(String name) fileOf;

  /// Opens a command's file.
  final ValueChanged<String> open;

  static CommandDetails? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CommandDetails>();

  @override
  bool updateShouldNotify(CommandDetails oldWidget) =>
      describe != oldWidget.describe ||
      fileOf != oldWidget.fileOf ||
      open != oldWidget.open;
}

/// The command [name]'s whole [description], in a tag's hover, and the way
/// to its file where it has one; nothing where it has neither.
class CommandDetailsView extends StatelessWidget {
  const CommandDetailsView({
    super.key,
    required this.name,
    required this.description,
    this.maxLines = 8,
  });

  final String name;
  final String description;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final details = CommandDetails.maybeOf(context);
    return FutureBuilder<String?>(
      future: details?.fileOf(name),
      builder: (context, file) {
        final path = file.data;
        if (description.isEmpty && path == null) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (description.isNotEmpty)
              Text(
                description,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            if (path != null && details != null)
              Padding(
                padding: EdgeInsets.only(top: description.isEmpty ? 0 : 6),
                child: _OpenLink(onTap: () => details.open(path)),
              ),
          ],
        );
      },
    );
  }
}

class _OpenLink extends StatelessWidget {
  const _OpenLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = themeColors['textLink.foreground'];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Codicons.goToFile, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              context.l10n.commandOpenDetails,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// [child] (a command's tag) with its details on hover, its file opened on
/// a click where it has one, where the conversation knows of [name].
class CommandTagDetails extends StatelessWidget {
  const CommandTagDetails({super.key, required this.name, required this.child});

  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final details = CommandDetails.maybeOf(context);
    if (details == null) return child;
    return HoverTooltip(
      // As the kernel describes it now.
      content: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: CommandDetailsView(
          name: name,
          description: details.describe(name) ?? '',
        ),
      ),
      child: FutureBuilder<String?>(
        future: details.fileOf(name),
        builder: (context, file) => switch (file.data) {
          final path? => PreviewClick(
            onOpen: () => details.open(path),
            child: child,
          ),
          null => child,
        },
      ),
    );
  }
}

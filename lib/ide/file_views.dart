import 'package:flutter/widgets.dart';

/// A kind of file shown as something of its own rather than its text: a
/// stash as the Stash page shows it (see docs/stash.md); later, say, a web
/// page or a spreadsheet. What shows it registers it ([FileViews.register])
/// while it can.
@immutable
class FileView {
  const FileView({
    required this.id,
    required this.matches,
    required this.build,
  });

  /// Tells it from the others (one registered again takes its place).
  final String id;

  /// Whether the file at [path] (absolute, on this machine) is one.
  final bool Function(String path) matches;

  /// It, for the file at [path], in place of an editor.
  final Widget Function(BuildContext context, String path) build;
}

/// The [FileView]s: where a file opens (the side panel's tabs, the IDE's
/// editor) asks [of] first, before it reads the file as text.
abstract final class FileViews {
  static final List<FileView> _views = [];

  static void register(FileView view) => _views
    ..removeWhere((other) => other.id == view.id)
    ..add(view);

  static void unregister(String id) =>
      _views.removeWhere((view) => view.id == id);

  /// The view of the file at [path]; null to show its text.
  static FileView? of(String path) {
    for (final view in _views) {
      if (view.matches(path)) return view;
    }
    return null;
  }

  static FileView? byId(String id) {
    for (final view in _views) {
      if (view.id == id) return view;
    }
    return null;
  }
}

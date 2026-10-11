import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../workspace/window_controls.dart';
import '../../theme/material_file_icons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'composer_files.dart';
import 'file_drop.dart';

/// [child], to drag [files] from onto the composer (the IDE's explorer
/// rows, its tabs…), as files are dragged in from other apps. With
/// [outward], they go on out of the window as the system drags files, to
/// let go in another app (Finder…), as VS Code's explorer does.
class FileDraggable extends StatefulWidget {
  const FileDraggable({
    super.key,
    required this.files,
    required this.child,
    this.onDragStarted,
    this.onDragEnd,
    this.localPaths,
    this.outward,
  });

  final List<ComposerFile> files;
  final Widget child;

  /// The drag began, and ended (dropped or not).
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnd;

  /// [files] as this machine's paths, at once (a local project's): the
  /// window drags them on itself the moment the pointer leaves it.
  final List<String> Function()? localPaths;

  /// [files] as this machine's paths, for other apps once the drag leaves
  /// the window (a remote project's downloaded first); null when they are
  /// not to be had. None: the drag stays in the window.
  final Future<List<String>?> Function()? outward;

  @override
  State<FileDraggable> createState() => _FileDraggableState();
}

class _FileDraggableState extends State<FileDraggable> {
  /// Out of the window, the system's drag: the app's own shows nothing.
  final ValueNotifier<bool> _out = ValueNotifier(false);

  /// Whether the app's own drag goes on (the pointer held down).
  bool _dragging = false;

  /// The window whose drag [WindowControls.armFileDrag] armed, while it
  /// watches for the pointer to leave it (macOS: a Flutter view sees too
  /// little of the pointer once out).
  int? _armed;

  /// Whether that window watches, as it answered.
  bool _watched = false;

  @override
  void dispose() {
    _disarm();
    _out.dispose();
    super.dispose();
  }

  bool get _goesOut => widget.outward != null && WindowControls.canDragFilesOut;

  void _arm() {
    final viewId = View.of(context).viewId;
    _armed = viewId;
    _watched = false;
    FileDrops.setDragOut(viewId, _left);
    unawaited(
      WindowControls.armFileDrag(
        widget.localPaths?.call(),
        viewId: viewId,
      ).then((watched) => _watched = watched && _armed == viewId),
    );
  }

  void _disarm() {
    final viewId = _armed;
    if (viewId == null) return;
    _armed = null;
    _watched = false;
    FileDrops.setDragOut(viewId, null);
    unawaited(WindowControls.disarmFileDrag(viewId: viewId));
  }

  /// The window saw the pointer leave it: [began] dragging the files on
  /// itself, else they are this machine's first.
  void _left(bool began) {
    if (!_dragging || _out.value) return;
    _out.value = true;
    if (!began) _goOut(_armed ?? View.of(context).viewId);
  }

  /// The pointer left the window with the files (a window that does not
  /// watch): the system drags them on, once they are this machine's.
  void _update(DragUpdateDetails details) {
    if (_watched || _out.value) return;
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    if ((Offset.zero & size).contains(details.globalPosition)) return;
    _out.value = true;
    _goOut(view.viewId);
  }

  void _goOut(int viewId) {
    final outward = widget.outward;
    if (outward == null) return;
    unawaited(() async {
      final paths = await outward().catchError((Object _) => null);
      // Let go while they came: nothing to drag on.
      final began =
          paths != null &&
          _dragging &&
          await WindowControls.startFileDrag(paths, viewId: viewId);
      if (!began && mounted && _dragging) _out.value = false;
    }());
  }

  @override
  Widget build(BuildContext context) => Draggable<FileDragData>(
    data: FileDragData(widget.files),
    // The composer places what is let go at the pointer.
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: ValueListenableBuilder(
      valueListenable: _out,
      builder: (context, out, _) =>
          out ? const SizedBox.shrink() : _Feedback(widget.files),
    ),
    onDragStarted: () {
      _dragging = true;
      _out.value = false;
      if (_goesOut) _arm();
      widget.onDragStarted?.call();
    },
    onDragUpdate: _goesOut ? _update : null,
    onDragEnd: (_) {
      _disarm();
      _dragging = false;
      _out.value = false;
      widget.onDragEnd?.call();
    },
    child: widget.child,
  );
}

/// What follows the pointer: a tag of the first file, beside it.
class _Feedback extends StatelessWidget {
  const _Feedback(this.files);

  final List<ComposerFile> files;

  @override
  Widget build(BuildContext context) {
    final first = files.first;
    return Transform.translate(
      offset: const Offset(14, 6),
      child: Material(
        type: MaterialType.transparency,
        child: Opacity(
          opacity: .9,
          child: Container(
            padding: const EdgeInsets.fromLTRB(5, 2, 6, 2),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: themeColors['chat.requestBorder']),
              boxShadow: [
                BoxShadow(
                  color: themeColors['widget.shadow'],
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (first.directory)
                  FolderIcon(first.name, size: 14)
                else
                  FileIcon(first.name, size: 15),
                const SizedBox(width: 5),
                Text(
                  files.length == 1
                      ? first.name
                      : '${first.name} +${files.length - 1}',
                  style: TextStyle(color: AppColors.text, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

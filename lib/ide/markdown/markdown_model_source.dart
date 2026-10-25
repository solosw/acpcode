import 'dart:async';

import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/services.dart';

/// A markdown document's model as a [MarkdownController]'s text: the
/// preview edits the text the source tab, the agent and saving have, and
/// Undo is the model's, one for both views.
class EditorModelMarkdownSource implements MarkdownTextSource {
  EditorModelMarkdownSource(this.model, {this.onEdited});

  final EditorDocumentModel model;

  /// Told after the preview changed the text (an edit, Undo, Redo).
  final VoidCallback? onEdited;

  @override
  String get text => model.text;

  @override
  void Function() listen(void Function(List<MdTextEdit> edits) onEdits) {
    final subscription = model.changes.listen(
      (event) => onEdits([
        for (final change in event.changes)
          MdTextEdit(
            change.rangeOffset,
            change.rangeOffset + change.rangeLength,
            change.text,
          ),
      ]),
    );
    return () => unawaited(subscription.cancel());
  }

  @override
  void edit(
    int start,
    int end,
    String text, {
    required TextSelection before,
    required TextSelection after,
    required bool join,
  }) {
    if (!join) model.closeUndoGroup();
    final changed = model.applyOffsetEdits(
      [EditorOffsetEdit(start, end, text)],
      selectionsBefore: [before],
      selectionsAfter: [after],
      coalesce: join,
    );
    if (changed) onEdited?.call();
  }

  @override
  void breakStep() => model.closeUndoGroup();

  @override
  bool get canUndo => model.canUndo;

  @override
  bool get canRedo => model.canRedo;

  @override
  bool undo() {
    if (!model.undo()) return false;
    onEdited?.call();
    return true;
  }

  @override
  bool redo() {
    if (!model.redo()) return false;
    onEdited?.call();
    return true;
  }

  @override
  TextSelection? get restoredSelection => model.restoredSelections?.firstOrNull;
}

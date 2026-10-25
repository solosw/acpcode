import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/ide/markdown/markdown_model_source.dart';
import 'package:baocode/ide/markdown/markdown_preview.dart';
import 'package:baocode/ide/markdown/markdown_task_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Markdown as people write it, each way of writing a thing kept.
const _written =
    '---\n'
    'title: Notes\n'
    '---\n'
    '\n'
    'Title\n'
    '=====\n'
    '\n'
    '* one\n'
    '+ two\n'
    '\n'
    '1) first\n'
    '2) second\n'
    '\n'
    'A [reference][ref], a [collapsed][] one and [ref].\n'
    '\n'
    '- item\n'
    '\n'
    '  ```dart\n'
    '  final x = 1;\n'
    '  ```\n'
    '\n'
    '- [ ] open\n'
    '- [x] done\n'
    '\n'
    'Hard break  \n'
    'and a backslash\\\n'
    'break.\n'
    '\n'
    'A note[^1].\n'
    '\n'
    '![shot](img/shot.png "A title")\n'
    '\n'
    '<div align="center">\n'
    '  <b>HTML</b>\n'
    '</div>\n'
    '\n'
    '~~~\n'
    'tildes\n'
    '~~~\n'
    '\n'
    '    indented code\n'
    '\n'
    '> quoted\n'
    '> > nested\n'
    '\n'
    '| a | b |\n'
    '|:--|--:|\n'
    '| 1 | 2 |\n'
    '\n'
    '\$\$\n'
    'x^2\n'
    '\$\$\n'
    '\n'
    'Inline \$y\$, <u>under</u>, ~~gone~~, ***both***.\n'
    '\n'
    '```mermaid\n'
    'graph TD; A-->B\n'
    '```\n'
    '\n'
    '[ref]: https://example.com "Example"\n'
    '[collapsed]: https://example.org\n'
    '[^1]: The note.\n'
    'Trailing tab\t\n';

MarkdownController _of(EditorDocumentModel model, {VoidCallback? onEdited}) =>
    MarkdownController.of(EditorModelMarkdownSource(model, onEdited: onEdited));

/// The lines of [after] that are not [before]'s, by their numbers.
List<int> _changedLines(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  expect(b.length, a.length);
  return [
    for (var i = 0; i < a.length; i++)
      if (a[i] != b[i]) i,
  ];
}

Future<void> _pumpPreview(
  WidgetTester tester,
  EditorDocumentModel model, {
  VoidCallback? onEdited,
}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: IdeMarkdownPreview(
          path: '/project/notes.md',
          model: model,
          pathContext: p.posix,
          readBytes: (_) async => throw StateError('not read'),
          onEdited: onEdited,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the preview edits the document\'s model', () {
    for (final (name, text) in [
      ('LF', _written),
      ('CRLF', _written.replaceAll('\n', '\r\n')),
    ]) {
      testWidgets('opened and left, the text is as it was ($name)', (
        tester,
      ) async {
        final model = EditorDocumentModel(text);
        var edits = 0;
        await _pumpPreview(tester, model, onEdited: () => edits++);
        // Shown, clicked into, scrolled through.
        await tester.tapAt(const Offset(300, 200));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        expect(model.text, text);
        expect(model.isDirty, isFalse);
        expect(model.version, 0);
        expect(model.canUndo, isFalse);
        expect(edits, 0);
      });
    }

    testWidgets('a task ticked: its line alone changes, the tab told', (
      tester,
    ) async {
      final model = EditorDocumentModel(_written);
      var edits = 0;
      await _pumpPreview(tester, model, onEdited: () => edits++);
      await tester.tap(find.byType(MarkdownTaskBox).first);
      await tester.pumpAndSettle();
      expect(_changedLines(_written, model.text), [
        _written.split('\n').indexOf('- [ ] open'),
      ]);
      expect(model.text, contains('- [x] open'));
      expect(model.isDirty, isTrue);
      expect(edits, 1);
    });

    test('a character typed: its line alone changes', () {
      for (final text in [_written, _written.replaceAll('\n', '\r\n')]) {
        final model = EditorDocumentModel(text);
        final controller = _of(model);
        final at = text.indexOf('Hard break');
        controller.selection = TextSelection.collapsed(offset: at + 4);
        controller.replace(at + 4, at + 4, '!', kind: MdEditKind.typing);
        expect(model.text, text.replaceFirst('Hard break', 'Hard! break'));
        expect(controller.text, model.text);
        expect(
          _changedLines(
            text.replaceAll('\r\n', '\n'),
            model.text.replaceAll('\r\n', '\n'),
          ),
          [text.replaceAll('\r\n', '\n').split('\n').indexOf('Hard break  ')],
        );
        controller.dispose();
      }
    });

    test('the source tab\'s and the agent\'s changes show, the caret moved '
        'along', () {
      final model = EditorDocumentModel('# Title\n\nSome text.\n');
      final controller = _of(model);
      var told = 0;
      controller.addListener(() => told++);
      final caret = '# Title\n\nSome '.length;
      controller.selection = TextSelection.collapsed(offset: caret);
      told = 0;
      // Typed in the source, before the caret.
      model.applyOffsetEdits([const EditorOffsetEdit(2, 2, 'My ')]);
      expect(controller.text, '# My Title\n\nSome text.\n');
      expect(controller.selection.baseOffset, caret + 3);
      expect(told, 1);
      // After it: the caret stays.
      model.applyOffsetEdits([
        EditorOffsetEdit(controller.length - 1, controller.length - 1, '!'),
      ]);
      expect(controller.selection.baseOffset, caret + 3);
      // The agent rewrote the file; it was reloaded.
      model.replaceText('# My Title\n\nIntro.\n\nSome text.!\n');
      expect(controller.text, model.text);
      expect(controller.infoOf(2).kind, MdLineKind.paragraph);
      expect(controller.lines.content(4), 'Some text.!');
      controller.dispose();
    });

    test('Undo is the model\'s, one for the source and the preview', () {
      final model = EditorDocumentModel('one\n\ntwo\n');
      final controller = _of(model);
      // Typed in the preview, a word: one step.
      controller.selection = const TextSelection.collapsed(offset: 3);
      for (final (i, char) in ' more'.split('').indexed) {
        controller.replace(3 + i, 3 + i, char, kind: MdEditKind.typing);
      }
      expect(model.text, 'one more\n\ntwo\n');
      // Typed in the source.
      model.closeUndoGroup();
      model.applyOffsetEdits([const EditorOffsetEdit(13, 13, '!')]);
      expect(controller.text, 'one more\n\ntwo!\n');

      // The preview's Undo takes back the source's typing first.
      expect(controller.undo(), isTrue);
      expect(model.text, 'one more\n\ntwo\n');
      expect(controller.text, model.text);
      // The source's Undo takes back the preview's, as one step, with its
      // caret.
      expect(model.undo(), isTrue);
      expect(controller.text, 'one\n\ntwo\n');
      expect(model.restoredSelections, [
        const TextSelection.collapsed(offset: 3),
      ]);
      expect(controller.redo(), isTrue);
      expect(model.text, 'one more\n\ntwo\n');
      expect(controller.selection, const TextSelection.collapsed(offset: 8));
      expect(model.isDirty, isTrue);
      expect(controller.undo(), isTrue);
      expect(model.isDirty, isFalse);
      controller.dispose();
    });

    test('an edit made in a group is one step of the model\'s', () {
      final model = EditorDocumentModel('a\nb\n');
      final controller = _of(model);
      controller.group(() {
        controller.replace(0, 0, '- ');
        controller.replace(4, 4, '- ');
      });
      expect(model.text, '- a\n- b\n');
      expect(model.undo(), isTrue);
      expect(model.text, 'a\nb\n');
      expect(model.canUndo, isFalse);
      controller.dispose();
    });
  });
}

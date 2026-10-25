import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _tag = MdAtoms.encode('tag lib/main.dart');

void main() {
  group('MdAtoms', () {
    test('an atom is its data between the marks; the marks in it go', () {
      expect(_tag, '\uE000tag lib/main.dart\uE001');
      expect(MdAtoms.encode('a\uE000b\uE001'), '\uE000ab\uE001');
      expect(MdAtoms.strip('x $_tag y'), 'x tag lib/main.dart y');
    });

    test('read back where they are, a lone mark text', () {
      final text = 'see $_tag and \uE000 then ${MdAtoms.encode('2')}';
      final runs = MdAtoms.parse(text);
      expect(runs, hasLength(2));
      expect(text.substring(runs[0].start, runs[0].end), _tag);
      expect(MdAtoms.data(runs[0], text), 'tag lib/main.dart');
      // The lone open mark is text: the atom after it is the later one.
      expect(MdAtoms.data(runs[1], text), '2');
      expect(MdAtoms.parse('a \uE001 b \uE000 c'), isEmpty);
      // Only those wholly in the range.
      expect(MdAtoms.parse(text, 0, runs[0].end - 1), isEmpty);
    });
  });

  group('a plain controller', () {
    test('every line a paragraph, its runs only atoms', () {
      final controller = MarkdownController(
        text: '# not a heading\n- [ ] nor a task *nor emphasis*\n$_tag `x`',
        plain: true,
      );
      for (var line = 0; line < 3; line++) {
        expect(controller.infoOf(line).kind, MdLineKind.paragraph);
      }
      expect(controller.inlinesOf(0), isEmpty);
      expect(controller.inlinesOf(1), isEmpty);
      expect(controller.inlinesOf(2).single.kind, MdInlineKind.atom);
    });

    test('an amend is undone with the step before it', () {
      final controller = MarkdownController(plain: true);
      controller.replace(
        0,
        0,
        _tag,
        selection: TextSelection.collapsed(offset: _tag.length),
      );
      controller.amend(_tag.length, _tag.length, ' ');
      expect(controller.text, '$_tag ');
      // The caret where it was.
      expect(controller.selection.baseOffset, _tag.length);
      controller.undo();
      expect(controller.text, '');
      controller.redo();
      expect(controller.text, '$_tag ');
    });

    test('an unrecorded change moves the selection along, Undo blind to '
        'it', () {
      final controller = MarkdownController(
        text: 'hello',
        selection: const TextSelection.collapsed(offset: 5),
        plain: true,
      );
      controller.replaceUnrecorded(0, 0, '> ');
      expect(controller.text, '> hello');
      expect(controller.selection, const TextSelection.collapsed(offset: 7));
      expect(controller.canUndo, isFalse);

      controller.replace(7, 7, '!');
      expect(controller.canUndo, isTrue);
      controller.forgetUndo();
      expect(controller.canUndo, isFalse);
      expect(controller.text, '> hello!');
    });
  });

  testWidgets('an input method is told each atom as one character, and '
      'nothing it types becomes one', (tester) async {
    final controller = MarkdownController(
      text: 'a${_tag}b',
      selection: TextSelection.collapsed(offset: 1 + _tag.length),
      plain: true,
    );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFFFFFFFF),
        builder: (context, _) => MarkdownEditor(
          controller: controller,
          focusNode: focus,
          style: const MarkdownEditorStyle(
            text: TextStyle(fontSize: 14, color: Color(0xFF000000)),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    final state = tester.state<MarkdownEditorState>(
      find.byType(MarkdownEditor),
    );
    final told = state.currentTextEditingValue!;
    expect(told.text, 'a\uFFFCb');
    expect(told.selection, const TextSelection.collapsed(offset: 2));

    // Typed after it: the atom stays itself.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'a\uFFFCxb',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    expect(controller.text, 'a${_tag}xb');

    // The marks, or the stand-in, typed: text, nothing of them kept.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'a\uFFFCx\uE000y\uE001\uFFFCb',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await tester.pump();
    expect(controller.text, 'a${_tag}xyb');
    expect(MdAtoms.parse(controller.text), hasLength(1));
  });
}

import 'dart:math';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

List<MdLineKind> kindsOf(String text) {
  final blocks = MdBlocks(MdLines(text));
  return [for (var i = 0; i < blocks.length; i++) blocks.info(i).kind];
}

void main() {
  test('lines keep the text as it is, \\r\\n and all', () {
    const text = 'one\r\ntwo\r\n\r\nthree';
    final lines = MdLines(text);
    expect(lines.text, text);
    expect(lines.lineCount, 4);
    expect(lines.content(0), 'one');
    expect(lines.lineEnd(0), 3);
    expect(lines.newline, '\r\n');
    lines.replace(1, 2, 'N');
    expect(lines.text, 'oNe\r\ntwo\r\n\r\nthree');
    final id = lines.idOf(1);
    lines.replace(lines.lineStart(1), lines.lineStart(1), 'x');
    expect(lines.idOf(1), id, reason: 'an edited line keeps its id');
    expect(lines.substring(3, 9), '\r\nxtwo');
  });

  test('each line is read as what it is', () {
    expect(
      kindsOf(
        [
          '# Title ##',
          '',
          'text',
          '- one',
          '  - two',
          '1) three',
          '- [x] done',
          '> quote',
          '',
          '```ts',
          'code',
          '```',
          '~~~',
          'more',
          '~~~',
          '',
          '| a | b |',
          '|---|---|',
          '| 1 | 2 |',
          '',
          r'$$',
          'x^2',
          r'$$',
          r'$$y$$',
          '<div>',
          'hi',
          '</div>',
          '',
          '[1]: https://a.b',
          '[^1]: note',
          '',
          '***',
          'Setext',
          '======',
          '',
          '    indented code',
        ].join('\n'),
      ),
      [
        MdLineKind.heading,
        MdLineKind.blank,
        MdLineKind.paragraph,
        MdLineKind.item,
        MdLineKind.item,
        MdLineKind.item,
        MdLineKind.item,
        MdLineKind.paragraph,
        MdLineKind.blank,
        MdLineKind.fenceOpen,
        MdLineKind.fence,
        MdLineKind.fenceClose,
        MdLineKind.fenceOpen,
        MdLineKind.fence,
        MdLineKind.fenceClose,
        MdLineKind.blank,
        MdLineKind.tableHead,
        MdLineKind.tableDelimiter,
        MdLineKind.tableRow,
        MdLineKind.blank,
        MdLineKind.mathOpen,
        MdLineKind.math,
        MdLineKind.mathClose,
        MdLineKind.mathLine,
        MdLineKind.html,
        MdLineKind.html,
        MdLineKind.html,
        MdLineKind.blank,
        MdLineKind.definition,
        MdLineKind.footnote,
        MdLineKind.blank,
        MdLineKind.rule,
        MdLineKind.heading,
        MdLineKind.setextUnderline,
        MdLineKind.blank,
        MdLineKind.indentedCode,
      ],
    );
  });

  test('marks and text: a heading\'s, an item\'s, a quote\'s', () {
    final blocks = MdBlocks(MdLines('## Title ##\n  - [ ] task\n> > deep'));
    final heading = blocks.info(0);
    expect(
      (heading.level, heading.contentStart, heading.contentEnd),
      (2, 3, 8),
    );
    final item = blocks.info(1);
    expect(item.level, 0);
    expect((item.markerStart, item.markerEnd), (2, 3));
    expect((item.task, item.taskStart, item.contentStart), (1, 4, 8));
    final quote = blocks.info(2);
    expect((quote.quoteDepth, quote.contentStart), (2, 4));
  });

  test('a list\'s items nest by their indent', () {
    final blocks = MdBlocks(MdLines('- a\n  - b\n    - c\n- d\n  more'));
    expect([for (var i = 0; i < 5; i++) blocks.info(i).level], [0, 1, 2, 0, 1]);
  });

  test('read again after an edit, the lines are as read from the start', () {
    final random = Random(7);
    const pieces = [
      '\n',
      '\n\n',
      '# ',
      '- ',
      '1. ',
      '> ',
      '```',
      '```js\n',
      '~~~\n',
      '| a | b |\n|---|---|\n',
      '| c |',
      r'$$',
      r'$$'
          '\n',
      '<div>\n',
      '<!-- ',
      '-->',
      '---',
      '===',
      '[x]: y\n',
      'text ',
      '    ',
      '**b**',
      '- [ ] ',
      '---\n',
    ];
    final lines = MdLines('start\n');
    final blocks = MdBlocks(lines);
    for (var step = 0; step < 3000; step++) {
      final length = lines.length;
      final start = random.nextInt(length + 1);
      final end = min(length, start + random.nextInt(6));
      final text = random.nextInt(4) == 0
          ? ''
          : pieces[random.nextInt(pieces.length)];
      final splice = lines.replace(start, end, text);
      blocks.update(splice);
      final fresh = MdBlocks(MdLines(lines.text));
      expect(blocks.length, fresh.length);
      for (var i = 0; i < fresh.length; i++) {
        expect(
          blocks.info(i),
          fresh.info(i),
          reason: 'line $i of ${lines.text.replaceAll('\n', r'\n')}',
        );
      }
      expect(blocks.definitions, fresh.definitions);
    }
  });
}

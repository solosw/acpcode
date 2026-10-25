import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_editor.dart';
import 'package:baocode/stash/stash_markdown.dart';
import 'package:baocode/stash/stash_note_editor.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Markdown written by hand and by agents, in the ways the editor itself
/// would not write it.
const _written = '''
Title line
==========

Sub *title*
---

* star item
* another, with a [reference link][ref] and a [collapsed][] one
  continued lazily
    + nested plus

1) first
2) second

   ```js
   code in an item
   ```

- [ ] open task
- [x] done task

Hard break with spaces
and with a backslash\\
then the end.

A footnote[^1] and ![a picture](1/shot.png "its title") inline.

<div align="center">
  <b>HTML block</b>
</div>

~~~python
def f():
    return "~~~"
~~~

    indented code

> quote
> > nested quote
>
> back

| a | b |
|:--|--:|
| 1 | **2** |

\$\$
x^2
\$\$

Inline \$e = mc^2\$ and <span style="color:red">red</span> <u>under</u> ~~struck~~.

***

[ref]: https://example.com "Example"
[collapsed]: <https://example.com/a b>
[^1]: The note, with `code`.
Trailing spaces stay\t \t''';

Future<(MemoryStashDisk, StashStore, int)> _stored(String body) async {
  final disk = MemoryStashDisk();
  final store = StashStore(disk);
  final note = await store.create(body: body);
  return (disk, store, note.id);
}

Future<void> _show(WidgetTester tester, StashStore store, int id) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [AppLocalizations.delegate],
      home: Scaffold(
        body: StashNoteEditor(
          store: store,
          id: id,
          create: (body) async => id,
          autofocus: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MarkdownController _controllerIn(WidgetTester tester) =>
    tester.state<MarkdownEditorState>(find.byType(MarkdownEditor)).controller;

List<MdInline> _runs(String text) => parseInline(text, 0, text.length);

void main() {
  test('the editor keeps the text as written', () {
    final controller = StashEditor.controllerFor(_written);
    expect(controller.text, _written);
    // Each line its own, as written.
    expect(controller.lines.lineCount, _written.split('\n').length);
    final crlf = _written.replaceAll('\n', '\r\n');
    expect(StashEditor.controllerFor(crlf).text, crlf);
  });

  testWidgets('opened and left as it was, the file is not written again', (
    tester,
  ) async {
    final (disk, store, id) = await tester.runAsync(
      () => _stored(_written),
    ) as (MemoryStashDisk, StashStore, int);
    final file = disk.files[id]!;
    final written = disk.modified[id];
    await _show(tester, store, id);
    final controller = _controllerIn(tester);
    // The caret through every line: marks shown and hidden again.
    for (var line = 0; line < controller.lines.lineCount; line++) {
      controller.selection = TextSelection.collapsed(
        offset: controller.lineStart(line),
      );
      await tester.pump();
    }
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.length,
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(disk.files[id], file);
    expect(disk.modified[id], written);
  });

  testWidgets('one character typed changes that line only', (tester) async {
    final (disk, store, id) = await tester.runAsync(
      () => _stored(_written),
    ) as (MemoryStashDisk, StashStore, int);
    final before = disk.files[id]!.split('\n');
    await _show(tester, store, id);
    final controller = _controllerIn(tester);
    final line = _written.split('\n').indexOf('2) second');
    controller.selection = TextSelection.collapsed(
      offset: controller.lineEnd(line),
    );
    await tester.pump();
    controller.replace(
      controller.selection.baseOffset,
      controller.selection.baseOffset,
      '!',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    final after = disk.files[id]!.split('\n');
    expect(after.length, before.length);
    final changed = [
      for (var i = 0; i < after.length; i++)
        if (after[i] != before[i]) after[i],
    ];
    // The line, and when the stash was changed.
    expect(changed, hasLength(2));
    expect(changed.first, startsWith('updated: '));
    expect(changed.last, '2) second!');
  });

  test('pictures and files are read where they are, none in code', () {
    const markdown =
        'a ![](1/a.png) [report.pdf](1/report.pdf) [web](https://x.dev)\n'
        '<img src="1/b.png" width="120">\n'
        '```\n![](1/c.png)\n```\n'
        '[card](https://x.dev "card") [x\\]y](/abs/x]y.txt)';
    final runs = stashRuns(markdown);
    expect(
      [for (final run in runs) run.path],
      ['1/a.png', '1/report.pdf', '1/b.png', '/abs/x]y.txt'],
    );
    expect(runs[1].name, 'report.pdf');
    expect(runs[3].name, 'x]y');
    expect(markdown.substring(runs[0].start, runs[0].end), '![](1/a.png)');
  });

  test('cards, files and pictures are written as markdown reads them', () {
    expect(stashPictureMarkdown('1/a b.png'), '![](<1/a b.png>)');
    expect(stashFileMarkdown('a[1].txt', '1/a.txt'), '[a\\[1\\].txt](1/a.txt)');
    expect(
      stashCardMarkdown('Title', 'https://x.dev'),
      '[Title](https://x.dev "card")',
    );
    final card = _runs(stashCardMarkdown('T', 'https://x.dev'));
    expect(isStashCard(card.single), isTrue);
    final file = _runs(stashFileMarkdown('a', '/x/a.txt'));
    expect(isStashFile(file.single), isTrue);
    final link = _runs('[a](https://x.dev)');
    expect(isStashFile(link.single), isFalse);
    expect(isStashCard(link.single), isFalse);
  });

  test('a file is a path, a page is not', () {
    expect(isStashFileHref('/Users/a/b.pdf'), isTrue);
    expect(isStashFileHref('~/b.pdf'), isTrue);
    expect(isStashFileHref(r'C:\a\b.pdf'), isTrue);
    expect(isStashFileHref('12/report.pdf'), isTrue);
    expect(isStashFileHref('https://x.dev/a.pdf'), isFalse);
    expect(isStashFileHref('mailto:a@b.c'), isFalse);
    expect(isStashFileHref('#top'), isFalse);
    expect(isStashFileHref('stash:12'), isFalse);
  });
}

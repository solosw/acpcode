// A stash's text is markdown, edited as it is written (see bao_markdown):
// the file keeps what was typed, line for line.
//
// What markdown has no mark for is written as the HTML markdown allows
// inline: a color or a background as a `<span style>`, an underline as
// `<u>`, a picture's width as `<img width>`. Formulas are `$…$` and
// `$$…$$`, tables GitHub's. A link titled "card" (`[title](url "card")`)
// shows as a card; one to a path (`[name](12/report.pdf)`) as a file's
// tag.

import 'package:bao_markdown/bao_markdown.dart';

/// Whether [href] is a file here rather than a page: a path, absolute or
/// in the stash folder (`12/report.pdf`).
bool isStashFileHref(String href) {
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(href)) return false;
  if (href.startsWith('mailto:') || href.startsWith('#')) return false;
  return href.startsWith('/') ||
      href.startsWith('~/') ||
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(href) ||
      RegExp(r'^\d+/').hasMatch(href);
}

/// The title a link shown as a card has.
const stashCardTitle = 'card';

/// Whether [run] is a link shown as a card.
bool isStashCard(MdInline run) =>
    run.kind == MdInlineKind.link && run.title == stashCardTitle;

/// Whether [run] is a link to a file (shown as its tag).
bool isStashFile(MdInline run) =>
    run.kind == MdInlineKind.link &&
    run.title != stashCardTitle &&
    isStashFileHref(run.href ?? '');

/// [text] as a link's text: its brackets (and backslashes) escaped.
String stashLinkText(String text) =>
    text.replaceAllMapped(RegExp(r'[\\\[\]]'), (m) => '\\${m[0]}');

/// A link's text as it reads: its escapes undone.
String stashUnescape(String text) => text.replaceAllMapped(
  RegExp(
    r'\\([\\`*_{}\[\]()#+\-.!|~$<>"'
    "'"
    r'])',
  ),
  (m) => m[1]!,
);

String _destination(String href) =>
    RegExp(r'[\s()<>]').hasMatch(href) ? '<$href>' : href;

/// A picture at [src] (relative to the stash folder, absolute, or a url).
String stashPictureMarkdown(String src) => '![](${_destination(src)})';

/// A file's tag: [name], linked to [path].
String stashFileMarkdown(String name, String path) =>
    '[${stashLinkText(name)}](${_destination(path)})';

/// A link shown as a card: [title], to [url].
String stashCardMarkdown(String title, String url) =>
    '[${stashLinkText(title)}](${_destination(url)} "$stashCardTitle")';

/// A picture or a file in a stash's markdown: where its markdown is, and
/// what it is.
typedef StashRun = ({
  int start,
  int end,
  bool picture,
  String path,
  String name,
});

/// The pictures and files of [markdown], in order (none in code).
List<StashRun> stashRuns(String markdown) {
  final lines = MdLines(markdown);
  final blocks = MdBlocks(lines);
  return _runs(
    lines,
    (i) => blocks.info(i).hasInline
        ? parseInline(
            lines.content(i),
            blocks.info(i).contentStart,
            blocks.info(i).contentEnd,
            definitions: blocks.definitions,
          )
        : const [],
  );
}

/// The pictures and files of [controller]'s text, in order: its lines'
/// runs, as it keeps them.
List<StashRun> stashRunsOf(MarkdownController controller) =>
    _runs(controller.lines, controller.inlinesOf);

List<StashRun> _runs(
  MdLines lines,
  List<MdInline> Function(int line) inlinesOf,
) {
  final found = <StashRun>[];
  for (var i = 0; i < lines.lineCount; i++) {
    final text = lines.content(i);
    // Neither a link nor a picture.
    if (!text.contains('](') && !text.contains('<img')) continue;
    final start = lines.lineStart(i);
    void visit(List<MdInline> runs) {
      for (final run in runs) {
        final href = run.href ?? '';
        if (run.kind == MdInlineKind.image && href.isNotEmpty) {
          found.add((
            start: start + run.start,
            end: start + run.end,
            picture: true,
            path: href,
            name: '',
          ));
        } else if (isStashFile(run) && href.isNotEmpty) {
          final name = stashUnescape(
            text.substring(run.innerStart, run.innerEnd),
          );
          found.add((
            start: start + run.start,
            end: start + run.end,
            picture: false,
            path: href,
            name: name.isEmpty ? href.split(RegExp(r'[\\/]')).last : name,
          ));
        } else {
          visit(run.children);
        }
      }
    }

    visit(inlinesOf(i));
  }
  return found;
}

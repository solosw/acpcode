import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/services.dart';

import 'composer_embeds.dart';

/// The composer's text being edited: plain text, not markdown, its things
/// (tags, pictures' references, a paste's…) atoms in it, each a
/// [ComposerEmbed] the caret skips and Backspace deletes whole.
///
/// What an input method changes is told it with each thing one character
/// (see [MdAtoms.shown]): one that gives back what precedes what it
/// composes (an inline emoji's suggestion) leaves those things be, and
/// nothing it types becomes one.
class ComposerController extends MarkdownController {
  ComposerController({super.text, super.selection}) : super(plain: true);

  /// The text as it shows, each thing one character (U+FFFC).
  String get shownText => composerShownText(text);

  /// The text as the message says it, each thing as its text.
  String get plainText => composerPlainText(text);

  /// The things in the text, with where each is.
  Iterable<({int start, int end, ComposerEmbed embed})> get embeds =>
      composerEmbedsIn(text);

  /// Where [offset] of the text is in [shownText] (inside a thing, at its
  /// start).
  int shownOffset(int offset) {
    var shown = offset;
    for (final run in MdAtoms.parse(text)) {
      if (run.start >= offset) break;
      shown -= offset >= run.end
          ? run.end - run.start - 1
          : offset - run.start;
    }
    return shown;
  }

  /// The offset of the text where [shown], an offset of [shownText], is.
  int offsetOfShown(int shown) {
    var offset = shown;
    for (final run in MdAtoms.parse(text)) {
      if (run.start >= offset) break;
      offset += run.end - run.start - 1;
    }
    return offset;
  }

  /// Everything taken out, as one step of Undo's.
  void clear() {
    if (length == 0) return;
    breakUndo();
    replace(0, length, '', selection: const TextSelection.collapsed(offset: 0));
    breakUndo();
  }
}

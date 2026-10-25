// What the perf app's agents say: markdown as a coding agent writes it
// (prose in Chinese and English, lists, tables, code in several languages,
// file references), and the files the IDE's scenarios open. Generated from
// a seed, so that every run renders the same text.

import 'dart:math';

/// Markdown and code from a seed: the same seed, the same text.
class PerfContent {
  PerfContent(int seed) : _random = Random(seed);

  final Random _random;

  T _pick<T>(List<T> items) => items[_random.nextInt(items.length)];
  int _between(int min, int max) => min + _random.nextInt(max - min + 1);

  static const _zh = [
    '先确认一下现有的实现：滚动位置由 `SmoothScrollController` 管理，列表本身是虚拟化的',
    '这里的问题在于每次增量更新都会触发整棵子树重建',
    '我看了 [chat_history_view.dart](lib/chat/chat_history_view.dart) 的布局逻辑',
    '改动之后，只有正在输出的那一行会重新排版，其余行保持缓存',
    '为了避免返工，我先把测试补上，再动实现',
    '这个函数在热路径上，**不能**在里面分配大对象',
    '测试全部通过，`flutter analyze` 也没有新的警告',
    '注意 Windows 上输入法的候选框位置依赖光标几何信息',
    '下面是修改后的版本，主要变化是把解析结果按块缓存起来',
    '如果文件很大，按行增量分词比整篇重新分词快得多',
  ];

  static const _en = [
    'The list only lays out the rows in view, so the cost should not grow '
        'with the length of the conversation',
    'I traced the extra frame to the tokenizer answering after the edit',
    'See `lib/ide/ide_editor.dart:412` for where the caret is revealed',
    'This keeps the **hot path** free of allocations proportional to the '
        'document',
    'The change is small: the parsed blocks are cached by their source text',
    'Running the analyzer and the related tests now',
    'Nothing else depends on this, so it is safe to inline',
    'With that in place the streaming row is the only one rebuilt per delta',
    'I also checked the [design notes](docs/stash.md) for the expected '
        'behavior',
    'Each delta appends to the last block instead of re-parsing the whole '
        'message',
  ];

  static const _identifiers = [
    'session',
    'transcript',
    'viewport',
    'lineStarts',
    'snapshot',
    'tokens',
    'controller',
    'composer',
    'feed',
    'layout',
    'offset',
    'cache',
    'delta',
    'buffer',
    'theme',
    'range',
  ];

  static const _types = [
    'ChatSession',
    'DocumentSnapshot',
    'EditorSurface',
    'TextMateDocument',
    'ChatHistoryView',
    'WheelGlide',
    'IdeWorkspace',
    'Transcript',
  ];

  static const _files = [
    'lib/chat/chat_history_view.dart',
    'lib/chat/chat_session.dart',
    'lib/chat/widgets/markdown_view.dart',
    'lib/ide/ide_editor.dart',
    'lib/kernel/transcript.dart',
    'packages/bao_editor/lib/monaco/flutter/editor_surface.dart',
    'lib/workspace/workspace.dart',
    'test/chat/history_scroll_test.dart',
  ];

  String _sentence() =>
      _random.nextBool() ? '${_pick(_zh)}。' : '${_pick(_en)}.';

  String paragraph() =>
      [for (var i = _between(2, 4); i > 0; i--) _sentence()].join(' ');

  String _list({bool numbered = false}) {
    final n = _between(3, 7);
    return [
      for (var i = 1; i <= n; i++)
        '${numbered ? '$i.' : '-'} ${_random.nextInt(3) == 0 ? '`${_pick(_files)}`：' : ''}${_sentence()}',
    ].join('\n');
  }

  String _table() {
    final columns = _between(3, 5);
    final rows = _between(4, 10);
    const headers = ['文件', 'Before', 'After', 'Δ', 'Notes'];
    String cell(int column) => switch (column) {
      0 => '`${_pick(_files).split('/').last}`',
      1 || 2 => '${_between(1, 400)}.${_between(0, 9)} ms',
      3 => '${_random.nextBool() ? '-' : '+'}${_between(1, 80)}%',
      _ => _pick(const ['ok', '待确认', 'hot path', 'cached', 'n/a']),
    };
    return [
      '| ${headers.take(columns).join(' | ')} |',
      '|${List.filled(columns, ' --- ').join('|')}|',
      for (var r = 0; r < rows; r++)
        '| ${[for (var c = 0; c < columns; c++) cell(c)].join(' | ')} |',
    ].join('\n');
  }

  /// A fenced block of [lines] lines in a language picked at random.
  String codeBlock({int? lines}) {
    final language = _pick(const [
      'dart',
      'typescript',
      'python',
      'json',
      'bash',
      'diff',
    ]);
    return '```$language\n${code(language, lines ?? _between(8, 40))}\n```';
  }

  /// [lines] lines of [language] that look like it.
  String code(String language, int lines) {
    final out = <String>[];
    var depth = 0;
    String indent() => '  ' * depth;
    while (out.length < lines) {
      final name = _pick(_identifiers);
      final type = _pick(_types);
      final n = _between(0, 99);
      switch (language) {
        case 'dart':
          if (depth == 0) {
            out.add(
              '${indent()}$type _$name$n($type $name, {int limit = $n}) {',
            );
            depth++;
          } else if (depth < 3 && _random.nextInt(4) == 0) {
            out.add('${indent()}for (var i = 0; i < $name.length; i++) {');
            depth++;
          } else if (_random.nextInt(5) == 0) {
            depth--;
            out.add('${indent()}}');
          } else {
            out.add(
              '${indent()}final ${name}At$n = $name.${_pick(_identifiers)}(i + $n); // ${_pick(_en).split(' ').take(4).join(' ')}',
            );
          }
        case 'typescript':
          if (depth == 0) {
            out.add(
              '${indent()}export function $name$n(input: $type, limit = $n): number {',
            );
            depth++;
          } else if (_random.nextInt(5) == 0) {
            depth--;
            out.add('${indent()}}');
          } else {
            out.add(
              '${indent()}const ${name}_$n = input.${_pick(_identifiers)}?.map((x) => x * $n) ?? [];',
            );
          }
        case 'python':
          if (depth == 0) {
            out.add('def ${name}_$n(${_pick(_identifiers)}, limit=$n):');
            depth = 1;
          } else if (_random.nextInt(6) == 0) {
            depth = 0;
            out.add('');
          } else {
            out.add(
              '    ${name}_$n = [x for x in ${_pick(_identifiers)} if x > $n]',
            );
          }
        case 'json':
          out.add(
            '  "$name$n": { "$type": $n, "enabled": ${_random.nextBool()} },',
          );
        case 'bash':
          out.add(
            _pick([
              'flutter test test/chat/${name}_test.dart --plain-name "$type"',
              'rg -n "$type" lib | head -$n',
              'git diff --stat HEAD~$n -- lib/',
              'dart analyze lib/chat',
            ]),
          );
        default: // diff
          out.add(
            '${_pick(const ['+', '-', ' '])}  final $name = $type.${_pick(_identifiers)}($n);',
          );
      }
    }
    while (depth > 0 && language != 'python') {
      depth--;
      out.add('${indent()}}');
    }
    return out.join('\n');
  }

  /// A reply of about [chars] characters; [heavy] has more and longer
  /// code blocks and tables.
  String reply(int chars, {bool heavy = false}) {
    final blocks = <String>[];
    var length = 0;
    while (length < chars) {
      final roll = _random.nextInt(heavy ? 10 : 14);
      final block = switch (roll) {
        0 => '## ${_pick(_en).split(' ').take(5).join(' ')}',
        1 => '### ${_pick(_zh).split('：').first}',
        2 || 3 => _list(numbered: roll == 3),
        4 => _table(),
        5 || 6 => codeBlock(lines: heavy ? _between(30, 80) : null),
        7 => '> ${_sentence()}',
        _ => paragraph(),
      };
      blocks.add(block);
      length += block.length + 2;
    }
    return blocks.join('\n\n');
  }

  /// A thought of about [chars] characters: prose only.
  String thought(int chars) {
    final out = StringBuffer();
    while (out.length < chars) {
      out
        ..write(paragraph())
        ..write('\n\n');
    }
    return out.toString().trimRight();
  }

  /// What `cat -n` prints of [lines] lines of Dart, as Read returns it.
  String numberedFile(int lines) {
    final text = code('dart', lines).split('\n');
    return [
      for (final (i, line) in text.indexed)
        '${(i + 1).toString().padLeft(6)}\t$line',
    ].join('\n');
  }

  /// A command's long output.
  String commandOutput(int lines) => [
    for (var i = 0; i < lines; i++)
      '00:${(i ~/ 10).toString().padLeft(2, '0')} +$i: ${_pick(_files)}: ${_pick(_types)} ${_pick(_en).split(' ').take(6).join(' ')}',
  ].join('\n');

  String filePath() => _pick(_files);
  String identifier() => _pick(_identifiers);
}

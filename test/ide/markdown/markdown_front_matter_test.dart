import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/markdown/markdown_front_matter.dart';

void main() {
  test('a skill\'s front matter reads as its keys and values', () {
    final properties = parseFrontMatterProperties(
      'name: baocode-stash\n'
      'description: "The user\'s Stash: ideas, \\"bugs\\""\n'
      'allowed-tools:\n'
      '  - "Read(//Users/me/Stash/**)"\n'
      '  - Edit\n'
      'tags: [a, \'it\'\'s\']\n'
      '# a comment\n'
      'notes: >\n'
      '  two\n'
      '  lines\n'
      'empty:\n',
    );
    expect(
      [
        for (final property in properties!)
          '${property.key} = ${property.text ?? property.items}',
      ],
      [
        'name = baocode-stash',
        'description = The user\'s Stash: ideas, "bugs"',
        'allowed-tools = [Read(//Users/me/Stash/**), Edit]',
        "tags = [a, it's]",
        'notes = two lines',
        'empty = ',
      ],
    );
  });

  test('what is not keys and values shows as YAML', () {
    expect(parseFrontMatterProperties('  indented: first'), isNull);
    expect(parseFrontMatterProperties('just text'), isNull);
    expect(parseFrontMatterProperties(''), isNull);
  });

  test('a value is written back quoted as it was, else only as needed', () {
    const source =
        '---\n'
        'name: pdf\n'
        'description: "Reads PDFs"\n'
        "note: 'old'\n"
        'tools:\n'
        '  - Read\n'
        '---';
    expect(
      setFrontMatterValue(source, 'description', 'Says "hi": \\o/'),
      contains('description: "Says \\"hi\\": \\\\o/"\n'),
    );
    expect(
      setFrontMatterValue(source, 'note', "it's"),
      contains("note: 'it''s'\n"),
    );
    expect(setFrontMatterValue(source, 'name', 'pdf-2'), contains('name: pdf-2\n'));
    // Bare where YAML would read it otherwise.
    expect(setFrontMatterValue(source, 'name', 'a: b'), contains('name: "a: b"\n'));
    expect(setFrontMatterValue(source, 'name', 'true'), contains('name: "true"\n'));
    expect(setFrontMatterValue(source, 'name', ''), contains('name: ""\n'));
    // Each read back as written.
    for (final value in ['Says "hi": \\o/', 'a: b', 'true', "it's", '']) {
      final written = setFrontMatterValue(source, 'description', value);
      final yaml = written.split('\n').sublist(1).takeWhile((l) => l != '---');
      final read = parseFrontMatterProperties(yaml.join('\n'))!;
      expect(read.firstWhere((p) => p.key == 'description').text, value);
    }
    expect(setFrontMatterValue(source, 'missing', 'x'), source);
  });

  test('only a value on its own line is edited in place', () {
    final properties = parseFrontMatterProperties(
      'name: a\nempty:\nblock: |\n  two\n  lines\nlist:\n  - x\n',
    )!;
    expect([for (final p in properties) p.inline], [true, true, false, false]);
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/claude_haiku.dart';

void main() {
  test('a question alone goes on stdin, its answer one JSON result', () {
    final arguments = claudeHaikuArguments('Be brief.');
    expect(arguments, isNot(contains('--input-format')));
    expect(arguments.join(' '), contains('--output-format json'));
    // No tools.
    expect(
      arguments.sublist(
        arguments.indexOf('--tools'),
        2 + arguments.indexOf('--tools'),
      ),
      ['--tools', ''],
    );
  });

  test('with pictures, a stream-json message: each after a line naming '
      'it, the question last; still no tools', () {
    final arguments = claudeHaikuArguments('Be brief.', message: true);
    expect(
      arguments.join(' '),
      contains('--input-format stream-json --output-format stream-json'),
    );
    expect(arguments, contains('--verbose'));
    expect(arguments, contains('--tools'));

    final image = ImageAttachment(
      bytes: Uint8List.fromList([1, 2, 3]),
      mediaType: 'image/png',
    );
    final message = jsonDecode(
      claudeHaikuMessage('What is it?', [(name: '1/shot.png', image: image)]),
    ) as Map<String, Object?>;
    expect(message['type'], 'user');
    expect((message['message']! as Map)['content'], [
      {'type': 'text', 'text': '[Picture: 1/shot.png]'},
      {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/png',
          'data': base64Encode([1, 2, 3]),
        },
      },
      {'type': 'text', 'text': 'What is it?'},
    ]);
  });

  test('with tools, those alone, some turns, and the folders it may read', () {
    const tools = ClaudeHaikuTools(
      directory: '/work/app',
      readable: ['/Users/me/BaoCode/Stash'],
      maxTurns: 16,
    );
    final arguments = claudeHaikuArguments('Be brief.', tools: tools);
    expect(
      arguments.sublist(
        arguments.indexOf('--tools'),
        2 + arguments.indexOf('--tools'),
      ),
      ['--tools', 'Read,Glob,Grep'],
    );
    expect(arguments.join(' '), contains('--max-turns 16'));
    expect(tools.settings, {
      'permissions': {
        'allow': ['Read(//Users/me/BaoCode/Stash/**)'],
      },
    });
    expect(const ClaudeHaikuTools().settings, isEmpty);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release compares the version against its own repository channel', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    expect(
      workflow,
      contains(
        r'https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/latest.json',
      ),
    );
    expect(workflow, isNot(contains('https://dl.baocode.dev/releases/latest.json')));
    expect(workflow, contains('curl -fsSL'));
  });
}

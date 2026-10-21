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
    expect(
      workflow,
      isNot(contains('https://dl.baocode.dev/releases/latest.json')),
    );
    expect(workflow, contains('curl -fsSL'));
  });

  test('Linux packages join the existing GitHub release channel', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    expect(
      workflow,
      contains('needs: [check, remote, remote-linux, macos, windows, linux]'),
    );
    expect(workflow, contains('arch: [x64, arm64]'));
    expect(workflow, contains('edition: [standard]'));
    expect(workflow, contains('sh tool/package_linux_deb.sh'));
    expect(
      workflow,
      contains('cp dist/linux-*/*.deb dist/linux-*/*.tar.gz out/'),
    );
    expect(
      workflow,
      contains(r'--linux-x64 out/BaoCode-$MARKETING-linux-amd64.deb'),
    );
    expect(
      workflow,
      contains(r'--linux-arm64 out/BaoCode-$MARKETING-linux-arm64.deb'),
    );
    expect(workflow, contains(r'gh release create "v$MARKETING"'));
    expect(workflow, contains(r'out/BaoCode-$MARKETING-linux-*.deb'));
    expect(workflow, contains(r'out/BaoCode-$MARKETING-linux-*.tar.gz'));
    expect(workflow, isNot(contains('r2.cloudflarestorage.com')));
  });
}

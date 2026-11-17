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

  test('desktop builds restore the native dependency with a Rust fallback', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    for (final job in ['macos', 'windows', 'linux']) {
      final header = '\n  $job:\n';
      expect(workflow, contains(header));
      final steps = workflow
          .split(header)[1]
          .split(RegExp(r'\n  [a-z][a-z0-9-]*:\n'))
          .first;
      expect(steps, contains('uses: ./.github/actions/bao-iroh-prebuilt'));
      expect(steps, contains("if: steps.iroh.outputs.hit != 'true'"));
      expect(steps, contains('uses: ./.github/actions/setup-rust'));
    }
    expect(workflow, contains('lib/libbao_iroh.so'));
    expect(workflow, isNot(contains('  share:')));
    expect(workflow, contains(r'symbols-linux-${{ matrix.arch }}'));
  });

  test('one Mac uploads remote builds before packaging its own app', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final jobs = <String, String>{};
    final headers = RegExp(
      r'^  ([a-z][a-z0-9-]*):$',
      multiLine: true,
    ).allMatches(workflow).toList();
    for (var i = 0; i < headers.length; i++) {
      jobs[headers[i][1]!] = workflow.substring(
        headers[i].end,
        i + 1 < headers.length ? headers[i + 1].start : workflow.length,
      );
    }
    final mac = jobs['macos']!;
    expect(
      jobs.values.where((job) => job.contains('runs-on: macos-')).length,
      1,
    );
    expect(mac, contains('needs: [check, remote-windows]'));
    expect(mac, contains('pattern: remote-windows-*'));
    expect(mac, contains('--out build/remote --all'));
    expect(mac, contains('--macos-x64-dart'));
    expect(mac, contains('--from build/remote-windows'));
    expect(mac, contains('tool/test_remote_server_macos.sh build/remote'));
    final upload = mac.indexOf('name: remote\n');
    final buildApp = mac.indexOf('tool/build_macos.dart --build-only');
    expect(upload, greaterThanOrEqualTo(0));
    expect(upload, lessThan(buildApp));
    expect(mac, contains('name: remote-linux'));
    expect(mac, isNot(contains('uses: ./.github/actions/wait-for-artifact')));
    for (final name in ['windows', 'linux']) {
      expect(jobs[name], contains('name: remote\n'));
      expect(jobs[name], contains('job: Build for macOS'));
    }
    expect(jobs['remote-linux'], contains('needs: macos'));
    // Every dependency still exists after moving the artifact producer.
    final needs = RegExp(r'^    needs: (.+)$', multiLine: true);
    for (final job in jobs.values) {
      for (final match in needs.allMatches(job)) {
        final dependencies = match[1]!
            .replaceAll('[', '')
            .replaceAll(']', '')
            .split(',');
        for (final dependency in dependencies) {
          expect(jobs.keys, contains(dependency.trim()));
        }
      }
    }
  });

  test('Linux packages join the existing GitHub release channel', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    expect(
      workflow,
      contains('needs: [check, remote-linux, macos, windows, linux]'),
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

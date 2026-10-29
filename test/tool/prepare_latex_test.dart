import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/prepare_latex.dart' as latex;

void main() {
  test(
    'both macOS architectures and Windows builds use fixed upstream hashes',
    () {
      expect(
        latex.tectonicBuilds.keys,
        containsAll([
          'macos-arm64',
          'macos-x64',
          'windows-x64',
          'windows-arm64',
        ]),
      );
      for (final spec in latex.tectonicBuilds.values) {
        expect(spec.sha, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(spec.file, contains(latex.tectonicVersion));
      }
      expect(
        latex.tectonicBuilds['windows-arm64'],
        latex.tectonicBuilds['windows-x64'],
      );
    },
  );

  test('verified offline resources stage for another architecture without running a compiler', () async {
    final root = await Directory.systemTemp.createTemp(
      'baocode-stage-tex-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File(p.join(root.path, 'tool', 'latex', 'example.tex'));
    await source.parent.create(recursive: true);
    await source.writeAsString('example source');
    final licenses = File(
      p.join(root.path, 'tool', 'latex', 'licenses', 'NOTICE.txt'),
    );
    await licenses.parent.create(recursive: true);
    await licenses.writeAsString('license fixture');
    final shared = Directory(p.join(root.path, 'build', 'latex-resources'));
    final bundle = Directory(p.join(shared.path, 'bundle'));
    await bundle.create(recursive: true);
    final file = File(p.join(bundle.path, 'example.sty'));
    await file.writeAsString('macro fixture');
    final fingerprint = File(p.join(bundle.path, 'SHA256SUM'));
    await fingerprint.writeAsString('0' * 64);
    final files = {
      'example.sty': sha256.convert(await file.readAsBytes()).toString(),
      'SHA256SUM': sha256.convert(await fingerprint.readAsBytes()).toString(),
    };
    final seed = sha256.convert([
      ...utf8.encode(
        '${latex.tectonicVersion} 6ffe055852f8faf66c0acbe1a7fb27f87b869a90bad1204f3bf4d9683f597c7c',
      ),
      ...await source.readAsBytes(),
    ]).toString();
    await File(p.join(shared.path, 'manifest.json'))
        .writeAsString(jsonEncode({'seed': seed, 'files': files}));
    final output = Directory(p.join(root.path, 'staged-runtime'));
    await output.create();
    await latex.prepareBundle(root, output, 'must-not-execute');
    expect(
      await File(p.join(output.path, 'bundle', 'example.sty')).readAsString(),
      'macro fixture',
    );
    expect(
      await File(p.join(output.path, 'NOTICE.txt')).readAsString(),
      'license fixture',
    );
    expect(
      await File(p.join(output.path, 'bundle-manifest.json')).exists(),
      isTrue,
    );
    // A corrupted cached resource is not silently packaged for another target.
    await file.writeAsString('corrupted');
    await expectLater(
      latex.prepareBundle(root, output, 'must-not-execute'),
      throwsA(isA<ProcessException>()),
    );
  });
}

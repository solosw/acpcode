@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/ide/file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

List<int> _utf16(String text, bool bigEndian) => [
  ...bigEndian ? [0xfe, 0xff] : [0xff, 0xfe],
  for (final unit in text.codeUnits)
    ...bigEndian ? [unit >> 8, unit & 255] : [unit & 255, unit >> 8],
];

void main() {
  for (final remote in [false, true]) {
    group(remote ? 'remote editor encoding' : 'local editor encoding', () {
      late Directory temp;
      late Future<String> Function(String path, {bool force}) read;
      late Future<void> Function(
        String path,
        String text, {
        String? expectedText,
      })
      write;
      RemoteHarness? harness;

      setUp(() async {
        temp = Directory.systemTemp.createTempSync('editor-encoding-');
        final root = temp.resolveSymbolicLinksSync();
        if (remote) {
          harness = await RemoteHarness.start();
          read = (path, {force = false}) =>
              harness!.client.read(root, path, force: force);
          write = (path, text, {expectedText}) => harness!.client.write(
            root,
            path,
            text,
            expectedText: expectedText,
          );
        } else {
          final files = IdeFileService(root);
          read = files.read;
          write = files.write;
        }
      });
      tearDown(() async {
        await harness?.close();
        harness = null;
        temp.deleteSync(recursive: true);
      });

      for (final bigEndian in [false, true]) {
        test(
          'UTF-16 ${bigEndian ? "BE" : "LE"} opens and saves with its BOM, byte order and newlines',
          () async {
            final file = File(p.join(temp.path, 'settings.txt'));
            final crlf = String.fromCharCodes([13, 10]);
            final lf = String.fromCharCode(10);
            final original = '中文 😀${crlf}second line$crlf';
            final bytes = _utf16(original, bigEndian);
            file.writeAsBytesSync(bytes);
            expect(await read(file.path), original);
            await write(file.path, original, expectedText: original);
            expect(file.readAsBytesSync(), bytes);
            final edited = '修改 🐦${lf}second line$lf';
            await write(file.path, edited, expectedText: original);
            expect(
              file.readAsBytesSync(),
              _utf16(edited.replaceAll(lf, crlf), bigEndian),
            );
            expect(await read(file.path), edited.replaceAll(lf, crlf));
          },
        );

        test(
          'UTF-16 ${bigEndian ? "BE" : "LE"} Open Anyway still reads text and protects external changes',
          () async {
            final file = File(p.join(temp.path, 'text.txt'));
            file.writeAsBytesSync(_utf16('原文', bigEndian));
            expect(await read(file.path, force: true), '原文');
            final external = _utf16('external edit', bigEndian);
            file.writeAsBytesSync(external);
            await expectLater(
              write(file.path, 'my edit', expectedText: '原文'),
              throwsA(isA<IdeFileConflictException>()),
            );
            expect(file.readAsBytesSync(), external);
          },
        );

        test(
          'UTF-16 ${bigEndian ? "BE" : "LE"} BOM-only files open empty and preserve encoding on edit',
          () async {
            final file = File(p.join(temp.path, 'empty.txt'));
            file.writeAsBytesSync(_utf16('', bigEndian));
            expect(await read(file.path), '');
            await write(file.path, 'new text', expectedText: '');
            expect(file.readAsBytesSync(), _utf16('new text', bigEndian));
          },
        );
      }

      test('Open Anyway replaces malformed UTF-16 for display, preserving untouched bytes', () async {
        final file = File(p.join(temp.path, 'malformed.txt'));
        final malformed = [0xff, 0xfe, 0, 0xd8, 0x61];
        file.writeAsBytesSync(malformed);
        final shown = await read(file.path, force: true);
        expect(shown, String.fromCharCodes([0xfffd, 0xfffd]));
        await write(file.path, shown, expectedText: shown);
        expect(file.readAsBytesSync(), malformed);
        await write(file.path, 'repaired 中文', expectedText: shown);
        expect(file.readAsBytesSync(), _utf16('repaired 中文', false));
        expect(await read(file.path), 'repaired 中文');
      });

      test(
        'UTF-8 with and without a BOM still reads and saves exactly',
        () async {
          for (final bom in [false, true]) {
            final file = File(p.join(temp.path, 'utf8-$bom.txt'));
            final prefix = bom ? [0xef, 0xbb, 0xbf] : <int>[];
            file.writeAsBytesSync([...prefix, ...utf8.encode('中文 😀')]);
            expect(await read(file.path), '中文 😀');
            await write(file.path, '修改 🐦', expectedText: '中文 😀');
            expect(file.readAsBytesSync(), [
              ...prefix,
              ...utf8.encode('修改 🐦'),
            ]);
          }
        },
      );

      test(
        'binary bytes and malformed UTF-16 stay rejected without changing disk',
        () async {
          final samples = [
            [0, 1, 2, 3],
            [0xc3, 0x28],
            [0xff, 0xfe, 0x61],
            [0xfe, 0xff, 0x61],
            [0xff, 0xfe, 0x00, 0xd8],
            [0xfe, 0xff, 0xdc, 0x00],
            [0xff, 0xfe, 0, 0, 0x61, 0, 0, 0],
          ];
          for (final bytes in samples) {
            final file = File(p.join(temp.path, 'invalid.bin'))
              ..writeAsBytesSync(bytes);
            await expectLater(
              read(file.path),
              throwsA(isA<IdeBinaryFileException>()),
            );
            expect(file.readAsBytesSync(), bytes);
          }
        },
      );
    });
  }
}

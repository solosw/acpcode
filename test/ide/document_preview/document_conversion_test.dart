import 'dart:convert';
import 'dart:io';

import 'package:baocode/ide/document_preview/document_conversion.dart';
import 'package:baocode/ide/document_preview/document_conversion_io.dart';
import 'package:baocode/ide/document_preview/document_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

TypeMatcher<DocumentConversionException> failure(
  DocumentConversionFailure failure,
) => isA<DocumentConversionException>().having(
  (error) => error.failure,
  'failure',
  failure,
);

void main() {
  late Directory fixture;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('baocode-tex-test-');
    await Directory(p.join(fixture.path, 'bundle')).create();
    await File(p.join(fixture.path, 'bundle', 'SHA256SUM'))
        .writeAsString('0' * 64);
    await File(
      p.join(fixture.path, Platform.isWindows ? 'tectonic.exe' : 'tectonic'),
    ).writeAsString('fixture');
  });
  tearDown(() => fixture.delete(recursive: true));

  test(
    'binary Office paths and editable TeX are recognized case-insensitively',
    () {
      for (final path in ['a.PDF', 'a.doc', 'a.DOCX', 'a.xls', 'a.XLSX']) {
        expect(ideIsDocumentPath(path), isTrue);
      }
      expect(ideIsDocumentPath('a.tex'), isFalse);
      expect(ideIsLatexPath('a.TeX'), isTrue);
    },
  );

  test('packaged runtime path is correct on macOS and Windows', () {
    expect(
      bundledLatexDirectory(
        '/Applications/BaoCode.app/Contents/MacOS/BaoCode',
        macOS: true,
        paths: p.Context(style: p.Style.posix),
      ),
      '/Applications/BaoCode.app/Contents/Resources/latex',
    );
    expect(
      bundledLatexDirectory(
        r'C:\Program Files\BaoCode\BaoCode.exe',
        macOS: false,
        paths: p.Context(style: p.Style.windows),
      ),
      r'C:\Program Files\BaoCode\latex',
    );
  });

  test(
    'missing bundle fails without searching PATH or running another compiler',
    () async {
      await File(p.join(fixture.path, 'bundle', 'SHA256SUM')).delete();
      var ran = false;
      final converter = LocalDocumentConverter(
        runtimeDirectory: fixture.path,
        run: (_, _, {required workingDirectory, required input}) async {
          ran = true;
          return (exitCode: 0, output: '');
        },
      );
      await expectLater(
        converter.latex('/p/a.tex', ''),
        throwsA(failure(DocumentConversionFailure.missingTex)),
      );
      expect(ran, isFalse);
    },
  );

  test('stdin snapshot uses an offline bundled engine, source directory and isolated output', () async {
    final source = File(p.join(fixture.path, '中文 main.tex'));
    await source.writeAsString('saved');
    String? temporary;
    final converter = LocalDocumentConverter(
      runtimeDirectory: fixture.path,
      run:
          (
            executable,
            arguments, {
            required workingDirectory,
            required input,
          }) async {
            expect(p.dirname(executable), fixture.path);
            expect(
              arguments,
              containsAll([
                '--only-cached',
                '--untrusted',
                '--bundle',
                '--outdir',
              ]),
            );
            expect(arguments.last, '-');
            expect(input, 'unsaved');
            expect(workingDirectory, fixture.path);
            final bundle = Uri.parse(
              arguments[arguments.indexOf('--bundle') + 1],
            );
            expect(
              p.normalize(bundle.toFilePath()),
              p.join(fixture.path, 'bundle'),
            );
            temporary = arguments[arguments.indexOf('--outdir') + 1];
            await File(p.join(temporary!, 'texput.pdf'))
                .writeAsBytes(ascii.encode('%PDF-1.4\nfixture'));
            return (exitCode: 0, output: 'compiled locally');
          },
    );
    final result = await converter.latex(source.path, 'unsaved');
    expect(result.log, 'compiled locally');
    expect(await source.readAsString(), 'saved');
    expect(await Directory(temporary!).exists(), isFalse);
  });

  test(
    'compiler diagnostics survive failure and temporary output is removed',
    () async {
      String? temporary;
      final converter = LocalDocumentConverter(
        runtimeDirectory: fixture.path,
        run: (_, arguments, {required workingDirectory, required input}) async {
          temporary = arguments[arguments.indexOf('--outdir') + 1];
          return (exitCode: 1, output: 'missing package.sty');
        },
      );
      await expectLater(
        converter.latex('/p/a.tex', 'bad'),
        throwsA(
          failure(DocumentConversionFailure.failed)
              .having((e) => e.log, 'log', contains('missing package.sty')),
        ),
      );
      expect(await Directory(temporary!).exists(), isFalse);
    },
  );

  test('a hanging bundled compiler is killed on timeout', () async {
    final engine = File(p.join(fixture.path, 'tectonic'));
    await engine.writeAsString('#!/bin/sh\ncat >/dev/null\nexec sleep 30\n');
    await Process.run('chmod', ['755', engine.path]);
    final converter = LocalDocumentConverter(
      runtimeDirectory: fixture.path,
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      converter.latex('${fixture.path}/a.tex', 'source'),
      throwsA(failure(DocumentConversionFailure.timeout)),
    );
  }, skip: Platform.isWindows);
}

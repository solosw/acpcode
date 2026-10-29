import 'dart:io';

import 'package:baocode/ide/document_preview/document_conversion.dart';
import 'package:baocode/ide/document_preview/document_conversion_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Explicit opt-in: runs only the bundled engine, never a system TeX install.
/// Set TECTONIC_CACHE_DIR to an empty directory to verify a cold offline build.
void main() {
  final runtime = Platform.environment['BAOCODE_LATEX_RUNTIME'];
  late Directory project;
  setUp(() async {
    project = await Directory.systemTemp.createTemp(
      'baocode-latex-integration-',
    );
  });
  tearDown(() => project.delete(recursive: true));

  test('bundled engine compiles unsaved source and relative inputs without saving the main file', () async {
    final main = File(p.join(project.path, '中文 main.tex'));
    await main.writeAsString('saved text, not LaTeX');
    await File(p.join(project.path, 'body.tex'))
        .writeAsString('Relative input works.');
    final result = await LocalDocumentConverter(runtimeDirectory: runtime)
        .latex(
          main.path,
          r'\documentclass{article}\usepackage{amsmath}\begin{document}\input{body}\[E=mc^2\]\end{document}',
        );
    expect(result.bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(result.bytes.take(5)), '%PDF-');
    expect(await main.readAsString(), 'saved text, not LaTeX');
    expect(await project.list().length, 2);
  }, skip: runtime == null);

  test('bundled Chinese fonts and math work without system TeX or downloaded packages', () async {
    final result = await LocalDocumentConverter(runtimeDirectory: runtime)
        .latex(
          p.join(project.path, 'main.tex'),
          r'\documentclass[fontset=fandol]{ctexart}\usepackage{amsmath}\begin{document}中文预览，\textbf{粗体}。\[x^2+y^2=z^2\]\end{document}',
        );
    expect(result.bytes.length, greaterThan(1000));
  }, skip: runtime == null);

  test('missing packages fail locally with diagnostics', () async {
    await expectLater(
      LocalDocumentConverter(runtimeDirectory: runtime).latex(
        p.join(project.path, 'main.tex'),
        r'\documentclass{article}\usepackage{baocode-missing-package}\begin{document}test\end{document}',
      ),
      throwsA(
        isA<DocumentConversionException>()
            .having(
              (error) => error.failure,
              'failure',
              DocumentConversionFailure.failed,
            )
            .having(
              (error) => error.log,
              'log',
              contains('baocode-missing-package'),
            ),
      ),
    );
  }, skip: runtime == null);
}

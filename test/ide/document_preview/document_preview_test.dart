import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/chat/side_panel/file_preview.dart';
import 'package:baocode/ide/document_preview/document_conversion.dart';
import 'package:baocode/ide/document_preview/document_preview.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:baocode/ide/document_preview/spreadsheet_preview.dart';

import 'office_fixtures.dart';

import '../workbench/fake_files.dart';

Widget _app(Widget child, {String locale = 'en'}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

class _Converter implements DocumentConverter {
  int calls = 0;
  final sources = <String>[];
  Completer<DocumentConversion>? gate;

  Future<DocumentConversion> _result() async {
    calls++;
    if (gate case final gate?) return gate.future;
    throw const DocumentConversionException(
      DocumentConversionFailure.failed,
      'fixture diagnostic',
    );
  }

  @override
  Future<DocumentConversion> latex(String path, String source) {
    sources.add(source);
    return _result();
  }
}

/// A small real PDF: lets the native viewer open and render one blank page.
Uint8List _pdf({int pages = 1}) {
  final text = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (final object in [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(pages, (i) => '${i + 3} 0 R').join(' ')}] /Count $pages >>',
    for (var i = 0; i < pages; i++) '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>',
  ]) {
    offsets.add(text.length);
    text.writeln('${offsets.length - 1} 0 obj\n$object\nendobj');
  }
  final xref = text.length;
  text.writeln('xref\n0 ${offsets.length}\n0000000000 65535 f ');
  for (final offset in offsets.skip(1)) {
    text.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
  }
  text.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(text.toString()));
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      if (finder.evaluate().isNotEmpty) break;
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // Widget tests have no native path_provider registration.
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
  });
  testWidgets('Word renders natively on open without invoking a converter', (
    tester,
  ) async {
    final converter = _Converter();
    var reads = 0;
    await tester.pumpWidget(
      _app(
        IdeDocumentPreview(
          path: '/p/a.docx',
          converter: converter,
          read: (_) async {
            reads++;
            return wordFixture();
          },
        ),
      ),
    );
    await tester.pump();
    expect(converter.calls, 0);
    await _waitFor(tester, find.text('Built-in Word 中文', findRichText: true));
    expect(reads, 1);
    expect(converter.calls, 0);
    expect(find.byType(DocxView), findsOneWidget);
    expect(find.text('Built-in Word 中文', findRichText: true), findsOneWidget);
    expect(find.text('Table cell', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'LaTeX preview compiles the latest snapshot and keeps the editor mounted',
    (tester) async {
      final converter = _Converter();
      var source = 'first unsaved source';
      final editor = GlobalKey();
      await tester.pumpWidget(
        _app(
          IdeLatexPreview(
            path: '/p/a.tex',
            source: () => source,
            converter: converter,
            child: TextField(key: editor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(converter.calls, 0);
      final element = editor.currentContext;
      await tester.tap(find.text('Compile LaTeX Preview'));
      await tester.pumpAndSettle();
      expect(converter.sources, ['first unsaved source']);
      expect(editor.currentContext, same(element));
      await tester.tap(find.text('Source'));
      await tester.pumpAndSettle();
      source = 'second unsaved source';
      await tester.tap(find.text('Compile LaTeX Preview'));
      await tester.pumpAndSettle();
      expect(converter.sources.last, source);
      expect(editor.currentContext, same(element));
    },
  );

  testWidgets('remote LaTeX cannot accidentally execute a local compiler', (
    tester,
  ) async {
    final converter = _Converter();
    await tester.pumpWidget(
      _app(
        IdeLatexPreview(
          path: '/remote/a.tex',
          source: () => 'source',
          enabled: false,
          converter: converter,
          child: const Text('editor'),
        ),
        locale: 'zh',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编译 LaTeX 预览'));
    await tester.pumpAndSettle();
    expect(converter.calls, 0);
    expect(find.textContaining('暂不支持远程项目'), findsWidgets);
  });

  testWidgets('closing a preview during conversion ignores its late result', (
    tester,
  ) async {
    final converter = _Converter()..gate = Completer<DocumentConversion>();
    await tester.pumpWidget(
      _app(
        IdeDocumentPreview(
          path: '/p/a.tex',
          converter: converter,
          latexSource: () => 'source',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compile LaTeX Preview'));
    await tester.pump();
    await tester.pumpWidget(_app(const SizedBox()));
    converter.gate!.completeError(
      const DocumentConversionException(DocumentConversionFailure.failed),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Excel renders data and switches worksheets without conversion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        IdeDocumentPreview(
          path: '/p/data.xlsx',
          read: (_) async => spreadsheetFixture(),
        ),
      ),
    );
    await _waitFor(tester, find.byType(SpreadsheetPreview));
    expect(find.text('Product'), findsOneWidget);
    expect(find.text('25'), findsOneWidget);
    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();
    expect(find.text('Second worksheet'), findsOneWidget);
    expect(find.text('=SUM(A1:B2)'), findsOneWidget);
  });

  for (final extension in ['doc', 'xls']) {
    testWidgets('legacy $extension explains the OOXML requirement', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          IdeDocumentPreview(
            path: '/p/file.$extension',
            read: (_) async => throw StateError('must not read'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Legacy .doc / .xls'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('PDF read failure is shown and can be retried', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      _app(
        IdeDocumentPreview(
          path: '/p/a.pdf',
          read: (_) async {
            reads++;
            throw StateError('Cannot read PDF');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Cannot read PDF'), findsOneWidget);
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(reads, 2);
  });

  testWidgets(
    'side panel Word documents bypass UTF-8 and use the document viewer',
    (tester) async {
      await tester.pumpWidget(
        _app(
          FilePreview(
            request: const FileOpenRequest('/p/a.docx'),
            files: TreeFiles({}),
            readBytes: (_) async => wordFixture(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(IdeDocumentPreview), findsOneWidget);
      await _waitFor(tester, find.byType(DocxView));
      expect(find.byType(DocxView), findsOneWidget);
      expect(find.textContaining('not found'), findsNothing);
    },
  );

  testWidgets('PDF bytes open and reload without showing cached old output', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      _app(
        IdeDocumentPreview(
          path: '/p/fixture.pdf',
          read: (_) async => _pdf(pages: ++reads),
        ),
      ),
    );
    // Native PDF decoding completes on a worker isolate, outside fake time.
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
        if (find.text('1 / 1').evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(PdfViewer), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    await tester.tap(find.text('Reload'));
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
        if (find.text('1 / 2').evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });
}

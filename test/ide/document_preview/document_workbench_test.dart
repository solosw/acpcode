import 'package:baocode/ide/document_preview/document_preview.dart';
import 'package:baocode/ide/ide_editor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workbench/fake_files.dart';

void main() {
  for (final extension in ['doc', 'docx', 'xls', 'xlsx']) {
    testWidgets(
      'IDE opens $extension with the document preview, not a binary placeholder',
      (tester) async {
        final name = 'report.$extension';
        await pumpWorkbench(tester, {name: '\x00binary'}, open: [name]);
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(find.byType(IdeDocumentPreview), findsOneWidget);
        expect(find.byType(IdeEditor), findsNothing);
        expect(find.byType(IdeDocumentPreview), findsOneWidget);
      },
    );
  }

  testWidgets(
    'TeX keeps the IDE source editor and switching tabs preserves its key',
    (tester) async {
      await pumpWorkbench(
        tester,
        {'main.tex': 'source', 'notes.txt': 'note'},
        open: ['main.tex'],
      );
      await tester.pumpAndSettle();
      expect(find.byType(IdeLatexPreview), findsOneWidget);
      expect(find.byType(IdeEditor), findsOneWidget);
      expect(find.text('Compile LaTeX Preview'), findsOneWidget);
      // There is no preview/compilation merely from opening the source.
      expect(find.byType(IdeDocumentPreview), findsNothing);
      await tester.tap(find.text('notes.txt').first);
      await tester.pumpAndSettle();
      expect(find.byType(IdeLatexPreview), findsNothing);
      expect(find.byType(IdeEditor), findsOneWidget);
      await tester.tap(find.text('main.tex').first);
      await tester.pumpAndSettle();
      expect(find.byType(IdeLatexPreview), findsOneWidget);
      expect(find.byType(IdeEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

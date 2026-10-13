import 'package:baocode/chat/widgets/edge_fade_mask.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_editor.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the text fades out at an edge scrolled past, not before', (
    tester,
  ) async {
    final document = Document()..insert(0, List.filled(80, 'line').join('\n'));
    final controller = StashEditor.controllerFor(document);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: StashEditor(
              controller: controller,
              store: StashStore(MemoryStashDisk()),
              ensureNote: () async => 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    EdgeFadeMask mask() =>
        tester.widget<EdgeFadeMask>(find.byType(EdgeFadeMask));
    expect(mask().top, isFalse);
    expect(mask().bottom, isTrue);
    await tester.drag(find.byType(QuillEditor), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(mask().top, isTrue);
  });
}

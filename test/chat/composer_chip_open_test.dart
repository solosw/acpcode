import 'package:baocode/chat/composer/composer_mock_data.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_files.dart';
import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _root = '/work/app';

/// [chip] under a scope whose files and folders open into [opened] and
/// [folders].
Future<void> _pump(
  WidgetTester tester,
  Widget chip, {
  required List<FileOpenRequest> opened,
  List<String>? folders,
}) async {
  final existence = FileExistence((_) async => true);
  addTearDown(existence.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: FileOpenScope(
          root: _root,
          paths: p.posix,
          onOpen: opened.add,
          onOpenFolder: folders?.add,
          existence: existence,
          inPanel: true,
          child: Center(child: chip),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _style = TextStyle(fontSize: 13);

void main() {
  testWidgets('a file\'s tag opens it where the chat\'s files open', (
    tester,
  ) async {
    final opened = <FileOpenRequest>[];
    await _pump(
      tester,
      ComposerTokenChip(
        data: ComposerTokenEmbed.file('lib/main.dart').data,
        textStyle: _style,
      ),
      opened: opened,
    );
    await tester.tap(find.byType(ComposerTokenChip));
    await tester.pump();
    expect(opened.single.path, '$_root/lib/main.dart');
  });

  testWidgets('a folder\'s tag shows it in the side panel\'s tree', (
    tester,
  ) async {
    final opened = <FileOpenRequest>[];
    final folders = <String>[];
    await _pump(
      tester,
      ComposerTokenChip(
        data: ComposerTokenEmbed.file('lib/chat', directory: true).data,
        textStyle: _style,
      ),
      opened: opened,
      folders: folders,
    );
    await tester.tap(find.byType(ComposerTokenChip));
    await tester.pump();
    expect(folders, ['$_root/lib/chat']);
    expect(opened, isEmpty);
  });

  testWidgets('a command\'s tag opens no file', (tester) async {
    final opened = <FileOpenRequest>[];
    await _pump(
      tester,
      ComposerTokenChip(
        data: ComposerTokenEmbed.fromSuggestion(
          const Suggestion(kind: SuggestionKind.command, label: 'plan'),
        ).data,
        textStyle: _style,
      ),
      opened: opened,
    );
    await tester.tap(find.byType(ComposerTokenChip));
    await tester.pump();
    expect(opened, isEmpty);
  });

  testWidgets('lines\' tag opens their file at them', (tester) async {
    final opened = <FileOpenRequest>[];
    await _pump(
      tester,
      ComposerCodeChip(
        data: ComposerCodeEmbed.of(
          const CodeReference(
            path: '$_root/lib/main.dart',
            start: 3,
            end: 4,
            code: 'a\nb\n',
          ),
        ).data,
        textStyle: _style,
      ),
      opened: opened,
    );
    await tester.tap(find.byType(ComposerCodeChip));
    await tester.pump();
    expect(opened.single.path, '$_root/lib/main.dart');
    expect((opened.single.range!.start, opened.single.range!.end), (3, 4));
  });
}

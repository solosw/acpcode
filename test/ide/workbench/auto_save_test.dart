import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_editor.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:path/path.dart' as p;

import 'fake_files.dart';

/// `files.autoSave`: `afterDelay` by default, once edits stop for
/// `files.autoSaveDelay`; explicit modes follow the user's settings.
void main() {
  UserSettings settingsOf(String json) {
    final temp = Directory.systemTemp.createTempSync('baocode-auto-save');
    addTearDown(() => temp.deleteSync(recursive: true));
    final settings = UserSettings(
      p.join(temp.path, 'User', 'settings.json'),
      debounce: Duration.zero,
    );
    addTearDown(settings.dispose);
    File(settings.path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(json);
    settings.loadSync();
    return settings;
  }

  Map<String, String> contentsOf(IdeWorkspace workspace) =>
      (workspace.files as TreeFiles).contents;

  for (final json in <String?>[null, '{}']) {
    testWidgets('afterDelay by default with settings $json', (tester) async {
      final workspace = await pumpWorkbench(
        tester,
        {'a.txt': 'a'},
        open: ['a.txt'],
        settings: json == null ? null : settingsOf(json),
      );
      final path = inRoot('a.txt');
      workspace.edit(path, 'edited');
      await tester.pump(const Duration(milliseconds: 999));
      expect(contentsOf(workspace)[path], 'a');
      expect(workspace.active!.dirty, isTrue);

      await tester.pump(const Duration(milliseconds: 1));
      expect(contentsOf(workspace)[path], 'edited');
      expect(workspace.active!.dirty, isFalse);
    });
  }

  testWidgets('an edit in the painted editor auto saves by default', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      nativeEditor: true,
    );
    await tester.pumpAndSettle();
    tester
        .state<IdeEditorState>(find.byType(IdeEditor))
        .insertAtCaret('edited');
    await tester.pump();
    final text = workspace.active!.text;
    expect(text, contains('edited'));
    expect(contentsOf(workspace)[inRoot('a.txt')], 'a');

    await tester.pump(const Duration(seconds: 1));
    expect(contentsOf(workspace)[inRoot('a.txt')], text);
    expect(workspace.active!.dirty, isFalse);
  });

  testWidgets('default delay survives switching editors', (tester) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a', 'b.txt': 'b'},
      open: ['a.txt', 'b.txt'],
    );
    workspace.edit(inRoot('b.txt'), 'edited');
    await tester.pump(const Duration(milliseconds: 200));
    workspace.select(inRoot('a.txt'));
    await tester.pump(const Duration(seconds: 1));
    expect(contentsOf(workspace)[inRoot('b.txt')], 'edited');
  });

  testWidgets('default delay survives window blur', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
    );
    workspace.edit(inRoot('a.txt'), 'edited');
    await tester.pump(const Duration(milliseconds: 200));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 1));
    expect(contentsOf(workspace)[inRoot('a.txt')], 'edited');
  });

  testWidgets('explicit off: an edit stays unsaved', (tester) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      settings: settingsOf('{"files.autoSave": "off"}'),
    );
    workspace.edit(inRoot('a.txt'), 'edited');
    await tester.pump(const Duration(seconds: 5));

    expect(contentsOf(workspace)[inRoot('a.txt')], 'a');
    expect(workspace.active!.dirty, isTrue);
  });

  testWidgets('afterDelay saves once edits stop for the delay', (tester) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      settings: settingsOf(
        '{"files.autoSave": "afterDelay", "files.autoSaveDelay": 500}',
      ),
    );
    final path = inRoot('a.txt');
    workspace.edit(path, 'a1');
    await tester.pump(const Duration(milliseconds: 300));
    workspace.edit(path, 'a12');
    await tester.pump(const Duration(milliseconds: 300));
    expect(contentsOf(workspace)[path], 'a');

    await tester.pump(const Duration(milliseconds: 300));
    expect(contentsOf(workspace)[path], 'a12');
    expect(workspace.active!.dirty, isFalse);
  });

  testWidgets('onFocusChange saves when another editor comes to the front', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a', 'b.txt': 'b'},
      open: ['a.txt', 'b.txt'],
      settings: settingsOf('{"files.autoSave": "onFocusChange"}'),
    );
    workspace.select(inRoot('a.txt'));
    await tester.pump();
    workspace.edit(inRoot('a.txt'), 'edited');
    await tester.pump(const Duration(seconds: 5));
    expect(contentsOf(workspace)[inRoot('a.txt')], 'a');

    workspace.select(inRoot('b.txt'));
    await tester.pump();
    expect(contentsOf(workspace)[inRoot('a.txt')], 'edited');
  });

  testWidgets('onWindowChange waits for the window to lose focus', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a', 'b.txt': 'b'},
      open: ['a.txt', 'b.txt'],
      settings: settingsOf('{"files.autoSave": "onWindowChange"}'),
    );
    final path = inRoot('b.txt');
    workspace.edit(path, 'edited');
    workspace.select(inRoot('a.txt'));
    await tester.pump(const Duration(seconds: 5));
    expect(contentsOf(workspace)[path], 'b');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(contentsOf(workspace)[path], 'edited');
  });

  testWidgets('close saves immediately without confirmation', (tester) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
    );
    final path = inRoot('a.txt');
    workspace.edit(path, 'edited');
    await tester.pump();
    await chord(tester, LogicalKeyboardKey.keyW, control: true);
    expect(find.textContaining('Do you want to save'), findsNothing);
    expect(contentsOf(workspace)[path], 'edited');
    expect(workspace.documents, isEmpty);

    await tester.pump(const Duration(seconds: 2));
    expect(contentsOf(workspace)[path], 'edited');
    expect(workspace.notifications.notifications, isEmpty);
  });

  for (final protection in ['off', 'untitled', 'conflict']) {
    testWidgets('close retains $protection protection and can cancel', (
      tester,
    ) async {
      final workspace = await pumpWorkbench(
        tester,
        {'a.txt': 'a'},
        open: ['a.txt'],
        settings: protection == 'off'
            ? settingsOf('{"files.autoSave": "off"}')
            : null,
      );
      final doc = protection == 'untitled'
          ? workspace.newUntitled()
          : workspace.active!;
      workspace.edit(doc.path, 'mine');
      if (protection == 'conflict') {
        contentsOf(workspace)[doc.path] = 'theirs';
      }
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyW, control: true);
      expect(find.textContaining('Do you want to save'), findsOneWidget);
      expect(workspace.documents, contains(doc));
      expect(doc.dirty, isTrue);
      expect(
        contentsOf(workspace)[inRoot('a.txt')],
        protection == 'conflict' ? 'theirs' : 'a',
      );
      expect(contentsOf(workspace).containsKey('Untitled-1'), isFalse);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(workspace.documents, contains(doc));
      expect(doc.text, 'mine');
    });
  }

  testWidgets('a file changed on disk is left for saving by hand, told once', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      settings: settingsOf('{"files.autoSaveDelay": 100}'),
    );
    final path = inRoot('a.txt');
    contentsOf(workspace)[path] = 'theirs';
    workspace.edit(path, 'mine');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(contentsOf(workspace)[path], 'theirs');
    expect(workspace.notifications.notifications, hasLength(1));

    workspace.edit(path, 'mine again');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(contentsOf(workspace)[path], 'theirs');
    expect(workspace.notifications.notifications, hasLength(1));
  });
}

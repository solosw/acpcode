import 'dart:async';

import 'package:baocode/stash/stash_note_editor.dart';
import 'package:baocode/stash/stash_ai.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/chat/composer/composer_files.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/stash/stash_actions.dart';
import 'package:baocode/stash/stash_controller.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_host.dart';
import 'package:baocode/stash/stash_note.dart';
import 'package:baocode/stash/stash_panel_view.dart';
import 'package:baocode/stash/stash_settings.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/ide/ide_list.dart';
import 'package:baocode/keybindings/keybinding_service.dart';
import 'package:baocode/platform/app_platform.dart';
import 'package:baocode/theme/material_file_icons.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/workspace/pin_window_button.dart';
import 'package:baocode/workspace/workspace.dart';

import '../window/fake_window_host.dart';

/// The system's windows, with the stash's panel.
class _StashWindowHost extends FakeWindowHost {
  _StashWindowHost(super.implicit);

  @override
  Future<int?> createStash() async {
    const id = 99;
    views[id] = FakeView(implicit, viewId: id);
    log.add('createStash');
    return id;
  }

  @override
  Future<void> showStash() async => log.add('showStash');

  @override
  Future<void> hideStash() async => log.add('hideStash');
}

void main() {
  late MemoryStashDisk disk;
  late StashStore store;
  late Workspace workspace;
  late _StashWindowHost host;
  late AppWindows windows;
  late StashController controller;

  const stashChannel = MethodChannel('test/stash');
  final hotkeys = <Object?>[];

  Future<void> setUpFlow(WidgetTester tester) async {
    hotkeys.clear();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      stashChannel,
      (call) async {
        if (call.method == 'setHotkey') hotkeys.add(call.arguments);
        return call.method == 'setHotkey' ? true : null;
      },
    );
    disk = MemoryStashDisk();
    store = StashStore(disk);
    workspace = Workspace.mock();
    host = _StashWindowHost(tester.view);
    windows = AppWindows(
      host: host,
      workspace: workspace,
      l10n: () => englishLocalizations,
      nextFrame: () async {},
    );
    await windows.start();
    controller = StashController(
      store: store,
      workspace: workspace,
      windows: windows,
      host: StashHost(channel: stashChannel),
    );
  }

  testWidgets('the shortcut shows the panel with a new stash, made at once, '
      'and hides it', (tester) async {
    await setUpFlow(tester);

    // From another app: nothing of it is kept.
    controller.pressed(StashCapture.none);
    await tester.pump();
    expect(host.log, containsAllInOrder(['createStash', 'showStash']));
    expect(controller.shown, isTrue);
    final id = controller.editing!;
    final note = store.byId(id)!;
    expect(note.source.isEmpty, isTrue);
    expect(note.project, isNull);
    await store.update(id, (note) => note.body = 'remember the cache bug');

    // The shortcut again, the panel in front: hidden, what was written kept.
    controller.pressed(const StashCapture(inApp: true, panelInFront: true));
    await tester.pump();
    expect(host.log.last, 'hideStash');
    expect(controller.shown, isFalse);
    expect(store.byId(id)!.body, 'remember the cache bug');

    // Shown again: another stash.
    controller.pressed(StashCapture.none);
    await tester.pump();
    expect(controller.editing, isNot(id));

    // Another app clicked meanwhile: the shortcut brings the panel back,
    // with the same stash.
    final again = controller.editing;
    final shows = host.log.where((entry) => entry == 'showStash').length;
    controller.pressed(const StashCapture(panelInFront: false));
    await tester.pump();
    expect(controller.shown, isTrue);
    expect(controller.editing, again);
    expect(
      host.log.where((entry) => entry == 'showStash'),
      hasLength(shows + 1),
    );

    await controller.hide();
    expect(store.notes.where((note) => !note.isBlank), hasLength(1));
    controller.dispose();
  });

  testWidgets('a stash left blank stays, the draft gone on with', (
    tester,
  ) async {
    await setUpFlow(tester);
    await controller.present();
    final first = controller.editing!;
    await controller.hide();
    expect(store.notes.map((note) => note.id), [first]);
    // Shown again: the same draft, no other made.
    await controller.present();
    expect(controller.editing, first);
    await controller.startNew();
    expect(controller.editing, first);

    // Written in, "New" makes one more; another picked, the blank one
    // stays a draft, and "New" goes back to it.
    await store.update(first, (note) => note.body = 'kept');
    await controller.startNew();
    final draft = controller.editing!;
    expect(draft, first + 1);
    await controller.edit(first);
    expect(store.byId(draft), isNotNull);
    await controller.startNew();
    expect(controller.editing, draft);
    expect(store.notes, hasLength(2));

    // One written and emptied is no draft: the shortcut does not go on
    // with it.
    await store.update(draft, (note) => note.body = 'soon gone');
    await store.update(draft, (note) => note.body = '');
    await controller.hide();
    await controller.present();
    expect(controller.editing, isNot(draft));
    expect(store.byId(controller.editing!)!.isDraft, isTrue);
    controller.dispose();
  });

  testWidgets('Clarify in the panel\'s bar: in the background, its answer '
      'in the text; failed, why on hover and again on a click', (tester) async {
    await setUpFlow(tester);
    final previous = ModelProviders.current;
    addTearDown(() => ModelProviders.current = previous);
    await (ModelProviders.current = ModelProviders.memory()).setActionsModel(
      ModelProviders.followAuxiliary,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final note = await store.create(body: 'btn hidden');
    await controller.edit(note.id);
    final answer = Completer<String>();
    controller.clarifier = (controller, id, text) => answer.future;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashPanelView(controller: controller, viewId: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = englishLocalizations;

    await tester.tap(find.text(l10n.stashExpand));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.clarifying(note.id), isTrue);
    expect(find.text(l10n.stashClarifying), findsOneWidget);
    answer.complete('The button is hidden.');
    await tester.pumpAndSettle();
    expect(controller.clarifying(note.id), isFalse);
    expect(
      StashNoteEditorState.showing(note.id)!.markdown,
      startsWith('The button is hidden.'),
    );

    var asked = 0;
    controller.clarifier = (controller, id, text) async {
      asked++;
      throw const StashAiException('Not signed in');
    };
    await tester.tap(find.text(l10n.stashExpand));
    await tester.pumpAndSettle();
    expect(find.text(l10n.stashClarifyFailedShort), findsOneWidget);
    await tester.tap(find.text(l10n.stashClarifyFailedShort));
    await tester.pumpAndSettle();
    expect(asked, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    controller.dispose();
  });

  testWidgets('the panel is not kept on top unless its pin is on', (
    tester,
  ) async {
    await setUpFlow(tester);
    const window = MethodChannel('baocode/window.7');
    final onTop = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (
      call,
    ) async {
      if (call.method == 'setAlwaysOnTop') onTop.add(call.arguments);
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashPanelView(controller: controller, viewId: 7),
        ),
      ),
    );
    await tester.pump();
    expect(onTop, [false]);

    await tester.tap(find.byType(PinWindowButton));
    await tester.pump();
    expect(controller.pinned, isTrue);
    expect(onTop, [false, true]);
    await tester.tap(find.byType(PinWindowButton));
    await tester.pump();
    expect(onTop, [false, true, false]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the list of all: icons and numbers, picked with the keys, '
      'selected with Cmd, dragged into an order, deleted', (tester) async {
    await setUpFlow(tester);
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final first = await store.create(body: 'first');
    final second = await store.create(body: 'second');
    final third = await store.create(body: 'third [doc.pdf](/tmp/doc.pdf)');
    await controller.edit(third.id);
    controller.showAll = true;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashPanelView(controller: controller, viewId: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder row(String title) =>
        find.ancestor(of: find.text(title), matching: find.byType(IdeListRow));
    expect(row('first'), findsOneWidget);
    expect(
      find.descendant(
        of: row('third doc.pdf'),
        matching: find.byType(FileIcon),
      ),
      findsOneWidget,
    );
    // Its number shows on hover only.
    final number = find.descendant(
      of: row('first'),
      matching: find.text('#${first.id}'),
    );
    expect(number, findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(row('first')));
    await tester.pump();
    expect(number, findsOneWidget);
    await mouse.removePointer();
    await tester.pump();

    // Clicked: shown, the keyboard left in the list; down goes on.
    await tester.tap(row('second'));
    await tester.pumpAndSettle();
    expect(controller.editing, second.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(controller.editing, first.id);

    // Cmd (Ctrl) adds one; dragged below the last, both go there.
    final command = AppPlatform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(command);
    await tester.tap(row('third doc.pdf'));
    await tester.sendKeyUpEvent(command);
    await tester.pumpAndSettle();
    expect(tester.widget<IdeListRow>(row('third doc.pdf')).selected, isTrue);
    final bottom = tester.getBottomLeft(row('first'));
    final drag = await tester.startGesture(tester.getCenter(row('first')));
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    await drag.moveTo(bottom + const Offset(40, 4));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(controller.sort, StashSort.manual);
    expect(
      [for (final note in store.sorted(store.notes, StashSort.manual)) note.id],
      [second.id, third.id, first.id],
    );

    // Renamed in its row with the explorer's key.
    await tester.sendKeyEvent(
      KeybindingService.instance.platform.name == 'mac'
          ? LogicalKeyboardKey.enter
          : LogicalKeyboardKey.f2,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'renamed');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.byId(first.id)!.title, 'renamed');
    expect(row('renamed'), findsOneWidget);

    // Deleted with the keys, after asking: the one above shown.
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(store.byId(first.id), isNull);
    expect(store.byId(third.id), isNull);
    expect(controller.editing, second.id);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    controller.dispose();
  });

  testWidgets('the panel closed by the system hides as asked', (tester) async {
    await setUpFlow(tester);
    windows.stashCloseRequested = () => controller.hide();
    await controller.present();
    windows.windowCloseRequested(99);
    await tester.pump();
    expect(host.log.last, 'hideStash');
    controller.dispose();
  });

  testWidgets('agents write stashes down and mark them done', (tester) async {
    await setUpFlow(tester);
    await controller.start();
    expect(hotkeys, [StashSettings.defaultHotkey]);
    expect(controller.hotkeyTaken, isTrue);
    const call = ClaudeSdkCall(cwd: '/work/app', sessionId: 'session-1');
    Future<Map<String, Object?>> tool(
      String name,
      Map<String, Object?> arguments,
    ) async {
      final answer = await ClaudeSdkTools.handle({
        'id': 1,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      }, call);
      return answer['result']! as Map<String, Object?>;
    }

    final created = await tool('stash_create', {
      'text': 'Retry uploads on 503',
      'title': 'Upload retries',
    });
    expect(created['isError'], isNull);
    final note = store.notes.single;
    expect(note.title, 'Upload retries');
    expect(note.project, '/work/app');
    expect(note.source.thread, 'session-1');

    final read = await tool('stash_read', {'id': note.id});
    expect(
      ((read['content']! as List).single as Map)['text'],
      contains('Retry uploads on 503'),
    );

    await tool('stash_complete', {'id': '#${note.id}'});
    expect(store.byId(note.id)!.status, StashStatus.done);
    expect(store.byId(note.id)!.thread?.session, 'session-1');

    final missing = await tool('stash_complete', {'id': 404});
    expect(missing['isError'], isTrue);

    // Dragged or mentioned into a message, it goes as a reference.
    final reference = stashReferenceOf(store, store.byId(note.id)!);
    expect(reference.reference, '[Stash #${note.id}]');
    final split = splitCodeAppendix(
      'do ${reference.reference}${codeAppendix([reference])}',
    );
    expect(split.references.values.single, isA<StashReference>());

    // Start's delayed panel, made: nothing left pending.
    await tester.pump(const Duration(seconds: 3));
    controller.dispose();
  });
}

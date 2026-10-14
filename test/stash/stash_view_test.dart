import 'dart:async';

import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/stash/stash_ai.dart';
import 'package:baocode/stash/stash_controller.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_host.dart';
import 'package:baocode/stash/stash_note.dart';
import 'package:baocode/stash/stash_note_editor.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:baocode/sidebar/sidebar.dart' show SidebarIconButton;
import 'package:baocode/stash/stash_view.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StashStore store;
  late StashController controller;
  late ModelProviders models;
  final previous = ModelProviders.current;

  setUp(() {
    store = StashStore(MemoryStashDisk());
    controller = StashController(
      store: store,
      workspace: Workspace.mock(),
      host: StashHost(channel: const MethodChannel('test/stash-view')),
    );
    models = ModelProviders.current = ModelProviders.memory();
  });

  tearDown(() {
    ModelProviders.current = previous;
    controller.dispose();
  });

  group('said clearly in the background', () {
    test('its text replaced in its file once the answer comes, a collected '
        'one a requirement', () async {
      final note = await store.create(body: 'btn hidden\n\n## 需求\n\nold');
      final answer = Completer<String>();
      String? asked;
      controller.clarifier = (controller, id, text) {
        asked = text;
        return answer.future;
      };
      final clarifying = controller.clarify(note.id);
      expect(controller.clarifying(note.id), isTrue);
      expect(asked, 'btn hidden');
      answer.complete('The button is hidden.');
      await clarifying;
      expect(controller.clarifying(note.id), isFalse);
      expect(controller.clarifyFailure(note.id), isNull);
      final now = store.byId(note.id)!;
      expect(now.body, startsWith('The button is hidden.'));
      expect(now.body, contains('## 需求\n\nold'));
      expect(now.status, StashStatus.requirement);
    });

    test('a failure is kept with its message, until dismissed', () async {
      final note = await store.create(body: 'btn hidden');
      controller.clarifier = (controller, id, text) async =>
          throw const StashAiException('Not signed in');
      await controller.clarify(note.id);
      expect(controller.clarifyFailure(note.id), (
        changed: false,
        message: 'Not signed in',
      ));
      expect(store.byId(note.id)!.body, 'btn hidden');
      controller.dismissClarifyFailure(note.id);
      expect(controller.clarifyFailure(note.id), isNull);
    });

    test('a text changed meanwhile is not replaced', () async {
      final note = await store.create(body: 'btn hidden');
      controller.clarifier = (controller, id, text) async {
        await store.update(id, (note) => note.body = 'btn hidden, and more');
        return 'The button is hidden.';
      };
      await controller.clarify(note.id);
      expect(controller.clarifyFailure(note.id)?.changed, isTrue);
      expect(store.byId(note.id)!.body, 'btn hidden, and more');
    });
  });

  Future<void> pumpView(WidgetTester tester, {int? open}) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashView(
            controller: controller,
            onClose: () {},
            onOpenAgent: (_) {},
            initial: open,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('"Clarify" asks for a model first, then goes on in the '
      'background: the card says so, the editor gets the answer, Undo takes '
      'it back; there is no Split', (tester) async {
    final note = await tester.runAsync(() => store.create(body: 'btn hidden'));
    final answer = Completer<String>();
    controller.clarifier = (controller, id, text) => answer.future;
    await pumpView(tester, open: note!.id);
    expect(find.text('Split'), findsNothing);

    await tester.tap(find.text('Clarify'));
    await tester.pumpAndSettle();
    // None picked yet: the menu that picks one, saying so.
    expect(find.text(englishLocalizations.aiModelFirst), findsOneWidget);
    expect(controller.clarifying(note.id), isFalse);
    await tester.tap(find.text(englishLocalizations.aiModelAuxiliary));
    // Spinning while it goes on: never settled.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(models.actionsModel, ModelProviders.followAuxiliary);
    expect(controller.clarifying(note.id), isTrue);
    expect(find.text('Clarifying…'), findsWidgets);

    answer.complete('The button is hidden.');
    await tester.pumpAndSettle();
    expect(controller.clarifying(note.id), isFalse);
    final editor = StashNoteEditorState.showing(note.id)!;
    expect(editor.markdown, startsWith('The button is hidden.'));
    editor.editor!.widget.controller.undo();
    expect(editor.markdown, startsWith('btn hidden'));

    // Picked: the next one asks no more, and the arrow beside it changes
    // the model.
    controller.clarifier = (controller, id, text) async =>
        throw const StashAiException('Not signed in');
    await tester.tap(find.text('Clarify'));
    await tester.pumpAndSettle();
    expect(find.text(englishLocalizations.aiModelFirst), findsNothing);
    expect(
      find.text(englishLocalizations.stashExpandFailed('Not signed in')),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(controller.clarifyFailure(note.id), isNotNull);
    await tester.tap(find.text('Dismiss').last);
    await tester.pumpAndSettle();
    expect(
      find.text(englishLocalizations.stashExpandFailed('Not signed in')),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets('the line between the cards and the stash drags, the width '
      'kept; a double click puts it back', (tester) async {
    final note = await tester.runAsync(() => store.create(body: 'something'));
    await pumpView(tester, open: note!.id);
    final sash = find.byKey(const ValueKey('stash-sash'));
    final before = tester.getTopLeft(sash).dx;
    await tester.drag(sash, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sash).dx, closeTo(before - 150, 1));
    final kept = controller.detailWidth;
    expect(kept, isNotNull);

    // The cards keep their least.
    await tester.drag(sash, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sash).dx, greaterThanOrEqualTo(320));

    await tester.tap(sash);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(sash);
    await tester.pumpAndSettle();
    expect(controller.detailWidth, isNull);
    expect(tester.getTopLeft(sash).dx, closeTo(before, 1));
    await unmount(tester);
  });

  testWidgets('a stash\'s file shows as the Stash page shows it', (
    tester,
  ) async {
    final note = await tester.runAsync(
      () => store.create(body: 'see the sidebar'),
    );
    final view = stashFileView(controller);
    final path = '${store.root}/${note!.id}.md';
    expect(view.matches(path), isTrue);
    expect(view.matches('${store.root}/99.md'), isFalse);
    expect(view.matches('${store.root}/${note.id}/a.png'), isFalse);
    expect(view.matches('/elsewhere/${note.id}.md'), isFalse);

    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: Builder(builder: (context) => view.build(context, path)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StashDetail), findsOneWidget);
    expect(find.text('Clarify'), findsOneWidget);
    // In a tab: closed with it, no button of its own.
    expect(find.byIcon(Codicons.close), findsNothing);
    expect(StashNoteEditorState.showing(note.id)?.markdown, 'see the sidebar');
    await unmount(tester);
  });

  testWidgets('with the sidebar hidden on macOS, the toggle is clear of the '
      'traffic lights, before the title', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashView(
            controller: controller,
            onClose: () {},
            onOpenAgent: (_) {},
            leading: const SidebarIconButton(
              icon: Codicons.layoutSidebarLeftOff,
              tooltip: 'Show sidebar',
              onTap: _noop,
            ),
            titleBarInset: AppMetrics.trafficLightsWidth + 8,
          ),
        ),
      ),
    );
    await tester.pump();
    final toggle = tester.getRect(find.byIcon(Codicons.layoutSidebarLeftOff));
    final title = tester.getRect(find.text(englishLocalizations.stashTitle));
    expect(toggle.left, greaterThanOrEqualTo(AppMetrics.trafficLightsWidth));
    expect(toggle.right, lessThanOrEqualTo(title.left));
    await unmount(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}

void _noop() {}

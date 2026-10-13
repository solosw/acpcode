import 'package:bao_editor/monaco/flutter/keybinding_entry.dart'
    show KeybindingPlatform;
import 'package:baocode/keybindings/key_chord.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/pages/stash_hotkey_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only keys the system takes from any app, with a modifier', () {
    String? spec(KeyChord chord) =>
        StashHotkeyField.specOf(chord, KeybindingPlatform.mac);
    expect(
      spec(const KeyChord(LogicalKeyboardKey.space, ctrl: true, shift: true)),
      'ctrl+shift+space',
    );
    expect(
      spec(const KeyChord(LogicalKeyboardKey.keyN, alt: true, meta: true)),
      'alt+cmd+n',
    );
    expect(
      spec(const KeyChord(LogicalKeyboardKey.minus, ctrl: true)),
      'ctrl+-',
    );
    expect(spec(const KeyChord(LogicalKeyboardKey.keyN)), isNull);
    expect(spec(const KeyChord(LogicalKeyboardKey.home, ctrl: true)), isNull);
  });

  testWidgets('clicked, it records the keys pressed next; Escape keeps the '
      'one it had', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Scaffold(
          body: Center(
            child: StashHotkeyField(
              hotkey: 'ctrl+shift+space',
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    final field = find.byType(StashHotkeyField);
    expect(find.text('Press the keys…'), findsNothing);

    await tester.tap(field);
    await tester.pump();
    expect(find.text('Press the keys…'), findsOneWidget);
    // No modifier: not taken.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(changes, isEmpty);
    expect(
      find.text('Needs a modifier with a letter, digit or common key'),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Press the keys…'), findsNothing);
    expect(changes, isEmpty);

    await tester.tap(field);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(changes, ['alt+k']);

    // Backspace: none.
    await tester.tap(field);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(changes, ['alt+k', '']);
  });
}

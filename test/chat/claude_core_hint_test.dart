import 'package:baocode/chat/panels/claude_core_hint.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ValueNotifier<ClaudeCore> setting;
  late int switched;

  setUp(() {
    setting = ValueNotifier(ClaudeCore.builtin);
    switched = 0;
    ClaudeCore.current = () => setting.value;
    ClaudeCore.changes = setting;
    ClaudeCore.pick = (core) async => setting.value = core;
  });

  tearDown(() {
    ClaudeCore.current = () => ClaudeCore.cli;
    ClaudeCore.changes = ValueNotifier(0);
    ClaudeCore.pick = (_) async {};
    ClaudeCoreHint.putOff.value = false;
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ClaudeCoreHint(onSwitched: () => switched++)),
    ),
  );

  testWidgets('on the built-in core: the CLI suggested; switching picks '
      'it, and the hint goes', (tester) async {
    await pump(tester);
    expect(find.textContaining('built-in core'), findsOneWidget);
    await tester.tap(find.text('Switch to Claude Code'));
    await tester.pump();
    expect(setting.value, ClaudeCore.cli);
    expect(switched, 1);
    expect(find.textContaining('built-in core'), findsNothing);
  });

  testWidgets('on the CLI: nothing', (tester) async {
    setting.value = ClaudeCore.cli;
    await pump(tester);
    expect(find.textContaining('built-in core'), findsNothing);
  });

  testWidgets('put off: gone, the core left as it is', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Not Now'));
    await tester.pump();
    expect(find.textContaining('built-in core'), findsNothing);
    expect(setting.value, ClaudeCore.builtin);
    expect(switched, 0);
  });
}

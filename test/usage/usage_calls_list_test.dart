import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/usage/ui/usage_calls.dart';
import 'package:baocode/usage/ui/usage_dashboard.dart';
import 'package:baocode/usage/ui/usage_filters.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:baocode/usage/usage_record.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

UsageCall _call(DateTime at, String model) => UsageCall(
  at: at,
  duration: const Duration(seconds: 1),
  status: 200,
  provider: 'relay',
  model: model,
  session: 's1',
  input: 100,
  output: 50,
);

Widget _app(
  List<UsageCall> calls,
  UsageLedger ledger, {
  List<UsageCall> underway = const [],
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Material(
    child: SingleChildScrollView(
      child: UsageCallsList(
        calls: calls,
        underway: underway,
        ledger: ledger,
        showSession: false,
      ),
    ),
  ),
);

void main() {
  testWidgets('usage dashboard can filter the gateway calling clients', (
    tester,
  ) async {
    final ledger = UsageLedger(MemoryUsageStorage());
    addTearDown(ledger.dispose);
    for (final client in ['Codex', 'OpenCode']) {
      ledger.record(
        UsageCall(
          at: DateTime.now(),
          duration: const Duration(seconds: 1),
          status: 200,
          provider: 'relay',
          model: 'model',
          source: 'gateway',
          clientAgent: client,
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Material(child: UsageSettingsPage(ledger: ledger)),
      ),
    );
    await tester.pumpAndSettle();
    final finder = find.byWidgetPredicate(
      (widget) => widget is UsageMultiPicker<String> && widget.label == '代理',
    );
    expect(finder, findsOneWidget);
    final picker = tester.widget<UsageMultiPicker<String>>(finder);
    expect(
      picker.choices.map((choice) => choice.label),
      containsAll(['Codex', 'OpenCode']),
    );
    picker.onChanged({'gateway/Codex'});
    await tester.pumpAndSettle();
    expect(tester.widget<UsageMultiPicker<String>>(finder).selected, {
      'gateway/Codex',
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gateway calls show their calling client and gateway source', (
    tester,
  ) async {
    final ledger = UsageLedger(MemoryUsageStorage());
    addTearDown(ledger.dispose);
    final call = UsageCall(
      at: DateTime.now(),
      duration: const Duration(seconds: 1),
      status: 200,
      provider: 'relay',
      model: 'model',
      source: 'gateway',
      clientAgent: 'OpenCode',
    );
    await tester.pumpWidget(_app([call], ledger));
    expect(find.text('OpenCode'), findsOneWidget);
    await tester.tap(find.byType(UsageClassTag));
    await tester.pump();
    expect(find.textContaining('本地模型网关'), findsOneWidget);
    expect(find.textContaining('OpenCode'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a call opened stays open as the calls are read again', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 1, 16);
    final ledger = UsageLedger(MemoryUsageStorage(), clock: () => now);
    addTearDown(ledger.dispose);
    ledger
      ..record(_call(now, 'model-a'))
      ..record(_call(now.add(const Duration(seconds: 5)), 'model-b'));
    final first = await tester.runAsync(() => ledger.ofSession('s1'));
    await tester.pumpWidget(_app(first!, ledger));

    // The older one opened.
    await tester.tap(find.byType(UsageClassTag).last);
    await tester.pump();
    expect(find.byType(UsageCallDetail), findsOneWidget);
    final opened = tester.element(find.byType(UsageCallDetail));

    // A newer call kept: the same ones read again as new objects, one more
    // above them.
    ledger.record(_call(now.add(const Duration(seconds: 9)), 'model-c'));
    final again = await tester.runAsync(() => ledger.ofSession('s1'));
    expect(identical(again![0], first[0]), isFalse);
    await tester.pumpWidget(_app(again, ledger));

    expect(find.byType(UsageCallDetail), findsOneWidget);
    expect(tester.element(find.byType(UsageCallDetail)), same(opened));
    // The ledger's telling and writing.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a call under way shows above the rest, how far it is, and '
      'does not open', (tester) async {
    // As narrow as the side panel's.
    tester.view
      ..physicalSize = const Size(480, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 11, 1, 16);
    final ledger = UsageLedger(MemoryUsageStorage(), clock: () => now);
    addTearDown(ledger.dispose);
    UsageCall underway({Duration? firstToken}) => UsageCall(
      at: now.add(const Duration(seconds: 30)),
      duration: const Duration(minutes: 5, seconds: 10),
      firstToken: firstToken,
      status: 0,
      provider: 'relay',
      model: 'model-live',
      session: 's1',
    );
    await tester.pumpWidget(
      _app([_call(now, 'model-a')], ledger, underway: [underway()]),
    );
    expect(find.textContaining('请求中'), findsOneWidget);
    expect(find.textContaining('5m 10s'), findsOneWidget);
    // Above the call kept.
    expect(
      tester.getTopLeft(find.textContaining('model-live')).dy,
      lessThan(tester.getTopLeft(find.textContaining('model-a')).dy),
    );
    await tester.tap(find.byType(UsageClassTag).first);
    await tester.pump();
    expect(find.byType(UsageCallDetail), findsNothing);

    await tester.pumpWidget(
      _app(
        [_call(now, 'model-a')],
        ledger,
        underway: [underway(firstToken: const Duration(seconds: 23))],
      ),
    );
    expect(find.textContaining('输出中'), findsOneWidget);
    expect(find.textContaining('首字 23s'), findsOneWidget);

    // Its first, alone.
    await tester.pumpWidget(_app(const [], ledger, underway: [underway()]));
    expect(find.textContaining('请求中'), findsOneWidget);
  });

  testWidgets('a call Claude Code gave up on shows as cancelled, not as '
      'failed', (tester) async {
    tester.view
      ..physicalSize = const Size(480, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 11, 1, 16);
    final ledger = UsageLedger(MemoryUsageStorage(), clock: () => now);
    addTearDown(ledger.dispose);
    final cancelled = UsageCall(
      at: now,
      duration: const Duration(minutes: 10),
      status: UsageCall.cancelledStatus,
      provider: 'relay',
      model: 'model-gone',
      session: 's1',
    );
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.failed, isFalse);
    await tester.pumpWidget(_app([cancelled], ledger));
    expect(find.textContaining('已取消'), findsOneWidget);
    expect(find.textContaining('499'), findsNothing);
  });
}

import 'dart:async';

import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/ide/ide_input.dart';
import 'package:baocode/models/gateway/gateway_settings.dart';
import 'package:baocode/settings/pages/model_gateway_section.dart';
import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway extends ChangeNotifier implements ModelGateway {
  @override
  GatewayConfig config = const GatewayConfig();

  @override
  bool running = false;

  @override
  bool starting = false;

  @override
  String? error;

  final updates = <GatewayConfig>[];
  Completer<void>? applying;

  void statusChanged() => notifyListeners();

  @override
  String? get baseUrl => running ? 'http://127.0.0.1:${config.port}' : null;

  @override
  Future<void> update(GatewayConfig value) async {
    updates.add(value);
    starting = true;
    notifyListeners();
    await applying?.future;
    config = value;
    starting = false;
    running = value.enabled;
    error = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Gateway gateway;

  setUp(() => gateway = _Gateway());
  tearDown(() => gateway.dispose());

  Future<void> pump(WidgetTester tester, {double width = 900}) async {
    tester.view.physicalSize = Size(width, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModelGatewaySection(gateway: gateway),
          ),
        ),
      ),
    );
  }

  Finder field(String label) => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is IdeInputBox && widget.semanticsLabel == label,
    ),
    matching: find.byType(EditableText),
  );

  Future<void> change(WidgetTester tester, String label, String value) async {
    await tester.enterText(field(label), value);
    await tester.pump();
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.text('Save and Apply'));
    await tester.pump();
  }

  Future<void> toggle(WidgetTester tester, String label) async {
    final row = tester.widget<SettingsSwitchRow>(
      find.byWidgetPredicate(
        (widget) => widget is SettingsSwitchRow && widget.label == label,
      ),
    );
    row.onChanged(!row.value);
    await tester.pump();
  }

  testWidgets('default settings start the gateway and copy its address', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester);
    expect(
      tester.widget<EditableText>(field('Listening port')).controller.text,
      '8317',
    );
    expect(
      tester.widget<EditableText>(field('Gateway API key')).controller.text,
      'baocode',
    );
    expect(
      tester.widget<EditableText>(field('Gateway API key')).obscureText,
      isTrue,
    );
    await toggle(tester, 'Enable local gateway');
    expect(gateway.updates.single.enabled, isTrue);
    expect(gateway.updates.single.useNetworkProxy, isTrue);
    expect(find.text('Gateway is running'), findsOneWidget);
    await tester.tap(find.text('Copy Address'));
    await tester.pump();
    expect(copied, 'http://127.0.0.1:8317');
  });

  testWidgets('validates drafts and applies port, key and network proxy', (
    tester,
  ) async {
    await pump(tester);
    await change(tester, 'Listening port', '70000');
    await apply(tester);
    expect(find.text('Enter a port between 1 and 65535.'), findsOneWidget);
    expect(gateway.updates, isEmpty);
    await change(tester, 'Listening port', '8500');
    for (final key in ['', 'bad key', '密钥', String.fromCharCode(127)]) {
      await change(tester, 'Gateway API key', key);
      await apply(tester);
      expect(
        find.text(
          'Enter a non-empty key using printable ASCII characters without spaces.',
        ),
        findsOneWidget,
      );
      expect(gateway.updates, isEmpty);
    }
    await change(tester, 'Gateway API key', 'my-local-key');
    await toggle(tester, 'Use BaoCode network proxy');
    await apply(tester);
    expect(gateway.updates.single.port, 8500);
    expect(gateway.updates.single.apiKey, 'my-local-key');
    expect(gateway.updates.single.useNetworkProxy, isFalse);
    expect(gateway.updates.single.enabled, isFalse);
  });

  testWidgets('runtime updates keep drafts; stopping ignores invalid drafts', (
    tester,
  ) async {
    gateway.config = const GatewayConfig(enabled: true);
    gateway.running = true;
    await pump(tester);
    await change(tester, 'Listening port', 'invalid');
    gateway.error = 'Port is busy';
    gateway.statusChanged();
    await tester.pump();
    expect(
      tester.widget<EditableText>(field('Listening port')).controller.text,
      'invalid',
    );
    expect(find.text('Gateway error: Port is busy'), findsOneWidget);
    await toggle(tester, 'Enable local gateway');
    expect(gateway.updates.single.enabled, isFalse);
    expect(gateway.updates.single.port, 8317);
    expect(find.text('Gateway is stopped'), findsOneWidget);
    expect(
      tester.widget<EditableText>(field('Listening port')).controller.text,
      'invalid',
    );
  });

  testWidgets('shows applying status without narrow layout overflow', (
    tester,
  ) async {
    gateway.applying = Completer<void>();
    await pump(tester, width: 420);
    await toggle(tester, 'Enable local gateway');
    expect(find.text('Applying gateway settings…'), findsOneWidget);
    final button = tester.widget<IdeButton>(
      find.byWidgetPredicate(
        (widget) => widget is IdeButton && widget.label == 'Save and Apply',
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
    gateway.applying!.complete();
    // The update completes before the widget's awaiting save clears its busy
    // flag; render the frame scheduled by that continuation as well.
    await tester.pumpAndSettle();
    expect(find.text('Gateway is running'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/telemetry/telemetry_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends UserSettings {
  _Settings() : super('unused');

  @override
  final Map<String, Object?> values = {};

  @override
  Future<void> update(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    notifyListeners();
  }
}

void main() {
  testWidgets('telemetry switch writes off and removes the key to enable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = _Settings();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GeneralSettingsPage(settings: settings)),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = englishLocalizations;
    final row = find.byWidgetPredicate(
      (widget) =>
          widget is SettingsSwitchRow &&
          widget.label == l10n.generalSettingsTelemetry,
    );
    expect(tester.widget<SettingsSwitchRow>(row).value, isTrue);
    // The upstream options remain alongside the restored telemetry switch.
    expect(find.text(l10n.generalSettingsQueuedMessages), findsOneWidget);
    expect(find.text(l10n.generalSettingsPromptSuggestions), findsOneWidget);
    expect(find.text(l10n.generalSettingsComposerPolish), findsOneWidget);

    await tester.ensureVisible(row);
    await tester.tap(find.text(l10n.generalSettingsTelemetry));
    await tester.pumpAndSettle();
    expect(settings[TelemetrySetting.settingKey], TelemetrySetting.off);
    expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);

    await tester.tap(find.text(l10n.generalSettingsTelemetry));
    await tester.pumpAndSettle();
    expect(settings.values.containsKey(TelemetrySetting.settingKey), isFalse);
    expect(tester.widget<SettingsSwitchRow>(row).value, isTrue);

    await settings.update(TelemetrySetting.settingKey, 'error');
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/platform/sleep_prevention.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends UserSettings {
  _Settings([Map<String, Object?> initial = const {}])
    : values = {...initial},
      super('unused');
  @override
  final Map<String, Object?> values;
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disabled by default, listens only to this setting, releases on disposal',
    () async {
      final settings = _Settings();
      addTearDown(settings.dispose);
      final calls = <bool>[];
      final sleep = SleepPrevention(
        settings,
        setEnabled: (value) async => calls.add(value),
      );
      await sleep.start();
      await sleep.start();
      expect(calls, [false]);
      await settings.update('unrelated', true);
      await sleep.settled;
      expect(calls, [false]);
      await settings.update(SleepPrevention.settingKey, true);
      await sleep.settled;
      expect(calls, [false, true]);
      await settings.update(SleepPrevention.settingKey, 'true');
      await sleep.settled;
      expect(calls, [false, true, false]);
      await sleep.dispose();
      await sleep.dispose();
      await settings.update(SleepPrevention.settingKey, true);
      await sleep.start();
      expect(calls, [false, true, false, false]);
    },
  );

  test('persisted choice is restored after settings reload', () async {
    final dir = await Directory.systemTemp.createTemp('baocode-sleep-');
    addTearDown(() => dir.delete(recursive: true));
    final settings = UserSettings('${dir.path}/settings.json');
    addTearDown(settings.dispose);
    await settings.load();
    await settings.update(SleepPrevention.settingKey, true);
    final restored = UserSettings(settings.path);
    addTearDown(restored.dispose);
    await restored.load();
    final calls = <bool>[];
    final sleep = SleepPrevention(
      restored,
      setEnabled: (value) async => calls.add(value),
    );
    await sleep.start();
    expect(calls, [true]);
    await sleep.dispose();
    expect(calls, [true, false]);
    expect(restored[SleepPrevention.settingKey], isTrue);
  });

  test('late enable cannot overtake rapid disable and shutdown', () async {
    final settings = _Settings({SleepPrevention.settingKey: true});
    addTearDown(settings.dispose);
    final pending = Completer<void>();
    final calls = <bool>[];
    final sleep = SleepPrevention(
      settings,
      setEnabled: (value) async {
        calls.add(value);
        if (value) await pending.future;
      },
    );
    final started = sleep.start();
    await Future<void>.delayed(Duration.zero);
    await settings.update(SleepPrevention.settingKey, null);
    final stopped = sleep.dispose();
    expect(calls, [true]);
    pending.complete();
    await started;
    await stopped;
    expect(calls, [true, false, false]);
  });

  test(
    'native failures are reported without preventing later disable',
    () async {
      final settings = _Settings({SleepPrevention.settingKey: true});
      addTearDown(settings.dispose);
      final errors = <Object>[];
      final calls = <bool>[];
      final sleep = SleepPrevention(
        settings,
        onError: errors.add,
        setEnabled: (value) async {
          calls.add(value);
          if (value) throw PlatformException(code: 'sleep_prevention');
        },
      );
      await sleep.start();
      expect(errors, hasLength(1));
      await settings.update(SleepPrevention.settingKey, null);
      await sleep.settled;
      await sleep.dispose();
      expect(calls, [true, false, false]);
    },
  );

  testWidgets(
    'desktop sends process-wide native requests and releases on exit',
    (tester) async {
      const channel = MethodChannel('baocode/window');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final settings = _Settings({SleepPrevention.settingKey: true});
      addTearDown(settings.dispose);
      final sleep = SleepPrevention(settings);
      await sleep.start();
      await sleep.dispose();
      expect(calls.map((c) => c.method), [
        'setPreventSleep',
        'setPreventSleep',
      ]);
      expect(calls.map((c) => c.arguments), [true, false]);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'General switch is off by default and persists only the enabled override',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
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
      final label = englishLocalizations.generalSettingsPreventSleep;
      final row = find.byWidgetPredicate(
        (w) => w is SettingsSwitchRow && w.label == label,
      );
      expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(settings[SleepPrevention.settingKey], isTrue);
      expect(tester.widget<SettingsSwitchRow>(row).value, isTrue);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(settings.values.containsKey(SleepPrevention.settingKey), isFalse);
      expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'sleep prevention is not offered on mobile',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GeneralSettingsPage())),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(englishLocalizations.generalSettingsPreventSleep),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}

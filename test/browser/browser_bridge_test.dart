import 'dart:convert';
import 'dart:io';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/l10n/app_localizations_en.dart';
import 'package:baocode/settings/pages/browser_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final bridge = BrowserBridge.instance;
  late Directory home;
  late File manifest;

  setUp(() {
    // Short: a socket's path has a hundred bytes or so.
    final temp = Directory('/tmp').createTempSync('bao-');
    addTearDown(() => temp.deleteSync(recursive: true));
    BrowserBridge.socketFolder = temp.path;
    home = Directory(p.join(temp.path, 'home'));
    BrowserBridge.home = home.path;
    manifest = File(
      p.join(
        home.path,
        'Library/Application Support/Google/Chrome/NativeMessagingHosts',
        '${BrowserBridge.hostName}.json',
      ),
    )..createSync(recursive: true);
    addTearDown(() async {
      bridge.enabled = true;
      await bridge.stop();
      BrowserBridge.home = null;
      BrowserBridge.socketFolder = null;
    });
  });

  /// A host of the browser's, as host.c is: its hello with the extension's
  /// origin, then the extension's.
  Future<Socket> connect(Map<String, Object?> hello) async {
    final socket = await Socket.connect(
      InternetAddress(BrowserBridge.socketPath, type: InternetAddressType.unix),
      0,
    );
    void send(Map<String, Object?> message) {
      final body = utf8.encode(jsonEncode(message));
      socket
        ..add(
          (ByteData(
            4,
          )..setUint32(0, body.length, Endian.little)).buffer.asUint8List(),
        )
        ..add(body);
    }

    send({
      'type': 'hello',
      'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
    });
    send({'type': 'hello', ...hello});
    await socket.flush();
    return socket;
  }

  Future<void> until(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('an extension of another protocol is kept apart, and said so', () async {
    await bridge.start();
    final current = await connect({
      'browser': 'Google Chrome',
      'version': '0.1.0',
    });
    addTearDown(current.destroy);
    await until(() => bridge.browsers.isNotEmpty);
    expect(bridge.browsers.single.browser, 'Google Chrome');
    expect(bridge.browsers.single.protocol, BrowserBridge.protocol);

    final newer = await connect({
      'browser': 'Microsoft Edge',
      'version': '9.0.0',
      'protocol': BrowserBridge.protocol + 1,
    });
    addTearDown(newer.destroy);
    await until(() => bridge.mismatched.isNotEmpty);
    expect(bridge.browsers.single.browser, 'Google Chrome');
    expect(bridge.mismatched.single.browser, 'Microsoft Edge');

    final l10n = AppLocalizationsEn();
    expect(BrowserSettingsPage.status(l10n, bridge), [
      (
        l10n.browserSettingsConnected('Google Chrome'),
        l10n.browserSettingsExtensionVersion('0.1.0'),
      ),
      (
        l10n.browserSettingsIncompatible('Microsoft Edge'),
        l10n.browserSettingsAppOld,
      ),
    ]);
  }, skip: !Platform.isMacOS);

  test('turned off, it lets the browsers go and takes the host away; on, it '
      'listens again', () async {
    await bridge.start();
    final socket = await connect({'browser': 'Google Chrome'});
    addTearDown(socket.destroy);
    await until(() => bridge.browsers.isNotEmpty);
    expect(bridge.used, isTrue);

    var told = 0;
    void listener() => told++;
    bridge.addListener(listener);
    addTearDown(() => bridge.removeListener(listener));

    final settings = ValueNotifier<Object?>(false);
    bridge.follow(settings, () => settings.value);
    expect(bridge.enabled, isFalse);
    expect(told, greaterThan(0));
    expect(bridge.used, isFalse, reason: 'no tools, no side panel page');
    await until(() => bridge.browsers.isEmpty);
    expect(bridge.browsers, isEmpty);
    await until(() => !manifest.existsSync());
    expect(manifest.existsSync(), isFalse);
    expect(File(BrowserBridge.socketPath).existsSync(), isFalse);

    settings.value = null;
    expect(bridge.enabled, isTrue);
    await until(() => File(BrowserBridge.socketPath).existsSync());
    final again = await connect({'browser': 'Google Chrome'});
    addTearDown(again.destroy);
    await until(() => bridge.browsers.isNotEmpty);
    expect(bridge.used, isTrue);
  }, skip: !Platform.isMacOS);
}

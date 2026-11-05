import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_mirror.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ide/workbench/fake_files.dart';

// The extension's native-messaging protocol, with no real browser or user data.
class _Browser {
  _Browser(this.socket) {
    socket.listen((bytes) {
      _buffer.addAll(bytes);
      while (_buffer.length >= 4) {
        final size = ByteData.sublistView(
          Uint8List.fromList(_buffer.take(4).toList()),
        ).getUint32(0, Endian.little);
        if (_buffer.length < size + 4) return;
        final request = (jsonDecode(
          utf8.decode(_buffer.sublist(4, size + 4)),
        ) as Map).cast<String, Object?>();
        _buffer.removeRange(0, size + 4);
        requests.add(request);
        send({
          'id': request['id'],
          'result': request['method'] == 'tabs.list'
              ? tabs
              : <String, Object?>{},
        });
      }
    });
  }

  final Socket socket;
  final _buffer = <int>[];
  final requests = <Map<String, Object?>>[];
  final tabs = [
    {
      'tabId': 7,
      'title': 'First shared page',
      'url': 'https://example.test/one',
    },
    {
      'tabId': 9,
      'title': 'Second shared page',
      'url': 'https://example.test/two',
    },
  ];

  Iterable<Map> cdp(String method) => requests
      .where((request) => request['method'] == 'cdp')
      .map((request) => request['params'] as Map)
      .where((params) => params['method'] == method);

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

  void frame(int tabId) => send({
    'type': 'event',
    'event': 'cdp',
    'tabId': tabId,
    'method': 'Page.screencastFrame',
    'params': {
      // A 1x1 PNG, displayed in the page's viewport.
      'data': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'sessionId': 1,
      'metadata': {'deviceWidth': 800, 'deviceHeight': 600},
    },
  });
}

void main() {
  final bridge = BrowserBridge.instance;
  late Directory temp;
  late DataDirectory previousData;
  late bool previousLoopback;
  late AgentSidePanel panel;
  late ChatSession session;
  _Browser? browser;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bao-browser-panel-');
    previousData = DataDirectory.current;
    previousLoopback = BrowserBridge.loopback;
    DataDirectory.current = DataDirectory(temp.path);
    BrowserBridge.socketFolder = temp.path;
    BrowserBridge.home = '${temp.path}/home';
    BrowserBridge.loopback = true;
    BrowserTools.lastTab.value = null;
    panel = AgentSidePanel();
    session = ChatSession(historyCount: 0);
  });

  tearDown(() async {
    browser?.socket.destroy();
    browser = null;
    bridge.enabled = true;
    await bridge.stop();
    BrowserTools.lastTab.value = null;
    BrowserBridge.socketFolder = null;
    BrowserBridge.home = null;
    BrowserBridge.loopback = previousLoopback;
    DataDirectory.current = previousData;
    session.dispose();
    panel.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<void> connect(WidgetTester tester) async {
    await tester.runAsync(() async {
      await bridge.start();
      final [port, token] = File(BrowserBridge.portPath)
          .readAsStringSync()
          .split(' ');
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        int.parse(port),
      );
      browser = _Browser(socket);
      browser!.send({
        'type': 'hello',
        'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
        'token': token,
      });
      browser!.send({
        'type': 'hello',
        'browser': 'Test Chrome',
        'protocol': BrowserBridge.protocol,
      });
      for (var i = 0; i < 100 && bridge.browsers.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(bridge.browsers, hasLength(1));
    });
    await tester.pump();
  }

  Future<void> pumpIo(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> pumpPanel(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Row(
          children: [
            SidePanelRail(
              session: session,
              onSelect: (section) => panel.showSection(session, section),
            ),
            Expanded(
              child: AgentSidePanelView(
                files: TreeFiles({}),
                notifications: IdeNotifications(),
                panel: panel,
                session: session,
                watchDirectory: (_) => const Stream.empty(),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Finder browserRail() => find.descendant(
    of: find.byKey(const ValueKey('side-panel-rail')),
    matching: find.byIcon(Codicons.globe),
  );

  testWidgets('browser page and rail follow connection and enabled state', (
    tester,
  ) async {
    await tester.runAsync(() async {
      bridge.enabled = false;
      await bridge.stop();
    });
    panel.showSection(session, SidePanelSection.browser);
    await pumpPanel(tester);
    expect(browserRail(), findsNothing);
    expect(find.byType(BrowserMirror), findsNothing);
    expect(panel.tabsOf(session).shown, SidePanelSection.changes);

    await tester.runAsync(() async {
      bridge.enabled = true;
    });
    await connect(tester);
    await pumpIo(tester);
    expect(browserRail(), findsOneWidget);
    expect(find.byType(BrowserMirror), findsOneWidget);
    expect(panel.tabsOf(session).shown, SidePanelSection.browser);
    expect(panel.tabsOf(session).current, isNull);

    panel.showSection(session, SidePanelSection.changes);
    await tester.pump();
    expect(find.byType(BrowserMirror), findsNothing);
    await tester.tap(browserRail());
    await pumpIo(tester);
    expect(find.byType(BrowserMirror), findsOneWidget);

    browser!.tabs.clear();
    await tester.runAsync(() async {
      await bridge.stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    // A previously connected browser keeps its entry while disconnected.
    expect(browserRail(), findsOneWidget);
    expect(find.textContaining('No browser is connected.'), findsOneWidget);

    await tester.runAsync(() async {
      bridge.enabled = false;
      await bridge.stop();
    });
    await tester.pump();
    expect(browserRail(), findsNothing);
    expect(find.byType(BrowserMirror), findsNothing);
    expect(panel.tabsOf(session).shown, SidePanelSection.changes);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('browser mirror streams the selected tab and forwards input', (
    tester,
  ) async {
    await connect(tester);
    panel.showSection(session, SidePanelSection.browser);
    await pumpPanel(tester);
    await pumpIo(tester);
    expect(browser!.cdp('Page.startScreencast').last['tabId'], 7);
    expect(find.textContaining('First shared page'), findsOneWidget);

    browser!.frame(7);
    await pumpIo(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(browser!.cdp('Page.screencastFrameAck'), isNotEmpty);
    final page = find.byType(Image);
    await tester.tap(page);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpIo(tester);
    expect(
      browser!
          .cdp('Input.dispatchMouseEvent')
          .map((call) => (call['params'] as Map)['type']),
      containsAll(['mousePressed', 'mouseReleased']),
    );
    expect(
      browser!
          .cdp('Input.dispatchKeyEvent')
          .map((call) => (call['params'] as Map)['key']),
      contains('Enter'),
    );

    await tester.tap(find.byTooltip('Reload'));
    await tester.tap(find.byTooltip('Show in Browser'));
    await pumpIo(tester);
    expect(browser!.cdp('Page.reload').last['tabId'], 7);
    expect(
      browser!.requests.where(
        (request) => request['method'] == 'tabs.activate',
      ),
      isNotEmpty,
    );

    await tester.tap(find.byTooltip('Shared Tabs'));
    await pumpIo(tester);
    await tester.tap(find.text('Second shared page'));
    await pumpIo(tester);
    expect(browser!.cdp('Page.startScreencast').last['tabId'], 9);

    BrowserTools.show(7);
    await pumpIo(tester);
    expect(browser!.cdp('Page.startScreencast').last['tabId'], 7);
    expect(BrowserTools.lastTab.value?.tabId, 7);

    panel.closeCurrent(session);
    expect(panel.shown, isFalse);
    await tester.pumpWidget(const SizedBox());
    await pumpIo(tester);
    expect(browser!.cdp('Page.stopScreencast').last['tabId'], 7);
  });
}

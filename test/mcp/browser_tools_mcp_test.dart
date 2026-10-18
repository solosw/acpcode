@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/mcp/tools_bridge.dart';
import 'package:baocode/mcp/tools_protocol.dart';
import 'package:baocode/mcp/tools_stdio.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('user MCP calls browser_tabs through the extension bridge', () async {
    final temp = Directory('/tmp').createTempSync('bao-browser-mcp-');
    final browser = BrowserBridge.instance;
    final tools = ToolsBridge.instance;
    BrowserBridge.home = p.join(temp.path, 'home');
    BrowserBridge.socketFolder = temp.path;
    DataDirectory.current = DataDirectory(p.join(temp.path, 'data'));
    Socket? extension;
    try {
      await browser.start();
      extension = await Socket.connect(
        InternetAddress(
          BrowserBridge.socketPath,
          type: InternetAddressType.unix,
        ),
        0,
      );
      void send(Map<String, Object?> message) {
        final body = utf8.encode(jsonEncode(message));
        extension!
          ..add(
            (ByteData(
              4,
            )..setUint32(0, body.length, Endian.little)).buffer.asUint8List(),
          )
          ..add(body);
      }

      var buffer = <int>[];
      extension.listen((bytes) {
        buffer.addAll(bytes);
        while (buffer.length >= 4) {
          final length = ByteData.sublistView(
            Uint8List.fromList(buffer),
            0,
            4,
          ).getUint32(0, Endian.little);
          if (buffer.length < length + 4) break;
          final request =
              jsonDecode(utf8.decode(buffer.sublist(4, length + 4))) as Map;
          buffer = buffer.sublist(length + 4);
          if (request['method'] == 'tabs.list') {
            send({
              'id': request['id'],
              'result': [
                {
                  'id': 7,
                  'tabId': 7,
                  'title': 'Shared test page',
                  'url': 'about:blank',
                },
              ],
            });
          }
        }
      });
      send({
        'type': 'hello',
        'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
      });
      send({
        'type': 'hello',
        'browser': 'Test browser',
        'protocol': BrowserBridge.protocol,
      });
      await extension.flush();
      for (var i = 0; i < 100 && browser.browsers.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(browser.browsers, hasLength(1));
      BrowserTools.register();
      await tools.start();
      final lines = <String>[];
      final controller = StreamController<List<int>>();
      final output = IOSink(controller.sink);
      final collect = controller.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      final code = await runToolsStdio(
        const [ToolsProtocol.flag],
        environment: {
          ToolsProtocol.dataDirectoryVariable: DataDirectory.current.path,
        },
        input: Stream.value(
          utf8.encode(
            '${jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {'name': 'browser_tabs', 'arguments': {}},
            })}\n',
          ),
        ),
        output: output,
      );
      expect(code, 0);
      final reply = jsonDecode(lines.single) as Map;
      expect((reply['result'] as Map)['isError'], isNot(true));
      final content =
          ((reply['result'] as Map)['content'] as List).single as Map;
      expect(content['text'], contains('Shared test page'));
      expect(content['text'], contains('Test browser'));
      await output.close();
      await collect.cancel();
    } finally {
      BrowserTools.unregister();
      extension?.destroy();
      await browser.stop();
      await tools.stop();
      BrowserBridge.home = null;
      BrowserBridge.socketFolder = null;
      temp.deleteSync(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}

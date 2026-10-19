@TestOn('vm')
library;

// The app's own executable, started as an agent's MCP server, answers with
// the running app's tools: what an ACP agent does (lib/mcp/tools_stdio.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/mcp/tools_bridge.dart';
import 'package:baocode/mcp/tools_protocol.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Built by `flutter build macos --release`, or where a run says it is.
  final app =
      Platform.environment['BAOCODE_MCP_TEST_APP'] ??
      'build/macos/Build/Products/Release/BaoCode.app/Contents/MacOS/BaoCode';
  final built = File(app).existsSync();

  test(
    'MCP stdio stays headless while waiting for client requests on macOS',
    () async {
      final data = Directory.systemTemp.createTempSync('tools-stdio-headless-');
      addTearDown(() => data.deleteSync(recursive: true));
      final probe = '${data.path}/window-probe';
      final compiled = await Process.run('xcrun', [
        'swiftc',
        'test/fixtures/mcp/window_probe.swift',
        '-o',
        probe,
      ]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      DataDirectory.current = DataDirectory(data.path);
      final bridge = ToolsBridge.instance;
      await bridge.start();
      addTearDown(bridge.stop);
      final process = await Process.start(app, const [
        ToolsProtocol.flag,
      ], environment: bridge.environmentFor(cwd: '/tmp/project-headless'));
      addTearDown(() => process.kill());
      final errors = process.stderr.transform(utf8.decoder).join();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(lines.cancel);
      process.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {},
        }),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 30)),
        isTrue,
      );
      expect(jsonDecode(lines.current), containsPair('id', 1));
      // Keep stdin open like an agent does for the entire conversation.
      // The previous test closed it immediately and missed the blank window.
      final result = await Process.run(probe, ['${process.pid}']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final state = jsonDecode(result.stdout as String) as Map;
      expect(
        state['maxVisibleWindows'],
        0,
        reason: 'An MCP server must not open a conversation window',
      );
      expect(state['activationPolicies'], [
        2,
      ], reason: 'An MCP child must be prohibited from activating a GUI');
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isNot(contains('BaoCode MCP:')));
    },
    skip: !Platform.isMacOS || !built
        ? 'requires a built macOS app and the macOS window server'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final discover in [false, true]) {
    test(
      'the built app answers with app tools (user endpoint: $discover)',
      () async {
        final data = Directory.systemTemp.createTempSync('tools-stdio-real-');
        addTearDown(() => data.deleteSync(recursive: true));
        DataDirectory.current = DataDirectory(data.path);
        final bridge = ToolsBridge.instance;
        await bridge.start();
        addTearDown(bridge.stop);
        ClaudeSdkTools.register(
          const ClaudeSdkTool(
            name: 'which_project',
            description: 'The project the call is about.',
            inputSchema: {'type': 'object'},
            run: _whichProject,
          ),
        );
        addTearDown(() => ClaudeSdkTools.unregister('which_project'));

        final process = await Process.start(
          app,
          const [ToolsProtocol.flag],
          environment: discover
              ? {ToolsProtocol.dataDirectoryVariable: data.path}
              : bridge.environmentFor(
                  cwd: '/tmp/project-e2e',
                  session: 'session-e2e',
                ),
          includeParentEnvironment: true,
        );
        addTearDown(() => process.kill());
        final errors = process.stderr.transform(utf8.decoder).join();
        final read = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((line) => jsonDecode(line) as Map<String, Object?>)
            .toList();
        process.stdin
          ..writeln(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': {},
            }),
          )
          ..writeln(
            jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
          )
          ..writeln(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 3,
              'method': 'tools/call',
              'params': {'name': 'which_project', 'arguments': {}},
            }),
          );
        await process.stdin.flush();
        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 60)),
          0,
          reason: 'a server ends once its messages do',
        );
        final answers = await read;
        expect(await errors, isNot(contains('BaoCode MCP:')));
        expect(answers, hasLength(3));
        final call = answers.singleWhere((answer) => answer['id'] == 3);
        expect(
          ((call['result']! as Map)['content']! as List).single,
          containsPair(
            'text',
            discover ? Directory.current.path : '/tmp/project-e2e',
          ),
          reason: 'the tool ran in the app, for the project it was given',
        );
      },
      skip: built
          ? false
          : 'the app is not built: flutter build macos --release',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<String> _whichProject(
  Map<String, Object?> input,
  ClaudeSdkCall call,
) async => call.cwd;

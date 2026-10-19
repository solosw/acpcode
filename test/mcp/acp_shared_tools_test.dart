@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/mcp/tools_bridge.dart';
import 'package:baocode/mcp/tools_protocol.dart';
import 'package:baocode/mcp/tools_registration.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttp extends HttpOverrides {}

void main() {
  late Directory temp;
  late DataDirectory previousData;
  late Map<String, String> environment;
  final bridge = ToolsBridge.instance;
  late CustomizationStore store;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('shared-acp-tools-');
    previousData = DataDirectory.current;
    DataDirectory.current = DataDirectory(p.join(temp.path, 'data'));
    environment = {
      'HOME': temp.path,
      'CLAUDE_CONFIG_DIR': p.join(temp.path, '.claude'),
    };
    store = CustomizationStore(
      homeDir: temp.path,
      configDir: environment['CLAUDE_CONFIG_DIR'],
    );
    await Future.wait(List.generate(5, (_) => bridge.start()));
    expect(bridge.http?.url, isNotNull);
    // A shared HTTP connection must not even need to resolve a launcher.
    await registerBaocodeTools(
      store: store,
      command: p.join(temp.path, 'missing-launcher'),
      dataDirectory: DataDirectory.current.path,
    );
  });
  tearDown(() async {
    await bridge.stop();
    DataDirectory.current = previousData;
    temp.deleteSync(recursive: true);
  });

  Future<AcpMcpServers> load(
    String project, {
    Map<String, Object?> capabilities = const {'http': true},
  }) => loadAcpMcpServers(
    KernelContext(cwd: project),
    capabilities,
    environment: environment,
  );

  Future<int> ping(Map<String, Object?> config) async {
    final http = _RealHttp().createHttpClient(null);
    try {
      final request = await http.postUrl(Uri.parse(config['url'] as String));
      for (final header in config['headers'] as List) {
        request.headers.set(
          header['name'] as String,
          header['value'] as String,
        );
      }
      request.headers.contentType = ContentType.json;
      request.headers.set('Accept', 'application/json, text/event-stream');
      request.write('{"jsonrpc":"2.0","id":1,"method":"ping"}');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      http.close(force: true);
    }
  }

  test(
    'all local conversations connect to one listener without a launcher',
    () async {
      final configFile = File(p.join(temp.path, '.claude.json'));
      final before = configFile.readAsStringSync();
      final loaded = await Future.wait([
        load('/project one'),
        load('/project two'),
      ]);
      for (final item in loaded) {
        expect(item.warnings, isEmpty);
        expect(item.servers.single['name'], 'baocode');
        expect(item.servers.single['type'], 'http');
        expect(item.servers.single.containsKey('command'), isFalse);
        expect(item.servers.single.containsKey('args'), isFalse);
      }
      final first = loaded[0].servers.single;
      final second = loaded[1].servers.single;
      expect(first['url'], second['url']);
      expect(first['headers'], isNot(second['headers']));
      expect(await ping(first), 200);
      expect(await ping(second), 200);
      loaded[0].close();
      expect(await ping(first), 401);
      expect(await ping(second), 200);
      loaded[1].close();
      // Transient URLs and capabilities must never be persisted to disk.
      expect(configFile.readAsStringSync(), before);
      expect(before, isNot(contains(first['url'] as String)));
    },
  );

  test(
    'stdio-only ACP agents retain the compatible headless launcher',
    () async {
      await registerBaocodeTools(
        store: store,
        command: Platform.resolvedExecutable,
        dataDirectory: DataDirectory.current.path,
      );
      final loaded = await load('/project', capabilities: {});
      expect(loaded.warnings, isEmpty);
      expect(loaded.servers.single['command'], Platform.resolvedExecutable);
      expect(loaded.servers.single['args'], [ToolsProtocol.flag]);
      expect(loaded.servers.single.containsKey('url'), isFalse);
      loaded.close();
    },
  );

  test(
    'project override is not replaced by the shared built-in server',
    () async {
      final project = Directory(p.join(temp.path, 'project'))..createSync();
      File(p.join(project.path, '.mcp.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'baocode': {'type': 'http', 'url': 'https://example.test/mcp'},
          },
        }),
      );
      final loaded = await load(project.path);
      expect(loaded.servers.single['url'], 'https://example.test/mcp');
      expect(loaded.servers.single['headers'], isEmpty);
      loaded.close();
    },
  );

  test(
    'disabled built-in server does not acquire a shared connection',
    () async {
      final project = p.join(temp.path, 'project');
      final file = File(p.join(temp.path, '.claude.json'));
      final config = jsonDecode(file.readAsStringSync()) as Map;
      config['projects'] = {
        project: {
          'disabledMcpServers': ['baocode'],
        },
      };
      file.writeAsStringSync(jsonEncode(config));
      final loaded = await load(project);
      expect(loaded.servers, isEmpty);
      loaded.close();
    },
  );

  test(
    'another data profile is not silently attached to the running app',
    () async {
      await registerBaocodeTools(
        store: store,
        command: Platform.resolvedExecutable,
        dataDirectory: p.join(temp.path, 'other-profile'),
      );
      final loaded = await load('/project');
      expect(loaded.servers.single.containsKey('url'), isFalse);
      expect(loaded.servers.single['command'], Platform.resolvedExecutable);
      loaded.close();
    },
  );

  test(
    'resume uses the resumed project when opening the shared connection',
    () async {
      final loaded = await loadAcpMcpServers(
        KernelContext(
          resume: SessionRecord(
            id: 'resume',
            title: 'Resume',
            cwd: '/resumed',
            updatedAt: DateTime.now(),
          ),
        ),
        {'http': true},
        environment: environment,
      );
      expect(loaded.servers.single['type'], 'http');
      expect(await ping(loaded.servers.single), 200);
      loaded.close();
    },
  );
}

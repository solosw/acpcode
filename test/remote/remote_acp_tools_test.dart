@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart' show RemoteHello, RemoteProtocol;
import 'package:bao_remote/server.dart' show ServerMcp;
import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/mcp/tools_bridge.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/remote/remote_host_settings.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  late Directory temp;
  late DataDirectory previousData;
  late SshHosts previousHosts;
  late RemoteHostSettings previousSettings;
  late MemoryConnector connector;
  late String home;
  late String project;
  late HttpClient http;
  final tools = ToolsBridge.instance;
  final loaded = <AcpMcpServers>[];

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('ssh-acp-tools-');
    previousData = DataDirectory.current;
    previousHosts = SshHosts.instance;
    previousSettings = RemoteHostSettings.instance;
    DataDirectory.current = DataDirectory(p.join(temp.path, 'client-data'));
    final serverData = Directory(p.join(temp.path, 'server-data'))
      ..createSync();
    home = Directory(p.join(temp.path, 'remote-home')).path;
    project = Directory(p.join(temp.path, 'project')).path;
    Directory(home).createSync();
    Directory(project).createSync();
    connector = MemoryConnector(serverData.path);
    SshHosts.instance = SshHosts(connect: connector.call);
    RemoteHostSettings.instance = RemoteHostSettings();
    http = _RealHttp().createHttpClient(null)..findProxy = (_) => 'DIRECT';
    await tools.start();
    expect(tools.http?.url, isNotNull);
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'ssh_context',
        description: 'Returns the app-side project context',
        inputSchema: const {'type': 'object'},
        run: (_, call) async => call.cwd,
      ),
    );
  });

  tearDown(() async {
    for (final item in loaded) {
      item.close();
    }
    loaded.clear();
    ClaudeSdkTools.unregister('ssh_context');
    ClaudeSdkTools.unregister('ssh_wait');
    http.close(force: true);
    await tools.stop();
    SshHosts.instance.dispose();
    SshHosts.instance = previousHosts;
    RemoteHostSettings.instance.dispose();
    RemoteHostSettings.instance = previousSettings;
    DataDirectory.current = previousData;
    temp.deleteSync(recursive: true);
  });

  Future<AcpMcpServers> load({
    Map<String, Object?> capabilities = const {'http': true},
    String? at,
    bool resume = false,
  }) async {
    final cwd = RemoteLocation.of('dev', at ?? project);
    final result = await loadAcpMcpServers(
      resume
          ? KernelContext(
              resume: SessionRecord(
                id: 'resume',
                title: 'Resume',
                cwd: cwd,
                updatedAt: DateTime.now(),
              ),
            )
          : KernelContext(cwd: cwd),
      capabilities,
      environment: {'HOME': home, 'CLAUDE_CONFIG_DIR': p.join(home, '.claude')},
    );
    loaded.add(result);
    return result;
  }

  Future<(int, Map<String, Object?>)> rpc(
    Map<String, Object?> config, {
    String method = 'ping',
    Map<String, Object?>? params,
    Uri? target,
    String? authority,
  }) async {
    final request = await http.postUrl(
      target ?? Uri.parse(config['url'] as String),
    );
    for (final header in config['headers'] as List) {
      request.headers.set(header['name'] as String, header['value'] as String);
    }
    if (authority != null) request.headers.set('Host', authority);
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'application/json, text/event-stream');
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': ?params,
      }),
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (
      response.statusCode,
      body.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(body) as Map).cast<String, Object?>(),
    );
  }

  void userConfig(Map<String, Object?> value) =>
      File(p.join(home, '.claude.json')).writeAsStringSync(jsonEncode(value));

  test(
    'SSH HTTP MCP reaches the app with remote context and no disk registration',
    () async {
      final first = await load();
      expect(first.warnings, isEmpty);
      final config = first.servers.single;
      expect(config['name'], 'baocode');
      expect(config['type'], 'http');
      final uri = Uri.parse(config['url'] as String);
      expect(uri.host, '127.0.0.1');
      expect(uri.port, isNot(tools.http!.url!.port));
      final client = await SshHosts.instance['dev'].ready;
      expect(client.forwardedPorts, contains(uri.port));
      final (status, response) = await rpc(
        config,
        method: 'tools/call',
        params: {'name': 'ssh_context', 'arguments': <String, Object?>{}},
      );
      expect(status, 200);
      expect(response.toString(), contains(RemoteLocation.of('dev', project)));
      expect(File(p.join(home, '.claude.json')).existsSync(), isFalse);
      expect(File(p.join(project, '.mcp.json')).existsSync(), isFalse);
      first.close();
      await until(() => client.forwardedPorts.isEmpty);
      // The same capability is revoked even if the forwarded listener is gone.
      expect(
        (await rpc(
          config,
          target: tools.http!.url,
          authority: uri.authority,
        )).$1,
        401,
      );
    },
  );

  test(
    'resumed conversations isolate tokens, authorities and pending calls',
    () async {
      final first = await load();
      final otherProject = Directory(p.join(temp.path, 'other'))..createSync();
      final second = await load(at: otherProject.path, resume: true);
      final one = first.servers.single;
      final two = second.servers.single;
      expect(one['headers'], isNot(two['headers']));
      final (status, context) = await rpc(
        two,
        method: 'tools/call',
        params: {'name': 'ssh_context', 'arguments': <String, Object?>{}},
      );
      expect(status, 200);
      expect(
        context.toString(),
        contains(RemoteLocation.of('dev', otherProject.path)),
      );
      // A token cannot be used with another conversation's forwarded authority.
      expect((await rpc(one, target: Uri.parse(two['url'] as String))).$1, 403);
      expect((await rpc(one, authority: 'attacker.invalid')).$1, 403);
      final waiting = Completer<void>();
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'ssh_wait',
          description: 'Wait for cancellation',
          inputSchema: const {'type': 'object'},
          run: (_, call) async {
            waiting.complete();
            await call.cancelled;
            return 'cancelled';
          },
        ),
      );
      final pending = rpc(
        one,
        method: 'tools/call',
        params: {'name': 'ssh_wait', 'arguments': <String, Object?>{}},
      );
      await waiting.future.timeout(const Duration(seconds: 3));
      first.close();
      await pending.timeout(const Duration(seconds: 3));
      expect((await rpc(two)).$1, 200);
    },
  );

  test(
    'remote user and project servers take precedence over the app fallback',
    () async {
      userConfig({
        'mcpServers': {
          'baocode': {'command': '/bin/sh'},
        },
      });
      final user = await load();
      expect(user.servers.single['command'], '/bin/sh');
      File(p.join(project, '.mcp.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'baocode': {'url': 'https://example.test/mcp'},
          },
        }),
      );
      final shared = await load();
      expect(shared.servers.single['url'], 'https://example.test/mcp');
      final client = await SshHosts.instance['dev'].ready;
      expect(client.forwardedPorts, isEmpty);
    },
  );

  test(
    'remote disabled name suppresses an unregistered app fallback',
    () async {
      userConfig({
        'projects': {
          project: {
            'disabledMcpServers': ['baocode'],
          },
        },
      });
      final result = await load();
      expect(result.servers, isEmpty);
      expect(result.warnings, isEmpty);
      expect((await SshHosts.instance['dev'].ready).forwardedPorts, isEmpty);
    },
  );

  test('local access switch blocks and revokes only the app bridge', () async {
    final first = await load();
    final config = first.servers.single;
    final uri = Uri.parse(config['url'] as String);
    RemoteHostSettings.instance.setLocalAccess('dev', false);
    final client = await SshHosts.instance['dev'].ready;
    await until(() => client.forwardedPorts.isEmpty);
    expect(
      (await rpc(config, target: tools.http!.url, authority: uri.authority)).$1,
      401,
    );
    final blocked = await load();
    expect(blocked.servers, isEmpty);
    expect(blocked.warnings.single, contains('local access'));
    userConfig({
      'mcpServers': {
        'own': {'command': '/bin/sh'},
      },
    });
    final own = await load();
    expect(own.servers.single['name'], 'own');
  });

  test('app fallback needs no POSIX commands on a Windows SSH host', () async {
    final client = await SshHosts.instance['dev'].ready;
    const command = [
      r'C:\Program Files\BaoCode\baocode-server.exe',
      'mcp-stdio',
    ];
    client.hello = RemoteHello.fromJson({
      ...client.hello!.toJson(),
      'platform': {'os': 'win', 'arch': 'x64'},
      'mcpStdioCommand': command,
    });
    final run =
        connector.links.single.server.peer.handlers[RemoteProtocol.processRun]!;
    connector.links.single.server.peer.handlers[RemoteProtocol.processRun] =
        (params, call) {
          final executable = (params as Map)['executable'];
          if (executable == 'env' || executable == 'sh') {
            fail('The app fallback must not require POSIX commands');
          }
          return run(params, call);
        };
    final direct = await load();
    expect(direct.warnings, isEmpty);
    expect((await rpc(direct.servers.single)).$1, 200);
    final stdio = await load(capabilities: {});
    expect(stdio.warnings, isEmpty);
    expect(stdio.servers.single['command'], command.first);
    expect(stdio.servers.single['args'], ['mcp-stdio']);
  });

  test(
    'old servers retain HTTP support and warn for the missing stdio relay',
    () async {
      final client = await SshHosts.instance['dev'].ready;
      client.hello = RemoteHello.fromJson({
        ...client.hello!.toJson(),
        'mcpStdioCommand': <String>[],
      });
      final stdio = await load(capabilities: {});
      expect(stdio.servers, isEmpty);
      expect(stdio.warnings.single, contains('remote server needs an update'));
      expect(client.forwardedPorts, isEmpty);
      final direct = await load();
      expect((await rpc(direct.servers.single)).$1, 200);
    },
  );

  test('a lost SSH session revokes its app capability', () async {
    final result = await load();
    final config = result.servers.single;
    final uri = Uri.parse(config['url'] as String);
    await connector.links.single.drop();
    expect(
      (await rpc(config, target: tools.http!.url, authority: uri.authority)).$1,
      401,
    );
  });

  test('stdio-only SSH ACP uses the server relay and keeps secrets out of arguments', () async {
    final previousCommand = ServerMcp.selfCommand;
    final dartLookup = await Process.run('sh', ['-c', 'command -v dart']);
    expect(dartLookup.exitCode, 0);
    final dart = (dartLookup.stdout as String).trim();
    ServerMcp.selfCommand = () => [
      dart,
      p.absolute('test/fixtures/remote_mcp_stdio.dart'),
    ];
    addTearDown(() => ServerMcp.selfCommand = previousCommand);
    final result = await load(capabilities: {});
    expect(result.warnings, isEmpty);
    final config = result.servers.single;
    expect(config['name'], 'baocode');
    expect(config['command'], dart);
    expect(config['args'], [
      p.absolute('test/fixtures/remote_mcp_stdio.dart'),
      'mcp-stdio',
    ]);
    final env = {
      for (final entry in config['env'] as List)
        entry['name'] as String: entry['value'] as String,
    };
    expect(env['BAOCODE_MCP_TOKEN'], isNotEmpty);
    expect(
      config['args'].toString(),
      isNot(contains(env['BAOCODE_MCP_TOKEN'])),
    );
    expect(config.toString(), isNot(contains(DataDirectory.current.path)));
    final client = await SshHosts.instance['dev'].ready;
    final process = await client.start(
      config['command'] as String,
      (config['args'] as List).cast<String>(),
      cwd: project,
      environment: env,
    );
    final replies = <Map>[];
    final out = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          replies.add(jsonDecode(line) as Map);
        });
    final errors = process.stderr.transform(utf8.decoder).join();
    process.write(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'ssh_context', 'arguments': <String, Object?>{}},
        })}\n',
      ),
    );
    await until(() => replies.isNotEmpty);
    expect(
      replies.single.toString(),
      contains(RemoteLocation.of('dev', project)),
    );
    result.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 5)),
      isNonZero,
    );
    expect(await errors, isNot(contains(env['BAOCODE_MCP_TOKEN'])));
    await out.cancel();
  });
}

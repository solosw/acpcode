import 'dart:io';

import 'package:baocode/customize/customizations.dart';
import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/acp/acp_mcp_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Customization server(
  String name,
  Map<String, Object?> config, {
  CustomizationScope scope = CustomizationScope.project,
  bool? enabled,
}) => Customization(
  kind: CustomizationKind.mcps,
  scope: scope,
  name: name,
  path: '/project/.mcp.json',
  server: config,
  enabled: enabled,
);

void main() {
  Future<AcpMcpServers> build(
    List<Customization> items, {
    Map<String, Object?> capabilities = const {},
    Map<String, String> environment = const {},
    AcpMcpCommandResolver? resolve,
  }) => buildAcpMcpServers(
    items,
    capabilities: capabilities,
    environment: environment,
    resolveCommand: resolve ?? (command, _) async => '/bin/$command',
  );

  test(
    'stdio maps env to ACP records, expands values and resolves command',
    () async {
      final resolved = <String>[];
      final result = await build(
        [
          server('browser', {
            'command': r'${RUNNER}',
            'args': ['--stdio', r'${OPTION:-default}', 'two words'],
            'env': {'TOKEN': r'${TOKEN}', 'PATH': '/tools'},
          }),
        ],
        environment: {'RUNNER': 'npx', 'TOKEN': 'secret', 'PATH': '/bin'},
        resolve: (command, env) async {
          resolved.add(command);
          expect(env['PATH'], '/tools');
          expect(env['TOKEN'], 'secret');
          return '/tools/npx';
        },
      );
      expect(resolved, ['npx']);
      expect(result.warnings, isEmpty);
      expect(result.servers, [
        {
          'name': 'browser',
          'command': '/tools/npx',
          'args': ['--stdio', 'default', 'two words'],
          'env': [
            {'name': 'TOKEN', 'value': 'secret'},
            {'name': 'PATH', 'value': '/tools'},
          ],
        },
      ]);
      // The entire inherited environment is not sent as MCP env.
      expect(result.servers.single.toString(), isNot(contains('RUNNER')));
    },
  );

  test('stdio defaults are required ACP arrays; no type tag', () async {
    final result = await build([
      server('stdio', {'command': 'server'}),
    ]);
    expect(result.servers.single, {
      'name': 'stdio',
      'command': '/bin/server',
      'args': [],
      'env': [],
    });
  });

  test('HTTP and SSE map headers only with advertised capabilities', () async {
    final items = [
      server('http', {
        'type': 'http',
        'url': r'https://${HOST}/mcp',
        'headers': {'Authorization': r'Bearer ${TOKEN}'},
      }),
      server('sse', {'type': 'sse', 'url': 'https://example.com/sse'}),
    ];
    final result = await build(
      items,
      capabilities: {'http': true, 'sse': true},
      environment: {'HOST': 'example.com', 'TOKEN': 'secret'},
    );
    expect(result.servers, [
      {
        'type': 'http',
        'name': 'http',
        'url': 'https://example.com/mcp',
        'headers': [
          {'name': 'Authorization', 'value': 'Bearer secret'},
        ],
      },
      {
        'type': 'sse',
        'name': 'sse',
        'url': 'https://example.com/sse',
        'headers': [],
      },
    ]);
    expect(result.warnings, isEmpty);
    final unsupported = await build(items);
    expect(unsupported.servers, isEmpty);
    expect(unsupported.warnings, hasLength(2));
    expect(unsupported.warnings.join(), isNot(contains('secret')));
    final httpOnly = await build(
      items,
      capabilities: {'http': true},
      environment: {'HOST': 'example.com', 'TOKEN': 'secret'},
    );
    expect(httpOnly.servers.single['type'], 'http');
    expect(httpOnly.warnings.single, contains('sse transport'));
  });

  test('URL without type defaults to HTTP, not stdio', () async {
    final result = await build(
      [
        server('api', {'url': 'https://example.com/mcp'}),
      ],
      capabilities: {'http': true},
    );
    expect(result.servers.single['type'], 'http');
  });

  test(
    'private project overrides shared project, which overrides user',
    () async {
      final result = await build([
        server('same', {'command': 'private'}, scope: CustomizationScope.local),
        server('same', {'command': 'user'}, scope: CustomizationScope.user),
        server('same', {'command': 'shared'}),
        server('other', {'command': 'user'}, scope: CustomizationScope.user),
      ]);
      expect(result.servers.map((entry) => entry['command']), [
        '/bin/private',
        '/bin/user',
      ]);
    },
  );

  test('disabled winning configuration does not fall back to user', () async {
    final result = await build([
      server('same', {'command': 'user'}, scope: CustomizationScope.user),
      server('same', {'command': 'project'}, enabled: false),
      server(
        'off',
        {'command': 'private'},
        scope: CustomizationScope.local,
        enabled: false,
      ),
    ], resolve: (_, _) async => fail('Disabled server must not be resolved'));
    expect(result.servers, isEmpty);
    expect(result.warnings, isEmpty);
  });

  test(
    'account connectors without connection details are not transferred',
    () async {
      final result = await build([
        const Customization(
          kind: CustomizationKind.mcps,
          scope: CustomizationScope.synced,
          name: 'account',
          path: '/state.json',
        ),
      ]);
      expect(result.servers, isEmpty);
      expect(result.warnings, isEmpty);
    },
  );

  test(
    'malformed configs warn without preventing valid stdio servers',
    () async {
      final result = await build(
        [
          server('args', {
            'command': 'server',
            'args': [1],
          }),
          server('env', {
            'command': 'server',
            'env': {'TOKEN': 123},
          }),
          server('command', {}),
          server('url', {'type': 'http', 'url': 'file:///secret'}),
          server('type', {'type': 'websocket', 'url': 'wss://example.com'}),
          server('valid', {'command': 'server'}),
        ],
        capabilities: {'http': true},
      );
      expect(result.warnings, hasLength(5));
      expect(result.warnings.join(), isNot(contains('file:///secret')));
      expect(result.servers.single['name'], 'valid');
    },
  );

  test(
    'missing env and executable give actionable, secret-free warnings',
    () async {
      final result = await build(
        [
          server('env', {
            'type': 'http',
            'url': 'https://example.com',
            'headers': {'Authorization': r'Bearer ${MISSING}'},
          }),
          server('command', {'command': 'secret-command'}),
        ],
        capabilities: {'http': true},
        resolve: (_, _) async => null,
      );
      expect(result.servers, isEmpty);
      expect(result.warnings.first, contains('MISSING'));
      expect(result.warnings.last, contains('executable not found'));
      expect(result.warnings.join(), isNot(contains('secret-command')));
    },
  );

  test(
    'resolves absolute, relative and PATH executable names on local host',
    () {
      final directory = Directory.systemTemp.createTempSync('acp-mcp-command-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final bin = Directory(p.join(directory.path, 'bin'))..createSync();
      final command = File(p.join(bin.path, 'mcp'))..writeAsStringSync('');
      final env = {'PATH': bin.path};
      expect(resolveLocalMcpCommand('mcp', env), command.path);
      expect(resolveLocalMcpCommand(command.path, const {}), command.path);
      expect(
        resolveLocalMcpCommand('./bin/mcp', const {}, cwd: directory.path),
        command.path,
      );
      expect(resolveLocalMcpCommand('missing', env), isNull);
    },
  );
  test(
    'Windows PATH, PATHEXT and case-insensitive overrides resolve correctly',
    () {
      final existing = {r'C:\tools\npx.cmd', r'C:\override\mcp.EXE'};
      final args = {'Path': r'C:\tools', 'PATHEXT': '.EXE;.CMD'};
      expect(
        resolveLocalMcpCommand(
          'npx',
          args,
          windows: true,
          cwd: r'C:\project',
          fileExists: existing.contains,
        ),
        r'C:\tools\npx.cmd',
      );
      expect(
        resolveLocalMcpCommand(
          'mcp',
          {...args, 'PATH': r'C:\override'},
          windows: true,
          cwd: r'C:\project',
          fileExists: existing.contains,
        ),
        r'C:\override\mcp.EXE',
      );
      expect(
        resolveLocalMcpCommand(
          r'C:\tools\npx.cmd',
          const {},
          windows: true,
          cwd: r'C:\project',
          fileExists: existing.contains,
        ),
        r'C:\tools\npx.cmd',
      );
    },
  );
}

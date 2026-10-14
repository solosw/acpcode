import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'loads the configured host files with scope precedence and disable state',
    () async {
      final directory = Directory.systemTemp.createTempSync('acp-mcp-config-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final home = p.join(directory.path, 'home');
      final config = p.join(home, '.claude');
      final project = p.join(directory.path, 'project');
      Directory(config).createSync(recursive: true);
      Directory(project).createSync();
      File(p.join(home, '.claude.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'same': {
              'command': Platform.resolvedExecutable,
              'args': ['user'],
            },
            'off': {'command': Platform.resolvedExecutable},
            'user': {'command': Platform.resolvedExecutable},
          },
          'projects': {
            project: {
              'mcpServers': {
                'same': {
                  'command': Platform.resolvedExecutable,
                  'args': ['private'],
                },
              },
              'disabledMcpServers': ['off'],
              'disabledMcpjsonServers': ['shared-off'],
            },
          },
        }),
      );
      File(p.join(project, '.mcp.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'same': {
              'command': Platform.resolvedExecutable,
              'args': ['shared'],
            },
            'shared-off': {'command': Platform.resolvedExecutable},
            'api': {
              'url': 'https://example.com/mcp',
              'headers': {'Authorization': r'Bearer ${TOKEN}'},
            },
          },
        }),
      );
      ClaudeEnvironment.use({'TOKEN': 'inherited'});
      addTearDown(() => ClaudeEnvironment.use(null));
      final result = await loadAcpMcpServers(
        KernelContext(cwd: project),
        {'http': true},
        environment: {
          'HOME': home,
          'CLAUDE_CONFIG_DIR': config,
          'TOKEN': 'override',
        },
      );
      expect(result.warnings, isEmpty);
      final byName = {
        for (final server in result.servers) server['name']: server,
      };
      expect(byName.keys, unorderedEquals(['same', 'user', 'api']));
      expect(byName['same']!['args'], ['private']);
      expect(byName['api']!['headers'], [
        {'name': 'Authorization', 'value': 'Bearer override'},
      ]);
    },
  );

  test('resume cwd selects project MCP when explicit cwd is absent', () async {
    final directory = Directory.systemTemp.createTempSync('acp-mcp-resume-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final config = p.join(directory.path, '.claude');
    Directory(config).createSync();
    File(p.join(directory.path, '.mcp.json')).writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'browser': {'command': Platform.resolvedExecutable},
        },
      }),
    );
    ClaudeEnvironment.use({});
    addTearDown(() => ClaudeEnvironment.use(null));
    final result = await loadAcpMcpServers(
      KernelContext(
        resume: SessionRecord(
          id: 'saved',
          title: 'Saved',
          cwd: directory.path,
          updatedAt: DateTime.utc(2026),
        ),
      ),
      const {},
      environment: {'HOME': directory.path, 'CLAUDE_CONFIG_DIR': config},
    );
    expect(result.servers.single['name'], 'browser');
  });
}

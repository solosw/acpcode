@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/acp/acp_mcp.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

void main() {
  test(
    'SSH MCP uses remote files, login env and POSIX executable resolution',
    () async {
      final directory = Directory.systemTemp.createTempSync('remote-acp-mcp-');
      final root = directory.resolveSymbolicLinksSync();
      final data = Directory(p.join(root, 'data'))..createSync();
      final home = p.join(root, 'home');
      final config = p.join(home, '.claude');
      final project = p.join(root, 'project');
      Directory(config).createSync(recursive: true);
      Directory(project).createSync();
      // Executable names with spaces are looked up as one argument, never code.
      final executable = File(p.join(project, 'server with spaces'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      File(p.join(home, '.claude.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'user': {'command': '/bin/sh'},
          },
          'projects': {
            project: {
              'disabledMcpjsonServers': ['off'],
            },
          },
        }),
      );
      final marker = p.join(project, 'must-not-exist');
      File(p.join(project, '.mcp.json')).writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'browser': {
              'command': './server with spaces',
              'args': [r'${HOME}'],
              'env': {
                'HOME_OF_AGENT': r'${HOME}',
                'HOST_ONLY': r'${SHELL:-/bin/sh}',
              },
            },
            'off': {'command': '/bin/sh'},
            'api': {
              'url': 'https://example.com/mcp',
              'headers': {'X-Host': r'${HOME}'},
            },
            'unsafe-name': {'command': 'sh; touch "$marker"'},
          },
        }),
      );
      final previous = SshHosts.instance;
      SshHosts.instance = SshHosts(connect: MemoryConnector(data.path).call);
      ClaudeEnvironment.use({
        'HOME': r'C:\Users\client',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'SHELL': Platform.environment['SHELL'] ?? '/bin/sh',
      });
      addTearDown(() {
        SshHosts.instance.dispose();
        SshHosts.instance = previous;
        ClaudeEnvironment.use(null);
        directory.deleteSync(recursive: true);
      });
      final result = await loadAcpMcpServers(
        KernelContext(cwd: RemoteLocation.of('dev', project)),
        {'http': true},
        environment: {'HOME': home, 'CLAUDE_CONFIG_DIR': config},
      );
      final byName = {
        for (final server in result.servers) server['name']: server,
      };
      expect(byName.keys, unorderedEquals(['user', 'browser', 'api']));
      expect(byName['browser']!['command'], executable.path);
      expect(byName['browser']!['args'], [home]);
      final env = byName['browser']!['env'] as List;
      expect(env.singleWhere((entry) => entry['name'] == 'HOME_OF_AGENT'), {
        'name': 'HOME_OF_AGENT',
        'value': home,
      });
      expect(result.servers.toString(), isNot(contains(r'C:\Users\client')));
      expect(byName['api']!['headers'], [
        {'name': 'X-Host', 'value': home},
      ]);
      expect(result.warnings.single, contains('unsafe-name'));
      expect(File(marker).existsSync(), isFalse);
    },
  );
}

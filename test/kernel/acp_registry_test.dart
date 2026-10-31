import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/kernel/acp_registry.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Registry extends AcpRegistry {
  final commands = <(String, List<String>)>[];
  final downloads = <Uri>[];
  Uint8List bytes = Uint8List(0);
  Object? failure;

  @override
  String get platform => 'darwin-aarch64';

  @override
  Future<Uint8List> download(Uri uri, int maxBytes) async {
    downloads.add(uri);
    return bytes;
  }

  @override
  Future<void> prepare(String command, List<String> arguments) async {
    commands.add((command, arguments));
    if (failure case final error?) throw error;
  }
}

AcpRegistryEntry _entry(Map<String, Object?> distribution) => AcpRegistryEntry(
  id: 'example',
  name: 'Example',
  description: 'Example ACP agent',
  version: '1.2.3',
  distribution: distribution,
);

Uint8List _tar(String name, String content) {
  final body = utf8.encode(content);
  final bytes = Uint8List(512 + ((body.length + 511) ~/ 512) * 512 + 1024);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, ascii.encode(value));
  text(0, name);
  text(100, '0000755');
  text(124, body.length.toRadixString(8).padLeft(11, '0'));
  text(148, '        ');
  text(156, '0');
  text(257, 'ustar');
  final sum = bytes.take(512).fold(0, (int sum, byte) => sum + byte);
  text(148, sum.toRadixString(8).padLeft(6, '0'));
  bytes.setRange(512, 512 + body.length, body);
  return Uint8List.fromList(gzip.encode(bytes));
}

void main() {
  test('reads official agents array, ignores invalid ids and sorts names', () {
    final entries = AcpRegistryEntry.parse({
      'version': '1.0.0',
      'agents': [
        {'id': 'z', 'name': 'Zed', 'distribution': <String, Object?>{}},
        {'id': '../escape', 'name': 'Bad', 'distribution': <String, Object?>{}},
        {'id': 'a', 'name': 'Alpha', 'distribution': <String, Object?>{}},
        {'id': 'incomplete'},
      ],
    });
    expect(entries.map((entry) => entry.id), ['a', 'z']);
    expect(() => AcpRegistryEntry.parse([]), throwsFormatException);
  });

  test('npx keeps scoped pinned package, arguments and environment', () async {
    final registry = _Registry();
    final entry = _entry({
      'npx': {
        'package': '@agentclientprotocol/codex-acp@2.5.0',
        'args': ['--profile', 'with spaces'],
        'env': {'EXAMPLE': 'value with spaces'},
      },
    });
    registry.bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'agents': [
            {
              'id': entry.id,
              'name': entry.name,
              'distribution': entry.distribution,
            },
          ],
        }),
      ),
    );
    expect(await registry.load(), hasLength(1));
    expect(registry.commands, isEmpty); // Browsing never executes a package.
    expect(registry.downloads.single.toString(), acpRegistryUrl);
    final agent = await registry.install(entry);
    expect(agent.command, 'npx');
    expect(agent.arguments, [
      '-y',
      '@agentclientprotocol/codex-acp@2.5.0',
      '--profile',
      'with spaces',
    ]);
    expect(agent.environment, {'EXAMPLE': 'value with spaces'});
    expect(registry.commands.single.$1, 'npm');
    expect(registry.commands.single.$2, [
      'exec',
      '--yes',
      '--package',
      '@agentclientprotocol/codex-acp@2.5.0',
      '--',
      'node',
      '-e',
      'process.exit(0)',
    ]);
  });

  test('uvx caches and launches the same pinned version', () async {
    final registry = _Registry();
    final agent = await registry.install(
      _entry({
        'uvx': {
          'package': 'minion-code@0.1.44',
          'args': ['acp'],
        },
      }),
    );
    expect(agent.command, 'uvx');
    expect(agent.arguments, ['minion-code==0.1.44', 'acp']);
    expect(registry.commands.single.$1, 'uvx');
    expect(registry.commands.single.$2, [
      '--from',
      'minion-code==0.1.44',
      'python',
      '-c',
      'pass',
    ]);
  });

  test(
    'unversioned packages, options and unsupported platforms are refused',
    () async {
      for (final package in [
        'example',
        '--help',
        'example@latest;touch /tmp/a',
        'https://example.com/agent.tgz',
      ]) {
        expect(
          _entry({
            'npx': {'package': package},
          }).planFor('linux-x86_64'),
          isNull,
        );
      }
      final registry = _Registry();
      await expectLater(registry.install(_entry({})), throwsUnsupportedError);
      expect(registry.commands, isEmpty);
    },
  );

  test('binary recipe rejects escapes, non-HTTPS and malformed digests', () {
    for (final command in [
      '../agent',
      '/bin/agent',
      r'C:\agent.exe',
      r'..\agent',
    ]) {
      expect(
        _entry({
          'binary': {
            'darwin-aarch64': {
              'archive': 'https://example.com/agent.zip',
              'cmd': command,
            },
          },
        }).planFor('darwin-aarch64'),
        isNull,
      );
    }
    expect(
      _entry({
        'binary': {
          'darwin-aarch64': {
            'archive': 'http://example.com/agent.zip',
            'cmd': './agent',
          },
        },
      }).planFor('darwin-aarch64'),
      isNull,
    );
    expect(
      _entry({
        'binary': {
          'darwin-aarch64': {
            'archive': 'https://example.com/agent.zip',
            'cmd': './agent',
            'sha256': 'bad',
          },
        },
      }).planFor('darwin-aarch64'),
      isNull,
    );
  });

  group('binary installation', () {
    late Directory temporary;
    late DataDirectory previous;
    setUp(() {
      temporary = Directory.systemTemp.createTempSync('baocode-acp-registry-');
      previous = DataDirectory.current;
      DataDirectory.current = DataDirectory(temporary.path);
    });
    tearDown(() {
      DataDirectory.current = previous;
      temporary.deleteSync(recursive: true);
    });

    test('checks digest, unpacks locally, does not start agent', () async {
      final registry = _Registry()
        ..bytes = _tar('bin/agent', 'example contents');
      final config = await registry.install(
        _entry({
          'binary': {
            'darwin-aarch64': {
              'archive': 'https://example.com/agent.tar.gz',
              'cmd': './bin/agent',
              'args': ['acp'],
              'sha256': sha256.convert(registry.bytes).toString(),
            },
          },
        }),
      );
      expect(File(config.command).readAsStringSync(), 'example contents');
      expect(p.isWithin(temporary.path, config.command), isTrue);
      expect(config.arguments, ['acp']);
      expect(registry.commands, isEmpty);
      expect(DataDirectory.items, contains('acp-agents'));
    });

    test('digest mismatch installs nothing', () async {
      final registry = _Registry()..bytes = _tar('agent', 'contents');
      await expectLater(
        registry.install(
          _entry({
            'binary': {
              'darwin-aarch64': {
                'archive': 'https://example.com/agent.tar.gz',
                'cmd': './agent',
                'sha256': List.filled(64, '0').join(),
              },
            },
          }),
        ),
        throwsFormatException,
      );
      expect(
        Directory(p.join(temporary.path, 'acp-agents')).existsSync(),
        isFalse,
      );
    });

    test(
      'archive traversal and missing executable clean up partial installs',
      () async {
        final registry = _Registry();
        for (final path in ['../../escape', 'not-the-agent']) {
          registry.bytes = _tar(path, 'contents');
          await expectLater(
            registry.install(
              _entry({
                'binary': {
                  'darwin-aarch64': {
                    'archive': 'https://example.com/agent.tar.gz',
                    'cmd': './agent',
                  },
                },
              }),
            ),
            throwsA(isA<Exception>()),
          );
          expect(
            Directory(p.join(temporary.path, 'acp-agents', 'example'))
                .listSync(),
            isEmpty,
          );
        }
        expect(File(p.join(temporary.path, 'escape')).existsSync(), isFalse);
      },
    );
  });

  test(
    'package failure propagates without producing a configuration',
    () async {
      final registry = _Registry()..failure = StateError('npm unavailable');
      await expectLater(
        registry.install(
          _entry({
            'npx': {'package': 'example@1.2.3'},
          }),
        ),
        throwsStateError,
      );
    },
  );
}

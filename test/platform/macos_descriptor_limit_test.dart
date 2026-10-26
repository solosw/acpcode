@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS raises only a low soft limit before either Flutter engine starts',
    () async {
      final source = File('macos/Runner/MainFlutterWindow.swift')
          .readAsStringSync();
      final start = source.indexOf(
        '  private static func prepareFileDescriptors() {',
      );
      final end = source.indexOf('\n  override func awakeFromNib()', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final launch = source.substring(end);
      expect(
        launch.indexOf('Self.prepareFileDescriptors()'),
        lessThan(launch.indexOf('if Self.isToolsStdio')),
      );
      final method = source
          .substring(start, end)
          .replaceFirst('private static func', 'func');
      final temp = Directory.systemTemp.createTempSync('baocode-fd-limit-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final swift = File('${temp.path}/limit.swift')
        ..writeAsStringSync('''
import Foundation
import Darwin
$method
var before = rlimit()
precondition(getrlimit(RLIMIT_NOFILE, &before) == 0)
before.rlim_cur = rlim_t(CommandLine.arguments[1])!
if CommandLine.arguments.count > 2 {
  before.rlim_max = rlim_t(CommandLine.arguments[2])!
}
precondition(setrlimit(RLIMIT_NOFILE, &before) == 0)
prepareFileDescriptors()
var after = rlimit()
precondition(getrlimit(RLIMIT_NOFILE, &after) == 0)
precondition(after.rlim_max == before.rlim_max)
print(after.rlim_cur)
''');
      final binary = '${temp.path}/limit';
      final compiled = await Process.run('xcrun', [
        'swiftc',
        swift.path,
        '-o',
        binary,
      ]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      for (final (arguments, expected) in [
        (['256'], '4096'),
        (['8192'], '8192'),
        (['256', '512'], '512'),
      ]) {
        final result = await Process.run(binary, arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect('${result.stdout}'.trim(), expected);
      }
    },
  );
}

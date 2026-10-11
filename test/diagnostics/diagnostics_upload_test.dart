import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:baocode/diagnostics/diagnostics_upload.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  group('answer', () {
    test('201 with the id: uploaded', () {
      final result = DiagnosticsUploader.answer(
        201,
        '{"id":"D7F3K2QX"}',
        omittedDumps: 2,
      );
      expect(result, isA<DiagnosticsUploaded>());
      result as DiagnosticsUploaded;
      expect(result.id, 'D7F3K2QX');
      expect(result.omittedDumps, 2);
    });

    test('a 2xx without an id it knows: the server failed', () {
      for (final body in ['', '{}', '{"id":"<b>"}', '[1]']) {
        final result = DiagnosticsUploader.answer(201, body);
        expect(result, isA<DiagnosticsFailed>());
        expect((result as DiagnosticsFailed).reason, DiagnosticsFailure.server);
      }
    });

    test('the statuses', () {
      DiagnosticsFailure reason(int status) =>
          (DiagnosticsUploader.answer(status, '') as DiagnosticsFailed).reason;
      expect(reason(413), DiagnosticsFailure.tooLarge);
      expect(reason(429), DiagnosticsFailure.rateLimited);
      expect(reason(400), DiagnosticsFailure.refused);
      expect(reason(404), DiagnosticsFailure.refused);
      expect(reason(500), DiagnosticsFailure.server);
      expect(reason(302), DiagnosticsFailure.server);
    });
  });

  group('upload', () {
    late Directory logs;
    late HttpServer server;
    late List<int> received;
    late ContentType? type;
    var status = 201;

    setUp(() async {
      HttpOverrides.global = _RealHttp();
      logs = await Directory.systemTemp.createTemp('baocode-diagnostics');
      File(p.join(logs.path, 'errors.log'))
          .writeAsStringSync('boom in /home/ann/a.dart\n');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      status = 201;
      server.listen((request) async {
        type = request.headers.contentType;
        received = [for (final chunk in await request.toList()) ...chunk];
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(status == 201 ? '{"id":"D7F3K2QX"}' : '{}');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await logs.delete(recursive: true);
      HttpOverrides.global = null;
    });

    DiagnosticsUploader uploader() => DiagnosticsUploader(
      folder: logs.path,
      url: Uri.parse('http://127.0.0.1:${server.port}/v1/diagnostics'),
      version: '1.0.7+8',
      os: 'linux',
      osVersion: '  Ubuntu 24.04  ',
      arch: 'x64',
      home: '/home/ann',
    );

    test('the meta and the logs, as multipart', () async {
      final result = await uploader().upload(
        note: '  卡住了  ',
        dumps: false,
        locale: 'zh',
      );
      expect((result as DiagnosticsUploaded).id, 'D7F3K2QX');
      expect(type?.mimeType, 'multipart/form-data');
      final boundary = type!.parameters['boundary']!;
      final text = latin1.decode(received);
      expect(text, startsWith('--$boundary\r\n'));
      expect(text, endsWith('\r\n--$boundary--\r\n'));
      final parts = text.split('--$boundary');
      expect(parts[1], contains('name="meta"'));
      final meta = jsonDecode(
        utf8.decode(latin1.encode(parts[1].split('\r\n\r\n')[1].trim())),
      );
      expect(meta, {
        'v': 1,
        'version': '1.0.7+8',
        'os': 'linux',
        'os_version': 'Ubuntu 24.04',
        'arch': 'x64',
        'locale': 'zh',
        'note': '卡住了',
        'files': [
          {'name': 'errors.log', 'size': 'boom in ~/a.dart\n'.length},
        ],
      });
      expect(parts[2], contains('name="logs"; filename="diagnostics.tar.gz"'));
      final logs = latin1.encode(
        parts[2].substring(parts[2].indexOf('\r\n\r\n') + 4),
      );
      final tar = gzip.decode(logs.sublist(0, logs.length - 2));
      expect(utf8.decode(tar), contains('boom in ~/a.dart'));
    });

    test('no note, a locale it would refuse, a long note clipped', () async {
      await uploader().upload(note: '   ', dumps: false, locale: 'zh Hans');
      var meta = _meta(received, type!);
      expect(meta.containsKey('note'), isFalse);
      expect(meta.containsKey('locale'), isFalse);

      await uploader().upload(note: '字' * 2100, dumps: false);
      meta = _meta(received, type!);
      expect(
        (meta['note'] as String).runes.length,
        DiagnosticsUploader.maxNote,
      );
    });

    test('a refusal, and no server', () async {
      status = 429;
      final limited = await uploader().upload(note: '', dumps: false);
      expect(
        (limited as DiagnosticsFailed).reason,
        DiagnosticsFailure.rateLimited,
      );
      expect(limited.status, 429);

      final gone = uploader();
      await server.close(force: true);
      final offline = await gone.upload(note: '', dumps: false);
      expect((offline as DiagnosticsFailed).reason, DiagnosticsFailure.network);
    });
  });
}

Map<String, Object?> _meta(List<int> body, ContentType type) {
  final boundary = type.parameters['boundary']!;
  final part = latin1.decode(body).split('--$boundary')[1];
  return jsonDecode(
    utf8.decode(latin1.encode(part.split('\r\n\r\n')[1].trim())),
  ) as Map<String, Object?>;
}

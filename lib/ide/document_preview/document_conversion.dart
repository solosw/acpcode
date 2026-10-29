import 'dart:typed_data';

import 'document_conversion_stub.dart'
    if (dart.library.io) 'document_conversion_io.dart'
    as platform;

/// The bundled Tectonic engine. Never searches PATH or downloads at runtime.
abstract interface class DocumentConverter {
  factory DocumentConverter() = platform.LocalDocumentConverter;

  Future<DocumentConversion> latex(String path, String source);
}

class DocumentConversion {
  const DocumentConversion(this.bytes, this.log);
  final Uint8List bytes;
  final String log;
}

enum DocumentConversionFailure { unavailable, missingTex, failed, timeout }

class DocumentConversionException implements Exception {
  const DocumentConversionException(this.failure, [this.log = '']);
  final DocumentConversionFailure failure;
  final String log;
  @override
  String toString() => '$failure: $log';
}

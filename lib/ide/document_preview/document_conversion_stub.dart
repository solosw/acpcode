import 'document_conversion.dart';

class LocalDocumentConverter implements DocumentConverter {
  @override
  Future<DocumentConversion> latex(String path, String source) async =>
      throw const DocumentConversionException(
        DocumentConversionFailure.unavailable,
      );
}

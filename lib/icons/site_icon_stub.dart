import 'dart:typed_data';

/// None on the web.
Future<T?> fetchSiteIcon<T>(
  Uri site,
  Future<T> Function(Uint8List bytes) take,
) async => null;

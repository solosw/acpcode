import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// OOXML only: never extract paths to disk, load external relationships, or run
/// macros. Bound both compressed input and declared expanded size before parsing.
Archive openOfficeArchive(Uint8List bytes) {
  if (bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('Office document exceeds 32 MB preview limit');
  }
  // Inspect central-directory sizes before ZipDecoder can materialize a
  // symbolic-link entry or any compressed file content.
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  var total = 0;
  if (directory.fileHeaders.length > 20000) {
    throw const FormatException('Too many entries in Office document');
  }
  for (final file in directory.fileHeaders) {
    total += file.uncompressedSize;
    if (file.uncompressedSize > 32 * 1024 * 1024 || total > 128 * 1024 * 1024) {
      throw const FormatException(
        'Office document exceeds expanded preview limit',
      );
    }
  }
  return ZipDecoder().decodeBytes(bytes);
}

XmlDocument officeXml(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file == null) throw FormatException('Missing OOXML part: $name');
  final text = utf8.decode(file.content);
  if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
    throw const FormatException('XML entities are not supported in previews');
  }
  return XmlDocument.parse(text);
}

// WOFF (1.0) fonts as the TrueType/OpenType (SFNT) Flutter's font loader
// takes: each table inflated, the table directory rebuilt.
//
// Follows https://www.w3.org/TR/WOFF/ (sections 3–5). WOFF2 (Brotli and
// transformed tables) is not decoded.

import 'dart:io';
import 'dart:typed_data';

/// [bytes] as an SFNT when they are a WOFF; otherwise [bytes] themselves.
/// Throws a [FormatException] for a malformed WOFF.
Uint8List sfntFromWoff(Uint8List bytes) {
  if (bytes.length < 44 ||
      bytes[0] != 0x77 || // w
      bytes[1] != 0x4f || // O
      bytes[2] != 0x46 || // F
      bytes[3] != 0x46) {
    return bytes;
  }
  final woff = ByteData.sublistView(bytes);
  final flavor = woff.getUint32(4);
  final numTables = woff.getUint16(12);
  if (numTables == 0 || 44 + numTables * 20 > bytes.length) {
    throw const FormatException('Truncated WOFF table directory');
  }
  final tables = <({int tag, int checksum, Uint8List data})>[];
  for (var i = 0; i < numTables; i++) {
    final entry = 44 + i * 20;
    final offset = woff.getUint32(entry + 4);
    final compLength = woff.getUint32(entry + 8);
    final origLength = woff.getUint32(entry + 12);
    if (offset + compLength > bytes.length || compLength > origLength) {
      throw const FormatException('Bad WOFF table');
    }
    final stored = Uint8List.sublistView(bytes, offset, offset + compLength);
    final data = compLength < origLength
        ? Uint8List.fromList(ZLibCodec().decode(stored))
        : stored;
    if (data.length != origLength) {
      throw const FormatException('Bad WOFF table length');
    }
    tables.add((
      tag: woff.getUint32(entry),
      checksum: woff.getUint32(entry + 16),
      data: data,
    ));
  }
  // The directory sorted by tag, as the SFNT's must be.
  tables.sort((a, b) => a.tag.compareTo(b.tag));
  var power = 1;
  var log = 0;
  while (power * 2 <= numTables) {
    power *= 2;
    log++;
  }
  final headerLength = 12 + numTables * 16;
  var length = headerLength;
  for (final table in tables) {
    length += (table.data.length + 3) & ~3;
  }
  final sfnt = Uint8List(length);
  final out = ByteData.sublistView(sfnt)
    ..setUint32(0, flavor)
    ..setUint16(4, numTables)
    ..setUint16(6, power * 16)
    ..setUint16(8, log)
    ..setUint16(10, numTables * 16 - power * 16);
  var offset = headerLength;
  for (final (i, table) in tables.indexed) {
    final record = 12 + i * 16;
    out
      ..setUint32(record, table.tag)
      ..setUint32(record + 4, table.checksum)
      ..setUint32(record + 8, offset)
      ..setUint32(record + 12, table.data.length);
    sfnt.setRange(offset, offset + table.data.length, table.data);
    offset += (table.data.length + 3) & ~3;
  }
  return sfnt;
}

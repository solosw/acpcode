import 'dart:typed_data';

import 'package:baocode/ide/document_preview/spreadsheet.dart';
import 'package:baocode/ide/document_preview/office_archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_fixtures.dart';

void main() {
  test('reads shared/rich/inline strings, booleans, sparse cells and cached formulas', () {
    final sheets = readSpreadsheet(spreadsheetFixture());
    expect(sheets.map((sheet) => sheet.name), ['销售', 'Summary']);
    expect(sheets[0].rows, 2);
    expect(sheets[0].columns, 4);
    expect(sheets[0].cells[0]![0]!.text, 'Product');
    expect(sheets[0].cells[1]![0]!.text, '中文');
    expect(sheets[0].cells[1]![1]!.text, '12.5');
    expect(sheets[0].cells[1]![2]!.text, 'TRUE');
    expect(sheets[0].cells[1]![3]!.text, '25');
    expect(sheets[0].cells[1]![3]!.formula, 'B2*2');
    expect(sheets[1].cells[0], isNull);
    expect(sheets[1].cells[2]![2]!.text, '=SUM(A1:B2)');
  });

  test(
    'large sparse extents are bounded without allocating a dense matrix',
    () {
      final parts = spreadsheetParts();
      parts['xl/worksheets/sheet1.xml'] = '<worksheet><dimension ref="XFD1048576"/><sheetData><row><c r="A1"><v>1</v></c><c r="XFD1048576"><v>2</v></c></row></sheetData></worksheet>';
      final sheet = readSpreadsheet(officeZip(parts))[0];
      expect(sheet.rows, 1);
      expect(sheet.columns, 1);
      expect(sheet.truncated, isTrue);
      expect(sheet.cells.length, 1);
    },
  );

  test('external relationship targets cannot be fetched', () {
    final parts = spreadsheetParts();
    parts['xl/_rels/workbook.xml.rels'] = '<Relationships><Relationship Id="rId1" Target="https://example.invalid/steal" TargetMode="External"/><Relationship Id="rId2" Target="../../secret.xml"/></Relationships>';
    expect(() => readSpreadsheet(officeZip(parts)), throwsFormatException);
  });

  test('invalid ZIP, missing XML and DTDs fail explicitly', () {
    expect(() => readSpreadsheet(officeZip({})), throwsFormatException);
    final parts = spreadsheetParts();
    parts['xl/sharedStrings.xml'] =
        '<!DOCTYPE sst [<!ENTITY xx "test">]><sst/>';
    expect(() => readSpreadsheet(officeZip(parts)), throwsFormatException);
  });

  test('central directory expansion limits are checked before content decompression', () {
    final bytes = wordFixture();
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length - 28; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(i + 24, 512 * 1024 * 1024, Endian.little);
        break;
      }
    }
    expect(() => openOfficeArchive(bytes), throwsFormatException);
  });

  test('Excel column headings', () {
    expect([0, 25, 26, 255].map(spreadsheetColumnLabel), [
      'A',
      'Z',
      'AA',
      'IV',
    ]);
  });
}

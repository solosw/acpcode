import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List officeZip(Map<String, String> parts) {
  final archive = Archive();
  for (final entry in parts.entries) {
    archive.add(
      ArchiveFile(
        entry.key,
        utf8.encode(entry.value).length,
        utf8.encode(entry.value),
      ),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List wordFixture([String text = 'Built-in Word 中文']) => officeZip({
  '[Content_Types].xml': '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
  '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
  'word/document.xml':
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>$text</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Table cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>',
});

Map<String, String> spreadsheetParts() => {
  'xl/workbook.xml': '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="销售" r:id="rId1"/><sheet name="Summary" r:id="rId2"/></sheets></workbook>',
  'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="/xl/worksheets/sheet2.xml"/></Relationships>',
  'xl/sharedStrings.xml': '<sst><si><t>Product</t></si><si><r><t>中</t></r><r><t>文</t></r></si></sst>',
  'xl/worksheets/sheet1.xml': '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>Total</t></is></c></row><row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>12.5</v></c><c r="C2" t="b"><v>1</v></c><c r="D2"><f>B2*2</f><v>25</v></c></row></sheetData></worksheet>',
  'xl/worksheets/sheet2.xml': '<worksheet><sheetData><row><c r="B3" t="inlineStr"><is><t>Second worksheet</t></is></c><c r="C3"><f>SUM(A1:B2)</f></c></row></sheetData></worksheet>',
};

Uint8List spreadsheetFixture() => officeZip(spreadsheetParts());

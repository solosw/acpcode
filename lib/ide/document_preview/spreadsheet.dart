import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'office_archive.dart';

class SpreadsheetCell {
  const SpreadsheetCell(this.text, {this.formula});
  final String text;
  final String? formula;
}

class SpreadsheetSheet {
  const SpreadsheetSheet(
    this.name,
    this.rows,
    this.columns,
    this.cells,
    this.truncated,
  );
  final String name;
  final int rows;
  final int columns;
  final Map<int, Map<int, SpreadsheetCell>> cells;
  final bool truncated;
}

/// Read-only OOXML: cached formula results are displayed, never recalculated.
/// Sparse storage and bounded extents prevent dimensions such as XFD1048576
/// from allocating a giant matrix or making the UI unresponsive.
List<SpreadsheetSheet> readSpreadsheet(Uint8List bytes) {
  final archive = openOfficeArchive(bytes);
  final workbook = officeXml(archive, 'xl/workbook.xml');
  final relationships = officeXml(archive, 'xl/_rels/workbook.xml.rels');
  final targets = <String, String>{};
  for (final rel in relationships.findAllElements('Relationship')) {
    if (rel.getAttribute('TargetMode') == 'External') continue;
    final id = rel.getAttribute('Id');
    final target = rel.getAttribute('Target');
    if (id == null ||
        target == null ||
        target.contains('://') ||
        target.contains(r'\')) {
      continue;
    }
    final name = p.posix.normalize(
      target.startsWith('/') ? target.substring(1) : p.posix.join('xl', target),
    );
    if (p.posix.isWithin('xl', name)) targets[id] = name;
  }
  final strings = <String>[];
  if (archive.findFile('xl/sharedStrings.xml') != null) {
    for (final item in officeXml(
      archive,
      'xl/sharedStrings.xml',
    ).findAllElements('si')) {
      strings.add(
        item.findAllElements('t').map((text) => text.innerText).join(),
      );
    }
  }
  const maxRows = 10000;
  const maxColumns = 256;
  const maxCells = 200000;
  var count = 0;
  final sheets = <SpreadsheetSheet>[];
  for (final sheet in workbook.findAllElements('sheet')) {
    if (sheets.length >= 100) {
      throw const FormatException('Too many worksheets');
    }
    String? id;
    for (final attribute in sheet.attributes) {
      if (attribute.name.local == 'id') id = attribute.value;
    }
    final target = targets[id];
    if (target == null) continue;
    final xml = officeXml(archive, target);
    final cells = <int, Map<int, SpreadsheetCell>>{};
    var rows = 0;
    var columns = 0;
    var truncated = false;
    for (final cell in xml.findAllElements('c')) {
      final address = cell.getAttribute('r') ?? '';
      final match = RegExp(r'^([A-Z]+)([1-9][0-9]*)$').firstMatch(address);
      if (match == null) continue;
      var column = 0;
      for (final code in match.group(1)!.codeUnits) {
        column = column * 26 + code - 64;
      }
      final row = int.tryParse(match.group(2)!) ?? maxRows + 1;
      if (row > maxRows || column > maxColumns || count >= maxCells) {
        truncated = true;
        continue;
      }
      final value = cell.getElement('v')?.innerText ?? '';
      final formula = cell.getElement('f')?.innerText;
      final type = cell.getAttribute('t');
      final String text;
      if (type == 's') {
        final index = int.tryParse(value);
        text = index != null && index >= 0 && index < strings.length
            ? strings[index]
            : '';
      } else if (type == 'inlineStr') {
        text =
            cell
                .getElement('is')
                ?.findAllElements('t')
                .map((t) => t.innerText)
                .join() ??
            '';
      } else if (type == 'b') {
        text = value == '1' ? 'TRUE' : 'FALSE';
      } else {
        text = value.isEmpty && formula != null ? '=$formula' : value;
      }
      if (text.isEmpty && formula == null) continue;
      count++;
      (cells[row - 1] ??= {})[column - 1] = SpreadsheetCell(
        text,
        formula: formula,
      );
      if (row > rows) rows = row;
      if (column > columns) columns = column;
    }
    sheets.add(
      SpreadsheetSheet(
        sheet.getAttribute('name') ?? 'Sheet',
        rows,
        columns,
        cells,
        truncated,
      ),
    );
  }
  if (sheets.isEmpty) throw const FormatException('No readable worksheets');
  return sheets;
}

String spreadsheetColumnLabel(int column) {
  var value = column + 1;
  var label = '';
  while (value > 0) {
    value--;
    label = String.fromCharCode(65 + value % 26) + label;
    value ~/= 26;
  }
  return label;
}

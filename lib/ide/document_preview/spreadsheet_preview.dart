import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'spreadsheet.dart';

class SpreadsheetPreview extends StatefulWidget {
  const SpreadsheetPreview({super.key, required this.sheets});
  final List<SpreadsheetSheet> sheets;
  @override
  State<SpreadsheetPreview> createState() => _SpreadsheetPreviewState();
}

class _SpreadsheetPreviewState extends State<SpreadsheetPreview> {
  int _sheet = 0;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheets[_sheet.clamp(0, widget.sheets.length - 1)];
    final columns = sheet.columns == 0 ? 1 : sheet.columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < widget.sheets.length; i++)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: ChoiceChip(
                    label: Text(widget.sheets[i].name),
                    selected: _sheet == i,
                    onSelected: (_) => setState(() {
                      _sheet = i;
                      if (_vertical.hasClients) _vertical.jumpTo(0);
                      if (_horizontal.hasClients) _horizontal.jumpTo(0);
                    }),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            sheet.truncated
                ? context.l10n.documentPreviewSheetTruncated
                : context.l10n.documentPreviewSheetNotice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Scrollbar(
              controller: _horizontal,
              thumbVisibility: true,
              notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 52 + columns * 150,
                  height: constraints.maxHeight,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _cell('', width: 52, header: true),
                          for (var column = 0; column < columns; column++)
                            _cell(spreadsheetColumnLabel(column), header: true),
                        ],
                      ),
                      Expanded(
                        child: Scrollbar(
                          controller: _vertical,
                          child: ListView.builder(
                            controller: _vertical,
                            itemExtent: 34,
                            itemCount: sheet.rows,
                            itemBuilder: (context, row) => Row(
                              children: [
                                _cell('${row + 1}', width: 52, header: true),
                                for (var column = 0; column < columns; column++)
                                  _cell(
                                    sheet.cells[row]?[column]?.text ?? '',
                                    formula: sheet.cells[row]?[column]?.formula,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _cell(
    String text, {
    double width = 150,
    bool header = false,
    String? formula,
  }) {
    final colors = Theme.of(context).colorScheme;
    final child = Container(
      width: width,
      height: 34,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: header ? colors.surfaceContainerHighest : colors.surface,
        border: Border(
          right: BorderSide(color: colors.outlineVariant),
          bottom: BorderSide(color: colors.outlineVariant),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: header ? FontWeight.w600 : null,
        ),
      ),
    );
    return Tooltip(
      message: formula == null ? text : '=$formula\n$text',
      child: child,
    );
  }
}

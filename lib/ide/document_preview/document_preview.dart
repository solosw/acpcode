import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../l10n/l10n.dart';
import '../file_service.dart';
import 'document_conversion.dart';
import 'office_archive.dart';
import 'spreadsheet.dart';
import 'spreadsheet_preview.dart';

/// Built-in PDF/OOXML rendering and explicitly compiled local LaTeX.
class IdeDocumentPreview extends StatefulWidget {
  const IdeDocumentPreview({
    super.key,
    required this.path,
    this.read,
    this.latexSource,
    this.converter,
    this.conversionEnabled = true,
    this.autoCompile = false,
  });

  final String path;
  final Future<Uint8List> Function(String path)? read;
  final String Function()? latexSource;
  final DocumentConverter? converter;
  final bool conversionEnabled;
  // Only set after the user presses the LaTeX Preview button.
  final bool autoCompile;

  @override
  State<IdeDocumentPreview> createState() => _IdeDocumentPreviewState();
}

class _IdeDocumentPreviewState extends State<IdeDocumentPreview> {
  final _controller = PdfViewerController();
  Uint8List? _bytes;
  Object? _error;
  String _log = '';
  List<SpreadsheetSheet>? _sheets;
  bool _busy = false;
  bool _showLog = false;
  int _request = 0;
  int _page = 1;
  int _pages = 0;

  String get _extension => p.extension(widget.path).toLowerCase();
  bool get _word => _extension == '.docx';
  bool get _excel => _extension == '.xlsx';
  bool get _legacy => _extension == '.doc' || _extension == '.xls';
  bool get _latex => widget.latexSource != null;

  @override
  void initState() {
    super.initState();
    if (!_latex || widget.autoCompile) unawaited(_load());
  }

  @override
  void didUpdateWidget(IdeDocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _request++;
      _bytes = null;
      _sheets = null;
      _error = null;
      _log = '';
      _busy = false;
      _pages = 0;
      if (!_latex || widget.autoCompile) unawaited(_load());
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_legacy) return;
      Uint8List bytes;
      List<SpreadsheetSheet>? sheets;
      var log = '';
      if (!_latex) {
        bytes = await (widget.read ?? readFileBytes)(widget.path);
        if (_word) {
          await compute(_validateWord, bytes);
        } else if (_excel) {
          sheets = await compute(readSpreadsheet, bytes);
        }
      } else {
        if (!widget.conversionEnabled) {
          throw const DocumentConversionException(
            DocumentConversionFailure.unavailable,
          );
        }
        final converter = widget.converter ?? DocumentConverter();
        final result = await converter.latex(
          widget.path,
          widget.latexSource!(),
        );
        bytes = result.bytes;
        log = result.log;
      }
      if (!mounted || request != _request) return;
      setState(() {
        _bytes = bytes;
        _sheets = sheets;
        _log = log;
        _pages = 0;
        _page = 1;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _log = error is DocumentConversionException
            ? error.log
            : error.toString();
      });
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  String _errorText(BuildContext context, Object error) {
    final l10n = context.l10n;
    if (error is! DocumentConversionException) {
      return localizedFileError(l10n, error);
    }
    return switch (error.failure) {
      DocumentConversionFailure.unavailable => l10n.documentPreviewUnavailable,
      DocumentConversionFailure.missingTex => l10n.documentPreviewMissingTex,
      DocumentConversionFailure.failed => l10n.documentPreviewFailed,
      DocumentConversionFailure.timeout => l10n.documentPreviewTimeout,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final action = _latex
        ? l10n.documentPreviewCompile
        : l10n.documentPreviewReload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wrap keeps the controls usable in narrow chat side panels.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed:
                  _busy || _legacy || (_latex && !widget.conversionEnabled)
                  ? null
                  : _load,
              icon: Icon(_latex ? Icons.play_arrow : Icons.refresh, size: 18),
              label: Text(action),
            ),
            if (_latex)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('Tectonic'),
              ),
            if (_pages > 0) ...[
              IconButton(
                tooltip: l10n.documentPreviewPreviousPage,
                onPressed: _page > 1
                    ? () => _controller.goToPage(pageNumber: _page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('$_page / $_pages'),
              IconButton(
                tooltip: l10n.documentPreviewNextPage,
                onPressed: _page < _pages
                    ? () => _controller.goToPage(pageNumber: _page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: l10n.documentPreviewZoomOut,
                onPressed: () => _controller.zoomDown(),
                icon: const Icon(Icons.zoom_out),
              ),
              IconButton(
                tooltip: l10n.documentPreviewZoomIn,
                onPressed: () => _controller.zoomUp(),
                icon: const Icon(Icons.zoom_in),
              ),
            ],
            if (_log.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _showLog = !_showLog),
                child: Text(l10n.documentPreviewLog),
              ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(_errorText(context, error)),
          ),
        if (_showLog && _log.isNotEmpty)
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_log),
            ),
          ),
        Expanded(
          child: _legacy
              ? Center(
                  child: Text(
                    l10n.documentPreviewLegacyFormat,
                    textAlign: TextAlign.center,
                  ),
                )
              : _bytes != null && _word
              ? DocxView.bytes(_bytes!, key: ObjectKey(_bytes))
              : _sheets != null
              ? SpreadsheetPreview(key: ObjectKey(_sheets), sheets: _sheets!)
              : _bytes != null
              ? PdfViewer(
                  PdfDocumentRefData(
                    _bytes!,
                    sourceName: widget.path,
                    // Each successful build/reload is a new document, even
                    // when another preview of this path is still cached.
                    key: PdfDocumentRefKey(widget.path, [_bytes]),
                  ),
                  key: ObjectKey(_bytes),
                  controller: _controller,
                  params: PdfViewerParams(
                    onViewerReady: (document, controller) {
                      if (mounted) {
                        setState(() => _pages = document.pages.length);
                      }
                    },
                    onPageChanged: (page) {
                      if (mounted) setState(() => _page = page ?? 1);
                    },
                  ),
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      !_latex
                          ? ''
                          : !widget.conversionEnabled
                          ? l10n.documentPreviewUnavailable
                          : l10n.documentPreviewTrustNotice,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

void _validateWord(Uint8List bytes) {
  final archive = openOfficeArchive(bytes);
  officeXml(archive, 'word/document.xml');
}

/// Keeps the source editor mounted while its compiled snapshot is shown.
class IdeLatexPreview extends StatefulWidget {
  const IdeLatexPreview({
    super.key,
    required this.path,
    required this.source,
    required this.child,
    this.enabled = true,
    this.converter,
  });
  final String path;
  final String Function() source;
  final Widget child;
  final bool enabled;
  final DocumentConverter? converter;

  @override
  State<IdeLatexPreview> createState() => _IdeLatexPreviewState();
}

class _IdeLatexPreviewState extends State<IdeLatexPreview> {
  bool _preview = false;
  bool _opened = false;
  int _compile = 0;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: context.l10n.documentPreviewTrustNotice,
          child: TextButton.icon(
            icon: Icon(_preview ? Icons.code : Icons.picture_as_pdf, size: 18),
            label: Text(
              _preview
                  ? context.l10n.sidePanelSource
                  : context.l10n.documentPreviewCompile,
            ),
            onPressed: () => setState(() {
              _preview = !_preview;
              _opened = true;
              if (_preview) _compile++;
            }),
          ),
        ),
      ),
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Offstage(offstage: _preview, child: widget.child),
            if (_opened)
              Offstage(
                offstage: !_preview,
                child: IdeDocumentPreview(
                  key: ValueKey((widget.path, _compile)),
                  path: widget.path,
                  latexSource: widget.source,
                  converter: widget.converter,
                  conversionEnabled: widget.enabled,
                  autoCompile: true,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

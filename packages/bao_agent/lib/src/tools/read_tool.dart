import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/decision.dart';
import '../util/json.dart';
import 'file_state.dart';
import 'tool.dart';

/// Reads a file: text numbered by line, an image as an image, a PDF as a
/// document, a notebook as its cells.
class ReadTool extends Tool {
  const ReadTool();

  static const maxLines = 2000;
  static const maxLineLength = 2000;

  /// The most a file read whole may be.
  static const maxBytes = 256 * 1024;

  /// The most a read's text may come to, in tokens (about 4 characters).
  static const maxTokens = 25000;

  /// The most an image may be as the API takes it.
  static const maxImageBytes = 3750 * 1024;

  static const imageTypes = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
  };

  @override
  String get name => 'Read';

  @override
  String get description =>
      '''Reads a file from the local filesystem. You can access any file directly by using this tool.
Assume this tool is able to read all files on the machine. If the user provides a path to a file, assume that path is valid. It is okay to read a file that does not exist; an error will be returned.

Usage:
- The file_path parameter must be an absolute path, not a relative path
- By default, it reads up to $maxLines lines starting from the beginning of the file
- You can optionally specify a line offset and limit (especially handy for long files), but it's recommended to read the whole file by not providing these parameters
- Any lines longer than $maxLineLength characters will be truncated
- Results are returned using cat -n format, with line numbers starting at 1
- This tool can read images (PNG, JPG, GIF, WebP): their contents are presented visually.
- This tool can read PDF files (.pdf). For large PDFs, provide the pages parameter to read specific page ranges (e.g., "1-5"). Maximum 20 pages per request.
- This tool can read Jupyter notebooks (.ipynb files) and returns all cells with their outputs.
- This tool can only read files, not directories. To read a directory, use an ls command via the Bash tool.
- You can call multiple tools in a single response. It is always better to speculatively read multiple potentially useful files in parallel.
- If you read a file that exists but has empty contents you will receive a system reminder warning in place of file contents.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'file_path': {
        'type': 'string',
        'description': 'The absolute path to the file to read',
      },
      'offset': {
        'type': 'integer',
        'description': 'The line number to start reading from. Only provide if the file is too large to read at once',
      },
      'limit': {
        'type': 'integer',
        'description': 'The number of lines to read. Only provide if the file is too large to read at once.',
      },
      'pages': {
        'type': 'string',
        'description': 'Page range for PDF files (e.g., "1-5", "3", "10-20"). Only applicable to PDF files. Maximum 20 pages per request.',
      },
    },
    'required': ['file_path'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  String? describe(Map<String, Object?> input) => asString(input['file_path']);

  @override
  String? ruleContent(Map<String, Object?> input) =>
      asString(input['file_path']);

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => context.session.permissions.checkRead(
    '${input['file_path']}',
    context.cwd,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    if (input['offset'] case final int offset when offset < 0) {
      return 'offset must not be negative';
    }
    if (input['limit'] case final int limit when limit <= 0) {
      return 'limit must be positive';
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = context.session.permissions.absolute(
      '${input['file_path']}',
      context.cwd,
    );
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      return ToolOutput.error(
        'EISDIR: $path is a directory, not a file. Use `ls` through the '
        'Bash tool, or the Glob tool, to see what is in it.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      return ToolOutput.error(_notFound(path, context.cwd));
    }
    final file = File(path);
    final extension = p.extension(path).toLowerCase();
    if (imageTypes[extension] case final mediaType?) {
      return _image(file, mediaType, context);
    }
    if (extension == '.pdf') return _pdf(file, asString(input['pages']));
    if (extension == '.ipynb') return _notebook(file, context);
    final length = file.lengthSync();
    final offset = asInt(input['offset']);
    final limit = asInt(input['limit']);
    if (length > maxBytes && offset == null && limit == null) {
      return ToolOutput.error(
        'File content (${(length / 1024).round()}KB) exceeds maximum allowed '
        'size (${maxBytes ~/ 1024}KB). Please use offset and limit parameters '
        'to read specific portions of the file, or use the Grep tool to '
        'search for specific content.',
      );
    }
    final bytes = file.readAsBytesSync();
    if (looksBinary(bytes)) {
      return ToolOutput.error(
        'This tool cannot read binary files. The file appears to be a binary '
        '$extension file. Please use appropriate tools for binary file '
        'analysis.',
      );
    }
    final decoded = decodeText(bytes);
    final text = decoded.text;
    final modified = file.lastModifiedSync();
    final lines = text.isEmpty ? <String>[] : text.split('\n');
    // A final newline ends the last line.
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final total = lines.length;
    // `offset` is a line number, 1 the first: 0 is taken as 1.
    final start = offset == null || offset <= 1 ? 0 : offset - 1;
    final count = limit ?? maxLines;
    context.run.readFiles[path] = FileRecord(
      content: text,
      modified: modified,
      offset: offset,
      limit: limit,
    );
    final reminders = context.session.memoryFor(path, context.run);
    String withReminders(String body) => [
      body,
      for (final reminder in reminders)
        '<system-reminder>\n$reminder\n</system-reminder>',
    ].join('\n\n');
    if (text.isEmpty) {
      return ToolOutput(
        withReminders(
          '<system-reminder>Warning: the file exists but the contents are '
          'empty.</system-reminder>',
        ),
        result: _textResult(path, '', 0, 1, 0),
      );
    }
    if (start >= total) {
      return ToolOutput(
        withReminders(
          '<system-reminder>Warning: the file exists but is shorter than the '
          'provided offset (${start + 1}). The file has $total lines.'
          '</system-reminder>',
        ),
        result: _textResult(path, '', 0, start + 1, total),
      );
    }
    final end = (start + count).clamp(0, total);
    final shown = [
      for (final line in lines.sublist(start, end))
        line.length > maxLineLength
            ? '${line.substring(0, maxLineLength)}… [line truncated]'
            : line,
    ];
    final body = numberLines(shown, start + 1);
    if (body.length ~/ 4 > maxTokens) {
      return ToolOutput.error(
        'File content (${body.length ~/ 4} tokens) exceeds maximum allowed '
        'tokens ($maxTokens). Please use offset and limit parameters to read '
        'specific portions of the file, or use the Grep tool to search for '
        'specific content.',
      );
    }
    final note = end < total && limit == null
        ? '\n\n<system-reminder>The file has $total lines; lines '
              '${start + 1}-$end are shown. Use offset and limit to read '
              'the rest.</system-reminder>'
        : '';
    return ToolOutput(
      withReminders('$body$note'),
      result: _textResult(
        path,
        shown.join('\n'),
        shown.length,
        start + 1,
        total,
      ),
    );
  }

  static Map<String, Object?> _textResult(
    String path,
    String content,
    int lines,
    int start,
    int total,
  ) => {
    'type': 'text',
    'file': {
      'filePath': path,
      'content': content,
      'numLines': lines,
      'startLine': start,
      'totalLines': total,
    },
  };

  /// What is said of a file not there: where else it might be.
  static String _notFound(String path, String cwd) {
    final buffer = StringBuffer('File does not exist.');
    final folder = Directory(p.dirname(path));
    if (folder.existsSync()) {
      final base = p.basenameWithoutExtension(path).toLowerCase();
      try {
        final similar = folder
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where(
              (other) =>
                  p.basenameWithoutExtension(other).toLowerCase() == base,
            )
            .take(3)
            .toList();
        if (similar.isNotEmpty) {
          buffer.write(' Did you mean ${similar.join(' or ')}?');
        }
      } on FileSystemException {
        // Nothing to suggest.
      }
    }
    buffer.write(' Current working directory: $cwd');
    return buffer.toString();
  }

  ToolOutput _image(File file, String mediaType, ToolContext context) {
    final bytes = file.readAsBytesSync();
    if (bytes.length > maxImageBytes) {
      return ToolOutput.error(
        'The image is ${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB, '
        'more than the ${(maxImageBytes / 1024 / 1024).toStringAsFixed(1)}MB '
        'the model takes. Resize it first (for example with `sips -Z 1568` '
        'on macOS or ImageMagick `convert -resize`), then read the smaller '
        'copy.',
      );
    }
    final data = base64Encode(bytes);
    context.run.readFiles[file.path] = FileRecord(
      content: '',
      modified: file.lastModifiedSync(),
      offset: 0,
    );
    return ToolOutput(
      [
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': mediaType, 'data': data},
        },
      ],
      result: {
        'type': 'image',
        'file': {
          'base64': data,
          'type': mediaType,
          'originalSize': bytes.length,
        },
      },
    );
  }

  ToolOutput _pdf(File file, String? pages) {
    final bytes = file.readAsBytesSync();
    if (pages != null) {
      final text = _pdfText(file.path, pages);
      if (text != null) {
        return ToolOutput(
          text,
          result: {
            'type': 'text',
            'file': {'filePath': file.path, 'content': text, 'pages': pages},
          },
        );
      }
    }
    if (bytes.length > 20 * 1024 * 1024) {
      return ToolOutput.error(
        'The PDF is too large to read whole '
        '(${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB). Give the '
        'pages parameter to read part of it.',
      );
    }
    return ToolOutput(
      [
        {
          'type': 'document',
          'source': {
            'type': 'base64',
            'media_type': 'application/pdf',
            'data': base64Encode(bytes),
          },
        },
      ],
      result: {
        'type': 'pdf',
        'file': {'filePath': file.path, 'originalSize': bytes.length},
      },
    );
  }

  /// The text of [pages] of the PDF at [path], by `pdftotext` where it is
  /// installed.
  static String? _pdfText(String path, String pages) {
    final match = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$').firstMatch(pages);
    if (match == null) return null;
    final first = int.parse(match[1]!);
    final last = int.parse(match[2] ?? match[1]!);
    if (last < first || last - first >= 20) return null;
    try {
      final result = Process.runSync('pdftotext', [
        '-f',
        '$first',
        '-l',
        '$last',
        '-layout',
        path,
        '-',
      ]);
      if (result.exitCode != 0) return null;
      return '${result.stdout}';
    } on ProcessException {
      return null;
    }
  }

  ToolOutput _notebook(File file, ToolContext context) {
    final text = readText(file).text;
    Map<String, Object?> notebook;
    try {
      notebook = asMap(jsonDecode(text));
    } on FormatException catch (error) {
      return ToolOutput.error('The notebook is not valid JSON: $error');
    }
    context.run.readFiles[file.path] = FileRecord(
      content: text,
      modified: file.lastModifiedSync(),
    );
    final language =
        asString(asMap(asMap(notebook['metadata'])['language_info'])['name']) ??
        'python';
    final blocks = <Map<String, Object?>>[];
    final cells = <Map<String, Object?>>[];
    for (final (index, raw) in asList(notebook['cells']).indexed) {
      final cell = asMap(raw);
      final id = asString(cell['id']) ?? 'cell-$index';
      final type = asString(cell['cell_type']) ?? 'code';
      final source = _joined(cell['source']);
      final out = StringBuffer('<cell id="$id">');
      if (type != 'code') out.write('<cell_type>$type</cell_type>');
      if (type == 'code' && language != 'python') {
        out.write('<language>$language</language>');
      }
      out.write('$source</cell id="$id">');
      blocks.add({'type': 'text', 'text': out.toString()});
      for (final output in asList(cell['outputs'])) {
        final o = asMap(output);
        final data = asMap(o['data']);
        final textOut = _joined(o['text'] ?? data['text/plain']);
        if (textOut.isNotEmpty) {
          blocks.add({'type': 'text', 'text': textOut});
        }
        if (o['output_type'] == 'error') {
          blocks.add({
            'type': 'text',
            'text': '${o['ename']}: ${o['evalue']}\n${_joined(o['traceback'])}',
          });
        }
        for (final mime in const ['image/png', 'image/jpeg']) {
          if (data[mime] case final String image) {
            blocks.add({
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': mime,
                'data': image.replaceAll('\n', ''),
              },
            });
          }
        }
      }
      cells.add({'cellType': type, 'source': source, 'cell_id': id});
    }
    return ToolOutput(
      blocks.isEmpty ? 'The notebook has no cells.' : blocks,
      result: {
        'type': 'notebook',
        'file': {'filePath': file.path, 'cells': cells},
      },
    );
  }

  static String _joined(Object? source) => switch (source) {
    final String text => text,
    final List<Object?> parts => parts.join(),
    _ => '',
  };
}

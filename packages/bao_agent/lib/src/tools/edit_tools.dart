import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/decision.dart';
import '../util/ids.dart';
import '../util/json.dart';
import 'diff.dart';
import 'file_state.dart';
import 'tool.dart';

/// What the editing tools share: the path made absolute, the permission
/// to change it, the check that it was read and has not changed since,
/// and the write with its checkpoint and record.
mixin _Editing on Tool {
  String pathKey = 'file_path';

  @override
  String? describe(Map<String, Object?> input) => asString(input[pathKey]);

  @override
  String? ruleContent(Map<String, Object?> input) => asString(input[pathKey]);

  String pathOf(Map<String, Object?> input, ToolContext context) =>
      context.session.permissions.absolute('${input[pathKey]}', context.cwd);

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => context.session.permissions.checkEdit(
    '${input[pathKey]}',
    context.cwd,
    context.run.permissionMode,
  );

  /// Writes [content] to [path] (as [like] was, or as UTF-8 with `\n`),
  /// kept first for a rewind, and remembered as read.
  Future<void> writeFile(
    String path,
    String content,
    ToolContext context, {
    FileText? like,
  }) async {
    await context.session.checkpoints.track(path);
    final file = File(path);
    file.parent.createSync(recursive: true);
    final encoded = (like ?? const FileText('')).encode(content);
    file.writeAsBytesSync(encoded, flush: true);
    context.run.readFiles[path] = FileRecord(
      content: content,
      modified: file.lastModifiedSync(),
    );
    context.session.fileChanged(path);
  }
}

/// Writes a file whole.
class WriteTool extends Tool with _Editing {
  WriteTool();

  @override
  String get name => 'Write';

  @override
  String get description => '''Writes a file to the local filesystem.

Usage:
- This tool will overwrite the existing file if there is one at the provided path.
- If this is an existing file, you MUST use the Read tool first to read the file's contents. This tool will fail if you did not read the file first.
- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
- NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
- Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'file_path': {
        'type': 'string',
        'description': 'The absolute path to the file to write (must be absolute, not relative)',
      },
      'content': {
        'type': 'string',
        'description': 'The content to write to the file',
      },
    },
    'required': ['file_path', 'content'],
    'additionalProperties': false,
  };

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = pathOf(input, context);
    if (FileSystemEntity.isDirectorySync(path)) {
      return '$path is a directory.';
    }
    if (!File(path).existsSync()) return null;
    return context.run.readFiles.staleness(path);
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = pathOf(input, context);
    final content = '${input['content'] ?? ''}';
    final file = File(path);
    final existed = file.existsSync();
    final before = existed ? readText(file) : null;
    await writeFile(path, content, context, like: before);
    if (before == null) {
      return ToolOutput(
        'File created successfully at: $path',
        result: {
          'type': 'create',
          'filePath': path,
          'content': content,
          'structuredPatch': <Object?>[],
          'originalFile': null,
        },
      );
    }
    final hunks = diffLines(before.text, content);
    return ToolOutput(
      'The file $path has been updated. Here\'s the result of running '
      '`cat -n` on a snippet of the edited file:\n'
      '${_changedSnippet(content, hunks)}',
      result: {
        'type': 'update',
        'filePath': path,
        'content': content,
        'structuredPatch': patchJson(hunks),
        'originalFile': before.text,
      },
    );
  }
}

/// The lines about the first change of [hunks] in [content], numbered.
String _changedSnippet(String content, List<Hunk> hunks) {
  final lines = content.split('\n');
  if (hunks.isEmpty) {
    return numberLines(lines.take(10).toList(), 1);
  }
  final first = hunks.first;
  final last = hunks.last;
  final from = (first.newStart - 1).clamp(0, lines.length);
  final to = (last.newStart - 1 + last.newLines).clamp(from, lines.length);
  // A long one shown in part.
  final end = to - from > 60 ? from + 60 : to;
  return numberLines(lines.sublist(from, end), from + 1);
}

/// One replacement of an edit.
class _Replacement {
  const _Replacement(this.oldString, this.newString, this.replaceAll);

  final String oldString;
  final String newString;
  final bool replaceAll;
}

/// [content] with [edit] made, or what is wrong with it.
(String?, String?) _apply(String content, _Replacement edit) {
  if (edit.oldString == edit.newString) {
    return (
      null,
      'No changes to make: old_string and new_string are exactly the same.',
    );
  }
  var old = edit.oldString;
  var replacement = edit.newString;
  var count = _count(content, old);
  if (count == 0) {
    // Typographic quotes where the model wrote straight ones, or the other
    // way round: the file's own taken.
    final actual = _findNormalized(content, old);
    if (actual != null) {
      replacement = _matchQuotes(replacement, actual, old);
      old = actual;
      count = _count(content, old);
    }
  }
  if (count == 0) {
    return (
      null,
      'String to replace not found in file.\nString: ${edit.oldString}',
    );
  }
  if (count > 1 && !edit.replaceAll) {
    return (
      null,
      'Found $count matches of the string to replace, but replace_all is '
          'false. To replace all occurrences, set replace_all to true. To '
          'replace only one occurrence, please provide more context to '
          'uniquely identify the instance.\nString: ${edit.oldString}',
    );
  }
  if (edit.replaceAll) {
    return (content.replaceAll(old, replacement), null);
  }
  // Deleting a whole line takes its line ending with it.
  if (replacement.isEmpty &&
      !old.endsWith('\n') &&
      content.contains('$old\n')) {
    return (content.replaceFirst('$old\n', ''), null);
  }
  return (content.replaceFirst(old, replacement), null);
}

int _count(String content, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var at = content.indexOf(needle);
  while (at >= 0) {
    count++;
    at = content.indexOf(needle, at + needle.length);
  }
  return count;
}

String _straight(String text) =>
    text.replaceAll(RegExp('[‘’‛]'), "'").replaceAll(RegExp('[“”‟]'), '"');

/// Where [needle] is in [content] once quotes are made straight in both:
/// the text of [content] there.
String? _findNormalized(String content, String needle) {
  final straightContent = _straight(content);
  final straightNeedle = _straight(needle);
  final at = straightContent.indexOf(straightNeedle);
  if (at < 0) return null;
  // Straightening keeps lengths, so the place is the same.
  return content.substring(at, at + needle.length);
}

/// [replacement] with the typographic quotes [actual] has where [written]
/// had straight ones.
String _matchQuotes(String replacement, String actual, String written) {
  if (!RegExp('[‘’“”]').hasMatch(actual)) return replacement;
  final usesDouble = actual.contains('“') || actual.contains('”');
  final usesSingle = actual.contains('‘') || actual.contains('’');
  final out = StringBuffer();
  var openDouble = true;
  for (var i = 0; i < replacement.length; i++) {
    final c = replacement[i];
    if (c == '"' && usesDouble) {
      out.write(openDouble ? '“' : '”');
      openDouble = !openDouble;
    } else if (c == "'" && usesSingle) {
      final before = i > 0 ? replacement[i - 1] : ' ';
      out.write(RegExp(r'\s|[(\[{]').hasMatch(before) ? '‘' : '’');
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

/// Replaces text in a file.
class EditTool extends Tool with _Editing {
  EditTool();

  @override
  String get name => 'Edit';

  @override
  String get description => '''Performs exact string replacements in files.

Usage:
- You must use your `Read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.
- When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: spaces + line number + tab. Everything after that tab is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.
- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
- The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.
- Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'file_path': {
        'type': 'string',
        'description': 'The absolute path to the file to modify',
      },
      'old_string': {'type': 'string', 'description': 'The text to replace'},
      'new_string': {
        'type': 'string',
        'description':
            'The text to replace it with (must be different from old_string)',
      },
      'replace_all': {
        'type': 'boolean',
        'default': false,
        'description': 'Replace all occurences of old_string (default false)',
      },
    },
    'required': ['file_path', 'old_string', 'new_string'],
    'additionalProperties': false,
  };

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = pathOf(input, context);
    final old = '${input['old_string'] ?? ''}';
    final file = File(path);
    if (p.extension(path) == '.ipynb') {
      return 'File is a Jupyter Notebook. Use the NotebookEdit tool to edit '
          'this file.';
    }
    if (!file.existsSync()) {
      // An empty old_string makes the file.
      if (old.isEmpty) return null;
      return 'File does not exist.';
    }
    if (old.isEmpty) {
      if (readText(file).text.trim().isEmpty) return null;
      return 'Cannot create new file - file already exists.';
    }
    return context.run.readFiles.staleness(path);
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = pathOf(input, context);
    final old = '${input['old_string'] ?? ''}';
    final replacement = '${input['new_string'] ?? ''}';
    final replaceAll = input['replace_all'] == true;
    final file = File(path);
    final before = file.existsSync() ? readText(file) : null;
    final original = before?.text ?? '';
    String updated;
    if (old.isEmpty) {
      updated = replacement;
    } else {
      final (result, error) = _apply(
        original,
        _Replacement(old, replacement, replaceAll),
      );
      if (error != null) return ToolOutput.error(error);
      updated = result!;
    }
    await writeFile(path, updated, context, like: before);
    final hunks = diffLines(original, updated);
    return ToolOutput(
      'The file $path has been updated. Here\'s the result of running '
      '`cat -n` on a snippet of the edited file:\n'
      '${replaceAll ? _changedSnippet(updated, hunks) : snippetAround(updated, replacement)}',
      result: {
        'filePath': path,
        'oldString': old,
        'newString': replacement,
        'originalFile': before == null ? null : original,
        'structuredPatch': patchJson(hunks),
        'userModified': false,
        'replaceAll': replaceAll,
      },
    );
  }
}

/// Changes a cell of a Jupyter notebook.
class NotebookEditTool extends Tool with _Editing {
  NotebookEditTool() {
    pathKey = 'notebook_path';
  }

  @override
  String get name => 'NotebookEdit';

  @override
  String get description =>
      'Completely replaces the contents of a specific cell in a Jupyter '
      'notebook (.ipynb file) with new source. Jupyter notebooks are '
      'interactive documents that combine code, text, and visualizations, '
      'commonly used for data analysis and scientific computing. The '
      'notebook_path parameter must be an absolute path, not a relative '
      'path. The cell_id is the ID of the cell to edit (as the Read tool '
      'shows it). Use edit_mode=insert to add a new cell after the cell '
      'with cell_id (or at the start without one). Use edit_mode=delete to '
      'delete the cell.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'notebook_path': {
        'type': 'string',
        'description': 'The absolute path to the Jupyter notebook file to edit (must be absolute, not relative)',
      },
      'cell_id': {
        'type': 'string',
        'description': 'The ID of the cell to edit. When inserting a new cell, the new cell will be inserted after the cell with this ID, or at the beginning if not specified.',
      },
      'new_source': {
        'type': 'string',
        'description': 'The new source for the cell',
      },
      'cell_type': {
        'type': 'string',
        'enum': ['code', 'markdown'],
        'description': 'The type of the cell (code or markdown). If not specified, it defaults to the current cell type. If using edit_mode=insert, this is required.',
      },
      'edit_mode': {
        'type': 'string',
        'enum': ['replace', 'insert', 'delete'],
        'description': 'The type of edit to make (replace, insert, delete). Defaults to replace.',
      },
    },
    'required': ['notebook_path', 'new_source'],
    'additionalProperties': false,
  };

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = pathOf(input, context);
    if (p.extension(path) != '.ipynb') {
      return 'File must be a Jupyter notebook (.ipynb file). For editing '
          'other file types, use the Edit tool.';
    }
    if (!File(path).existsSync()) return 'Notebook file does not exist.';
    final mode = asString(input['edit_mode']) ?? 'replace';
    if (mode == 'insert' && input['cell_type'] == null) {
      return 'Cell type is required when using edit_mode=insert.';
    }
    return context.run.readFiles.staleness(path);
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final path = pathOf(input, context);
    final file = File(path);
    final before = readText(file);
    final Map<String, Object?> notebook;
    try {
      notebook = {...asMap(jsonDecode(before.text))};
    } on FormatException {
      return ToolOutput.error('Notebook is not valid JSON.');
    }
    final cells = [
      for (final cell in asList(notebook['cells'])) {...asMap(cell)},
    ];
    final mode = asString(input['edit_mode']) ?? 'replace';
    final cellId = asString(input['cell_id']);
    final source = '${input['new_source'] ?? ''}';
    var index = cellId == null
        ? -1
        : cells.indexWhere((cell) => cell['id'] == cellId);
    if (index < 0 && cellId != null) {
      // `cell-3`, as the Read tool names cells without ids.
      final numbered = RegExp(r'^cell-(\d+)$').firstMatch(cellId);
      if (numbered != null) index = int.parse(numbered[1]!);
      if (index >= cells.length) index = -1;
    }
    if (index < 0 && (mode != 'insert' || cellId != null)) {
      return ToolOutput.error('Cell with ID "$cellId" not found in notebook.');
    }
    final language =
        asString(asMap(asMap(notebook['metadata'])['language_info'])['name']) ??
        'python';
    String oldSource = '';
    String cellType = asString(input['cell_type']) ?? 'code';
    String? newId = cellId;
    List<String> lines(String text) {
      final parts = text.split('\n');
      return [
        for (final (i, part) in parts.indexed)
          i < parts.length - 1 ? '$part\n' : part,
      ]..removeWhere((line) => line.isEmpty);
    }

    switch (mode) {
      case 'delete':
        oldSource = _joined(cells[index]['source']);
        cells.removeAt(index);
      case 'insert':
        newId = _newCellId();
        final cell = <String, Object?>{
          'cell_type': cellType,
          'id': newId,
          'metadata': <String, Object?>{},
          'source': lines(source),
          if (cellType == 'code') ...{
            'execution_count': null,
            'outputs': <Object?>[],
          },
        };
        cells.insert(index + 1, cell);
      default:
        final cell = cells[index];
        oldSource = _joined(cell['source']);
        cellType =
            asString(input['cell_type']) ??
            asString(cell['cell_type']) ??
            'code';
        cell['source'] = lines(source);
        cell['cell_type'] = cellType;
        if (cellType == 'code') {
          cell['execution_count'] = null;
          cell['outputs'] = <Object?>[];
        } else {
          cell.remove('execution_count');
          cell.remove('outputs');
        }
    }
    notebook['cells'] = cells;
    final updated = '${const JsonEncoder.withIndent(' ').convert(notebook)}\n';
    await writeFile(path, updated, context, like: before);
    final said = switch (mode) {
      'delete' => 'Deleted cell $cellId',
      'insert' => 'Inserted cell $newId',
      _ => 'Updated cell $cellId with $source',
    };
    return ToolOutput(
      said,
      result: {
        'new_source': source,
        'old_source': oldSource,
        'cell_id': newId,
        'cell_type': cellType,
        'language': language,
        'edit_mode': mode,
        'error': '',
        'notebook_path': path,
        'original_file': before.text,
        'updated_file': updated,
      },
    );
  }

  static String _joined(Object? source) => switch (source) {
    final String text => text,
    final List<Object?> parts => parts.join(),
    _ => '',
  };

  static String _newCellId() => randomId(8);
}

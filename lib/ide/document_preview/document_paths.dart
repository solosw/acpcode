import 'package:path/path.dart' as p;

/// Binary documents must never be opened or saved as UTF-8 text.
bool ideIsDocumentPath(String path) => const {
  '.pdf',
  '.doc',
  '.docx',
  '.xls',
  '.xlsx',
}.contains(p.extension(path).toLowerCase());

bool ideIsLatexPath(String path) => p.extension(path).toLowerCase() == '.tex';

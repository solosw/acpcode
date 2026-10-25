// Where a markdown file's links and images go, and its headings'
// anchors, as GitHub makes them.

import 'package:path/path.dart' as p;

/// [heading]'s anchor, as GitHub makes one: lower case, its punctuation
/// dropped and its spaces dashes. Letters of any script stay.
String markdownSlug(String heading) => heading
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}\p{Pc}\- ]', unicode: true), '')
    .replaceAll(' ', '-');

/// Where a link of a markdown file goes.
sealed class MarkdownLinkTarget {
  const MarkdownLinkTarget();
}

/// A heading of the same file.
class MarkdownAnchorLink extends MarkdownLinkTarget {
  const MarkdownAnchorLink(this.anchor);

  final String anchor;
}

/// A web page or a mail, for the browser.
class MarkdownExternalLink extends MarkdownLinkTarget {
  const MarkdownExternalLink(this.uri);

  final Uri uri;
}

/// A file of the project's host, and the part of it after `#`.
class MarkdownFileLink extends MarkdownLinkTarget {
  const MarkdownFileLink(this.path, [this.fragment]);

  final String path;
  final String? fragment;
}

/// Where [href], in the markdown file at [document], goes: relative paths
/// are the file's folder's, in [context]'s style (a remote project's are
/// POSIX). Null for what opens nothing (other schemes).
MarkdownLinkTarget? resolveMarkdownLink(
  String? href,
  String document,
  p.Context context,
) {
  final link = href?.trim();
  if (link == null || link.isEmpty) return null;
  if (link.startsWith('#')) {
    return MarkdownAnchorLink(markdownDecode(link.substring(1)));
  }
  final uri = Uri.tryParse(link);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  // `C:\notes.md` is a path, not a scheme.
  if (scheme.length > 1) {
    if (const {'http', 'https', 'mailto'}.contains(scheme)) {
      return MarkdownExternalLink(uri!);
    }
    if (scheme == 'file' && uri!.path.isNotEmpty) {
      final path = uri.toFilePath(windows: context.style == p.Style.windows);
      return MarkdownFileLink(path, uri.hasFragment ? uri.fragment : null);
    }
    return null;
  }
  final hash = link.indexOf('#');
  final relative = markdownDecode(hash < 0 ? link : link.substring(0, hash));
  final fragment = hash < 0 ? null : markdownDecode(link.substring(hash + 1));
  if (relative.isEmpty) {
    return fragment == null ? null : MarkdownAnchorLink(fragment);
  }
  return MarkdownFileLink(
    context.normalize(
      context.isAbsolute(relative)
          ? relative
          : context.join(context.dirname(document), relative),
    ),
    fragment,
  );
}

/// An image's [src] in the markdown file at [document]: a web address, or
/// the path of a file of the project's host. Null for what is neither.
({Uri? url, String? path})? resolveMarkdownImage(
  String src,
  String document,
  p.Context context,
) {
  final target = resolveMarkdownLink(src, document, context);
  return switch (target) {
    MarkdownExternalLink(:final uri) when uri.scheme.startsWith('http') => (
      url: uri,
      path: null,
    ),
    MarkdownFileLink(:final path) => (url: null, path: path),
    _ => null,
  };
}

/// [text] with its `%xx` escapes decoded; as it is where one is not valid.
String markdownDecode(String text) {
  try {
    return Uri.decodeComponent(text);
  } on ArgumentError {
    return text;
  }
}

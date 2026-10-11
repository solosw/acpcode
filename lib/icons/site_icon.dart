import 'dart:typed_data';

import 'site_icon_stub.dart'
    if (dart.library.io) 'site_icon_io.dart'
    as platform;

/// The icon of the site at [site] (an upstream's base URL), taken by
/// [take]: the first of those its page links to, then `/favicon.ico`,
/// that [take] does not refuse (by throwing); of its domain's site when
/// its own has none (`api.example.com`'s is `example.com`'s). Null when
/// none is taken.
Future<T?> fetchSiteIcon<T>(
  Uri site,
  Future<T> Function(Uint8List bytes) take,
) => platform.fetchSiteIcon(site, take);

/// The pages whose icons [site] may show, its own first: its origin, then
/// its domain's above it, down to the one under the top level.
List<Uri> siteIconPages(Uri site) {
  final host = site.host.toLowerCase();
  if (host.isEmpty) return const [];
  final pages = [Uri(scheme: site.scheme, host: host, port: site.port)];
  // An address, or a name of this machine, has nothing above it.
  if (host == 'localhost' || RegExp(r'^[\d.]+$|:').hasMatch(host)) {
    return pages;
  }
  final labels = host.split('.');
  for (var i = 1; i < labels.length - 1; i++) {
    pages.add(Uri(scheme: 'https', host: labels.skip(i).join('.')));
  }
  return pages;
}

/// The icons [html] (the page at [page]) links to, the best first: an SVG,
/// then the largest; `data:` ones among them.
List<Uri> siteIconLinks(String html, Uri page) {
  final links = <({Uri url, int rank})>[];
  for (final tag in RegExp(
    r'<link\b[^>]*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final attributes = <String, String>{
      for (final attribute in _attribute.allMatches(tag[0]!))
        attribute[1]!.toLowerCase(): _unescape(
          attribute[2] ?? attribute[3] ?? attribute[4] ?? '',
        ),
    };
    final rel = (attributes['rel'] ?? '').toLowerCase().split(RegExp(r'\s+'));
    final href = attributes['href']?.trim() ?? '';
    // Safari's pinned tab mask is a silhouette, black.
    if (href.isEmpty ||
        !rel.any((r) => r == 'icon' || r == 'apple-touch-icon')) {
      continue;
    }
    final Uri url;
    try {
      url = page.resolve(href);
    } on FormatException {
      continue;
    }
    final svg =
        attributes['type'] == 'image/svg+xml' ||
        url.path.toLowerCase().endsWith('.svg') ||
        href.startsWith('data:image/svg');
    final sizes = [
      for (final size in RegExp(
        r'(\d+)x\d+',
      ).allMatches(attributes['sizes'] ?? ''))
        int.parse(size[1]!),
    ];
    final side = sizes.isNotEmpty
        ? sizes.reduce((a, b) => a > b ? a : b)
        : rel.contains('apple-touch-icon')
        ? 180
        : 16;
    links.add((url: url, rank: svg ? 1 << 20 : side));
  }
  links.sort((a, b) => b.rank - a.rank);
  return [for (final link in links) link.url];
}

final _attribute = RegExp(
  r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
);

String _unescape(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

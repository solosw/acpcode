import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'site_icon.dart';

/// See [fetchSiteIcon]: through the app's proxy, as every [HttpClient].
/// Each page is looked at at once, a subdomain's and its domain's: one
/// that does not answer does not hold up the next; the first's icons are
/// still taken first.
Future<T?> fetchSiteIcon<T>(
  Uri site,
  Future<T> Function(Uint8List bytes) take,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    // Some sites answer a browser only.
    ..userAgent =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
  try {
    final pages = [
      for (final page in siteIconPages(site)) _iconsOf(client, page),
    ];
    final tried = <Uri>{};
    for (final icons in pages) {
      for (final (url, bytes) in await icons) {
        if (!tried.add(url)) continue;
        try {
          return await take(bytes);
        } on Object {
          // Not a picture taken: the next.
        }
      }
    }
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The icons [page] links to, then its `/favicon.ico`, downloaded: the
/// best first; those that could not be, left out.
Future<List<(Uri, Uint8List)>> _iconsOf(HttpClient client, Uri page) async {
  final html = await _get(client, page, _maxPage);
  final urls = {
    if (html != null)
      ...siteIconLinks(utf8.decode(html.bytes, allowMalformed: true), html.url),
    (html?.url ?? page).resolve('/favicon.ico'),
  }.toList();
  final downloads = await Future.wait([
    for (final url in urls)
      url.isScheme('data')
          ? Future(() => url.data!.contentAsBytes())
                .then<Uint8List?>((bytes) => bytes)
                .catchError((_) => null)
          : _get(client, url, _maxIcon).then((answer) => answer?.bytes),
  ]);
  return [
    for (final (i, bytes) in downloads.indexed)
      if (bytes != null && bytes.isNotEmpty) (urls[i], bytes),
  ];
}

const _maxPage = 1024 * 1024;
const _maxIcon = 5 * 1024 * 1024;

/// What [url] answers, and where it ended up after redirects; null for a
/// failure, or more than [max] bytes.
Future<({Uint8List bytes, Uri url})?> _get(
  HttpClient client,
  Uri url,
  int max,
) async {
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 8))) {
      builder.add(chunk);
      if (builder.length > max) return null;
    }
    var at = url;
    for (final redirect in response.redirects) {
      at = at.resolveUri(redirect.location);
    }
    return (bytes: builder.takeBytes(), url: at);
  } on Object {
    return null;
  }
}

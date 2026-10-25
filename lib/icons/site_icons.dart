import 'dart:async';

import 'package:flutter/foundation.dart';

import 'icon_library.dart';
import 'site_icon.dart';

/// How a site's icon is fetched: [fetchSiteIcon]'s way.
typedef SiteIconFetch = Future<IconImage?> Function(
  Uri site,
  Future<IconImage> Function(Uint8List bytes) take,
);

/// The icons of the sites of upstreams of models that show no other:
/// fetched the first time one is asked for, in the background, and kept
/// (by host) in a library of their own, not among the pictures the user
/// uploaded. Tells its listeners as one comes.
class SiteIcons extends ChangeNotifier {
  SiteIcons({IconLibrary? library, SiteIconFetch? fetch})
    : _library = library ?? IconLibrary(),
      _fetch = fetch ?? fetchSiteIcon;

  /// The app's; main() keeps it in the cache.
  static SiteIcons current = SiteIcons();

  final IconLibrary _library;
  final SiteIconFetch _fetch;

  /// The picture of each host fetched while the app runs, by id: the
  /// library keeps a picture once, under the first name it came with.
  final Map<String, String> _ids = {};

  /// The hosts looked up while the app runs (found, not, or under way):
  /// each once.
  final Set<String> _asked = {};

  /// [site]'s icon, kept from before or fetched since; null while it is
  /// not there (it is fetched then, once), or when the site has none.
  IconImage? of(Uri site) {
    final host = site.host.toLowerCase();
    if (host.isEmpty) return null;
    if (_kept(host) case final image?) return image;
    request(site);
    return null;
  }

  /// Fetches [site]'s icon, unless it is kept or was asked for already.
  void request(Uri site) {
    final host = site.host.toLowerCase();
    if (host.isEmpty || !_asked.add(host)) return;
    unawaited(_lookUp(site, host));
  }

  IconImage? _kept(String host) {
    if (_ids[host] case final id?) return _library[id];
    for (final image in _library.images) {
      if (image.name == host) return image;
    }
    return null;
  }

  Future<void> _lookUp(Uri site, String host) async {
    await _library.load();
    final image =
        _kept(host) ??
        await _fetch(site, (bytes) => _library.add(bytes, name: host));
    if (image == null) return;
    _ids[host] = image.id;
    notifyListeners();
  }
}

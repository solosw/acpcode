import 'featured_upstreams.dart';

/// See [FeaturedUpstream.loader]: none where files cannot be kept.
Future<List<FeaturedUpstream>> fetchFeaturedUpstreams({
  Uri? feed,
  String? cacheDir,
}) async => const [];

/// See [FeaturedUpstream.keptLoader]: none where files cannot be kept.
Future<List<FeaturedUpstream>> readFeaturedUpstreams({
  String? cacheDir,
}) async => const [];

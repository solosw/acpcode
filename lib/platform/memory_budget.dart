import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// What the app's own caches may hold, for its memory to stay within
/// 500MB whatever it shows.
///
/// Skia keeps the GPU's textures it is done with (scratch layers, glyph
/// atlases) up to a limit the engine sets from the window's size: 48 bytes
/// a pixel, some 150MB for a small window, 300MB for a big one, all of it
/// held as the app's for as long as it runs. Kept to [skiaCacheBytes], what
/// a frame uses is still there for the next: frames took no longer with
/// 32MB than with 1GB (tool/perf).
abstract final class MemoryBudget {
  static int skiaCacheBytes = 32 << 20;

  /// Decoded images (pictures pasted in the chat, the browser's).
  static int imageCacheBytes = 48 << 20;

  static void apply() {
    PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheBytes;
    // Skia's (Impeller has no such cache, and ignores it).
    unawaited(
      SystemChannels.skia
          .invokeMethod<void>('Skia.setResourceCacheMaxBytes', skiaCacheBytes)
          .catchError((Object _) {}),
    );
  }
}

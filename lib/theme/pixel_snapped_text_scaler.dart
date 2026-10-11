import 'package:flutter/painting.dart';

/// [base], with every size it gives rounded to a whole device pixel.
///
/// Windows rasterizes each glyph at the font's size in physical pixels; a
/// 13px font at 125% is drawn at 16.25 and its stems land between pixels,
/// which reads blurry next to native text. Rounding the size puts them back
/// on the pixel grid, at the cost of up to half a pixel of size.
class PixelSnappedTextScaler extends TextScaler {
  const PixelSnappedTextScaler(this.base, this.devicePixelRatio);

  final TextScaler base;
  final double devicePixelRatio;

  @override
  double scale(double fontSize) {
    final scaled = base.scale(fontSize);
    if (devicePixelRatio <= 0 || !scaled.isFinite) return scaled;
    return (scaled * devicePixelRatio).roundToDouble() / devicePixelRatio;
  }

  @override
  @Deprecated('Use scale instead.')
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor;

  @override
  bool operator ==(Object other) =>
      other is PixelSnappedTextScaler &&
      other.base == base &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode => Object.hash(base, devicePixelRatio);

  @override
  String toString() => 'PixelSnappedTextScaler($base, dpr: $devicePixelRatio)';
}

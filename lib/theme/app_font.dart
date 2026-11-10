import 'package:flutter/widgets.dart';

/// The app's one typeface, bundled in pubspec.yaml (`fonts:`). ThemeData sets
/// it for every widget; only text drawn straight onto a canvas
/// (`TextPainter`, chart tooltips) has to name it, since it inherits nothing.
const kAppFont = 'Montserrat';

extension RtlLetterSpacing on BuildContext {
  /// [value] in left-to-right text, 0 in Arabic: Arabic letters join, and
  /// any letter spacing pulls them apart.
  double letterSpacingFor(double value) =>
      Directionality.of(this) == TextDirection.rtl ? 0 : value;
}

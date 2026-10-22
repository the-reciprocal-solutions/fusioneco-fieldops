import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

/// "08:05" in the phone's local time.
String clockText(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}

/// "2 h 13 min" or "45 min"; the units come from i18n.
String durationText(BuildContext context, Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final hs = 'capture.on_site_h'.getString(context);
  final ms = 'capture.on_site_min'.getString(context);
  return h > 0 ? '$h $hs $m $ms' : '${d.inMinutes} $ms';
}

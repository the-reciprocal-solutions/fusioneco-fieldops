import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

/// "just now" / "5 min ago" / "3 h ago" / "2 d ago", localized.
String timeAgo(BuildContext context, DateTime? at, {DateTime? now}) {
  if (at == null) return '';
  final d = (now ?? DateTime.now()).difference(at);
  String fmt(String key, int n) => context.formatString(key.getString(context), [n]);
  if (d.inMinutes < 1) return 'time.just_now'.getString(context);
  if (d.inHours < 1) return fmt('time.minutes_ago', d.inMinutes);
  if (d.inDays < 1) return fmt('time.hours_ago', d.inHours);
  return fmt('time.days_ago', d.inDays);
}

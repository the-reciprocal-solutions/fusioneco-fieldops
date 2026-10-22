import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/day_attendance.dart';
import '../attendance/day_rules.dart';
import 'local_notifications.dart';
import 'push_content.dart';

/// Keeps the phone's own "check in" / "end your day" reminders in step with today's shift
/// (docs/daily-attendance-shift-plan.md, D8). The server pushes the same alerts when there is
/// signal; these are drawn by the phone at the exact moment, so they still arrive in a basement
/// or with no data. Both use one tag per day and kind, so a push replaces the local one.
class DayReminders {
  DayReminders._();

  static const _kinds = ['grace_ended', 'end_reminder'];

  /// Schedules what [dayRemindersFor] says should be waiting and cancels the rest. Never throws:
  /// a reminder problem must not break the day card.
  static Future<void> sync({required DayToday? today, required DayLocal? local, DateTime Function()? now}) async {
    try {
      final date = today?.date;
      if (date == null) return;
      final due = dayRemindersFor(today: today, local: local, now: (now ?? DateTime.now)());
      final wanted = {for (final r in due) r.key: r};
      final lang = await LocalNotifications.language();
      for (final kind in _kinds) {
        final r = wanted[kind];
        if (r == null) {
          await LocalNotifications.cancelReminder('day:$date:$kind');
          continue;
        }
        final isGrace = kind == 'grace_ended';
        await LocalNotifications.scheduleReminder(
          tag: r.tag,
          title: pushText(isGrace ? 'day.grace_title' : 'day.end_title', lang: lang),
          body: pushText(isGrace ? 'day.grace_body' : 'day.end_body', lang: lang),
          at: r.at,
          payload: jsonEncode({'title': pushText(isGrace ? 'day.grace_title' : 'day.end_title', lang: lang), 'category': 'work_order', 'threadId': r.tag}),
        );
      }
    } catch (e) {
      debugPrint('day reminders: $e');
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/day_attendance.dart';
import '../../state/day_capture_controller.dart';
import '../../widgets/tech_popup.dart';
import 'day_sheet.dart';

/// The one place the screens start or end the technician's DAY from (daily
/// attendance for payroll), so the dashboard card and the shell banner behave
/// the same. Everything works with no signal: the day is written on the phone
/// first and sent by the queue.

/// Start my day (or "Start off-day work" on a weekly off / holiday).
/// Returns true when the day was started.
Future<bool> startMyDay(BuildContext context, WidgetRef ref, DayToday today) async {
  final off = today.dayType == DayType.weeklyOff || today.dayType == DayType.holiday;
  if (off) {
    final ok = await _confirmOffDay(context);
    if (ok != true || !context.mounted) return false;
  }
  final saved = await showDaySheet(context, DayCaptureArgs.start(today: today));
  if (saved && context.mounted) {
    showTechPopup(context, message: 'attend.saved_in'.getString(context), queued: true);
  }
  return saved;
}

/// End my day.
Future<bool> endMyDay(BuildContext context, WidgetRef ref, DayToday today, DayLocal local) async {
  final saved = await showDaySheet(context, DayCaptureArgs.end(today: today, local: local));
  if (saved && context.mounted) {
    showTechPopup(context, message: 'attend.saved_out'.getString(context), queued: true);
  }
  return saved;
}

Future<bool?> _confirmOffDay(BuildContext context) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text('attend.off_day_confirm_title'.getString(context)),
    content: Text('attend.off_day_confirm_body'.getString(context)),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('common.cancel'.getString(context))),
      ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: Text('attend.start_off_day'.getString(context))),
    ],
  ),
);

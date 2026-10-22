import '../../domain/day_attendance.dart';
import '../../domain/capture.dart';

/// Pure rules for the daily attendance card (docs/daily-attendance-shift-plan.md).
/// No database, no network, no clock reads: every rule is unit-tested on its own
/// (test/day_rules_test.dart).
///
/// The SERVER decides late, absent, overtime and what payroll sees, from the
/// phone tap time. Everything here only decides what the card says and which
/// button it offers, so it is right with no signal. Principle (same as site
/// visits): the app never stops a technician; weak evidence is recorded and
/// flagged for a supervisor.

/// Where the technician is in their day.
enum DayPhase {
  /// No shift set (or not loaded yet): nothing is expected, the card stays out of the way.
  noShift,

  /// A weekly off, holiday or leave with the day not started. The card offers
  /// "Start off-day work" only on a weekly off / holiday.
  offDay,

  /// A working day and "Start my day" has not opened yet.
  beforeOpen,

  /// Open, inside grace: on time if they start now.
  canStart,

  /// Past grace, before the half-day limit: late, and told to check in.
  late,

  /// Past the half-day limit: starting now counts as a half day.
  veryLate,

  /// Started, shift still running.
  working,

  /// Started, the shift has ended and they have not ended the day.
  shiftEnded,

  /// Started, never ended, and the server already closed the day at the shift end
  /// (nobody checked out). They can still end it to correct the closing time.
  autoClosed,

  /// Started and ended.
  done,
}

/// What the card needs to draw one frame.
class DayCardState {
  const DayCardState({
    required this.phase,
    this.dayType = DayType.working,
    this.minutesToGraceEnd,
    this.minutesLate,
    this.holidayName,
  });

  final DayPhase phase;
  final DayType dayType;

  /// In [DayPhase.canStart]: minutes of grace left (never negative).
  final int? minutesToGraceEnd;

  /// In [DayPhase.late] / [DayPhase.veryLate]: minutes since the shift start.
  final int? minutesLate;
  final String? holidayName;

  /// "Start my day" (or "Start off-day work") is available.
  bool get canStartDay => switch (phase) {
    DayPhase.canStart || DayPhase.late || DayPhase.veryLate => true,
    DayPhase.offDay => dayType == DayType.weeklyOff || dayType == DayType.holiday,
    _ => false,
  };

  bool get canEndDay => phase == DayPhase.working || phase == DayPhase.shiftEnded || phase == DayPhase.autoClosed;

  /// Past the grace time and nothing started: the shell banner shows.
  bool get needsCheckIn => phase == DayPhase.late || phase == DayPhase.veryLate;
}

int _minutes(Duration d) => d.inMinutes;

/// The state of the card at [now], from the cached shift for today and the
/// phone's own record of the day.
DayCardState dayCardState({required DayToday? today, required DayLocal? local, required DateTime now}) {
  if (today == null || !today.hasShift || today.shift == null) return const DayCardState(phase: DayPhase.noShift);

  if (local != null && local.isEnded) return DayCardState(phase: DayPhase.done, dayType: today.dayType);

  if (local != null && local.isStarted) {
    if (local.flags.contains('AUTO_CLOSED')) return DayCardState(phase: DayPhase.autoClosed, dayType: today.dayType);
    final ends = today.endsAt;
    final over = ends != null && !now.isBefore(ends);
    return DayCardState(phase: over ? DayPhase.shiftEnded : DayPhase.working, dayType: today.dayType);
  }

  if (today.dayType != DayType.working) {
    return DayCardState(phase: DayPhase.offDay, dayType: today.dayType, holidayName: today.holidayName);
  }

  final opens = today.opensAt;
  final graceEnds = today.graceEndsAt;
  final half = today.halfDayFrom;
  final starts = today.startsAt;
  if (opens != null && now.isBefore(opens)) return const DayCardState(phase: DayPhase.beforeOpen);
  if (graceEnds == null || !now.isAfter(graceEnds)) {
    return DayCardState(phase: DayPhase.canStart, minutesToGraceEnd: graceEnds == null ? null : _minutes(graceEnds.difference(now)).clamp(0, 100000));
  }
  final late = starts == null ? null : _minutes(now.difference(starts));
  if (half != null && !now.isBefore(half)) return DayCardState(phase: DayPhase.veryLate, minutesLate: late);
  return DayCardState(phase: DayPhase.late, minutesLate: late);
}

/// A reminder the phone draws by itself at [at], with no signal needed. [key] matches the
/// server's alert kind (`grace_ended`, `end_reminder`) so a push for the same thing replaces it
/// instead of stacking a second banner.
class DayReminder {
  const DayReminder({required this.key, required this.date, required this.at});
  final String key;
  final String date;
  final DateTime at;

  /// One id per day and kind, so scheduling again replaces rather than doubles.
  String get tag => 'day:$date:$key';
}

/// Which local reminders should be waiting, from the cached shift and the phone's own record.
/// Pure. Nothing on a day off, nothing once the moment has passed, nothing once it is not needed.
List<DayReminder> dayRemindersFor({required DayToday? today, required DayLocal? local, required DateTime now}) {
  if (today == null || !today.hasShift || today.shift == null || today.date == null) return const [];
  if (today.dayType != DayType.working) return const [];
  final date = today.date!;
  if (local != null && local.isEnded) return const [];
  if (local == null || !local.isStarted) {
    final graceEnds = today.graceEndsAt;
    if (graceEnds != null && graceEnds.isAfter(now)) return [DayReminder(key: 'grace_ended', date: date, at: graceEnds)];
    return const [];
  }
  if (local.flags.contains('AUTO_CLOSED')) return const [];
  final ends = today.endsAt;
  if (ends != null && ends.isAfter(now)) return [DayReminder(key: 'end_reminder', date: date, at: ends)];
  return const [];
}

/// A guess at the status a start at [inAt] will get, so the card can say "on
/// time" or "late" before the server has answered. The server's answer replaces it.
String estimateStatus(DayToday today, DateTime inAt) {
  if (today.dayType != DayType.working) return 'off_day_work';
  final graceEnds = today.graceEndsAt;
  if (graceEnds == null || !inAt.isAfter(graceEnds)) return 'present';
  final half = today.halfDayFrom;
  if (half != null && inAt.isAfter(half)) return 'half_day';
  return 'late';
}

/// Late minutes the server will most likely count (0 when inside grace).
int estimateLateMinutes(DayToday today, DateTime inAt) {
  final graceEnds = today.graceEndsAt;
  final starts = today.startsAt;
  if (starts == null || today.dayType != DayType.working) return 0;
  if (graceEnds == null || !inAt.isAfter(graceEnds)) return 0;
  final from = today.shift?.lateFrom == 'grace_end' ? graceEnds : starts;
  final m = inAt.difference(from).inMinutes;
  return m < 1 ? 1 : m;
}

/// When the cached "today" no longer describes the real day (the phone has been
/// offline across midnight, or the shift ended long ago) it is rolled forward
/// whole days using the shift's own rules, so the card is right the next
/// morning with no signal. Only the weekly off is known offline; a public
/// holiday or leave the server added is picked up on the next connection.
///
/// Returns [today] unchanged while it is still current. Assumes the shift's
/// time zone has no clock change between the two days (true for the zones in
/// use); the next connection corrects it anyway.
DayToday rollForward(DayToday today, DateTime now, {Duration lateAccept = const Duration(hours: 6)}) {
  final closes = today.closesAt;
  final shift = today.shift;
  final date = today.date;
  if (!today.hasShift || closes == null || shift == null || date == null) return today;
  final staleAfter = closes.add(const Duration(hours: 2));
  if (now.isBefore(staleAfter)) return today;

  final days = (now.difference(closes).inHours / 24).ceil().clamp(1, 60);
  DateTime? shiftBy(DateTime? t) => t?.add(Duration(days: days));
  final d = DateTime.tryParse('${date}T00:00:00Z');
  if (d == null) return today;
  final newDate = d.add(Duration(days: days));
  final weekday = newDate.weekday % 7; // Dart: Mon=1..Sun=7 -> 0=Sunday
  return DayToday(
    hasShift: true,
    fetchedAt: today.fetchedAt,
    date: newDate.toIso8601String().substring(0, 10),
    dayType: shift.weeklyOffDays.contains(weekday) ? DayType.weeklyOff : DayType.working,
    shift: shift,
    startsAt: shiftBy(today.startsAt),
    endsAt: shiftBy(today.endsAt),
    opensAt: shiftBy(today.opensAt),
    graceEndsAt: shiftBy(today.graceEndsAt),
    halfDayFrom: shiftBy(today.halfDayFrom),
    absentFrom: shiftBy(today.absentFrom),
    closesAt: shiftBy(today.closesAt),
    homeBuildingId: today.homeBuildingId,
  );
}

/// The body of the day check-out for the queue: the same event shape as a site
/// visit, plus the shift [date] the phone is ending and a copy of the start of
/// day, so the server can still create the day if the start request never
/// arrived (a whole shift offline, then a dropped first request). The copy has
/// no photo: the start request already carries it.
Map<String, dynamic> buildDayCheckOutBody({
  required String eventId,
  required String date,
  required DateTime at,
  required DateTime queuedAt,
  required CaptureFix fix,
  required String startEventId,
  required DateTime startAt,
  required CaptureFix startFix,
  String? startReason,
  String? photoPlaceholder,
  String? reason,
  String? deviceId,
  String? appVersion,
}) {
  Map<String, dynamic> event({
    required String id,
    required DateTime at,
    required DateTime queuedAt,
    required CaptureFix fix,
    String? photo,
    String? reason,
  }) => {
    'eventId': id,
    'at': at.toUtc().toIso8601String(),
    'queuedAt': queuedAt.toUtc().toIso8601String(),
    'fixKind': fix.kind.wire,
    if (fix.hasCoords) ...{
      'lat': fix.lat,
      'lng': fix.lng,
      if (fix.accuracyM != null) 'accuracyM': fix.accuracyM,
    },
    if (fix.mock) 'mock': true,
    'photoUrl': ?photo,
    if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    'deviceId': ?deviceId,
    'appVersion': ?appVersion,
  };

  return {
    ...event(id: eventId, at: at, queuedAt: queuedAt, fix: fix, photo: photoPlaceholder, reason: reason),
    'date': date,
    'checkIn': event(id: startEventId, at: startAt, queuedAt: startAt, fix: startFix, reason: startReason),
  };
}

/// The body of the day check-in for the queue.
Map<String, dynamic> buildDayCheckInBody({
  required String eventId,
  required DateTime at,
  required DateTime queuedAt,
  required CaptureFix fix,
  String? photoPlaceholder,
  String? reason,
  String? deviceId,
  String? appVersion,
}) => {
  'eventId': eventId,
  'at': at.toUtc().toIso8601String(),
  'queuedAt': queuedAt.toUtc().toIso8601String(),
  'fixKind': fix.kind.wire,
  if (fix.hasCoords) ...{
    'lat': fix.lat,
    'lng': fix.lng,
    if (fix.accuracyM != null) 'accuracyM': fix.accuracyM,
  },
  if (fix.mock) 'mock': true,
  'photoUrl': ?photoPlaceholder,
  if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
  'deviceId': ?deviceId,
  'appVersion': ?appVersion,
};

/// A refused day end in plain words, never the server's raw message.
String plainDayIssue({required int? status, String? code}) {
  switch (code) {
    case 'NO_SHIFT':
      return 'You have no shift set. Ask your supervisor.';
    case 'MONTH_LOCKED':
      return 'This month is closed for payroll. Ask your supervisor to enter it.';
    case 'DAY_NOT_STARTED':
      return 'The server has no start of day to end.';
  }
  if (status == 403) return 'You are not allowed to do this.';
  return 'The server refused this entry.';
}

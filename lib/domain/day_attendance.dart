/// Daily attendance for payroll (docs/daily-attendance-shift-plan.md, server
/// documentation/daily-attendance.md).
///
/// This is the PHONE's copy: what the day card shows (the shift, the moments it
/// counts to, whether the technician has started and ended the day) and the
/// start / end taps themselves. The server's copy is the record payroll reads
/// and the one that decides late, absent and overtime; this file only carries
/// enough to make the card right with no signal.
library;

import 'capture.dart';

/// What kind of day it is for this technician (the server decides; offline the
/// phone only knows weekly offs, from the shift).
enum DayType {
  working,
  weeklyOff,
  holiday,
  leave;

  static DayType fromWire(String? v) => switch (v) {
    'weekly_off' => DayType.weeklyOff,
    'holiday' => DayType.holiday,
    'leave' => DayType.leave,
    _ => DayType.working,
  };

  String get wire => switch (this) {
    DayType.weeklyOff => 'weekly_off',
    DayType.working => 'working',
    DayType.holiday => 'holiday',
    DayType.leave => 'leave',
  };
}

/// The shift rules the card needs.
class ShiftInfo {
  const ShiftInfo({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.graceInMin,
    required this.halfDayAfterMin,
    required this.absentAfterMin,
    this.lateFrom = 'start',
    this.weeklyOffDays = const [0],
  });

  final String id;
  final String name;
  final String startTime;
  final String endTime;
  final int graceInMin;
  final int halfDayAfterMin;
  final int absentAfterMin;
  final String lateFrom;
  final List<int> weeklyOffDays;

  factory ShiftInfo.fromJson(Map<String, dynamic> j) => ShiftInfo(
    id: '${j['id'] ?? ''}',
    name: '${j['name'] ?? ''}',
    startTime: '${j['startTime'] ?? '09:00'}',
    endTime: '${j['endTime'] ?? '18:00'}',
    graceInMin: (j['graceInMin'] as num?)?.toInt() ?? 15,
    halfDayAfterMin: (j['halfDayAfterMin'] as num?)?.toInt() ?? 120,
    absentAfterMin: (j['absentAfterMin'] as num?)?.toInt() ?? 240,
    lateFrom: '${j['lateFrom'] ?? 'start'}',
    weeklyOffDays: [for (final d in (j['weeklyOffDays'] as List? ?? const [0])) (d as num).toInt()],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'startTime': startTime,
    'endTime': endTime,
    'graceInMin': graceInMin,
    'halfDayAfterMin': halfDayAfterMin,
    'absentAfterMin': absentAfterMin,
    'lateFrom': lateFrom,
    'weeklyOffDays': weeklyOffDays,
  };
}

/// "Today" as the server last described it, cached on the phone.
class DayToday {
  const DayToday({
    required this.hasShift,
    required this.fetchedAt,
    this.date,
    this.dayType = DayType.working,
    this.holidayName,
    this.shift,
    this.startsAt,
    this.endsAt,
    this.opensAt,
    this.graceEndsAt,
    this.halfDayFrom,
    this.absentFrom,
    this.closesAt,
    this.homeBuildingId,
    this.serverRecord,
  });

  const DayToday.none(DateTime fetchedAt) : this(hasShift: false, fetchedAt: fetchedAt);

  final bool hasShift;

  /// When the phone got this from the server.
  final DateTime fetchedAt;

  /// The shift date (the date the shift STARTS), `YYYY-MM-DD`.
  final String? date;
  final DayType dayType;
  final String? holidayName;
  final ShiftInfo? shift;
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// "Start my day" opens.
  final DateTime? opensAt;

  /// Last moment that still counts as on time.
  final DateTime? graceEndsAt;
  final DateTime? halfDayFrom;
  final DateTime? absentFrom;

  /// A check-in is still taken until this moment.
  final DateTime? closesAt;
  final String? homeBuildingId;

  /// The server's day record, when it had one.
  final Map<String, dynamic>? serverRecord;

  static DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

  factory DayToday.fromServer(Map<String, dynamic> j, {required DateTime fetchedAt}) {
    if (j['hasShift'] != true) return DayToday.none(fetchedAt);
    return DayToday(
      hasShift: true,
      fetchedAt: fetchedAt,
      date: j['date'] as String?,
      dayType: DayType.fromWire(j['dayType'] as String?),
      holidayName: j['holidayName'] as String?,
      shift: j['shift'] is Map ? ShiftInfo.fromJson(Map<String, dynamic>.from(j['shift'] as Map)) : null,
      startsAt: _dt(j['startsAt']),
      endsAt: _dt(j['endsAt']),
      opensAt: _dt(j['opensAt']),
      graceEndsAt: _dt(j['graceEndsAt']),
      halfDayFrom: _dt(j['halfDayFrom']),
      absentFrom: _dt(j['absentFrom']),
      closesAt: _dt(j['closesAt']),
      homeBuildingId: j['homeBuildingId'] as String?,
      serverRecord: j['record'] is Map ? Map<String, dynamic>.from(j['record'] as Map) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'hasShift': hasShift,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'date': date,
    'dayType': dayType.wire,
    'holidayName': holidayName,
    'shift': shift?.toJson(),
    'startsAt': startsAt?.toUtc().toIso8601String(),
    'endsAt': endsAt?.toUtc().toIso8601String(),
    'opensAt': opensAt?.toUtc().toIso8601String(),
    'graceEndsAt': graceEndsAt?.toUtc().toIso8601String(),
    'halfDayFrom': halfDayFrom?.toUtc().toIso8601String(),
    'absentFrom': absentFrom?.toUtc().toIso8601String(),
    'closesAt': closesAt?.toUtc().toIso8601String(),
    'homeBuildingId': homeBuildingId,
    'record': serverRecord,
  };

  factory DayToday.fromCache(Map<String, dynamic> j) {
    final fetched = DateTime.tryParse('${j['fetchedAt']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
    if (j['hasShift'] != true) return DayToday.none(fetched);
    return DayToday.fromServer({...j, 'hasShift': true}, fetchedAt: fetched);
  }
}

/// One end (start or end) of the technician's day, on the phone.
class DayLocal {
  const DayLocal({
    required this.userId,
    required this.date,
    this.shiftName,
    this.inAt,
    this.inFix,
    this.inPhotoPath,
    this.inReason,
    this.outAt,
    this.outFix,
    this.outPhotoPath,
    this.outReason,
    this.inSync = SendState.none,
    this.outSync = SendState.none,
    this.inIssue,
    this.outIssue,
    this.status,
    this.lateMinutes,
    this.workedMinutes,
    this.flags = const [],
    this.reviewStatus,
  });

  final String userId;
  final String date;
  final String? shiftName;

  final DateTime? inAt;
  final CaptureFix? inFix;
  final String? inPhotoPath;
  final String? inReason;

  final DateTime? outAt;
  final CaptureFix? outFix;
  final String? outPhotoPath;
  final String? outReason;

  final SendState inSync;
  final SendState outSync;
  final String? inIssue;
  final String? outIssue;

  /// What the server decided (present, late, half_day, absent, off_day_work…), once it answered.
  final String? status;
  final int? lateMinutes;
  final int? workedMinutes;
  final List<String> flags;
  final String? reviewStatus;

  bool get isStarted => inAt != null;
  bool get isEnded => outAt != null;
  bool get hasUnsentEnd => inSync == SendState.queued || outSync == SendState.queued;

  DayLocal copyWith({
    String? shiftName,
    DateTime? inAt,
    CaptureFix? inFix,
    String? inPhotoPath,
    String? inReason,
    DateTime? outAt,
    CaptureFix? outFix,
    String? outPhotoPath,
    String? outReason,
    SendState? inSync,
    SendState? outSync,
    String? inIssue,
    String? outIssue,
    bool clearInIssue = false,
    bool clearOutIssue = false,
    String? status,
    int? lateMinutes,
    int? workedMinutes,
    List<String>? flags,
    String? reviewStatus,
  }) => DayLocal(
    userId: userId,
    date: date,
    shiftName: shiftName ?? this.shiftName,
    inAt: inAt ?? this.inAt,
    inFix: inFix ?? this.inFix,
    inPhotoPath: inPhotoPath ?? this.inPhotoPath,
    inReason: inReason ?? this.inReason,
    outAt: outAt ?? this.outAt,
    outFix: outFix ?? this.outFix,
    outPhotoPath: outPhotoPath ?? this.outPhotoPath,
    outReason: outReason ?? this.outReason,
    inSync: inSync ?? this.inSync,
    outSync: outSync ?? this.outSync,
    inIssue: clearInIssue ? null : (inIssue ?? this.inIssue),
    outIssue: clearOutIssue ? null : (outIssue ?? this.outIssue),
    status: status ?? this.status,
    lateMinutes: lateMinutes ?? this.lateMinutes,
    workedMinutes: workedMinutes ?? this.workedMinutes,
    flags: flags ?? this.flags,
    reviewStatus: reviewStatus ?? this.reviewStatus,
  );

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'date': date,
    'shiftName': shiftName,
    'inAt': inAt?.toUtc().toIso8601String(),
    'inFix': inFix?.toJson(),
    'inPhotoPath': inPhotoPath,
    'inReason': inReason,
    'outAt': outAt?.toUtc().toIso8601String(),
    'outFix': outFix?.toJson(),
    'outPhotoPath': outPhotoPath,
    'outReason': outReason,
    'inSync': inSync.name,
    'outSync': outSync.name,
    'inIssue': inIssue,
    'outIssue': outIssue,
    'status': status,
    'lateMinutes': lateMinutes,
    'workedMinutes': workedMinutes,
    'flags': flags,
    'reviewStatus': reviewStatus,
  };

  factory DayLocal.fromJson(Map<String, dynamic> j) => DayLocal(
    userId: j['userId'] as String,
    date: j['date'] as String,
    shiftName: j['shiftName'] as String?,
    inAt: j['inAt'] == null ? null : DateTime.parse(j['inAt'] as String).toLocal(),
    inFix: j['inFix'] == null ? null : CaptureFix.fromJson(Map<String, dynamic>.from(j['inFix'] as Map)),
    inPhotoPath: j['inPhotoPath'] as String?,
    inReason: j['inReason'] as String?,
    outAt: j['outAt'] == null ? null : DateTime.parse(j['outAt'] as String).toLocal(),
    outFix: j['outFix'] == null ? null : CaptureFix.fromJson(Map<String, dynamic>.from(j['outFix'] as Map)),
    outPhotoPath: j['outPhotoPath'] as String?,
    outReason: j['outReason'] as String?,
    inSync: SendState.fromName(j['inSync'] as String?),
    outSync: SendState.fromName(j['outSync'] as String?),
    inIssue: j['inIssue'] as String?,
    outIssue: j['outIssue'] as String?,
    status: j['status'] as String?,
    lateMinutes: (j['lateMinutes'] as num?)?.toInt(),
    workedMinutes: (j['workedMinutes'] as num?)?.toInt(),
    flags: [for (final f in (j['flags'] as List? ?? const [])) '$f'],
    reviewStatus: j['reviewStatus'] as String?,
  );
}

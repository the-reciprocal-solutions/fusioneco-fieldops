import '../core/network/envelope.dart';

/// A schedule a person asked for ("remind me every Monday at 8…"), from
/// `/api/schedules` or embedded in a conversation message as a schedule card
/// (docs/superpowers/specs/2026-09-30-orchestrator-and-schedules.md, O3).
///
/// Shape: `ScheduleDTO` in `../fusion-eco-server/src/services/schedules/types.ts`
/// ("## Contract (server)" C3). Read tolerantly. The server's own words for
/// the cadence (`human`: "Every Monday 08:00") win; `cron` / `runAt` are
/// only parsed as a fallback (see `cadence_text.dart`).

enum ScheduleKind { reminder, agentTask, watch }

enum ScheduleStatus { active, paused, done, expired, failed }

enum ScheduleRunResult { started, done, failed, none }

class ScheduleCadence {
  const ScheduleCadence({
    this.freq,
    this.interval = 1,
    this.days = const [],
    this.at,
    this.date,
    this.until,
    this.timezone,
  });

  /// once | hourly | daily | weekdays | weekly | monthly — null when unknown.
  final String? freq;
  final int interval;

  /// Lower-case three-letter day names (`mon`…`sun`) for weekly schedules.
  final List<String> days;

  /// "08:00" (24 h) local to [timezone].
  final String? at;

  /// One-off: when it runs.
  final DateTime? date;
  final DateTime? until;
  final String? timezone;

  static ScheduleCadence fromJson(dynamic json) {
    if (json is! Map) return const ScheduleCadence();
    final rawDays = json['days'] ?? json['byDay'] ?? json['weekdays'];
    final days = <String>[
      if (rawDays is List) for (final d in rawDays) ?_dayKey(d),
      if (rawDays is String) for (final d in rawDays.split(',')) ?_dayKey(d),
    ];
    return ScheduleCadence(
      freq: firstNonEmpty([json['freq'], json['type'], json['every'], json['repeat']])?.toLowerCase(),
      interval: asInt(json['interval'] ?? json['everyHours'] ?? json['n']) ?? 1,
      days: days,
      at: firstNonEmpty([json['at'], json['time']]),
      date: asDate(json['date'] ?? json['runAt'] ?? json['once']),
      until: asDate(json['until']),
      timezone: firstNonEmpty([json['timezone'], json['tz']]),
    );
  }

  /// The common 5-field crons the server writes (`M H * * *` daily,
  /// `M H * * 1-5` weekdays, `M H * * 1,3` weekly, `M H D * *` monthly,
  /// `M */N * * *` every N hours). Anything else → unknown (null freq), and
  /// the card falls back to "Next run …".
  static ScheduleCadence fromCron(String? cron, {String? tz, DateTime? until}) {
    final f = (cron ?? '').trim().split(RegExp(r'\s+'));
    if (f.length != 5) return ScheduleCadence(timezone: tz, until: until);
    final (min, hour, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4]);
    String? at() {
      final h = int.tryParse(hour), m = int.tryParse(min);
      if (h == null || m == null) return null;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }

    final everyHours = RegExp(r'^\*/(\d+)$').firstMatch(hour);
    if (everyHours != null && dom == '*' && mon == '*' && dow == '*') {
      return ScheduleCadence(freq: 'hourly', interval: int.parse(everyHours.group(1)!), timezone: tz, until: until);
    }
    if (hour == '*' && dom == '*' && mon == '*' && dow == '*') {
      return ScheduleCadence(freq: 'hourly', timezone: tz, until: until);
    }
    if (mon != '*') return ScheduleCadence(timezone: tz, until: until);
    if (dom == '*' && dow == '*') return ScheduleCadence(freq: 'daily', at: at(), timezone: tz, until: until);
    if (dom == '*') {
      final days = <String>[];
      for (final part in dow.split(',')) {
        final range = part.split('-');
        final a = int.tryParse(range.first), b = int.tryParse(range.last);
        if (a == null || b == null) return ScheduleCadence(timezone: tz, until: until);
        for (var d = a; d <= b; d++) {
          final k = _dayKey(d % 7);
          if (k != null && !days.contains(k)) days.add(k);
        }
      }
      return ScheduleCadence(freq: 'weekly', days: days, at: at(), timezone: tz, until: until);
    }
    if (dow == '*' && int.tryParse(dom) != null) {
      return ScheduleCadence(freq: 'monthly', at: at(), timezone: tz, until: until);
    }
    return ScheduleCadence(timezone: tz, until: until);
  }

  static String? _dayKey(dynamic d) {
    if (d is num) {
      // 0 = Sunday (JS) … 6 = Saturday.
      const js = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
      final i = d.toInt();
      return i >= 0 && i < 7 ? js[i] : null;
    }
    final s = d.toString().trim().toLowerCase();
    if (s.length < 2) return null;
    const map = {'mo': 'mon', 'tu': 'tue', 'we': 'wed', 'th': 'thu', 'fr': 'fri', 'sa': 'sat', 'su': 'sun'};
    return map[s.substring(0, 2)];
  }
}

class ScheduleRun {
  const ScheduleRun({required this.id, required this.result, this.at, this.summary, this.error});
  final String id;
  final ScheduleRunResult result;
  final DateTime? at;
  final String? summary;
  final String? error;

  factory ScheduleRun.fromJson(Map<String, dynamic> json) => ScheduleRun(
    id: json['id']?.toString() ?? '',
    result: _runResult(json['status'] ?? json['result']),
    at: asDate(json['finishedAt'] ?? json['at'] ?? json['startedAt'] ?? json['createdAt']),
    summary: firstNonEmpty([json['summary']]),
    error: firstNonEmpty([json['error'], json['reason']]),
  );
}

ScheduleRunResult _runResult(dynamic v) => switch (v?.toString()) {
  'done' || 'succeeded' || 'success' || 'completed' || 'ok' => ScheduleRunResult.done,
  // `skipped`: a fire over the run budget — the owner is told it failed.
  'failed' || 'error' || 'skipped' => ScheduleRunResult.failed,
  'started' || 'running' || 'queued' => ScheduleRunResult.started,
  _ => ScheduleRunResult.none,
};

class UserSchedule {
  const UserSchedule({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    this.request,
    this.cadence = const ScheduleCadence(),
    this.cadenceText,
    this.nextRunAt,
    this.lastRun,
    this.entity,
    this.entityId,
    this.recordRef,
    this.ownerName,
    this.originMessageId,
    this.canEdit = true,
  });

  final String id;
  final String title;
  final ScheduleKind kind;
  final ScheduleStatus status;

  /// The words the person used, kept so a run re-asks the same thing.
  final String? request;
  final ScheduleCadence cadence;

  /// The server's own plain-words cadence, when it sends one.
  final String? cadenceText;
  final DateTime? nextRunAt;
  final ScheduleRun? lastRun;

  /// The record it came from (conversation entity key + UUID), if any.
  final String? entity;
  final String? entityId;
  final String? recordRef;
  final String? ownerName;

  /// The message that asked for it, in the thread [entity]/[entityId].
  final String? originMessageId;

  /// Owner or Admin may pause / delete it.
  final bool canEdit;

  bool get isPaused => status == ScheduleStatus.paused;
  bool get isFinished => status == ScheduleStatus.done || status == ScheduleStatus.expired;

  factory UserSchedule.fromJson(Map<String, dynamic> json) {
    final last = json['lastRun'];
    final record = json['record'];
    final origin = json['origin'];
    final lastStatus = json['lastStatus'] ?? json['lastResult'];
    final structured = json['cadence'] ?? json['rule'] ?? json['recurrence'] ?? json['repeat'];
    final tz = firstNonEmpty([json['tz'], json['timezone']]);
    final runAt = asDate(json['runAt']);
    final cadence = structured != null
        ? ScheduleCadence.fromJson(structured)
        : (json['cron'] != null && json['cron'].toString().trim().isNotEmpty)
            ? ScheduleCadence.fromCron(json['cron'].toString(), tz: tz, until: asDate(json['until']))
            : runAt != null
                ? ScheduleCadence(freq: 'once', date: runAt, timezone: tz)
                : const ScheduleCadence();
    return UserSchedule(
      id: firstNonEmpty([json['id'], json['scheduleId']]) ?? '',
      title: firstNonEmpty([json['title'], json['name'], json['request'], json['text']]) ?? '',
      kind: switch (json['kind']?.toString()) {
        'agent_task' || 'agentTask' => ScheduleKind.agentTask,
        'watch' => ScheduleKind.watch,
        _ => ScheduleKind.reminder,
      },
      status: switch (json['status']?.toString()) {
        'paused' => ScheduleStatus.paused,
        'done' || 'completed' => ScheduleStatus.done,
        'expired' => ScheduleStatus.expired,
        'failed' => ScheduleStatus.failed,
        _ => (asBool(json['paused']) ?? false) ? ScheduleStatus.paused : ScheduleStatus.active,
      },
      request: firstNonEmpty([json['request'], json['text'], json['prompt']]),
      cadence: cadence,
      cadenceText: firstNonEmpty([json['cadenceText'], json['human'], json['when']]),
      nextRunAt: asDate(json['nextRunAt'] ?? json['nextRun']),
      lastRun: last is Map
          ? ScheduleRun.fromJson(Map<String, dynamic>.from(last))
          : (lastStatus != null || json['lastRunAt'] != null)
              ? ScheduleRun(
                  id: '',
                  result: _runResult(lastStatus is Map ? lastStatus['status'] : lastStatus),
                  at: asDate(lastStatus is Map ? (lastStatus['at'] ?? json['lastRunAt']) : json['lastRunAt']),
                  summary: firstNonEmpty([
                    json['lastSummary'],
                    if (lastStatus is Map) lastStatus['summary'],
                  ]),
                )
              : null,
      // The thread it came from wins over the record it is about.
      entity: firstNonEmpty([if (origin is Map) origin['entity'], json['entity'], if (record is Map) record['entity']]),
      entityId: firstNonEmpty([
        if (origin is Map) origin['entityId'],
        json['entityId'],
        if (record is Map) record['entityId'],
        if (record is Map) record['id'],
      ]),
      originMessageId: origin is Map ? firstNonEmpty([origin['messageId']]) : null,
      canEdit: asBool(json['canEdit']) ?? true,
      recordRef: firstNonEmpty([json['recordRef'], if (record is Map) record['ref']]),
      ownerName: firstNonEmpty([json['ownerName'], if (json['owner'] is Map) (json['owner'] as Map)['name']]),
    );
  }
}

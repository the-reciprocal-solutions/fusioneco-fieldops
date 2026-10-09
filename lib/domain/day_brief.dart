import '../core/network/envelope.dart';

/// The "Your day" brief — `GET /api/fm/technicians/me/day-brief`
/// (server `src/services/dayBrief/types.ts`, documentation/technician-day-brief.md;
/// change both together). FieldOps side: docs/day-brief.md.
///
/// Parsed tolerantly: an older or partial answer still yields a usable brief
/// (missing lists are empty, missing flags are false). The ORDER of [steps]
/// is the server's rules order; the model only wrote the `ai` texts.
enum TextSource { ai, rules }

TextSource _source(Object? raw) => raw?.toString() == 'ai' ? TextSource.ai : TextSource.rules;

Map<String, String> _params(Object? raw) => raw is Map
    ? {for (final e in raw.entries) e.key.toString(): e.value?.toString() ?? ''}
    : const {};

class DayItem {
  const DayItem({required this.code, this.params = const {}, required this.text, this.source = TextSource.rules});

  final String code;
  final Map<String, String> params;

  /// English rules text, or the model's text (`code == 'ai_tip'`).
  final String text;
  final TextSource source;

  factory DayItem.fromJson(Map<String, dynamic> json) => DayItem(
        code: json['code']?.toString() ?? 'ai_tip',
        params: _params(json['params']),
        text: json['text']?.toString() ?? '',
        source: _source(json['source']),
      );

  Map<String, dynamic> toJson() => {'code': code, 'params': params, 'text': text, 'source': source.name};
}

class DayPermit {
  const DayPermit({
    required this.state,
    this.permitId,
    this.permitNo,
    this.status,
    this.type,
    this.typeLabel,
    this.validUntil,
    this.nextAction,
  });

  /// `live | expiring | not_live | suspended | suggested`.
  final String state;
  final String? permitId;
  final String? permitNo;
  final String? status;
  final String? type;
  final String? typeLabel;
  final DateTime? validUntil;
  final String? nextAction;

  bool get blocking => state == 'not_live' || state == 'suspended' || state == 'suggested';

  static DayPermit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return DayPermit(
      state: json['state']?.toString() ?? 'suggested',
      permitId: firstNonEmpty([json['permitId']]),
      permitNo: firstNonEmpty([json['permitNo']]),
      status: firstNonEmpty([json['status']]),
      type: firstNonEmpty([json['type']]),
      typeLabel: firstNonEmpty([json['typeLabel']]),
      validUntil: asDate(json['validUntil']),
      nextAction: firstNonEmpty([json['nextAction']]),
    );
  }
}

class DayStep {
  const DayStep({
    required this.order,
    required this.kind,
    required this.id,
    this.ref,
    required this.title,
    this.location,
    this.due,
    this.status = '',
    this.priority = 'Medium',
    this.done = false,
    this.reason = '',
    this.reasonSource = TextSource.rules,
    this.reasonCode = 'due_today',
    this.reasonParams = const {},
    this.samePlaceAsPrevious = false,
    this.items = const [],
    this.route,
    this.permit,
    this.safety = false,
    this.overdue = false,
    this.inProgress = false,
    this.permitBlocked = false,
  });

  final int order;

  /// `wo | pm | rm | inspection | snag | invite`.
  final String kind;
  final String id;
  final String? ref;
  final String title;
  final String? location;
  final DateTime? due;
  final String status;
  final String priority;

  /// From the record's own status only — never from the model.
  final bool done;
  final String reason;
  final TextSource reasonSource;
  final String reasonCode;
  final Map<String, String> reasonParams;
  final bool samePlaceAsPrevious;
  final List<DayItem> items;

  /// Web technician path (`/technician/...`), mapped onto this app's routes.
  final String? route;
  final DayPermit? permit;
  final bool safety;
  final bool overdue;
  final bool inProgress;
  final bool permitBlocked;

  bool get isJob => kind != 'invite';

  DayStep copyWith({bool? done, List<DayItem>? items, DayPermit? permit}) => DayStep(
        order: order,
        kind: kind,
        id: id,
        ref: ref,
        title: title,
        location: location,
        due: due,
        status: status,
        priority: priority,
        done: done ?? this.done,
        reason: reason,
        reasonSource: reasonSource,
        reasonCode: reasonCode,
        reasonParams: reasonParams,
        samePlaceAsPrevious: samePlaceAsPrevious,
        items: items ?? this.items,
        route: route,
        permit: permit ?? this.permit,
        safety: safety,
        overdue: overdue,
        inProgress: inProgress,
        permitBlocked: permitBlocked || (permit?.blocking ?? false),
      );

  factory DayStep.fromJson(Map<String, dynamic> json) {
    final flags = json['flags'] is Map ? Map<String, dynamic>.from(json['flags'] as Map) : const <String, dynamic>{};
    final rawItems = json['beforeYouGoItems'];
    final items = rawItems is List
        ? rawItems.whereType<Map>().map((e) => DayItem.fromJson(Map<String, dynamic>.from(e))).toList()
        : (json['beforeYouGo'] is List
            ? (json['beforeYouGo'] as List).map((t) => DayItem(code: 'ai_tip', text: t.toString(), source: TextSource.rules)).toList()
            : const <DayItem>[]);
    return DayStep(
      order: asInt(json['order']) ?? 0,
      kind: json['kind']?.toString() ?? 'wo',
      id: json['id']?.toString() ?? '',
      ref: firstNonEmpty([json['ref']]),
      title: firstNonEmpty([json['title']]) ?? '',
      location: firstNonEmpty([json['location']]),
      due: asDate(json['due']),
      status: json['status']?.toString() ?? '',
      priority: json['priority']?.toString() ?? 'Medium',
      done: asBool(json['done']) ?? false,
      reason: json['reason']?.toString() ?? '',
      reasonSource: _source(json['reasonSource']),
      reasonCode: json['reasonCode']?.toString() ?? 'due_today',
      reasonParams: _params(json['reasonParams']),
      samePlaceAsPrevious: asBool(json['samePlaceAsPrevious']) ?? false,
      items: items,
      route: firstNonEmpty([json['route']]),
      permit: DayPermit.fromJson(json['permit']),
      safety: asBool(flags['safety']) ?? false,
      overdue: asBool(flags['overdue']) ?? false,
      inProgress: asBool(flags['inProgress']) ?? false,
      permitBlocked: asBool(flags['permitBlocked']) ?? false,
    );
  }
}

class DayCounts {
  const DayCounts({
    this.open = 0,
    this.overdue = 0,
    this.doneToday = 0,
    this.invites = 0,
    this.permitsNeeded = 0,
    this.reminders = 0,
  });

  final int open;
  final int overdue;
  final int doneToday;
  final int invites;
  final int permitsNeeded;
  final int reminders;

  factory DayCounts.fromJson(Object? raw) {
    final json = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return DayCounts(
      open: asInt(json['open']) ?? 0,
      overdue: asInt(json['overdue']) ?? 0,
      doneToday: asInt(json['doneToday']) ?? 0,
      invites: asInt(json['invites']) ?? 0,
      permitsNeeded: asInt(json['permitsNeeded']) ?? 0,
      reminders: asInt(json['reminders']) ?? 0,
    );
  }

  /// Counts for a list of steps the phone built or merged itself.
  factory DayCounts.of(List<DayStep> steps) {
    final open = steps.where((s) => !s.done && s.isJob).toList();
    return DayCounts(
      open: open.length,
      overdue: open.where((s) => s.overdue).length,
      doneToday: steps.where((s) => s.done).length,
      invites: steps.where((s) => !s.isJob).length,
      permitsNeeded: open.where((s) => s.permitBlocked).length,
    );
  }
}

class DayTip {
  const DayTip({required this.code, required this.stepId, this.permitId, this.params = const {}});

  final String code;
  final String stepId;
  final String? permitId;
  final Map<String, String> params;

  factory DayTip.fromJson(Map<String, dynamic> json) => DayTip(
        code: json['code']?.toString() ?? 'permit_first',
        stepId: json['stepId']?.toString() ?? '',
        permitId: firstNonEmpty([json['permitId']]),
        params: _params(json['params']),
      );
}

class DayBrief {
  const DayBrief({
    required this.summary,
    this.summarySource = TextSource.rules,
    required this.generatedAt,
    this.steps = const [],
    this.counts = const DayCounts(),
    this.tips = const [],
    this.aiAvailable = false,
  });

  final String summary;
  final TextSource summarySource;
  final DateTime generatedAt;
  final List<DayStep> steps;
  final DayCounts counts;
  final List<DayTip> tips;
  final bool aiAvailable;

  bool get aiSummary => aiAvailable && summarySource == TextSource.ai && summary.trim().isNotEmpty;

  factory DayBrief.fromJson(Map<String, dynamic> json) {
    final steps = json['steps'] is List
        ? (json['steps'] as List).whereType<Map>().map((e) => DayStep.fromJson(Map<String, dynamic>.from(e))).toList()
        : const <DayStep>[];
    final tips = json['tips'] is List
        ? (json['tips'] as List).whereType<Map>().map((e) => DayTip.fromJson(Map<String, dynamic>.from(e))).toList()
        : const <DayTip>[];
    return DayBrief(
      summary: json['summary']?.toString() ?? '',
      summarySource: _source(json['summarySource']),
      generatedAt: asDate(json['generatedAt']) ?? DateTime.now(),
      steps: steps,
      counts: DayCounts.fromJson(json['counts']),
      tips: tips,
      aiAvailable: asBool(json['aiAvailable']) ?? false,
    );
  }
}

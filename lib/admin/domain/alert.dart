/// Alert Center shapes — server `src/services/alerts/types.ts` (AlertItem,
/// AlertSummary) and `actions.ts` (AlertDetail). Only the fields the phone
/// shows; parsing is tolerant of missing ones.
library;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
String? _str(Object? v) => v == null ? null : '$v';

/// Severity order, worst first (server SEVERITY_RANK).
const alertSeverities = ['critical', 'high', 'medium', 'low'];
const alertStatuses = ['active', 'acknowledged', 'resolved'];

class AlertItem {
  const AlertItem({
    required this.key,
    required this.title,
    required this.severity,
    required this.status,
    this.detail = '',
    this.ref = '',
    this.sourceLabel = '',
    this.stage = '',
    this.raisedAt,
    this.lastAt,
    this.count = 1,
    this.buildingName,
    this.assetName,
    this.location,
    this.readingText,
    this.assigneeName,
    this.assigneeId,
    this.teamName,
    this.ackDueAt,
    this.workOrderRef,
    this.workOrderId,
    this.workOrderStatus,
    this.assetId,
    this.source = '',
    this.snoozedUntil,
    this.snoozeReason,
    this.simulated = false,
  });

  /// `sa:<id>` / `pd:` / `ac:` / `sl:` — the id every action and deep link uses.
  final String key;
  final String title;
  final String severity;
  final String status;
  final String detail;
  final String ref;
  final String sourceLabel;

  /// new | assigned | acknowledged | in_progress | snoozed | resolved
  final String stage;
  final DateTime? raisedAt;
  final DateTime? lastAt;
  final int count;
  final String? buildingName;
  final String? assetName;
  final String? location;

  /// "12.4 °C · above 9 °C", already formatted.
  final String? readingText;
  final String? assigneeName;
  final String? assigneeId;
  final String? teamName;
  final DateTime? ackDueAt;
  final String? workOrderRef;
  final String? workOrderId;
  final String? workOrderStatus;
  final String? assetId;

  /// sensor | predictive | access | sla
  final String source;
  final DateTime? snoozedUntil;
  final String? snoozeReason;
  final bool simulated;

  /// Snoozed and the snooze hasn't run out.
  bool get isSnoozed => snoozedUntil != null && snoozedUntil!.isAfter(DateTime.now());

  bool get isOpen => status != 'resolved';

  /// Not acknowledged and past the acknowledge deadline.
  bool get ackOverdue => status == 'active' && ackDueAt != null && ackDueAt!.isBefore(DateTime.now());

  /// Building · location · asset, each once — access alarms carry the same
  /// text in buildingName and location ("L2 Office West").
  String get where => {buildingName, location, assetName}.whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  factory AlertItem.fromJson(Map<String, dynamic> j) {
    final reading = j['reading'] is Map ? j['reading'] as Map : null;
    String? readingText;
    if (reading != null && reading['value'] != null) {
      final unit = reading['unit'] == null ? '' : ' ${reading['unit']}';
      final cond = reading['condition'] == null ? '' : ' · ${reading['condition']}';
      readingText = '${reading['value']}$unit$cond';
    }
    final assignee = j['assignee'] is Map ? j['assignee'] as Map : null;
    final team = j['team'] is Map ? j['team'] as Map : null;
    final wo = j['workOrder'] is Map ? j['workOrder'] as Map : null;
    return AlertItem(
      key: '${j['key']}',
      title: '${j['title'] ?? ''}',
      severity: '${j['severity'] ?? 'low'}',
      status: '${j['status'] ?? 'active'}',
      detail: '${j['detail'] ?? ''}',
      ref: '${j['ref'] ?? ''}',
      sourceLabel: '${j['sourceLabel'] ?? ''}',
      stage: '${j['stage'] ?? ''}',
      raisedAt: _date(j['raisedAt']),
      lastAt: _date(j['lastAt']),
      count: (j['count'] as num?)?.toInt() ?? 1,
      buildingName: _str(j['buildingName']),
      assetName: _str(j['assetName']),
      location: _str(j['location']),
      readingText: readingText,
      assigneeName: _str(assignee?['name']),
      assigneeId: _str(assignee?['id']),
      teamName: _str(team?['name']),
      ackDueAt: _date(j['ackDueAt']),
      workOrderRef: _str(wo?['ref']),
      workOrderId: _str(wo?['id']),
      workOrderStatus: _str(wo?['status']),
      assetId: _str(j['assetId']),
      source: '${j['source'] ?? ''}',
      snoozedUntil: _date(j['snoozedUntil']),
      snoozeReason: _str(j['snoozeReason']),
      simulated: j['simulated'] == true,
    );
  }
}

/// One building in the summary's facet: id (`none` = no building), name, count.
typedef BuildingCount = ({String id, String name, int count});

class AlertSummary {
  const AlertSummary({
    this.open = 0,
    this.critical = 0,
    this.unacknowledged = 0,
    this.mine = 0,
    this.overdueAck = 0,
    this.unavailable = const [],
    this.buildings = const [],
  });

  final int open;
  final int critical;
  final int unacknowledged;
  final int mine;
  final int overdueAck;

  /// Sources the server could not read this time (plain words).
  final List<String> unavailable;

  /// `facets.building`: every building with alerts under the other filters,
  /// most alerts first (server feed.ts). Drives the phone's building filter.
  final List<BuildingCount> buildings;

  factory AlertSummary.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    final facets = j['facets'] is Map ? j['facets'] as Map : const {};
    return AlertSummary(
      open: n('open'),
      critical: n('critical'),
      unacknowledged: n('unacknowledged'),
      mine: n('mine'),
      overdueAck: n('overdueAck'),
      unavailable: (j['unavailable'] as List? ?? const []).map((e) => '$e').toList(),
      buildings: [
        for (final b in (facets['building'] as List? ?? const []).whereType<Map>())
          if (b['value'] != null) (id: '${b['value']}', name: '${b['label'] ?? ''}', count: (b['count'] as num?)?.toInt() ?? 0),
      ],
    );
  }
}

/// One page of `GET /api/fm/alerts`.
class AlertPage {
  const AlertPage({required this.rows, required this.total, required this.summary});

  final List<AlertItem> rows;
  final int total;
  final AlertSummary summary;

  factory AlertPage.fromJson(Map<String, dynamic> j) => AlertPage(
        rows: (j['rows'] as List? ?? const []).whereType<Map<String, dynamic>>().map(AlertItem.fromJson).toList(),
        total: (j['total'] as num?)?.toInt() ?? 0,
        summary: AlertSummary.fromJson(j['summary'] as Map<String, dynamic>? ?? const {}),
      );
}

class AlertEvent {
  const AlertEvent({required this.action, this.note, this.userName, this.at});

  /// raised | acknowledged | resolved | reopened | note | assigned | escalated | …
  final String action;
  final String? note;
  final String? userName;
  final DateTime? at;

  factory AlertEvent.fromJson(Map<String, dynamic> j) => AlertEvent(
        action: '${j['action'] ?? ''}',
        note: _str(j['note']),
        userName: _str(j['userName']),
        at: _date(j['at']),
      );
}

/// `GET /api/fm/alerts/:key`.
class AlertDetail {
  const AlertDetail({
    required this.alert,
    this.events = const [],
    this.canTake = false,
    this.canAssign = false,
    this.canSnooze = false,
    this.snoozeChoices = defaultSnoozeChoices,
  });

  final AlertItem alert;
  final List<AlertEvent> events;

  /// The server's own "may take this" (open, not already mine).
  final bool canTake;

  /// May hand it to someone else (admins and the covering team).
  final bool canAssign;
  final bool canSnooze;

  /// Snooze lengths in minutes the server accepts (routing.ts SNOOZE_CHOICES).
  final List<int> snoozeChoices;

  AlertDetail withAlert(AlertItem a) => AlertDetail(
        alert: a,
        events: events,
        canTake: canTake,
        canAssign: canAssign,
        canSnooze: canSnooze,
        snoozeChoices: snoozeChoices,
      );

  factory AlertDetail.fromJson(Map<String, dynamic> j) {
    final can = j['can'] is Map ? j['can'] as Map : const {};
    return AlertDetail(
      alert: AlertItem.fromJson(j['alert'] as Map<String, dynamic>),
      events: (j['events'] as List? ?? const []).whereType<Map<String, dynamic>>().map(AlertEvent.fromJson).toList(),
      canTake: can['take'] == true,
      canAssign: can['assign'] == true,
      canSnooze: can['snooze'] == true,
      snoozeChoices: [
        for (final m in (j['snoozeChoices'] as List? ?? defaultSnoozeChoices))
          if (m is num) m.toInt(),
      ],
    );
  }
}

const defaultSnoozeChoices = [15, 30, 60, 120, 240, 480, 1440];

/// Someone the alert may be handed to (`GET /:key/assignees`).
typedef Assignee = ({String id, String name, String role, List<String> teams});

Assignee assigneeFromJson(Map<String, dynamic> j) => (
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      role: '${j['role'] ?? ''}',
      teams: [for (final t in j['teams'] as List? ?? const []) '$t'],
    );

/// The web's "Create work order" link for this alert (client lib/apis/alerts.ts
/// workOrderHref): the new work order form, filled in; saving it links back.
String workOrderCreatePath(AlertItem a) {
  const priority = {'critical': 'Critical', 'high': 'High', 'medium': 'Medium', 'low': 'Low'};
  final lines = [
    a.detail,
    if (a.readingText != null) 'Reading: ${a.readingText}',
    if (a.buildingName != null) 'Building: ${a.buildingName}',
    'Alert ${a.ref} · ${a.sourceLabel}',
  ].where((l) => l.isNotEmpty).join('\n');
  final q = {
    'title': a.title.length > 200 ? a.title.substring(0, 200) : a.title,
    'description': lines.length > 4000 ? lines.substring(0, 4000) : lines,
    'priority': priority[a.severity] ?? 'Medium',
    'alert': a.key,
    if (a.assetId != null && a.source != 'access') 'assetId': a.assetId!,
  };
  return Uri(path: '/facility-management/work-order/create', queryParameters: q).toString();
}

/// The filters the phone offers (a subset of the web's).
class AlertFilters {
  const AlertFilters({
    this.severity = const {},
    this.status = const {'active', 'acknowledged'},
    this.mineOnly = false,
    this.buildings = const {},
  });

  final Set<String> severity;

  /// Building ids (`none` = alerts with no building); empty = every building.
  final Set<String> buildings;

  /// Default: open alerts only.
  final Set<String> status;
  final bool mineOnly;

  AlertFilters copyWith({Set<String>? severity, Set<String>? status, bool? mineOnly, Set<String>? buildings}) => AlertFilters(
        severity: severity ?? this.severity,
        status: status ?? this.status,
        mineOnly: mineOnly ?? this.mineOnly,
        buildings: buildings ?? this.buildings,
      );

  /// Query for `GET /api/fm/alerts` — lists are comma-joined, as the web sends them.
  Map<String, dynamic> toQuery({int size = 50, int page = 1}) => {
        if (severity.isNotEmpty) 'severity': severity.join(','),
        if (status.isNotEmpty) 'status': status.join(','),
        if (mineOnly) 'assignee': 'me',
        if (buildings.isNotEmpty) 'building': buildings.join(','),
        // Worst first; ties: open before closed, newest first (server feed.ts).
        'sort': '-severity',
        'size': '$size',
        if (page > 1) 'page': '$page',
      };

  @override
  bool operator ==(Object other) =>
      other is AlertFilters &&
      other.mineOnly == mineOnly &&
      other.severity.length == severity.length &&
      other.severity.containsAll(severity) &&
      other.status.length == status.length &&
      other.status.containsAll(status) &&
      other.buildings.length == buildings.length &&
      other.buildings.containsAll(buildings);

  @override
  int get hashCode =>
      Object.hash(mineOnly, Object.hashAllUnordered(severity), Object.hashAllUnordered(status), Object.hashAllUnordered(buildings));
}

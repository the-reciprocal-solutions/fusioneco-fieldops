import '../core/network/envelope.dart';

/// Snag Assistant domain (docs/snag-assistant.md). A snag is an *observed
/// defect* that closes only when a second person verifies the fix — a peer of
/// a work order, never part of one. The wire vocabulary below mirrors the
/// server's `services/snag/snagRules.ts`; change both together.

enum SnagStatus {
  open('open'),
  inProgress('in-progress'),
  ready('ready'),
  closed('closed'),
  waived('waived');

  const SnagStatus(this.wire);
  final String wire;

  static SnagStatus parse(dynamic v) {
    final s = v?.toString();
    for (final value in values) {
      if (value.wire == s) return value;
    }
    return SnagStatus.open;
  }

  /// Still needs someone to do something: fix it, or verify the fix.
  bool get isLive =>
      this == SnagStatus.open || this == SnagStatus.inProgress || this == SnagStatus.ready;
}

/// Ordered most to least severe, so `index` doubles as a sort key.
enum SnagPriority {
  critical('critical'),
  major('major'),
  minor('minor'),
  cosmetic('cosmetic');

  const SnagPriority(this.wire);
  final String wire;

  static SnagPriority parse(dynamic v, {SnagPriority fallback = SnagPriority.minor}) {
    final s = v?.toString();
    for (final value in values) {
      if (value.wire == s) return value;
    }
    return fallback;
  }

  static SnagPriority? tryParse(dynamic v) {
    final s = v?.toString();
    for (final value in values) {
      if (value.wire == s) return value;
    }
    return null;
  }
}

enum SnagContext {
  construction('construction'),
  fmTakeover('fm-takeover'),
  dlp('dlp'),
  operations('operations'),
  fitout('fitout');

  const SnagContext(this.wire);
  final String wire;

  static SnagContext parse(dynamic v, {SnagContext fallback = SnagContext.operations}) {
    final s = v?.toString();
    for (final value in values) {
      if (value.wire == s) return value;
    }
    return fallback;
  }
}

enum SnagAction { start, ready, verify, reject, reopen, waive }

/// Trade slugs, in the order the walk-mode chip rail shows them by default.
/// `low-current` is ELV: data, CCTV, access control, BMS field wiring.
const kSnagTrades = <String>[
  'finishes',
  'electrical',
  'plumbing',
  'hvac',
  'doors-windows',
  'joinery',
  'civil',
  'fire',
  'low-current',
  'facade-roof',
  'lifts',
  'external',
  'cleaning',
  'other',
];

const kSnagIssueTypes = <String>[
  'defect',
  'incomplete',
  'damage',
  'missing',
  'safety',
  'non-compliance',
  'cleaning',
  'observation',
];

class SnagPin {
  const SnagPin({required this.floorId, required this.x, required this.y});

  final String floorId;

  /// 0..1 fractions of the floor plan image's width/height.
  final double x;
  final double y;

  static SnagPin? fromJson(dynamic json) {
    if (json is! Map) return null;
    final floorId = json['floorId']?.toString();
    final x = asDouble(json['x']);
    final y = asDouble(json['y']);
    if (floorId == null || floorId.isEmpty || x == null || y == null) return null;
    return SnagPin(floorId: floorId, x: x, y: y);
  }

  Map<String, dynamic> toJson() => {'kind': 'plan', 'floorId': floorId, 'x': x, 'y': y};
}

/// A highlighted defect area on one photo (2026-10-06): a box in NORMALISED
/// photo coordinates — 0..1 of the photo's width and height, origin at the
/// photo's top-left — so it draws the same on a thumbnail and full screen.
/// Photo space is never mirrored, so Arabic (RTL) draws the same box.
///
/// AI assist proposes them (`regions` in `POST /api/snags/ai/assist`); the
/// ones the technician keeps travel on the photo's evidence item. Grounded
/// exactly like the server's `snagRules.ts` `normaliseRegions` (change both):
/// numbers only, clamped to the photo, slivers (< 2 %) and whole-photo boxes
/// dropped, label limited to [kSnagIssueTypes], near-duplicates dropped, at
/// most [maxCount]. Anything unusable is dropped, never guessed (fail closed).
class SnagRegion {
  const SnagRegion({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.label,
    this.severity,
  });

  final double x;
  final double y;
  final double w;
  final double h;

  /// One of [kSnagIssueTypes].
  final String label;
  final SnagPriority? severity;

  static const maxCount = 5;
  static const minSide = 0.02;

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _round4(double v) => (v * 10000).roundToDouble() / 10000;

  /// One grounded region, or null when [json] is not a usable box.
  static SnagRegion? tryParse(dynamic json, {SnagPriority? fallbackSeverity}) {
    if (json is! Map) return null;
    final raw = [json['x'], json['y'], json['w'], json['h']];
    if (raw.any((v) => v is! num || !v.isFinite)) return null;
    final [x, y, w, h] = [for (final v in raw) (v as num).toDouble()];
    final x1 = _clamp01(x < x + w ? x : x + w);
    final y1 = _clamp01(y < y + h ? y : y + h);
    final x2 = _clamp01(x < x + w ? x + w : x);
    final y2 = _clamp01(y < y + h ? y + h : y);
    final bw = _round4(x2 - x1);
    final bh = _round4(y2 - y1);
    if (bw < minSide || bh < minSide) return null;
    if (bw >= 0.98 && bh >= 0.98) return null;
    final label = json['label']?.toString().trim().toLowerCase();
    if (label == null || !kSnagIssueTypes.contains(label)) return null;
    final sev = json['severity']?.toString().trim().toLowerCase();
    return SnagRegion(
      x: _round4(x1),
      y: _round4(y1),
      w: bw,
      h: bh,
      label: label,
      severity: SnagPriority.tryParse(sev) ?? fallbackSeverity,
    );
  }

  /// A grounded list: unusable entries and near-duplicates dropped, capped.
  static List<SnagRegion> listFrom(dynamic json, {SnagPriority? fallbackSeverity}) {
    if (json is! List) return const [];
    final out = <SnagRegion>[];
    for (final item in json) {
      if (out.length >= maxCount) break;
      final r = tryParse(item, fallbackSeverity: fallbackSeverity);
      if (r == null || out.any((k) => k.iou(r) > 0.85)) continue;
      out.add(r);
    }
    return out;
  }

  /// Intersection over union with [o], 0..1.
  double iou(SnagRegion o) {
    final ix = (_min(x + w, o.x + o.w) - _max(x, o.x)).clamp(0.0, 1.0).toDouble();
    final iy = (_min(y + h, o.y + o.h) - _max(y, o.y)).clamp(0.0, 1.0).toDouble();
    final inter = ix * iy;
    final union = w * h + o.w * o.h - inter;
    return union > 0 ? inter / union : 0.0;
  }

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'label': label,
    if (severity != null) 'severity': severity!.wire,
  };

  @override
  bool operator ==(Object other) =>
      other is SnagRegion &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h &&
      other.label == label &&
      other.severity == severity;

  @override
  int get hashCode => Object.hash(x, y, w, h, label, severity);
}

/// One photo or voice note on a snag. [localPath] is this device's copy
/// (`snag_media/`), kept after sync so the inspector can still see their own
/// photos offline; [url] is the uploaded copy and is null until then.
class SnagEvidence {
  const SnagEvidence({
    required this.id,
    required this.kind,
    required this.stage,
    required this.capturedAt,
    this.url,
    this.localPath,
    this.capturedBy,
    this.capturedByName,
    this.note,
    this.lat,
    this.lng,
    this.regions = const [],
  });

  final String id;

  /// `photo` | `audio`.
  final String kind;

  /// `before` (the defect) | `after` (the fix) | `extra`.
  final String stage;
  final DateTime capturedAt;
  final String? url;
  final String? localPath;
  final String? capturedBy;
  final String? capturedByName;
  final String? note;
  final double? lat;
  final double? lng;

  /// Highlighted defect areas the technician kept on this photo (photos only).
  final List<SnagRegion> regions;

  bool get isPhoto => kind == 'photo';
  bool get isAfter => stage == 'after';

  factory SnagEvidence.fromJson(Map<String, dynamic> json) {
    final geo = json['geo'];
    final kind = json['kind']?.toString() == 'audio' ? 'audio' : 'photo';
    return SnagEvidence(
      id: json['id']?.toString() ?? '',
      kind: kind,
      stage: switch (json['stage']?.toString()) {
        'after' => 'after',
        'extra' => 'extra',
        _ => 'before',
      },
      capturedAt: asDate(json['capturedAt']) ?? DateTime.now(),
      url: _httpUrl(json['url']),
      localPath: json['localPath']?.toString(),
      capturedBy: json['capturedBy']?.toString(),
      capturedByName: json['capturedByName']?.toString(),
      note: json['note']?.toString(),
      lat: geo is Map ? asDouble(geo['lat']) : null,
      lng: geo is Map ? asDouble(geo['lng']) : null,
      regions: kind == 'photo' ? SnagRegion.listFrom(json['regions']) : const [],
    );
  }

  /// Local storage shape: everything, including [localPath].
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'stage': stage,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'url': ?url,
    'localPath': ?localPath,
    'capturedBy': ?capturedBy,
    'capturedByName': ?capturedByName,
    'note': ?note,
    if (lat != null && lng != null) 'geo': {'lat': lat, 'lng': lng},
    if (regions.isNotEmpty) 'regions': [for (final r in regions) r.toJson()],
  };

  SnagEvidence withLocalPath(String? path) => SnagEvidence(
    id: id,
    kind: kind,
    stage: stage,
    capturedAt: capturedAt,
    url: url,
    localPath: path,
    capturedBy: capturedBy,
    capturedByName: capturedByName,
    note: note,
    lat: lat,
    lng: lng,
    regions: regions,
  );
}

/// One entry in a snag's append-only audit trail.
class SnagActivity {
  const SnagActivity({
    required this.id,
    required this.at,
    required this.type,
    this.by,
    this.byName,
    this.note,
    this.reason,
  });

  final String id;
  final DateTime at;

  /// raised | started | ready | verified | rejected | reopened | waived |
  /// evidence | duplicate-report | comment | edited
  final String type;
  final String? by;
  final String? byName;
  final String? note;
  final String? reason;

  factory SnagActivity.fromJson(Map<String, dynamic> json) => SnagActivity(
    id: json['id']?.toString() ?? '',
    at: asDate(json['at']) ?? DateTime.now(),
    type: json['type']?.toString() ?? 'comment',
    by: json['by']?.toString(),
    byName: json['byName']?.toString(),
    note: json['note']?.toString(),
    reason: json['reason']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'type': type,
    'by': ?by,
    'byName': ?byName,
    'note': ?note,
    'reason': ?reason,
  };
}

/// Why this device's last attempt to send a snag write did not go through
/// (2026-10-06). Local only — never sent, cleared as soon as the server's
/// copy is saved. The screens turn it into plain words
/// (`core/snag/snag_send_state.dart`); the raw server message is never shown.
class SnagSendIssue {
  const SnagSendIssue({required this.status, required this.at, this.code, this.dropped = false});

  /// HTTP status of the failed replay; 0 = no HTTP answer.
  final int status;
  final String? code;

  /// true = the queue gave up on it (a 4xx): nothing will retry until the
  /// technician taps Retry. false = still queued and retrying on its own.
  final bool dropped;
  final DateTime at;

  static SnagSendIssue? fromJson(dynamic v) {
    if (v is! Map) return null;
    return SnagSendIssue(
      status: asInt(v['status']) ?? 0,
      code: firstNonEmpty([v['code']]),
      dropped: asBool(v['dropped']) ?? false,
      at: asDate(v['at']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'status': status,
    'code': ?code,
    'dropped': dropped,
    'at': at.toUtc().toIso8601String(),
  };
}

class Snag {
  const Snag({
    required this.id,
    required this.context,
    required this.issueType,
    required this.trade,
    required this.priority,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.number,
    this.reference,
    this.description,
    this.buildingId,
    this.floorId,
    this.spaceId,
    this.locationLabel,
    this.locationText,
    this.pin,
    this.assetId,
    this.assetName,
    this.assetReferenceId,
    this.surveyId,
    this.workOrderId,
    this.responsibleParty,
    this.assigneeName,
    this.assignedToUserId,
    this.dueDate,
    this.evidence = const [],
    this.activity = const [],
    this.reopenedCount = 0,
    this.reportCount = 1,
    this.raisedBy,
    this.raisedByName,
    this.readyBy,
    this.readyAt,
    this.verifiedBy,
    this.verifiedAt,
    this.closedAt,
    this.localOnly = false,
    this.sendIssue,
  });

  final String id;
  final int? number;
  final String? reference;
  final SnagContext context;
  final String issueType;
  final String trade;
  final SnagPriority priority;
  final String title;
  final String? description;
  final SnagStatus status;
  final String? buildingId;
  final String? floorId;
  final String? spaceId;
  final String? locationLabel;
  final String? locationText;
  final SnagPin? pin;
  final String? assetId;
  final String? assetName;
  final String? assetReferenceId;
  final String? surveyId;
  final String? workOrderId;
  final String? responsibleParty;
  final String? assigneeName;
  final String? assignedToUserId;
  final DateTime? dueDate;
  final List<SnagEvidence> evidence;
  final List<SnagActivity> activity;
  final int reopenedCount;
  final int reportCount;
  final String? raisedBy;
  final String? raisedByName;
  final String? readyBy;
  final DateTime? readyAt;
  final String? verifiedBy;
  final DateTime? verifiedAt;
  final DateTime? closedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// True until the server has confirmed this snag exists (a fetch returned
  /// it, or the create answered 2xx). Never sent to the server.
  final bool localOnly;

  /// Set when the last send of a write for this snag failed; see
  /// [SnagSendIssue]. Never sent to the server.
  final SnagSendIssue? sendIssue;

  /// "SN-00042" once the server has numbered it; until then the first six
  /// characters of the client id, so two unsynced snags never read the same.
  String get displayRef => reference ?? '#${id.length > 6 ? id.substring(0, 6) : id}';

  List<SnagEvidence> get photos => evidence.where((e) => e.isPhoto).toList();
  List<SnagEvidence> get beforePhotos =>
      evidence.where((e) => e.isPhoto && e.stage != 'after').toList();
  List<SnagEvidence> get afterPhotos =>
      evidence.where((e) => e.isPhoto && e.stage == 'after').toList();
  SnagEvidence? get coverPhoto {
    final before = beforePhotos;
    if (before.isNotEmpty) return before.first;
    final all = photos;
    return all.isEmpty ? null : all.first;
  }

  bool isOverdue(DateTime now) =>
      dueDate != null &&
      (status == SnagStatus.open || status == SnagStatus.inProgress) &&
      dueDate!.isBefore(now);

  factory Snag.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    List<Map<String, dynamic>> maps(dynamic v) => v is List
        ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const [];
    return Snag(
      id: json['id']?.toString() ?? '',
      number: asInt(json['number']),
      reference: firstNonEmpty([json['reference']]),
      context: SnagContext.parse(json['context']),
      issueType: firstNonEmpty([json['issueType']]) ?? 'defect',
      trade: firstNonEmpty([json['trade']]) ?? 'other',
      priority: SnagPriority.parse(json['priority']),
      title: firstNonEmpty([json['title']]) ?? 'Snag',
      description: firstNonEmpty([json['description']]),
      status: SnagStatus.parse(json['status']),
      buildingId: firstNonEmpty([json['buildingId']]),
      floorId: firstNonEmpty([json['floorId']]),
      spaceId: firstNonEmpty([json['spaceId']]),
      locationLabel: firstNonEmpty([json['locationLabel']]),
      locationText: firstNonEmpty([json['locationText']]),
      pin: SnagPin.fromJson(json['pin']),
      assetId: firstNonEmpty([json['assetId']]),
      assetName: firstNonEmpty([json['assetName']]),
      assetReferenceId: firstNonEmpty([json['assetReferenceId']]),
      surveyId: firstNonEmpty([json['surveyId']]),
      workOrderId: firstNonEmpty([json['workOrderId']]),
      responsibleParty: firstNonEmpty([json['responsibleParty']]),
      assigneeName: firstNonEmpty([json['assigneeName']]),
      assignedToUserId: firstNonEmpty([json['assignedToUserId']]),
      dueDate: asDate(json['dueDate']),
      evidence: maps(json['evidence']).map(SnagEvidence.fromJson).toList(),
      activity: maps(json['activity']).map(SnagActivity.fromJson).toList(),
      reopenedCount: asInt(json['reopenedCount']) ?? 0,
      reportCount: asInt(json['reportCount']) ?? 1,
      raisedBy: firstNonEmpty([json['raisedBy']]),
      raisedByName: firstNonEmpty([json['raisedByName']]),
      readyBy: firstNonEmpty([json['readyBy']]),
      readyAt: asDate(json['readyAt']),
      verifiedBy: firstNonEmpty([json['verifiedBy']]),
      verifiedAt: asDate(json['verifiedAt']),
      closedAt: asDate(json['closedAt']),
      createdAt: asDate(json['clientCreatedAt']) ?? asDate(json['createdAt']) ?? now,
      updatedAt: asDate(json['updatedAt']) ?? now,
      localOnly: asBool(json['localOnly']) ?? false,
      sendIssue: SnagSendIssue.fromJson(json['sendIssue']),
    );
  }

  /// Local storage shape (the `snags.json` column).
  Map<String, dynamic> toJson() => {
    'id': id,
    'number': ?number,
    'reference': ?reference,
    'context': context.wire,
    'issueType': issueType,
    'trade': trade,
    'priority': priority.wire,
    'title': title,
    'description': ?description,
    'status': status.wire,
    'buildingId': ?buildingId,
    'floorId': ?floorId,
    'spaceId': ?spaceId,
    'locationLabel': ?locationLabel,
    'locationText': ?locationText,
    'pin': ?pin?.toJson(),
    'assetId': ?assetId,
    'assetName': ?assetName,
    'assetReferenceId': ?assetReferenceId,
    'surveyId': ?surveyId,
    'workOrderId': ?workOrderId,
    'responsibleParty': ?responsibleParty,
    'assigneeName': ?assigneeName,
    'assignedToUserId': ?assignedToUserId,
    'dueDate': ?dueDate?.toUtc().toIso8601String(),
    'evidence': evidence.map((e) => e.toJson()).toList(),
    'activity': activity.map((a) => a.toJson()).toList(),
    'reopenedCount': reopenedCount,
    'reportCount': reportCount,
    'raisedBy': ?raisedBy,
    'raisedByName': ?raisedByName,
    'readyBy': ?readyBy,
    'readyAt': ?readyAt?.toUtc().toIso8601String(),
    'verifiedBy': ?verifiedBy,
    'verifiedAt': ?verifiedAt?.toUtc().toIso8601String(),
    'closedAt': ?closedAt?.toUtc().toIso8601String(),
    'clientCreatedAt': createdAt.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'localOnly': localOnly,
    'sendIssue': ?sendIssue?.toJson(),
  };

  Snag copyWith({
    SnagStatus? status,
    String? title,
    String? description,
    String? trade,
    String? issueType,
    SnagPriority? priority,
    List<SnagEvidence>? evidence,
    List<SnagActivity>? activity,
    int? reopenedCount,
    int? reportCount,
    String? readyBy,
    DateTime? readyAt,
    String? verifiedBy,
    DateTime? verifiedAt,
    DateTime? closedAt,
    DateTime? updatedAt,
    SnagPin? pin,
    bool? localOnly,
    SnagSendIssue? sendIssue,
    bool clearSendIssue = false,
    bool clearReady = false,
    bool clearVerified = false,
  }) => Snag(
    id: id,
    number: number,
    reference: reference,
    context: context,
    issueType: issueType ?? this.issueType,
    trade: trade ?? this.trade,
    priority: priority ?? this.priority,
    title: title ?? this.title,
    description: description ?? this.description,
    status: status ?? this.status,
    buildingId: buildingId,
    floorId: floorId,
    spaceId: spaceId,
    locationLabel: locationLabel,
    locationText: locationText,
    pin: pin ?? this.pin,
    assetId: assetId,
    assetName: assetName,
    assetReferenceId: assetReferenceId,
    surveyId: surveyId,
    workOrderId: workOrderId,
    responsibleParty: responsibleParty,
    assigneeName: assigneeName,
    assignedToUserId: assignedToUserId,
    dueDate: dueDate,
    evidence: evidence ?? this.evidence,
    activity: activity ?? this.activity,
    reopenedCount: reopenedCount ?? this.reopenedCount,
    reportCount: reportCount ?? this.reportCount,
    raisedBy: raisedBy,
    raisedByName: raisedByName,
    readyBy: clearReady ? null : (readyBy ?? this.readyBy),
    readyAt: clearReady ? null : (readyAt ?? this.readyAt),
    verifiedBy: clearVerified ? null : (verifiedBy ?? this.verifiedBy),
    verifiedAt: clearVerified ? null : (verifiedAt ?? this.verifiedAt),
    closedAt: clearVerified ? null : (closedAt ?? this.closedAt),
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    localOnly: localOnly ?? this.localOnly,
    sendIssue: clearSendIssue ? null : (sendIssue ?? this.sendIssue),
  );
}

/// A room swept during a survey — the evidence that a room with no snags was
/// actually inspected (coverage), not merely skipped.
class SpaceSweep {
  const SpaceSweep({
    required this.spaceId,
    required this.clear,
    required this.snagCount,
    required this.at,
    this.spaceName,
    this.floorId,
    this.by,
    this.byName,
  });

  final String spaceId;
  final String? spaceName;
  final String? floorId;
  final bool clear;
  final int snagCount;
  final DateTime at;
  final String? by;
  final String? byName;

  factory SpaceSweep.fromJson(Map<String, dynamic> json) => SpaceSweep(
    spaceId: json['spaceId']?.toString() ?? '',
    spaceName: json['spaceName']?.toString(),
    floorId: json['floorId']?.toString(),
    clear: asBool(json['clear']) ?? false,
    snagCount: asInt(json['snagCount']) ?? 0,
    at: asDate(json['at']) ?? DateTime.now(),
    by: json['by']?.toString(),
    byName: json['byName']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'spaceId': spaceId,
    'spaceName': ?spaceName,
    'floorId': ?floorId,
    'clear': clear,
    'snagCount': snagCount,
    'at': at.toUtc().toIso8601String(),
    'by': ?by,
    'byName': ?byName,
  };
}

class SnagSurvey {
  const SnagSurvey({
    required this.id,
    required this.name,
    required this.context,
    required this.startedAt,
    this.buildingId,
    this.buildingName,
    this.completed = false,
    this.inspectedSpaces = const [],
    this.startedBy,
    this.startedByName,
    this.completedAt,
    this.localOnly = false,
  });

  final String id;
  final String name;
  final SnagContext context;
  final String? buildingId;
  final String? buildingName;
  final bool completed;
  final List<SpaceSweep> inspectedSpaces;
  final String? startedBy;
  final String? startedByName;
  final DateTime startedAt;
  final DateTime? completedAt;
  final bool localOnly;

  SpaceSweep? sweepFor(String spaceId) {
    for (final s in inspectedSpaces) {
      if (s.spaceId == spaceId) return s;
    }
    return null;
  }

  factory SnagSurvey.fromJson(Map<String, dynamic> json) => SnagSurvey(
    id: json['id']?.toString() ?? '',
    name: firstNonEmpty([json['name']]) ?? 'Survey',
    context: SnagContext.parse(json['context'], fallback: SnagContext.fmTakeover),
    buildingId: firstNonEmpty([json['buildingId']]),
    buildingName: firstNonEmpty([json['buildingName']]),
    completed: json['status']?.toString() == 'completed',
    inspectedSpaces: json['inspectedSpaces'] is List
        ? (json['inspectedSpaces'] as List)
              .whereType<Map>()
              .map((e) => SpaceSweep.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const [],
    startedBy: firstNonEmpty([json['startedBy']]),
    startedByName: firstNonEmpty([json['startedByName']]),
    startedAt: asDate(json['startedAt']) ?? DateTime.now(),
    completedAt: asDate(json['completedAt']),
    localOnly: asBool(json['localOnly']) ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'context': context.wire,
    'buildingId': ?buildingId,
    'buildingName': ?buildingName,
    'status': completed ? 'completed' : 'active',
    'inspectedSpaces': inspectedSpaces.map((s) => s.toJson()).toList(),
    'startedBy': ?startedBy,
    'startedByName': ?startedByName,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'completedAt': ?completedAt?.toUtc().toIso8601String(),
    'localOnly': localOnly,
  };

  SnagSurvey copyWith({
    List<SpaceSweep>? inspectedSpaces,
    bool? completed,
    DateTime? completedAt,
    bool? localOnly,
  }) => SnagSurvey(
    id: id,
    name: name,
    context: context,
    buildingId: buildingId,
    buildingName: buildingName,
    completed: completed ?? this.completed,
    inspectedSpaces: inspectedSpaces ?? this.inspectedSpaces,
    startedBy: startedBy,
    startedByName: startedByName,
    startedAt: startedAt,
    completedAt: completedAt ?? this.completedAt,
    localOnly: localOnly ?? this.localOnly,
  );
}

class SnagBuilding {
  const SnagBuilding({required this.id, required this.name, this.location});
  final String id;
  final String name;
  final String? location;

  factory SnagBuilding.fromJson(Map<String, dynamic> json) => SnagBuilding(
    id: json['id']?.toString() ?? '',
    name: firstNonEmpty([json['name']]) ?? 'Building',
    location: firstNonEmpty([json['location']]),
  );
}

class SnagSpace {
  const SnagSpace({required this.id, required this.name, this.ref, this.zone});
  final String id;
  final String name;
  final String? ref;
  final String? zone;

  factory SnagSpace.fromJson(Map<String, dynamic> json) => SnagSpace(
    id: json['id']?.toString() ?? '',
    name: firstNonEmpty([json['name'], json['ref']]) ?? 'Room',
    ref: firstNonEmpty([json['ref']]),
    zone: firstNonEmpty([json['zone']]),
  );
}

class SnagFloor {
  const SnagFloor({
    required this.id,
    required this.name,
    this.number,
    this.hasPlan = false,
    this.spaces = const [],
  });

  final String id;
  final String name;
  final String? number;
  final bool hasPlan;
  final List<SnagSpace> spaces;

  factory SnagFloor.fromJson(Map<String, dynamic> json) => SnagFloor(
    id: json['id']?.toString() ?? '',
    name: firstNonEmpty([json['name'], json['number']]) ?? 'Floor',
    number: firstNonEmpty([json['number']]),
    hasPlan: asBool(json['hasPlan']) ?? false,
    spaces: json['spaces'] is List
        ? (json['spaces'] as List)
              .whereType<Map>()
              .map((e) => SnagSpace.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const [],
  );
}

/// A building's floors › rooms, cached for walk mode.
class SnagLocationTree {
  const SnagLocationTree({required this.id, required this.name, this.floors = const []});
  final String id;
  final String name;
  final List<SnagFloor> floors;

  int get spaceCount => floors.fold(0, (sum, f) => sum + f.spaces.length);

  SnagFloor? floor(String? id) {
    if (id == null) return null;
    for (final f in floors) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// The floor holding [spaceId], and the room itself.
  (SnagFloor, SnagSpace)? locate(String? spaceId) {
    if (spaceId == null) return null;
    for (final f in floors) {
      for (final s in f.spaces) {
        if (s.id == spaceId) return (f, s);
      }
    }
    return null;
  }

  factory SnagLocationTree.fromJson(Map<String, dynamic> json) => SnagLocationTree(
    id: json['id']?.toString() ?? '',
    name: firstNonEmpty([json['name']]) ?? 'Building',
    floors: json['floors'] is List
        ? (json['floors'] as List)
              .whereType<Map>()
              .map((e) => SnagFloor.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const [],
  );
}

/// What `POST /api/snags/assist` proposes. Every field is optional: a value
/// outside the vocabulary is dropped server-side, and the UI keeps whatever
/// the inspector already chose for anything missing.
class SnagSuggestion {
  const SnagSuggestion({
    this.title,
    this.description,
    this.issueType,
    this.trade,
    this.priority,
    this.confidence,
    this.transcript,
  });

  final String? title;
  final String? description;
  final String? issueType;
  final String? trade;
  final SnagPriority? priority;
  final double? confidence;
  final String? transcript;

  factory SnagSuggestion.fromJson(Map<String, dynamic> json) => SnagSuggestion(
    title: firstNonEmpty([json['title']]),
    description: firstNonEmpty([json['description']]),
    issueType: kSnagIssueTypes.contains(json['issueType']) ? json['issueType'] as String : null,
    trade: kSnagTrades.contains(json['trade']) ? json['trade'] as String : null,
    priority: SnagPriority.tryParse(json['priority']),
    confidence: asDouble(json['confidence']),
    transcript: firstNonEmpty([json['transcript']]),
  );
}

String? _httpUrl(dynamic v) {
  final s = v?.toString();
  if (s == null || !(s.startsWith('http://') || s.startsWith('https://'))) return null;
  return s;
}

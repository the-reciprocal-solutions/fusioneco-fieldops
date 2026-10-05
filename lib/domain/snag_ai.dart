import '../core/network/envelope.dart';
import 'snag.dart';

/// The "after the snap" AI assist answer (`POST /api/snags/ai/assist`,
/// server documentation/snag-assistant.md "AI assist"). Proposals only:
/// nothing here is ever saved unless the technician applies it with a tap.
/// Parsing re-checks every value against this app's own vocabularies, so a
/// server (or model) that drifts can never put an unknown trade on a snag.
enum SnagAiStatus {
  /// The assistant answered.
  ok,

  /// No connection — the snag still saves; device photo tips still show.
  offline,

  /// Reachable, but nothing usable (engine busy, timed out, older server).
  unavailable,
}

/// The capture-tip codes the server may return (snagAiAssist.ts
/// CAPTURE_TIP_CODES). Unknown codes are dropped.
const kSnagCaptureTips = <String>[
  'too_dark',
  'blurry',
  'too_far',
  'too_close',
  'add_wide_shot',
  'add_close_up',
  'add_reference_object',
  'subject_unclear',
];

/// Missing-field codes (snagAiAssist.ts MISSING_FIELD_CODES).
const kSnagMissingFields = <String>['photo', 'location', 'trade', 'priority', 'title'];

class SnagAiDuplicate {
  const SnagAiDuplicate({
    required this.id,
    required this.status,
    required this.score,
    this.reference,
    this.title,
    this.trade,
    this.priority,
    this.locationLabel,
    this.coverUrl,
  });

  final String id;
  final String? reference;
  final String? title;
  final SnagStatus status;
  final String? trade;
  final SnagPriority? priority;
  final String? locationLabel;
  final String? coverUrl;
  final double score;

  String get displayRef => reference ?? '#${id.length > 6 ? id.substring(0, 6) : id}';

  static SnagAiDuplicate? fromJson(Map<String, dynamic> j) {
    final id = firstNonEmpty([j['id']]);
    if (id == null) return null;
    final url = firstNonEmpty([j['coverUrl']]);
    return SnagAiDuplicate(
      id: id,
      reference: firstNonEmpty([j['reference']]),
      title: firstNonEmpty([j['title']]),
      status: SnagStatus.parse(j['status']),
      trade: kSnagTrades.contains(j['trade']) ? j['trade'] as String : null,
      priority: SnagPriority.tryParse(j['priority']),
      locationLabel: firstNonEmpty([j['locationLabel']]),
      coverUrl: url != null && url.startsWith('http') ? url : null,
      score: asDouble(j['score']) ?? 0,
    );
  }
}

class SnagAiResult {
  const SnagAiResult({
    required this.status,
    this.title,
    this.description,
    this.issueType,
    this.trade,
    this.priority,
    this.likelyCause,
    this.recommendedFix,
    this.responsibleTrade,
    this.confidence,
    this.captureTips = const [],
    this.duplicates = const [],
    this.missing = const [],
  });

  const SnagAiResult.offline({List<String> captureTips = const []})
    : this(status: SnagAiStatus.offline, captureTips: captureTips);

  const SnagAiResult.unavailable({List<String> captureTips = const []})
    : this(status: SnagAiStatus.unavailable, captureTips: captureTips);

  final SnagAiStatus status;
  final String? title;
  final String? description;
  final String? issueType;
  final String? trade;
  final SnagPriority? priority;
  final String? likelyCause;
  final String? recommendedFix;
  final String? responsibleTrade;
  final double? confidence;

  /// Codes from [kSnagCaptureTips].
  final List<String> captureTips;
  final List<SnagAiDuplicate> duplicates;

  /// Codes from [kSnagMissingFields].
  final List<String> missing;

  bool get hasSuggestions =>
      title != null ||
      description != null ||
      issueType != null ||
      trade != null ||
      priority != null ||
      likelyCause != null ||
      recommendedFix != null ||
      responsibleTrade != null;

  /// [deviceTips]: tips the phone found itself (dark/blurry), merged in so
  /// they show even when the server's answer lacks them.
  factory SnagAiResult.fromJson(Map<String, dynamic> json, {List<String> deviceTips = const []}) {
    final s = json['suggestions'] is Map ? Map<String, dynamic>.from(json['suggestions'] as Map) : const <String, dynamic>{};
    List<Map<String, dynamic>> maps(dynamic v) =>
        v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final tips = <String>{
      ...deviceTips,
      for (final t in json['captureTips'] is List ? json['captureTips'] as List : const [])
        if (kSnagCaptureTips.contains(t is Map ? t['code'] : t)) (t is Map ? t['code'] : t) as String,
    };
    final available = asBool(json['available']) ?? false;
    final conf = asDouble(json['confidence']);
    return SnagAiResult(
      status: available ? SnagAiStatus.ok : SnagAiStatus.unavailable,
      title: _text(s['title'], 80),
      description: _text(s['description'], 600),
      issueType: kSnagIssueTypes.contains(s['issueType']) ? s['issueType'] as String : null,
      trade: kSnagTrades.contains(s['trade']) ? s['trade'] as String : null,
      priority: SnagPriority.tryParse(s['priority']),
      likelyCause: _text(s['likelyCause'], 300),
      recommendedFix: _text(s['recommendedFix'], 300),
      responsibleTrade: kSnagTrades.contains(s['responsibleTrade']) ? s['responsibleTrade'] as String : null,
      confidence: conf?.clamp(0, 1).toDouble(),
      captureTips: [for (final c in kSnagCaptureTips) if (tips.contains(c)) c],
      duplicates: [for (final d in maps(json['duplicates'])) ?SnagAiDuplicate.fromJson(d)],
      missing: [
        for (final m in json['missing'] is List ? json['missing'] as List : const [])
          if (kSnagMissingFields.contains(m)) m as String,
      ],
    );
  }

  static String? _text(dynamic v, int max) {
    final t = firstNonEmpty([v]);
    if (t == null) return null;
    return t.length > max ? t.substring(0, max) : t;
  }
}

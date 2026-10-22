/// What the phone captured at the moment of a tap on "Start my day" / "End my day":
/// the position, and how far each end is on its way to the server
/// (docs/daily-attendance-shift-plan.md).
library;

/// How good the position behind a start / end of day is. Matches the server's
/// `FixKind`.
enum FixKind {
  /// A fresh fix from the GPS / network provider.
  gps,

  /// Only the phone's last remembered position (stale; its age is kept).
  lastKnown,

  /// No position at all (GPS off, basement, permission refused).
  none;

  String get wire => switch (this) {
    FixKind.gps => 'gps',
    FixKind.lastKnown => 'last_known',
    FixKind.none => 'none',
  };

  static FixKind fromWire(String? v) => switch (v) {
    'gps' => FixKind.gps,
    'last_known' => FixKind.lastKnown,
    _ => FixKind.none,
  };
}

/// What the phone saw at the moment of a tap.
class CaptureFix {
  const CaptureFix({
    required this.kind,
    this.lat,
    this.lng,
    this.accuracyM,
    this.mock = false,
    this.ageSeconds,
  });

  const CaptureFix.none() : this(kind: FixKind.none);

  final FixKind kind;
  final double? lat;
  final double? lng;
  final double? accuracyM;

  /// Android reported the position as coming from a mock-location app.
  final bool mock;

  /// For [FixKind.lastKnown]: how old the remembered position was.
  final int? ageSeconds;

  bool get hasCoords => kind != FixKind.none && lat != null && lng != null;

  Map<String, dynamic> toJson() => {
    'kind': kind.wire,
    'lat': lat,
    'lng': lng,
    'accuracyM': accuracyM,
    'mock': mock,
    'ageSeconds': ageSeconds,
  };

  factory CaptureFix.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const CaptureFix.none();
    return CaptureFix(
      kind: FixKind.fromWire(j['kind'] as String?),
      lat: (j['lat'] as num?)?.toDouble(),
      lng: (j['lng'] as num?)?.toDouble(),
      accuracyM: (j['accuracyM'] as num?)?.toDouble(),
      mock: j['mock'] == true,
      ageSeconds: (j['ageSeconds'] as num?)?.toInt(),
    );
  }
}

/// Where one END of the day (the start, or the end) is on its way to the server.
enum SendState {
  /// Not queued (a check-out that has not happened yet).
  none,

  /// Saved on the phone and in the offline queue; will send by itself.
  queued,

  /// The server has it.
  synced,

  /// The server refused it for good; see [DayLocal.inIssue] / [outIssue].
  rejected;

  static SendState fromName(String? v) =>
      SendState.values.firstWhere((s) => s.name == v, orElse: () => SendState.none);
}

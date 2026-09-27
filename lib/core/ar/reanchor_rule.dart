import 'ar_engine.dart' show ArTracking;

/// Why the overlay should be re-checked against a corner or a board.
enum ReanchorReason {
  /// Tracking was lost for [ReanchorMonitor.lossHold] or longer and came back.
  trackingLost,

  /// The tracker reported `relocalizing` (its map jumped) and came back.
  relocalized,

  /// The user walked more than [ReanchorMonitor.walkLimitM] since the last
  /// reference: tracking drift grows with distance (`ArSigma.driftPerMetre`).
  walkedFar,
}

/// When to stop trusting a placed model and prompt "Re-check a corner or
/// board". Plain rooms give ARCore few features, so the map slides after a
/// tracking loss or a long walk even with every observation anchored; the
/// badge must say so instead of staying calmly amber or green.
///
/// Rules:
/// - a loss that lasts at least [lossHold] (limited, paused, stopped, not
///   available), or any `relocalizing` reason, fires **when tracking comes
///   back** — that's when a re-check can actually be done; a blip of
///   excessive motion under [lossHold] never does;
/// - walking more than [walkLimitM] since the last reference fires once.
///
/// It fires at most once per reference: [reset] after the next observation.
/// Pure; `test/ar_reanchor_rule_test.dart`.
class ReanchorMonitor {
  ReanchorMonitor({
    this.walkLimitM = 7,
    this.lossHold = const Duration(milliseconds: 1500),
  });

  final double walkLimitM;
  final Duration lossHold;

  DateTime? _lostSince;
  var _relocalizing = false;
  var _fired = false;

  /// True once it has fired since the last [reset].
  bool get fired => _fired;

  /// Feeds a tracking change. Returns a reason when the model should now be
  /// re-checked; null otherwise (and always null once fired).
  ReanchorReason? tracking(DateTime at, String state, String? reason) {
    if (state == ArTracking.tracking) {
      final since = _lostSince;
      final relocalized = _relocalizing;
      _lostSince = null;
      _relocalizing = false;
      if (since == null) return null;
      if (relocalized) return _fire(ReanchorReason.relocalized);
      if (at.difference(since) >= lossHold) return _fire(ReanchorReason.trackingLost);
      return null;
    }
    if (state == ArTracking.initializing) return null; // before the first lock, nothing to doubt
    _lostSince ??= at;
    if (reason == 'relocalizing') _relocalizing = true;
    return null;
  }

  /// Feeds the distance walked since the last reference.
  ReanchorReason? walked(double sinceReferenceM) =>
      sinceReferenceM > walkLimitM ? _fire(ReanchorReason.walkedFar) : null;

  ReanchorReason? _fire(ReanchorReason r) {
    if (_fired) return null;
    _fired = true;
    return r;
  }

  /// A new reference was observed (or alignment started over).
  void reset() {
    _fired = false;
    _lostSince = null;
    _relocalizing = false;
  }
}

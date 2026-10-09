import '../../domain/snag.dart';

/// One thing about a snag's photos this device cannot explain by itself.
/// Reported to the developer integrity log — never "fixed" by guessing.
class SnagIntegrityFinding {
  const SnagIntegrityFinding({required this.kind, required this.snagId, required this.evidenceIds, this.ref});

  /// `possible-misattached` | `after-photo-without-ready`
  /// (see `SnagIntegrityLog`).
  final String kind;
  final String snagId;
  final String? ref;
  final List<String> evidenceIds;

  /// Stable across scans, so a finding is logged once.
  String get key => '$kind:$snagId:${evidenceIds.join(",")}';
}

/// Pure scan for photos that may sit on the wrong snag (2026-10-10, owner
/// iPhone report: "I captured one photo in walk mode … it somehow got added
/// to an existing snag's after-photos").
///
/// Until 2026-10-10 a walk shot whose room and trade matched another live
/// snag opened the duplicate sheet, and its primary button ("Same issue —
/// add my photo") put the shot on *that* snag as a "+1" instead of raising a
/// new one — including on snags already marked ready, whose gallery is the
/// fix evidence. The server only says "this person added a +1 photo here";
/// whether it was meant is something only the person can tell, so this scan
/// reports, it does not move photos.
abstract final class SnagIntegrityScan {
  static const possibleMisattached = 'possible-misattached';
  static const afterPhotoWithoutReady = 'after-photo-without-ready';

  static List<SnagIntegrityFinding> find(Iterable<Snag> snags, {String? actorId}) {
    final out = <SnagIntegrityFinding>[];
    for (final s in snags) {
      // 1. "+1" photos added through the duplicate guard. Matched to the
      //    person, not to a time window: an offline walk replays hours
      //    after capture, so the server's event time says nothing.
      final plusOneBy = {
        for (final a in s.activity)
          if (a.type == 'duplicate-report' && a.by != null && (actorId == null || a.by == actorId)) a.by!,
      };
      if (plusOneBy.isNotEmpty) {
        final ids = [
          for (final e in s.evidence)
            if (e.isPhoto && e.stage == 'extra' && plusOneBy.contains(e.capturedBy)) e.id,
        ];
        if (ids.isNotEmpty) {
          out.add(SnagIntegrityFinding(kind: possibleMisattached, snagId: s.id, ref: s.reference, evidenceIds: ids));
        }
      }
      // 2. After-photos whose taker never marked this snag ready. The only
      //    writer of `stage: after` is the "ready" transition, which records
      //    the photo and the event together, so a lone after-photo is a
      //    record this device cannot explain. Needs the timeline: a lean
      //    list row (no activity yet) is skipped, not judged.
      if (s.activity.isNotEmpty) {
        final readyBy = {for (final a in s.activity) if (a.type == 'ready') a.by};
        final ids = [
          for (final e in s.evidence)
            if (e.isPhoto && e.isAfter && e.capturedBy != null && !readyBy.contains(e.capturedBy)) e.id,
        ];
        if (ids.isNotEmpty) {
          out.add(SnagIntegrityFinding(kind: afterPhotoWithoutReady, snagId: s.id, ref: s.reference, evidenceIds: ids));
        }
      }
    }
    return out;
  }
}

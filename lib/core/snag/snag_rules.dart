import 'dart:math' as math;

import '../../domain/snag.dart';

/// Snag Assistant — pure rules, no I/O (tested in test/snag_rules_test.dart).
///
/// [SnagRules.apply] ports the server's `services/snag/snagRules.ts`
/// `applyTransition` so an offline device can move a snag optimistically and
/// show the right buttons. The server stays the authority: if this port ever
/// disagrees, the queued write lands in the conflict log and the next fetch
/// restores the server's state. Change the two files together.

class SnagTransitionFailure {
  const SnagTransitionFailure(this.code, this.message);

  /// Same codes as the server: INVALID_TRANSITION, AFTER_PHOTO_REQUIRED,
  /// SELF_VERIFY, REASON_REQUIRED, WAIVE_FORBIDDEN.
  final String code;
  final String message;
}

class SnagTransitionResult {
  const SnagTransitionResult.ok(Snag this.snag) : failure = null;
  const SnagTransitionResult.fail(SnagTransitionFailure this.failure) : snag = null;

  final Snag? snag;
  final SnagTransitionFailure? failure;
  bool get ok => snag != null;
}

abstract final class SnagRules {
  static SnagTransitionResult apply(
    Snag snag,
    SnagAction action, {
    required String actorId,
    String? actorName,
    String actorRole = 'Technician',
    String? reason,
    String? note,
    List<SnagEvidence> added = const [],
    required String activityId,
    DateTime? now,
    bool allowSelfVerify = false,
  }) {
    final at = now ?? DateTime.now();
    final why = reason?.trim() ?? '';
    final s = snag.status;
    final evidence = [...snag.evidence, ...added];

    SnagTransitionResult fail(String code, String message) =>
        SnagTransitionResult.fail(SnagTransitionFailure(code, message));

    Snag next(SnagStatus status, String type, {int? reopenedCount}) {
      return snag.copyWith(
        status: status,
        evidence: evidence,
        reopenedCount: reopenedCount,
        updatedAt: at,
        activity: [
          ...snag.activity,
          SnagActivity(
            id: activityId,
            at: at,
            type: type,
            by: actorId,
            byName: actorName,
            note: (note?.trim().isEmpty ?? true) ? null : note!.trim(),
            reason: why.isEmpty ? null : why,
          ),
        ],
      );
    }

    switch (action) {
      case SnagAction.start:
        if (s != SnagStatus.open) return fail('INVALID_TRANSITION', 'Only an open snag can be started.');
        return SnagTransitionResult.ok(next(SnagStatus.inProgress, 'started'));

      case SnagAction.ready:
        if (s != SnagStatus.open && s != SnagStatus.inProgress) {
          return fail('INVALID_TRANSITION', 'This snag cannot be marked ready now.');
        }
        if (!evidence.any((e) => e.isPhoto && e.isAfter)) {
          return fail('AFTER_PHOTO_REQUIRED', 'Add a photo of the fixed work first.');
        }
        return SnagTransitionResult.ok(
          next(SnagStatus.ready, 'ready').copyWith(readyBy: actorId, readyAt: at),
        );

      case SnagAction.verify:
        if (s != SnagStatus.ready) return fail('INVALID_TRANSITION', 'Only a snag marked ready can be verified.');
        if (!allowSelfVerify && snag.readyBy != null && snag.readyBy == actorId) {
          return fail('SELF_VERIFY', 'Someone other than the person who fixed it has to verify it.');
        }
        return SnagTransitionResult.ok(
          next(SnagStatus.closed, 'verified').copyWith(verifiedBy: actorId, verifiedAt: at, closedAt: at),
        );

      case SnagAction.reject:
        if (s != SnagStatus.ready) return fail('INVALID_TRANSITION', 'Only a snag marked ready can be rejected.');
        if (why.isEmpty) return fail('REASON_REQUIRED', 'Say why the fix was not accepted.');
        return SnagTransitionResult.ok(
          next(SnagStatus.open, 'rejected', reopenedCount: snag.reopenedCount + 1)
              .copyWith(clearReady: true, clearVerified: true),
        );

      case SnagAction.reopen:
        if (s != SnagStatus.closed) return fail('INVALID_TRANSITION', 'Only a closed snag can be reopened.');
        if (why.isEmpty) return fail('REASON_REQUIRED', 'Say why the snag is being reopened.');
        return SnagTransitionResult.ok(
          next(SnagStatus.open, 'reopened', reopenedCount: snag.reopenedCount + 1)
              .copyWith(clearReady: true, clearVerified: true),
        );

      case SnagAction.waive:
        if (actorRole != 'Admin') return fail('WAIVE_FORBIDDEN', 'Only an administrator can waive a snag.');
        if (s == SnagStatus.closed || s == SnagStatus.waived) {
          return fail('INVALID_TRANSITION', 'This snag cannot be waived now.');
        }
        if (why.isEmpty) return fail('REASON_REQUIRED', 'A waiver needs a justification.');
        return SnagTransitionResult.ok(next(SnagStatus.waived, 'waived').copyWith(closedAt: at));
    }
  }

  /// The buttons a detail screen offers [userId]. Waive is never offered in
  /// the app (web-only commercial decision); `ready` is offered even without
  /// an after photo because pressing it is how the photo gets taken.
  static List<SnagAction> actionsFor(Snag snag, String userId) {
    switch (snag.status) {
      case SnagStatus.open:
        return const [SnagAction.start, SnagAction.ready];
      case SnagStatus.inProgress:
        return const [SnagAction.ready];
      case SnagStatus.ready:
        return snag.readyBy == userId ? const [] : const [SnagAction.verify, SnagAction.reject];
      case SnagStatus.closed:
        return const [SnagAction.reopen];
      case SnagStatus.waived:
        return const [];
    }
  }
}

// ---------------------------------------------------------------------------
// Duplicate guard (UC-3)
// ---------------------------------------------------------------------------

/// The fields of a snag about to be raised that the duplicate guard compares.
class SnagDraftSignature {
  const SnagDraftSignature({
    required this.trade,
    this.buildingId,
    this.floorId,
    this.spaceId,
    this.assetId,
    this.issueType,
    this.title,
    this.pin,
    this.surveyId,
    this.raisedBy,
  });

  final String trade;
  final String? buildingId;
  final String? floorId;
  final String? spaceId;
  final String? assetId;
  final String? issueType;
  final String? title;
  final SnagPin? pin;
  final String? surveyId;
  final String? raisedBy;
}

class DuplicateCandidate {
  const DuplicateCandidate(this.snag, this.score, this.reasons);
  final Snag snag;

  /// 0..1+; ≥ [SnagDuplicateFinder.threshold] is shown to the inspector.
  final double score;

  /// Signal keys for the UI: space, floor, asset, trade, type, pin, words.
  final List<String> reasons;
}

enum DuplicateChoice { sameIssue, different }

/// The person's answer to the duplicate sheet. [snag] is the existing snag
/// they picked for "Same issue"; null for "Different".
class DuplicateDecision {
  const DuplicateDecision(this.choice, [this.snag]);
  final DuplicateChoice choice;
  final Snag? snag;
}

/// Scores open snags against a draft. The cost of a false positive is one
/// "Different" tap; the cost of a false negative is a duplicate on a punch
/// list that then gets fixed twice or argued about — so the bar is moderate.
///
/// A same-room, same-trade match on its own (0.55) is deliberately *below*
/// the bar: two electrical snags in one room are usually two defects. One
/// more signal — same asset, a close pin, same issue type or overlapping
/// words — tips it over.
abstract final class SnagDuplicateFinder {
  static const threshold = 0.6;

  static List<DuplicateCandidate> find(
    SnagDraftSignature draft,
    Iterable<Snag> pool, {
    int max = 3,
  }) {
    final out = <DuplicateCandidate>[];
    for (final s in pool) {
      // Open / in progress only. A *ready* snag is waiting for someone to
      // verify the fix: its gallery is the fix evidence, and a "+1" photo
      // landing there sits right beside the after-photos (owner iPhone
      // report 2026-10-10: "my walk photo got added to an existing snag's
      // after-photos"). A defect seen again on a ready snag is a reject.
      if (s.status != SnagStatus.open && s.status != SnagStatus.inProgress) continue;
      if (draft.buildingId != null && s.buildingId != null && s.buildingId != draft.buildingId) continue;
      // The inspector knows what they raised minutes ago in this same walk;
      // asking them about it again is pure friction.
      if (draft.surveyId != null &&
          s.surveyId == draft.surveyId &&
          draft.raisedBy != null &&
          s.raisedBy == draft.raisedBy) {
        continue;
      }
      var score = 0.0;
      final reasons = <String>[];
      final sameAsset = draft.assetId != null && s.assetId == draft.assetId;
      if (draft.spaceId != null && s.spaceId == draft.spaceId) {
        score += 0.35;
        reasons.add('space');
      } else if (draft.spaceId != null && s.spaceId != null) {
        // Two different rooms: identical words in room 101 and room 109 are
        // two defects. Only the same asset (a riser, a duct run) links them.
        if (!sameAsset) continue;
      } else if (draft.floorId != null && s.floorId == draft.floorId) {
        // One side was raised at floor level, so "same floor" is the most
        // precise location match available.
        score += 0.1;
        reasons.add('floor');
      } else if (draft.spaceId != null || draft.floorId != null) {
        // Different floor entirely: only an asset match could still make
        // this the same defect.
        if (!sameAsset) continue;
      }
      if (sameAsset) {
        score += 0.3;
        reasons.add('asset');
      }
      if (s.trade == draft.trade) {
        score += 0.2;
        reasons.add('trade');
      }
      if (draft.issueType != null && s.issueType == draft.issueType) {
        score += 0.1;
        reasons.add('type');
      }
      final a = draft.pin;
      final b = s.pin;
      if (a != null && b != null && a.floorId == b.floorId) {
        final d = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
        if (d < 0.04) {
          score += 0.25;
          reasons.add('pin');
        } else if (d < 0.08) {
          score += 0.12;
          reasons.add('pin');
        }
      }
      final words = wordSimilarity(draft.title, s.title);
      if (words > 0) {
        score += 0.35 * words;
        if (words >= 0.3) reasons.add('words');
      }
      if (score >= threshold) out.add(DuplicateCandidate(s, score, reasons));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return out.take(max).toList();
  }

  static const _stop = {
    'the', 'and', 'for', 'with', 'from', 'not', 'near', 'room', 'area', 'side', 'into', 'this', 'that', 'has', 'are', 'was',
  };

  static Set<String> _tokens(String? s) => (s ?? '')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9؀-ۿ]+'))
      .where((w) => w.length >= 3 && !_stop.contains(w))
      .toSet();

  /// Jaccard over content words. 0 when either side has none.
  static double wordSimilarity(String? a, String? b) {
    final x = _tokens(a);
    final y = _tokens(b);
    if (x.isEmpty || y.isEmpty) return 0;
    final inter = x.intersection(y).length;
    return inter / x.union(y).length;
  }
}

// ---------------------------------------------------------------------------
// Readiness (UC-9) — readinessService's principle: unmeasured ≠ passed
// ---------------------------------------------------------------------------

class ReadinessDimension {
  const ReadinessDimension({
    required this.key,
    required this.weight,
    required this.score,
    required this.detail,
  });

  /// coverage | blockers | closure | quality
  final String key;
  final double weight;

  /// 0..1, or null when there is nothing yet to measure it on.
  final double? score;

  /// e.g. "18/24" — shown under the dimension.
  final String detail;

  bool get measured => score != null;
}

class SnagReadiness {
  const SnagReadiness(this.score, this.dimensions);

  /// Weighted over *measured* dimensions only; null when none are.
  final double? score;
  final List<ReadinessDimension> dimensions;

  double get evaluatedWeight =>
      dimensions.where((d) => d.measured).fold(0.0, (s, d) => s + d.weight);
}

abstract final class SnagReadinessCalculator {
  static SnagReadiness compute({
    required List<Snag> snags,
    int? spacesInScope,
    int? spacesInspected,
  }) {
    final counted = snags.where((s) => s.status != SnagStatus.waived).toList();
    final critical = counted.where((s) => s.priority == SnagPriority.critical).toList();
    final openCritical = critical.where((s) => s.status.isLive).length;
    final closed = counted.where((s) => s.status == SnagStatus.closed).length;
    final everReady = counted.where((s) => s.readyAt != null || s.status == SnagStatus.closed || s.reopenedCount > 0);
    final reopened = counted.where((s) => s.reopenedCount > 0).length;

    final dims = <ReadinessDimension>[
      ReadinessDimension(
        key: 'coverage',
        weight: 0.3,
        score: (spacesInScope ?? 0) > 0
            ? ((spacesInspected ?? 0) / spacesInScope!).clamp(0.0, 1.0)
            : null,
        detail: (spacesInScope ?? 0) > 0 ? '${spacesInspected ?? 0}/$spacesInScope' : '—',
      ),
      ReadinessDimension(
        key: 'blockers',
        weight: 0.3,
        // No snag raised at all tells us nothing; a raised set with no
        // criticals in it is a real, full score.
        score: counted.isEmpty ? null : (critical.isEmpty ? 1.0 : 1 - openCritical / critical.length),
        detail: critical.isEmpty ? '0' : '$openCritical/${critical.length}',
      ),
      ReadinessDimension(
        key: 'closure',
        weight: 0.25,
        score: counted.isEmpty ? null : closed / counted.length,
        detail: '$closed/${counted.length}',
      ),
      ReadinessDimension(
        key: 'quality',
        weight: 0.15,
        score: everReady.isEmpty ? null : 1 - reopened / everReady.length,
        detail: everReady.isEmpty ? '—' : '$reopened/${everReady.length}',
      ),
    ];
    final w = dims.where((d) => d.measured).fold(0.0, (s, d) => s + d.weight);
    final score = w == 0
        ? null
        : dims.where((d) => d.measured).fold(0.0, (s, d) => s + d.weight * d.score!) / w;
    return SnagReadiness(score, dims);
  }
}

// ---------------------------------------------------------------------------
// "Waiting on you" (UC-8)
// ---------------------------------------------------------------------------

enum WaitingReason { verify, fix, overdue }

class WaitingItem {
  const WaitingItem(this.snag, this.reason);
  final Snag snag;
  final WaitingReason reason;
}

abstract final class SnagQueues {
  /// Verification first (someone's fix is blocked on it), then fixes assigned
  /// to me by severity, then snags I raised that are now overdue. A snag
  /// appears once, under its most urgent reason.
  static List<WaitingItem> waitingOn(String userId, Iterable<Snag> snags, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final verify = <Snag>[];
    final fix = <Snag>[];
    final overdue = <Snag>[];
    for (final s in snags) {
      if (s.status == SnagStatus.ready && s.readyBy != userId) {
        verify.add(s);
      } else if (s.assignedToUserId == userId &&
          (s.status == SnagStatus.open || s.status == SnagStatus.inProgress)) {
        fix.add(s);
      } else if (s.raisedBy == userId && s.isOverdue(t)) {
        overdue.add(s);
      }
    }
    int byReady(Snag a, Snag b) =>
        (a.readyAt ?? a.updatedAt).compareTo(b.readyAt ?? b.updatedAt);
    int bySeverityThenDue(Snag a, Snag b) {
      final p = a.priority.index.compareTo(b.priority.index);
      if (p != 0) return p;
      final ad = a.dueDate ?? DateTime(9999);
      final bd = b.dueDate ?? DateTime(9999);
      return ad.compareTo(bd);
    }

    verify.sort(byReady);
    fix.sort(bySeverityThenDue);
    overdue.sort(bySeverityThenDue);
    return [
      ...verify.map((s) => WaitingItem(s, WaitingReason.verify)),
      ...fix.map((s) => WaitingItem(s, WaitingReason.fix)),
      ...overdue.map((s) => WaitingItem(s, WaitingReason.overdue)),
    ];
  }

  /// The verify run's queue: ready snags someone else fixed, oldest first.
  static List<Snag> toVerify(String userId, Iterable<Snag> snags) {
    final list = snags.where((s) => s.status == SnagStatus.ready && s.readyBy != userId).toList();
    list.sort((a, b) => (a.readyAt ?? a.updatedAt).compareTo(b.readyAt ?? b.updatedAt));
    return list;
  }

  /// Hub list order: live before done, then severity, then newest.
  static List<Snag> sortForList(Iterable<Snag> snags) {
    final list = snags.toList();
    list.sort((a, b) {
      final live = (b.status.isLive ? 1 : 0).compareTo(a.status.isLive ? 1 : 0);
      if (live != 0) return live;
      final p = a.priority.index.compareTo(b.priority.index);
      if (p != 0) return p;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }
}

/// Per-floor sweep coverage for the survey dashboard.
class FloorCoverage {
  const FloorCoverage({required this.floor, required this.inspected, required this.clear, required this.total});
  final SnagFloor floor;
  final int inspected;
  final int clear;
  final int total;
  double get ratio => total == 0 ? 0 : inspected / total;
}

List<FloorCoverage> floorCoverage(SnagLocationTree tree, SnagSurvey survey) => [
  for (final f in tree.floors)
    FloorCoverage(
      floor: f,
      inspected: f.spaces.where((s) => survey.sweepFor(s.id) != null).length,
      clear: f.spaces.where((s) => survey.sweepFor(s.id)?.clear ?? false).length,
      total: f.spaces.length,
    ),
];

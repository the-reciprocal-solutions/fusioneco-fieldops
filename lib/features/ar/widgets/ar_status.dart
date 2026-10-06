import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ar/alignment_estimator.dart';
import '../../../state/ar_catalog_controller.dart' show arOfflineProvider;
import '../../../state/ar_session_controller.dart';
import '../../../state/providers.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import 'ar_chrome.dart';

/// Words for the honest badge (docs/ar-setup-and-gamma-parity.md §2.7).
/// What was measured, never an estimate: "Locked ±2 cm · 2 corners".

ArBadgeTone arBadgeTone(AlignmentQuality q) => switch (q) {
  AlignmentQuality.none => ArBadgeTone.none,
  AlignmentQuality.placed => ArBadgeTone.placed,
  AlignmentQuality.locked => ArBadgeTone.locked,
  AlignmentQuality.drifting => ArBadgeTone.drifting,
  AlignmentQuality.manual => ArBadgeTone.manual,
  AlignmentQuality.siteMismatch => ArBadgeTone.mismatch,
};

/// "2 boards", "1 corner", "1 board + 1 corner".
String arObservationSummary(BuildContext context, int boards, int corners) {
  final parts = <String>[
    if (boards > 0) boards == 1 ? arTr(context, 'ar.badge.one_board') : arTr(context, 'ar.badge.n_boards', [boards]),
    if (corners > 0) corners == 1 ? arTr(context, 'ar.badge.one_corner') : arTr(context, 'ar.badge.n_corners', [corners]),
  ];
  return parts.join(' + ');
}

/// The full badge text. [compact] drops the tail for the phone's combined
/// pill ("Locked ±2 cm").
String arBadgeText(BuildContext context, ArBadgeInfo b, {bool compact = false}) {
  final what = arObservationSummary(context, b.boards, b.corners);
  final pm = arCentimetres(context, b.residualM < 0.01 ? 0.01 : b.residualM, plusMinus: true);
  switch (b.quality) {
    case AlignmentQuality.none:
      return arTr(context, compact ? 'ar.badge.none_short' : 'ar.badge.none');
    case AlignmentQuality.placed:
      if (compact) return arTr(context, 'ar.badge.placed_short');
      if (b.boards == 1 && b.corners == 0) return arTr(context, 'ar.badge.placed_board');
      if (b.corners == 1 && b.boards == 0) return arTr(context, 'ar.badge.placed_corner');
      // Far enough apart for positions, but agreeing only to 2–5 cm: usable,
      // not green (AlignmentEstimator.greenResidualM).
      if (b.residualM > AlignmentEstimator.greenResidualM) {
        return arTr(context, 'ar.badge.placed_loose', [what, pm]);
      }
      return arTr(context, 'ar.badge.placed_close', [what]);
    case AlignmentQuality.locked:
      if (compact) return arTr(context, 'ar.badge.locked_short', [pm]);
      final walked = b.walkedSinceCheckM;
      if (walked != null && walked >= 1) {
        return arTr(context, 'ar.badge.locked_checked', [pm, what, arMetres(context, walked)]);
      }
      return arTr(context, 'ar.badge.locked', [pm, what]);
    case AlignmentQuality.drifting:
      return arTr(context, 'ar.badge.drifting');
    case AlignmentQuality.manual:
      // "Place by hand": never measured, and says so when not at true size.
      if (b.handPlaced) {
        final pct = b.scalePct;
        if (pct == null) return arTr(context, compact ? 'ar.badge.hand_short' : 'ar.badge.hand');
        return arTr(context, compact ? 'ar.badge.hand_short_scaled' : 'ar.badge.hand_scaled', ['$pct%']);
      }
      return arTr(context, compact ? 'ar.badge.manual_short' : 'ar.badge.manual', [arCentimetres(context, b.nudgeM)]);
    case AlignmentQuality.siteMismatch:
      return arTr(context, compact ? 'ar.badge.mismatch_short' : 'ar.badge.mismatch', [arCentimetres(context, b.residualM)]);
  }
}

/// The session badge, watching the session itself.
class ArSessionBadge extends ConsumerWidget {
  const ArSessionBadge({super.key, this.compact = false, this.onTap, this.withSync = false});

  final bool compact;
  final VoidCallback? onTap;

  /// Phone: one combined pill ("Locked ±2 cm · offline").
  final bool withSync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(arSessionProvider.select((s) => s.badge));
    var text = arBadgeText(context, badge, compact: compact);
    if (withSync) {
      final offline = ref.watch(arOfflineProvider).valueOrNull ?? false;
      final queued = ref.watch(pendingMutationCountProvider).valueOrNull ?? 0;
      if (offline) {
        text = '$text · ${arTr(context, 'ar.sync.offline_short')}';
      } else if (queued > 0) {
        text = '$text · ${arTr(context, 'ar.sync.queued_short', [queued])}';
      }
    }
    // A hand placement is amber, like any placement nobody measured.
    final tone = badge.handPlaced && badge.quality == AlignmentQuality.manual ? ArBadgeTone.placed : arBadgeTone(badge.quality);
    return ArStatusBadge(tone: tone, text: text, onTap: onTap, dense: compact);
  }
}

/// iPad's sync chip next to the badge: "Offline · 3 queued".
class ArSyncChip extends ConsumerWidget {
  const ArSyncChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(arOfflineProvider).valueOrNull ?? false;
    final queued = ref.watch(pendingMutationCountProvider).valueOrNull ?? 0;
    if (!offline && queued == 0) return const SizedBox.shrink();
    final text = offline
        ? (queued > 0 ? arTr(context, 'ar.sync.offline_queued', [queued]) : arTr(context, 'ar.sync.offline'))
        : arTr(context, 'ar.sync.queued', [queued]);
    final st = ArChromeStyle.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: st.surface(), borderRadius: BorderRadius.circular(14), border: st.border()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(offline ? ArIcons.offline : ArIcons.sync, size: st.iconSize(15), color: st.fg),
          const SizedBox(width: 6),
          AppText.bodySmall(
            text,
            color: st.fg,
            weight: st.weight(FontWeight.w600),
            style: st.text(Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

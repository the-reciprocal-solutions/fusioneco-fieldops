import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ar/drill_check.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_view_models.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import 'ar_discipline_legend.dart';

/// Drill check: hold the centre crosshair on the spot you want to drill,
/// and the card says whether a modelled service is behind it — green "Safe
/// to drill here", amber within 30 cm, red within 15 cm, with the element,
/// which way it is and how deep. The geometry is `core/ar/drill_check.dart`;
/// the controller re-runs it on camera poses at most 5 times a second.
///
/// It is a model check, not a detector: the card always says how accurate
/// today's alignment is and to confirm with a detector before drilling.

/// Everything the card and the crosshair say about one reading.
class _Look {
  const _Look(this.bg, this.fg, this.accent, this.icon, this.headline, this.detail);
  final Color bg;
  final Color fg;
  final Color accent;
  final IconData icon;
  final String headline;
  final String? detail;
}

_Look _lookFor(BuildContext context, ArDrillStatus status, ArDrillReading? r) {
  final nearest = r?.nearest;
  return switch (status) {
    ArDrillStatus.notPlaced => _Look(
      FeArColors.placedBg,
      FeArColors.placedFg,
      FeArColors.drillCaution,
      ArIcons.realign,
      'ar.drill.align_short'.getString(context),
      'ar.drill.align_first'.getString(context),
    ),
    ArDrillStatus.noWalls => _Look(
      FeArColors.manualBg,
      FeArColors.manualFg,
      FeArColors.onGlassMuted,
      ArIcons.info,
      'ar.drill.point'.getString(context),
      'ar.drill.no_walls'.getString(context),
    ),
    ArDrillStatus.noHit => _Look(
      FeArColors.manualBg,
      FeArColors.manualFg,
      Colors.white,
      ArIcons.crosshair,
      'ar.drill.point'.getString(context),
      'ar.drill.point_body'.getString(context),
    ),
    ArDrillStatus.safe => _Look(
      FeArColors.lockedBg,
      FeArColors.lockedFg,
      FeArColors.drillSafe,
      ArIcons.check,
      'ar.drill.safe'.getString(context),
      nearest == null
          ? 'ar.drill.safe_none'.getString(context)
          : arTr(context, 'ar.drill.safe_nearest', [arCentimetres(context, nearest.planeDistanceM)]),
    ),
    ArDrillStatus.caution => _Look(
      FeArColors.placedBg,
      FeArColors.placedFg,
      FeArColors.drillCaution,
      ArIcons.warning,
      arTr(context, 'ar.drill.caution', [arCentimetres(context, nearest?.planeDistanceM ?? 0.3)]),
      nearest == null ? null : arDrillFindingText(context, nearest),
    ),
    ArDrillStatus.danger => _Look(
      FeArColors.mismatchBg,
      FeArColors.mismatchFg,
      FeArColors.drillDanger,
      ArIcons.warning,
      'ar.drill.danger'.getString(context),
      nearest == null ? null : arDrillFindingText(context, nearest),
    ),
  };
}

/// "Cold water — 8 cm below, 4 cm deep".
String arDrillFindingText(BuildContext context, DrillFinding<ArFeature> f) {
  final name = f.ref.displayName;
  final depth = arCentimetres(context, f.depthM);
  if (f.direction == DrillDirection.behind) return arTr(context, 'ar.drill.finding_behind', [name, depth]);
  return arTr(context, 'ar.drill.finding', [
    name,
    arCentimetres(context, f.planeDistanceM),
    'ar.drill.dir.${f.direction.name}'.getString(context),
    depth,
  ]);
}

ArDrillStatus _statusOf(ArWorkspaceState ws, ArSessionState s) =>
    ws.drill?.status ?? (s.isPlaced ? ArDrillStatus.noHit : ArDrillStatus.notPlaced);

/// The card (iPad action card, phone sheet) while Drill check is on. The
/// verdict comes first so the phone's collapsed sheet still shows it.
class ArDrillPanel extends ConsumerWidget {
  const ArDrillPanel({super.key, required this.tablet, required this.onBackToSetup});

  final bool tablet;
  final VoidCallback onBackToSetup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    final s = ref.watch(arSessionProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final r = ws.drill;
    final status = _statusOf(ws, s);
    final look = _lookFor(context, status, r);
    final hit = r?.hit;
    final feature = r?.feature;
    final more = (r?.nearbyCount ?? 0) - 1;
    final residual = math.max(0.01, s.fit?.maxResidualM ?? 0.01);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tablet) ...[
          ArEyebrow('ar.drill.title'.getString(context)),
          const SizedBox(height: 6),
        ],
        Semantics(
          liveRegion: true,
          label: [look.headline, ?look.detail].join('. '),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: look.bg,
              borderRadius: BorderRadius.circular(14),
              border: BorderDirectional(start: BorderSide(color: look.accent, width: 4)),
            ),
            child: Row(
              children: [
                Icon(look.icon, size: 22, color: look.fg),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText.titleSmall(look.headline, color: look.fg, weight: FontWeight.w800),
                      if (look.detail != null) AppText.bodySmall(look.detail!, color: look.fg, weight: FontWeight.w600),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'ar.common.close'.getString(context),
                  onPressed: ctrl.toggleDrill,
                  icon: Icon(ArIcons.close, size: 18, color: look.fg),
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                ),
              ],
            ),
          ),
        ),
        if (hit != null) ...[
          const SizedBox(height: 8),
          AppText.caption(
            arTr(context, 'ar.drill.wall', [arMetres(context, hit.distanceM), arMetres(context, hit.heightAboveFloorM)]),
            color: FeColors.ink2,
          ),
        ],
        if (more > 0) ...[
          const SizedBox(height: 2),
          AppText.caption(arTr(context, 'ar.drill.more', [more]), color: FeColors.ink2, weight: FontWeight.w600),
        ],
        if (feature != null) ...[
          const SizedBox(height: 10),
          ArSecondaryButton(
            label: arTr(context, 'ar.drill.open', [feature.displayName]),
            icon: ArIcons.identify,
            onPressed: () => ctrl.selectFromDrill(feature),
          ),
        ],
        if (status == ArDrillStatus.notPlaced) ...[
          const SizedBox(height: 10),
          ArPrimaryButton(label: 'ar.work.place_now'.getString(context), icon: ArIcons.realign, onPressed: onBackToSetup),
        ],
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(ArIcons.info, size: 14, color: FeColors.ink2),
            const SizedBox(width: 6),
            Expanded(
              child: AppText.caption(
                arTr(context, 'ar.drill.accuracy', [arCentimetres(context, residual, plusMinus: true)]),
                color: FeColors.ink2,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The centre crosshair and a one-line verdict under it, on the camera.
/// Centred on the view, which is where the camera-centre ray points.
/// Never takes a touch: taps go through to the model.
class ArDrillCrosshair extends ConsumerWidget {
  const ArDrillCrosshair({super.key, required this.viewSize});

  final Size viewSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    final s = ref.watch(arSessionProvider);
    final status = _statusOf(ws, s);
    final look = _lookFor(context, status, ws.drill);
    final c = Offset(viewSize.width / 2, viewSize.height / 2);
    const box = 64.0;
    final nearest = ws.drill?.nearest;
    final st = ArChromeStyle.of(context);
    final pill = switch (status) {
      ArDrillStatus.caution || ArDrillStatus.danger when nearest != null => arDrillFindingText(context, nearest),
      _ => look.headline,
    };
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: c.dx - box / 2,
            top: c.dy - box / 2,
            width: box,
            height: box,
            child: CustomPaint(painter: _CrosshairPainter(look.accent, sunlight: st.sunlight)),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: c.dy + box / 2 + 6,
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: st.surface(strong: true),
                  borderRadius: BorderRadius.circular(12),
                  border: st.border(),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ArLegendDot(colour: look.accent, size: st.sunlight ? 12 : 10),
                    const SizedBox(width: 7),
                    Flexible(
                      child: AppText.bodySmall(
                        pill,
                        color: st.fg,
                        weight: st.weight(FontWeight.w700),
                        style: st.text(Theme.of(context).textTheme.bodySmall),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter(this.colour, {this.sunlight = false});
  final Color colour;

  /// Sunlight: a solid black halo and a thicker stroke, so the ring still
  /// reads against a sunlit wall.
  final bool sunlight;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.3;
    final shadow = Paint()
      ..color = sunlight ? Colors.black : Colors.black54
      ..strokeWidth = sunlight ? 7 : 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = colour
      ..strokeWidth = sunlight ? 3.5 : 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final p in [shadow, line]) {
      canvas.drawCircle(c, r, p);
      // Ticks outside the ring, leaving the centre clear to aim with.
      canvas.drawLine(c + Offset(0, -size.height / 2 + 2), c + Offset(0, -r - 4), p);
      canvas.drawLine(c + Offset(0, r + 4), c + Offset(0, size.height / 2 - 2), p);
      canvas.drawLine(c + Offset(-size.width / 2 + 2, 0), c + Offset(-r - 4, 0), p);
      canvas.drawLine(c + Offset(r + 4, 0), c + Offset(size.width / 2 - 2, 0), p);
    }
    canvas.drawCircle(c, sunlight ? 3.5 : 2.5, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter old) => old.colour != colour || old.sunlight != sunlight;
}

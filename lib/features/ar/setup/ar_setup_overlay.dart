import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/ar/alignment_estimator.dart';
import '../../../core/ar/corner_matcher.dart';
import '../../../core/ar/marker_code.dart';
import '../../../core/ar/vec.dart';
import '../../../core/ar/wall_fit.dart';
import '../../../state/ar_prefs_controller.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_setup_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import '../widgets/ar_mini_plan.dart';
import '../widgets/ar_status.dart';
import '../widgets/ar_sunlight.dart';
import '../widgets/ar_visuals.dart';
import '../workspace/ar_workspace.dart' show arRefocus;
import 'ar_method_chooser.dart';
import 'ar_register_board_card.dart';

/// Everything drawn over the camera while the model is being placed
/// (canvas row 6 + TabMethod/TabSnap/TabRegister and their phone twins).
///
/// Phone: one card at the bottom, in the thumb zone; the pin and chips on
/// the camera. iPad (≥ 900 px): the guidance card with its mini plan sits
/// top-left, like TabSnap, and actions stay inside it or centred at the
/// bottom — nothing important under the phone's top-left dead zone.
class ArSetupOverlay extends ConsumerStatefulWidget {
  const ArSetupOverlay({super.key, required this.tablet, required this.topInset});

  final bool tablet;

  /// Height of the session's top bar, so chips sit under it.
  final double topInset;

  @override
  ConsumerState<ArSetupOverlay> createState() => _ArSetupOverlayState();
}

class _ArSetupOverlayState extends ConsumerState<ArSetupOverlay> {
  /// M2: the user tapped "Start aligning" (or the pack was already local).
  var _readyAck = false;
  var _planOpen = false;

  /// The user's show/hide choice for the card during a scanning step; reset
  /// when the step changes. Null = the default (collapsed while scanning).
  bool? _cardOpen;
  ArSetupStep? _cardStep;

  /// Steps where the camera matters more than the card: the card shrinks to a
  /// "Show steps" bar so the pin, the crosshair and the board are visible
  /// (device test 2026-09-27: the card covered the scan).
  static const _scanSteps = {
    ArSetupStep.cornerA,
    ArSetupStep.cornerB,
    ArSetupStep.wallTaps,
    ArSetupStep.baseline,
    ArSetupStep.boardScan,
    ArSetupStep.boardLock,
  };

  /// A result waiting for a decision (a snapped corner to use): the card
  /// opens by itself.
  bool _needsDecision(ArSetupState setup) => switch (setup.step) {
    ArSetupStep.cornerA => setup.snapped != null,
    ArSetupStep.cornerB => setup.snapped != null || setup.matchedB != null,
    _ => false,
  };

  ArSetupController get _ctrl => ref.read(arSetupProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(arSetupProvider);
    final s = ref.watch(arSessionProvider);
    final tablet = widget.tablet;

    final showReady = !_readyAck &&
        s.args?.focusCode != null &&
        s.args?.installCode == null &&
        (setup.step == ArSetupStep.boardScan || setup.step == ArSetupStep.choose);

    final Widget card = showReady ? _ReadyCard(onStart: () => setState(() => _readyAck = true)) : _cardFor(context, setup, s);

    final tapping = setup.step == ArSetupStep.wallTaps || setup.step == ArSetupStep.baseline;
    if (_cardStep != setup.step) {
      _cardStep = setup.step;
      _cardOpen = null;
    }
    final scanning = _scanSteps.contains(setup.step) && !showReady;
    final collapsed = scanning && !_needsDecision(setup) && !(_cardOpen ?? false);
    final Widget shownCard = collapsed
        ? _CollapsedCardBar(onOpen: () => setState(() => _cardOpen = true))
        : scanning
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: _HideCardChip(onHide: () => setState(() => _cardOpen = false)),
                  ),
                  const SizedBox(height: 6),
                  card,
                ],
              )
            : card;
    return Stack(
      children: [
        // ARCore/ARKit have no focus-at-point: a double-tap anywhere on the
        // camera restarts autofocus (steps that measure taps use single taps).
        if (!tapping)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () => arRefocus(ref),
            ),
          ),
        // Wall taps and the baseline tap measure where the finger lands. The
        // overlay fills the AR view, so its local position is a view point.
        if (tapping)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                ArHaptics.snap();
                final p = d.localPosition;
                if (setup.step == ArSetupStep.wallTaps) {
                  _ctrl.addWallTap(p.dx, p.dy);
                } else {
                  _ctrl.addBaselineTap(p.dx, p.dy);
                }
              },
            ),
          ),
        if (tapping && setup.measuring)
          const Center(
            child: IgnorePointer(
              child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)),
            ),
          ),
        if (setup.step == ArSetupStep.cornerA || setup.step == ArSetupStep.cornerB)
          Center(
            child: ArSnapPin(
              snapped: setup.snapped != null,
              faceAngles: setup.snapped == null ? null : _screenFaces(setup.snapped!),
            ),
          ),
        if (setup.step == ArSetupStep.boardLock)
          Center(child: ArLockRing(progress: setup.lockProgress, ok: setup.sighting?.acceptable ?? true)),
        if (setup.step == ArSetupStep.boardScan && !showReady) const Center(child: _BoardViewfinder()),
        PositionedDirectional(
          top: widget.topInset + 8,
          start: tablet ? 380 : 16,
          // Landscape phone: stop short of the side-docked card.
          end: tablet ? 100 : (_landscapePhone(context) ? math.min(380, MediaQuery.sizeOf(context).width * 0.45) + 24 : 16),
          child: _TopChips(setup: setup, session: s),
        ),
        if (tablet && _stepUsesGridRail(setup.step))
          PositionedDirectional(
            top: widget.topInset + 8,
            end: 20,
            child: _GridRail(visible: s.gridVisible),
          )
        else if (!tablet && _stepUsesGridRail(setup.step))
          PositionedDirectional(
            top: widget.topInset + 64,
            // Landscape phone: the setup card docks on the trailing side.
            start: _landscapePhone(context) ? 12 : null,
            end: _landscapePhone(context) ? null : 12,
            child: Column(
              children: [
                ArGlassButton(
                  icon: ArIcons.grid,
                  label: 'ar.tool.grid'.getString(context),
                  active: s.gridVisible,
                  onTap: () => ref.read(arSessionProvider.notifier).setGridVisible(!s.gridVisible),
                ),
                const SizedBox(height: 8),
                ArGlassButton(
                  icon: ArIcons.plan,
                  label: 'ar.menu.floor_plan'.getString(context),
                  active: _planOpen,
                  onTap: () => setState(() => _planOpen = !_planOpen),
                ),
                const SizedBox(height: 8),
                ArGlassButton(icon: ArIcons.focus, label: 'ar.tool.focus'.getString(context), onTap: () => arRefocus(ref)),
              ],
            ),
          ),
        if (!tablet && _planOpen && _stepUsesGridRail(setup.step))
          PositionedDirectional(
            top: widget.topInset + 64,
            start: _landscapePhone(context) ? 72 : 16,
            end: _landscapePhone(context) ? math.min(380, MediaQuery.sizeOf(context).width * 0.45) + 24 : 72,
            child: ArCard(
              padding: const EdgeInsets.all(10),
              radius: 18,
              child: SizedBox(height: 180, child: _plan(setup, s)),
            ),
          ),
        if (tablet)
          PositionedDirectional(
            top: widget.topInset + 8,
            start: 20,
            width: 340,
            bottom: 20,
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: SingleChildScrollView(child: _animated(shownCard)),
            ),
          )
        else if (_landscapePhone(context))
          // Landscape phone: a bottom card would cover most of a short view,
          // pin and crosshair included. Dock it on the trailing side instead.
          PositionedDirectional(
            top: widget.topInset + 8,
            end: 12 + MediaQuery.paddingOf(context).right,
            bottom: 12 + MediaQuery.paddingOf(context).bottom,
            width: math.min(380, MediaQuery.sizeOf(context).width * 0.45),
            child: Align(
              alignment: AlignmentDirectional.topEnd,
              child: SingleChildScrollView(child: _animated(shownCard)),
            ),
          )
        else
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.66),
              child: SingleChildScrollView(child: _animated(shownCard)),
            ),
          ),
        if (setup.otherFloorCode != null)
          Positioned.fill(child: _OtherFloorPrompt(setup: setup)),
      ],
    );
  }

  /// A phone held sideways (the AR screen may rotate; the tablet layout is
  /// chosen separately by width and height).
  bool _landscapePhone(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  bool _stepUsesGridRail(ArSetupStep step) =>
      step == ArSetupStep.start || step == ArSetupStep.cornerA || step == ArSetupStep.cornerB;

  Widget _animated(Widget card) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 260),
    switchInCurve: Curves.easeOutCubic,
    transitionBuilder: (child, anim) => FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(anim),
        child: child,
      ),
    ),
    child: KeyedSubtree(key: ValueKey(ref.read(arSetupProvider).step), child: card),
  );

  /// The detected faces as screen angles: the AR-world face directions,
  /// relative to where the camera looks, so the drawn lines lean the same
  /// way as the real walls (an illustration, not a projection).
  (double, double)? _screenFaces(DetectedCorner d) {
    final fwd = ref.read(arSessionProvider).cameraForwardAr;
    final heading = fwd == null ? 0.0 : math.atan2(fwd.x, -fwd.z);
    double toScreen(Vec2 f) {
      final a = math.atan2(f.x, -f.y) - heading;
      return math.pi / 2 + a * 0.5 + (f.x >= 0 ? -0.9 : 0.9);
    }

    return (toScreen(d.faceAAr), toScreen(d.faceBAr));
  }

  Widget _plan(ArSetupState setup, ArSessionState s) {
    final floor = s.floor;
    final ranked = setup.ranked;
    final focus = setup.chosenA?.posTile.xz;
    return ArMiniPlan(
      plan: s.plan,
      corners: ranked.take(12).toList(),
      selectedCornerId: setup.step == ArSetupStep.cornerB ? setup.suggestedB?.id : setup.chosenA?.id,
      gridLines: s.gridVisible ? (floor?.gridLines ?? const []) : const [],
      markers: floor?.activeMarkers ?? const [],
      camera: s.cameraTile,
      heading: s.forwardTileXz,
      target: s.target?.centre,
      focus: s.plan == null ? null : focus,
      focusRadiusM: 9,
      onTapCorner: setup.step == ArSetupStep.start || setup.step == ArSetupStep.cornerA ? _ctrl.chooseCornerA : null,
    );
  }

  Widget _cardFor(BuildContext context, ArSetupState setup, ArSessionState s) {
    switch (setup.step) {
      case ArSetupStep.choose:
        return ArMethodChooser(tablet: widget.tablet);
      case ArSetupStep.start:
        return _StartCard(setup: setup, session: s, plan: _plan(setup, s), tablet: widget.tablet);
      case ArSetupStep.cornerA:
        // Phones get the plan too: in a rectangular room every inside corner
        // looks alike, and without seeing which one is chosen people snapped
        // a different one and the model landed rotated (first device run).
        return _CornerACard(setup: setup, session: s, plan: _plan(setup, s), planHeight: widget.tablet ? 180 : 140);
      case ArSetupStep.cornerB:
        return _CornerBCard(setup: setup, session: s, plan: widget.tablet ? _plan(setup, s) : null);
      case ArSetupStep.boardScan:
        return _BoardScanCard(session: s);
      case ArSetupStep.boardLock:
        return _BoardLockCard(setup: setup);
      case ArSetupStep.aligned:
        return _AlignedCard(setup: setup, session: s);
      case ArSetupStep.locked:
        return _LockedCard(setup: setup);
      case ArSetupStep.leaveBoard:
        return _LeaveBoardCard(session: s);
      case ArSetupStep.register:
        return ArRegisterBoardCard(tablet: widget.tablet);
      case ArSetupStep.nudge:
        return _NudgeCard(session: s);
      case ArSetupStep.mismatch:
        return _MismatchCard(session: s);
      case ArSetupStep.wallTaps:
        return _WallTapsCard(setup: setup);
      case ArSetupStep.baseline:
        return const _BaselineCard();
    }
  }
}

// ------------------------------------------------------------------ chips

class _TopChips extends ConsumerWidget {
  const _TopChips({required this.setup, required this.session});

  final ArSetupState setup;
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chips = <Widget>[];
    switch (setup.step) {
      case ArSetupStep.cornerA:
        final a = setup.chosenA;
        final n = a == null ? 1 : setup.ranked.indexOf(a) + 1;
        chips.add(ArGlassChip(text: arTr(context, 'ar.corner.chip_a', [n, a?.label ?? ''])));
        if (setup.snapped != null) chips.add(_snappedChip(context, setup.snapped!));
      case ArSetupStep.cornerB:
        if (setup.matchedB != null) {
          chips.add(ArStatusBadge(
            tone: ArBadgeTone.locked,
            text: arTr(context, 'ar.corner.matched', [setup.matchedB!.label, _shape(context, setup.matchedB!.kind, setup.matchedB!.angleDeg)]),
          ));
        } else if (setup.snapped != null) {
          chips.add(_snappedChip(context, setup.snapped!));
        }
      case ArSetupStep.boardLock:
        final code = setup.lockingCode;
        final label = code == null ? '' : (session.floor?.markerByCode(code)?.label ?? MarkerCode.display(code));
        chips.add(ArGlassChip(text: arTr(context, 'ar.lock.locking_onto', [label])));
      case ArSetupStep.boardScan:
        chips.add(ArGlassChip(text: 'ar.board.point_at'.getString(context), icon: ArIcons.board));
      case ArSetupStep.wallTaps:
        chips.add(ArGlassChip(
          text: arTr(context, 'ar.walls.chip', [setup.wallIndex + 1, setup.currentTaps.length]),
          icon: ArIcons.crosshair,
        ));
      case ArSetupStep.baseline:
        chips.add(ArGlassChip(text: 'ar.baseline.chip'.getString(context), icon: ArIcons.crosshair));
      default:
        break;
    }
    // The room scan: how much of the room is measured, and the depth sensor
    // when the device has one (never named by vendor or part).
    if (session.scanOverlayOn && (session.capabilities?.scanOverlay ?? false)) {
      final scan = session.scan;
      final depth = session.capabilities?.lidar ?? false;
      chips.add(ArGlassChip(
        text: scan == null || scan.isEmpty
            ? (depth ? 'ar.scan.depth_active' : 'ar.scan.scanning').getString(context)
            : arTr(context, depth ? 'ar.scan.progress_depth' : 'ar.scan.progress', [scan.percent, scan.surfaces]),
        icon: ArIcons.roomScan,
        iconColor: scan != null && scan.percent >= 100 ? FeColors.success : null,
      ));
    }
    // Debug builds only (docs/ar-recording-playback.md).
    if (session.recordingPath != null) {
      chips.add(ArGlassChip(
        text: 'ar.debug.recording'.getString(context),
        icon: ArIcons.capture,
        iconColor: FeColors.danger,
        strong: true,
        onTap: () => ref.read(arSessionProvider.notifier).debugStopRecording(),
      ));
    }
    if (session.playbackPath != null) {
      chips.add(ArGlassChip(
        text: arTr(context, 'ar.debug.replaying', [session.playbackPath!.split('/').last]),
        icon: ArIcons.resume,
        onTap: () => ref.read(arSessionProvider.notifier).debugReplay(null),
      ));
    }
    if (session.tracking == 'limited' || session.tracking == 'initializing') {
      chips.add(ArGlassChip(
        text: session.tracking == 'initializing'
            ? 'ar.tracking.initializing'.getString(context)
            : 'ar.tracking.limited'.getString(context),
        icon: ArIcons.info,
        strong: true,
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in chips) Padding(padding: const EdgeInsets.only(bottom: 8), child: Center(child: c)),
      ],
    );
  }

  Widget _snappedChip(BuildContext context, DetectedCorner d) => ArStatusBadge(
    // A floor tap is a rough corner: say so in amber, not a calm green.
    tone: d.method == 'floorTap' ? ArBadgeTone.placed : ArBadgeTone.locked,
    text: arTr(context, 'ar.corner.snapped_via', [_shape(context, d.kind, d.angleDeg), _method(context, d.method)]),
  );
}

/// How a corner was found, for the snapped chip: "walls" (tracked planes),
/// "LiDAR", "wall taps", "floor tap".
String _method(BuildContext context, String method) => switch (method) {
      'lidar' => 'ar.corner.method_lidar'.getString(context),
      'planes' || 'plane' => 'ar.corner.method_planes'.getString(context),
      WallFitter.method => 'ar.corner.method_depthtaps'.getString(context),
      'depth' => 'ar.corner.method_depth'.getString(context),
      _ => 'ar.corner.method_floortap'.getString(context),
    };

/// "90° outside corner", "inside 90°", "column edge".
String _shape(BuildContext context, String kind, double angleDeg) {
  final deg = angleDeg.round();
  return switch (kind) {
    'inside' => arTr(context, 'ar.corner.shape_inside', [deg]),
    'column' => arTr(context, 'ar.corner.shape_column', [deg]),
    _ => arTr(context, 'ar.corner.shape_outside', [deg]),
  };
}

class _GridRail extends ConsumerWidget {
  const _GridRail({required this.visible});
  final bool visible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ArChromeStyle.of(context).surface(),
        borderRadius: BorderRadius.circular(18),
        border: ArChromeStyle.of(context).border(),
      ),
      child: _RailTool(
        icon: ArIcons.grid,
        label: 'ar.tool.grid'.getString(context),
        active: visible,
        onTap: () => ref.read(arSessionProvider.notifier).setGridVisible(!visible),
      ),
    );
  }
}

class _RailTool extends StatelessWidget {
  const _RailTool({required this.icon, required this.label, required this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 64,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: active ? FeColors.ink : Colors.white),
              const SizedBox(height: 3),
              AppText.caption(label, color: active ? FeColors.ink : Colors.white, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

class _BoardViewfinder extends StatelessWidget {
  const _BoardViewfinder();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 190,
        height: 230,
        child: CustomPaint(painter: _BracketsPainter()),
      ),
    );
  }
}

class _BracketsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const l = 26.0;
    final w = size.width;
    final h = size.height;
    canvas.drawPath(Path()..moveTo(0, l)..lineTo(0, 0)..lineTo(l, 0), p);
    canvas.drawPath(Path()..moveTo(w - l, 0)..lineTo(w, 0)..lineTo(w, l), p);
    canvas.drawPath(Path()..moveTo(w, h - l)..lineTo(w, h)..lineTo(w - l, h), p);
    canvas.drawPath(Path()..moveTo(l, h)..lineTo(0, h)..lineTo(0, h - l), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ------------------------------------------------------------------ cards

/// M2: "Getting Level 3 ready" — the 15 m around the board first, the rest
/// streams while the user aligns. Nobody waits for the whole floor.
class _ReadyCard extends ConsumerWidget {
  const _ReadyCard({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arSessionProvider);
    final d = s.download;
    final floor = s.floor;
    final firstBuild = (floor == null || floor.builds.isEmpty) ? null : floor.builds.first;
    // A stopped download still lets the user start: whatever is on the
    // phone renders, and the rest resumes when there's signal.
    final ready = d.focusReady || d.done || (floor?.fromCache ?? false) || d.error != null;
    final markers = floor?.activeMarkers.length ?? 0;
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(
                        value: d.totalBytes == 0 ? null : d.fraction,
                        strokeWidth: 5,
                        color: FeColors.primary,
                        backgroundColor: FeColors.line,
                      ),
                    ),
                    Icon(ready ? ArIcons.check : ArIcons.download, color: FeColors.primary),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.titleMedium(arTr(context, 'ar.ready.title', [floor?.floorName ?? '']), weight: FontWeight.w800),
                    if (firstBuild != null)
                      AppText.bodySmall(
                        arTr(context, 'ar.ready.build', [firstBuild.version ?? '-', floor?.buildingName ?? '']),
                        color: FeColors.ink2,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ReadyRow(
            done: (d.focusReady && d.focusTotalBytes > 0) || (floor?.fromCache ?? false),
            title: 'ar.ready.around'.getString(context),
            trailing: arMegabytes(context, d.focusTotalBytes == 0 ? (floor?.focusBytes ?? 0) : d.focusTotalBytes),
          ),
          _ReadyRow(done: floor != null, title: 'ar.ready.markers'.getString(context), trailing: '$markers'),
          _ReadyRow(
            done: d.done,
            title: arTr(context, 'ar.ready.rest', [floor?.floorName ?? '']),
            trailing: d.done
                ? arMegabytes(context, d.restBytes)
                : arTr(context, 'ar.ready.streaming', [arMegabytes(context, d.restBytes)]),
            busy: !d.done,
          ),
          if (d.error != null) ...[
            const SizedBox(height: 8),
            ArHintRow(text: d.error!.getString(context)),
          ],
          const SizedBox(height: 10),
          AppText.bodySmall('ar.ready.note'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          ArPrimaryButton(label: 'ar.ready.start'.getString(context), onPressed: ready ? onStart : null, icon: ArIcons.board),
        ],
      ),
    );
  }
}

class _ReadyRow extends StatelessWidget {
  const _ReadyRow({required this.done, required this.title, required this.trailing, this.busy = false});
  final bool done;
  final String title;
  final String trailing;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(color: done ? FeArColors.lockedBg : FeArColors.manualBg, shape: BoxShape.circle),
            child: done
                ? const Icon(ArIcons.check, size: 15, color: FeArColors.lockedIcon)
                : (busy
                      ? const Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(strokeWidth: 2, color: FeColors.primary),
                        )
                      : const SizedBox.shrink()),
          ),
          const SizedBox(width: 12),
          Expanded(child: AppText.bodyMedium(title, weight: FontWeight.w600)),
          AppText.bodySmall(trailing, color: FeColors.ink2),
        ],
      ),
    );
  }
}

/// S1: "Place the model" — no boards near, snap two corners; tap the one
/// you're standing near on the mini plan.
class _StartCard extends ConsumerWidget {
  const _StartCard({required this.setup, required this.session, required this.plan, required this.tablet});
  final ArSetupState setup;
  final ArSessionState session;
  final Widget plan;
  final bool tablet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final a = setup.chosenA;
    final n = a == null ? 1 : setup.ranked.indexOf(a) + 1;
    final contextLine = _contextLine(context, session);
    final hasBoards = (session.floor?.activeMarkers.length ?? 0) > 0;
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (contextLine != null) ...[
            ArEyebrow(contextLine),
            const SizedBox(height: 4),
          ],
          AppText.title('ar.start.title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium(
            (hasBoards ? 'ar.start.body_boards' : 'ar.start.body').getString(context),
            color: FeColors.ink2,
          ),
          const SizedBox(height: 12),
          SizedBox(height: tablet ? 220 : 190, child: plan),
          const SizedBox(height: 10),
          if (a != null)
            Row(
              children: [
                const Icon(ArIcons.pin, size: 16, color: FeColors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: AppText.bodySmall(
                    arTr(context, 'ar.start.chosen', [n, a.label]),
                    weight: FontWeight.w700,
                    color: FeColors.ink,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 4),
          AppText.bodySmall('ar.start.hint'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          ArPrimaryButton(
            label: arTr(context, 'ar.start.go', [n]),
            icon: ArIcons.corner,
            onPressed: a == null ? null : ctrl.startCornerA,
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: hasBoards ? () => ctrl.chooseMethod(ArPlaceMethod.board) : ctrl.otherMethod,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: AppText.label(
              (hasBoards ? 'ar.start.scan_instead' : 'ar.common.other_method').getString(context),
              color: FeColors.primary,
              weight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

String? _contextLine(BuildContext context, ArSessionState s) {
  final args = s.args;
  if (args == null) return null;
  final parts = <String>[
    if (args.workOrderId != null) arTr(context, 'ar.start.for_work_order'),
    if (s.target != null) s.target!.displayName,
    ?args.spaceName,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// S2 / TabSnap / PhSnap: aim the pin at corner A.
class _CornerACard extends ConsumerWidget {
  const _CornerACard({required this.setup, required this.session, this.plan, this.planHeight = 180});
  final ArSetupState setup;
  final ArSessionState session;
  final Widget? plan;
  final double planHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final a = setup.chosenA;
    final snapped = setup.snapped;
    final lidarHidden = snapped != null && snapped.method == 'lidar';
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: AppText.titleMedium('ar.corner.one_of_two'.getString(context), weight: FontWeight.w800)),
              const ArStepDots(count: 2, index: 0),
            ],
          ),
          if (plan != null) ...[
            const SizedBox(height: 10),
            SizedBox(height: planHeight, child: plan),
            const SizedBox(height: 4),
            AppText.caption('ar.corner.tap_other'.getString(context), color: FeColors.ink2),
          ],
          const SizedBox(height: 10),
          AppText.bodyMedium(
            a == null ? 'ar.corner.aim'.getString(context) : arTr(context, 'ar.corner.aim_at', [a.label]),
            color: FeColors.ink2,
          ),
          if (session.gridVisible && (session.floor?.gridLines.isNotEmpty ?? false)) ...[
            const SizedBox(height: 6),
            AppText.bodySmall('ar.corner.grid_hint'.getString(context), color: FeColors.ink2),
          ],
          if (snapped != null) ...[
            const SizedBox(height: 10),
            ArSuccessRow(
              text: arTr(context, 'ar.corner.snapped_via', [_shape(context, snapped.kind, snapped.angleDeg), _method(context, snapped.method)]),
            ),
            if (lidarHidden) ...[
              const SizedBox(height: 6),
              AppText.bodySmall('ar.corner.lidar_note'.getString(context), color: FeColors.ink2),
            ],
          ] else if (!session.demo) ...[
            const SizedBox(height: 10),
            ArHintRow(text: 'ar.corner.coach_edge'.getString(context)),
            const SizedBox(height: 6),
            AppText.bodySmall('ar.corner.coach_texture'.getString(context), color: FeColors.ink2),
          ],
          if (!session.demo && setup.offerWallTaps) ...[
            const SizedBox(height: 10),
            _WallTapsOffer(onStart: ctrl.startWallTaps),
          ],
          if (session.demo && snapped == null) ...[
            const SizedBox(height: 8),
            _DemoButton(label: 'ar.demo.snap'.getString(context), onTap: ctrl.demoSnap),
          ],
          const SizedBox(height: 14),
          ArPrimaryButton(label: 'ar.corner.use'.getString(context), icon: ArIcons.check, onPressed: snapped == null ? null : ctrl.useCornerA),
          const SizedBox(height: 4),
          TextButton(
            onPressed: ctrl.otherMethod,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: AppText.label('ar.common.other_method'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// S3: corner B, matched automatically. Suggests a good one; asks with two
/// big buttons only when two candidates are equally close.
class _CornerBCard extends ConsumerWidget {
  const _CornerBCard({required this.setup, required this.session, this.plan});
  final ArSetupState setup;
  final ArSessionState session;
  final Widget? plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final a = session.floor?.corners.where((c) => c.id == setup.cornerAId).toList() ?? const <CornerCandidate>[];
    final first = a.isEmpty ? null : a.first;
    final suggestion = setup.suggestedB;
    final matched = setup.matchedB;
    final ambiguous = setup.ambiguousB;
    final distance = (first != null && matched != null) ? first.posTile.distanceXzTo(matched.posTile) : null;
    final suggestDist = (first != null && suggestion != null) ? first.posTile.distanceXzTo(suggestion.posTile) : null;

    Widget body;
    if (ambiguous.length >= 2) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium('ar.corner.which'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 10),
          for (final m in ambiguous.take(2)) ...[
            ArPrimaryButton(
              label: m.candidate.label,
              color: FeColors.ink,
              onPressed: () => ctrl.useCornerB(m.candidate),
            ),
            const SizedBox(height: 8),
          ],
        ],
      );
    } else if (matched != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium('ar.corner.b_found'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium(
            distance == null
                ? 'ar.corner.b_found_sub_plain'.getString(context)
                : arTr(context, 'ar.corner.b_found_sub', [arMetres(context, distance)]),
            color: FeColors.ink2,
          ),
          if (setup.tooCloseB) ...[
            const SizedBox(height: 8),
            ArHintRow(text: 'ar.corner.too_close'.getString(context)),
          ],
          const SizedBox(height: 14),
          ArPrimaryButton(label: 'ar.corner.use'.getString(context), icon: ArIcons.check, onPressed: ctrl.useCornerB),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: AppText.titleMedium('ar.corner.two_of_two'.getString(context), weight: FontWeight.w800)),
              const ArStepDots(count: 2, index: 1),
            ],
          ),
          const SizedBox(height: 6),
          AppText.bodyMedium(
            suggestion == null || suggestDist == null
                ? 'ar.corner.b_any'.getString(context)
                : arTr(context, 'ar.corner.b_suggest', [suggestion.label, arMetres(context, suggestDist)]),
            color: FeColors.ink2,
          ),
          if (setup.noMatchB) ...[
            const SizedBox(height: 8),
            ArHintRow(text: 'ar.corner.no_match'.getString(context)),
          ] else if (setup.tooCloseB) ...[
            const SizedBox(height: 8),
            ArHintRow(text: 'ar.corner.too_close'.getString(context)),
          ],
          if (!session.demo && setup.offerWallTaps) ...[
            const SizedBox(height: 10),
            _WallTapsOffer(onStart: ctrl.startWallTaps),
          ],
          if (session.demo) ...[
            const SizedBox(height: 8),
            _DemoButton(label: 'ar.demo.snap_b'.getString(context), onTap: ctrl.demoSnap),
          ],
        ],
      );
    }

    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: ArSessionBadge(),
          ),
          if (plan != null) ...[
            const SizedBox(height: 10),
            SizedBox(height: 170, child: plan),
          ],
          // One rough corner (floor tap / wall taps) sets a rough heading:
          // ask for a far point before anything else.
          if (!session.demo && setup.wantsBaseline && ambiguous.isEmpty) ...[
            const SizedBox(height: 12),
            ArHintRow(text: 'ar.baseline.nudge'.getString(context)),
            const SizedBox(height: 8),
            ArSecondaryButton(label: 'ar.baseline.start'.getString(context), icon: ArIcons.crosshair, onPressed: ctrl.startBaseline),
          ] else if (setup.baselineDone) ...[
            const SizedBox(height: 12),
            ArSuccessRow(text: 'ar.baseline.done_short'.getString(context)),
          ],
          const SizedBox(height: 12),
          body,
          const SizedBox(height: 4),
          TextButton(
            onPressed: ctrl.carryOn,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: AppText.label('ar.corner.carry_on_amber'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Pointing at a board, before the engine locks on.
class _BoardScanCard extends ConsumerWidget {
  const _BoardScanCard({required this.session});
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final focus = session.args?.focusCode;
    final focusLabel = focus == null ? null : session.floor?.markerByCode(focus)?.label;
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium(
            focusLabel == null ? 'ar.board.title'.getString(context) : arTr(context, 'ar.board.title_label', [focusLabel]),
            weight: FontWeight.w800,
          ),
          const SizedBox(height: 4),
          AppText.bodyMedium('ar.board.body'.getString(context), color: FeColors.ink2),
          if (session.demo) ...[
            const SizedBox(height: 10),
            _DemoButton(label: 'ar.demo.scan_board'.getString(context), onTap: () => ctrl.demoScanBoard()),
            const SizedBox(height: 6),
            _DemoButton(label: 'ar.demo.scan_board_awkward'.getString(context), onTap: () => ctrl.demoScanBoard(awkward: true)),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: ctrl.otherMethod,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: AppText.label('ar.common.other_method'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// M3: "Hold still", with coaching chips that turn green by themselves.
class _BoardLockCard extends ConsumerWidget {
  const _BoardLockCard({required this.setup});
  final ArSetupState setup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = setup.sighting;
    final ctrl = ref.read(arSetupProvider.notifier);
    final demo = ref.watch(arSessionProvider.select((s) => s.demo));
    final chips = <Widget>[
      _CoachChip(
        ok: m?.distanceOk ?? true,
        text: m == null
            ? '—'
            : (m.distanceOk
                  ? arMetres(context, m.distanceM)
                  : (m.distanceM > 2 ? 'ar.lock.closer'.getString(context) : 'ar.lock.back'.getString(context))),
      ),
      _CoachChip(ok: m?.squareOn ?? true, text: (m?.squareOn ?? true) ? 'ar.lock.square'.getString(context) : 'ar.lock.face_it'.getString(context)),
      _CoachChip(ok: m?.steady ?? true, text: (m?.steady ?? true) ? 'ar.lock.steady'.getString(context) : 'ar.lock.hold'.getString(context)),
    ];
    final failing = m != null && !m.acceptable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArCameraTitle('ar.lock.hold_still'.getString(context)),
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: chips),
        const SizedBox(height: 14),
        AppText.bodySmall(
          (failing ? 'ar.lock.fix_hint' : 'ar.lock.about_a_second').getString(context),
          color: FeArColors.onGlassMuted,
          align: TextAlign.center,
        ),
        if (failing) ...[
          const SizedBox(height: 12),
          ArOnCameraButton(
            label: demo ? 'ar.demo.scan_board'.getString(context) : 'ar.lock.try_again'.getString(context),
            icon: demo ? ArIcons.demo : ArIcons.board,
            onPressed: demo ? () => ctrl.demoScanBoard() : ctrl.retryLock,
          ),
        ],
      ],
    );
  }
}

class _CoachChip extends StatelessWidget {
  const _CoachChip({required this.ok, required this.text});
  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) => ArGlassChip(
    text: text,
    icon: ok ? ArIcons.check : ArIcons.warning,
    iconColor: ok ? FeColors.success : FeColors.warning,
  );
}

/// M4: amber with one board; a radar points at the next one.
class _AlignedCard extends ConsumerWidget {
  const _AlignedCard({required this.setup, required this.session});
  final ArSetupState setup;
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final next = setup.nextBoard;
    final here = session.cameraTile ?? (session.observations.isEmpty ? null : session.observations.last.bTile);
    double? bearing;
    double? distance;
    String? dirKey;
    if (next != null && here != null) {
      distance = here.distanceXzTo(next.posTile);
      final fwd = session.forwardTileXz ?? _facingFromLastBoard(session);
      if (fwd != null) {
        final to = Vec2(next.posTile.x - here.x, next.posTile.z - here.z);
        bearing = math.atan2(fwd.x * to.y - fwd.y * to.x, fwd.x * to.x + fwd.y * to.y);
        final deg = bearing * 180 / math.pi;
        dirKey = deg.abs() <= 45
            ? 'ar.dir.ahead'
            : deg.abs() >= 135
            ? 'ar.dir.behind'
            : (deg > 0 ? 'ar.dir.right' : 'ar.dir.left');
      }
    }
    return ArCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ArRadar(bearingRad: bearing),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.titleMedium('ar.aligned.title'.getString(context), weight: FontWeight.w800),
                    const SizedBox(height: 3),
                    if (next != null)
                      AppText.bodyMedium(
                        distance == null
                            ? arTr(context, 'ar.aligned.next_plain', [next.label])
                            : arTr(context, 'ar.aligned.next', [
                                next.label,
                                arMetres(context, distance),
                                (dirKey ?? 'ar.dir.nearby').getString(context),
                                arTr(context, arWallKey(next.normalTile.x, next.normalTile.z)),
                              ]),
                        color: FeColors.ink2,
                      )
                    else
                      AppText.bodyMedium('ar.aligned.no_next'.getString(context), color: FeColors.ink2),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AppText.bodySmall('ar.aligned.why'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          Row(
            children: [
              if (next != null) ...[
                Expanded(
                  flex: 13,
                  child: ArPrimaryButton(
                    label: arTr(context, 'ar.aligned.scan', [next.label]),
                    onPressed: session.demo ? ctrl.demoScanBoard : ctrl.retryLock,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(flex: 10, child: ArSecondaryButton(label: 'ar.aligned.carry_on'.getString(context), onPressed: ctrl.goToWork)),
            ],
          ),
          if (session.demo && next != null) ...[
            const SizedBox(height: 6),
            AppText.caption('ar.demo.scan_hint'.getString(context), color: FeColors.ink2, align: TextAlign.center),
          ],
        ],
      ),
    );
  }

  /// Without a camera pose, assume the user faces the board they scanned.
  Vec2? _facingFromLastBoard(ArSessionState s) {
    for (final o in s.observations.reversed) {
      if (o is MarkerObs) return Vec2(-o.normalTile.x, -o.normalTile.z).normalized;
    }
    return null;
  }
}

/// S4: green. Offer "Make next time one scan" with the ghost outline.
class _LockedCard extends ConsumerWidget {
  const _LockedCard({required this.setup});
  final ArSetupState setup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final hasGhost = setup.ghost != null;
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(alignment: AlignmentDirectional.centerStart, child: ArSessionBadge()),
          const SizedBox(height: 12),
          AppText.titleMedium((hasGhost ? 'ar.locked.leave_title' : 'ar.locked.title').getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium((hasGhost ? 'ar.locked.leave_body' : 'ar.locked.body').getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          if (hasGhost)
            Row(
              children: [
                Expanded(
                  flex: 14,
                  child: ArPrimaryButton(label: 'ar.locked.scan_spare'.getString(context), icon: ArIcons.board, onPressed: ctrl.leaveBoard),
                ),
                const SizedBox(width: 10),
                Expanded(flex: 10, child: ArSecondaryButton(label: 'ar.common.not_now'.getString(context), onPressed: ctrl.notNow)),
              ],
            )
          else
            ArPrimaryButton(label: 'ar.locked.start_work'.getString(context), icon: ArIcons.next, onPressed: ctrl.goToWork),
          const SizedBox(height: 4),
          TextButton(
            onPressed: ctrl.startNudge,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: AppText.label('ar.locked.fine_tune'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// The ghost is up; waiting for the spare to be scanned.
class _LeaveBoardCard extends ConsumerWidget {
  const _LeaveBoardCard({required this.session});
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium('ar.leave.title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium('ar.leave.body'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 10),
          const _Step(n: 1, key: ValueKey('leave1')),
          const _Step(n: 2, key: ValueKey('leave2')),
          const _Step(n: 3, key: ValueKey('leave3')),
          if (session.demo) ...[
            const SizedBox(height: 8),
            _DemoButton(label: 'ar.demo.scan_spare'.getString(context), onTap: ctrl.demoScanSpare),
          ],
          const SizedBox(height: 8),
          ArSecondaryButton(label: 'ar.common.not_now'.getString(context), onPressed: ctrl.notNow),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({super.key, required this.n});
  final int n;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: FeColors.infoSoft, shape: BoxShape.circle),
            child: AppText.caption('$n', color: FeColors.primary, weight: FontWeight.w800),
          ),
          const SizedBox(width: 10),
          Expanded(child: AppText.bodySmall('ar.leave.step$n'.getString(context), color: FeColors.ink)),
        ],
      ),
    );
  }
}

/// S5: the guided single-axis nudge, 5 mm per tap.
class _NudgeCard extends ConsumerWidget {
  const _NudgeCard({required this.session});
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(alignment: AlignmentDirectional.centerStart, child: ArSessionBadge()),
          const SizedBox(height: 12),
          AppText.titleMedium('ar.nudge.title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium('ar.nudge.body'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          Row(
            children: [
              _NudgeButton(icon: ArIcons.minus, label: 'ar.nudge.away'.getString(context), onTap: () => ctrl.nudge(-1)),
              Expanded(
                child: Column(
                  children: [
                    AppText.headlineSmall(arSignedCentimetres(context, session.nudgeM), weight: FontWeight.w800),
                    AppText.caption('ar.nudge.step'.getString(context), color: FeColors.ink2),
                  ],
                ),
              ),
              _NudgeButton(icon: ArIcons.plus, label: 'ar.nudge.toward'.getString(context), onTap: () => ctrl.nudge(1)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: ArSecondaryButton(label: 'ar.nudge.reset'.getString(context), onPressed: session.nudgeM == 0 ? null : ctrl.resetNudge)),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: ArPrimaryButton(label: 'ar.common.done'.getString(context), onPressed: ctrl.doneNudge)),
            ],
          ),
        ],
      ),
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: FeArColors.manualBg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            ArHaptics.snap();
            onTap();
          },
          child: SizedBox(width: 64, height: 64, child: Icon(icon, size: 26, color: FeColors.ink)),
        ),
      ),
    );
  }
}

/// Red: the observations disagree by more than 5 cm.
class _MismatchCard extends ConsumerWidget {
  const _MismatchCard({required this.session});
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(alignment: AlignmentDirectional.centerStart, child: ArSessionBadge()),
          const SizedBox(height: 12),
          AppText.titleMedium('ar.mismatch.title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium('ar.mismatch.body'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          ArPrimaryButton(label: 'ar.mismatch.resnap'.getString(context), icon: ArIcons.realign, onPressed: () => ctrl.reAlign()),
          const SizedBox(height: 8),
          ArSecondaryButton(label: 'ar.mismatch.carry_on'.getString(context), onPressed: ctrl.goToWork),
        ],
      ),
    );
  }
}

/// "This board is on Level 4" — switch floors or stay.
class _OtherFloorPrompt extends ConsumerWidget {
  const _OtherFloorPrompt({required this.setup});
  final ArSetupState setup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    return ColoredBox(
      color: Colors.black45,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ArCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText.titleMedium(arTr(context, 'ar.other_floor.title', [setup.otherFloorName ?? '']), weight: FontWeight.w800),
                  const SizedBox(height: 4),
                  AppText.bodyMedium('ar.other_floor.body'.getString(context), color: FeColors.ink2),
                  const SizedBox(height: 14),
                  ArPrimaryButton(
                    label: arTr(context, 'ar.other_floor.switch', [setup.otherFloorName ?? '']),
                    onPressed: () => context.pushReplacement(Routes.arMarker(setup.otherFloorCode!)),
                  ),
                  const SizedBox(height: 8),
                  ArSecondaryButton(label: 'ar.other_floor.stay'.getString(context), onPressed: ctrl.dismissOtherFloor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Walls not detected — tap each wall 3 times near the corner."
class _WallTapsOffer extends StatelessWidget {
  const _WallTapsOffer({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArHintRow(text: 'ar.corner.coach_no_walls'.getString(context)),
        const SizedBox(height: 8),
        ArSecondaryButton(label: 'ar.walls.start'.getString(context), icon: ArIcons.crosshair, onPressed: onStart),
      ],
    );
  }
}

/// Wall taps: 3–5 taps on each wall near the corner; Dart fits the corner.
class _WallTapsCard extends ConsumerWidget {
  const _WallTapsCard({required this.setup});
  final ArSetupState setup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final onWallB = setup.wallIndex == 1;
    final n = setup.currentTaps.length;
    final enough = n >= WallFitter.minTaps;
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText.titleMedium(
                  arTr(context, 'ar.walls.title', [setup.wallIndex + 1]),
                  weight: FontWeight.w800,
                ),
              ),
              ArStepDots(count: 2, index: setup.wallIndex),
            ],
          ),
          const SizedBox(height: 4),
          AppText.bodyMedium(
            (onWallB ? 'ar.walls.body_b' : 'ar.walls.body_a').getString(context),
            color: FeColors.ink2,
          ),
          const SizedBox(height: 10),
          _TapCount(label: arTr(context, 'ar.walls.wall_n', [1]), count: setup.tapsA.length, active: !onWallB),
          _TapCount(label: arTr(context, 'ar.walls.wall_n', [2]), count: setup.tapsB.length, active: onWallB),
          const SizedBox(height: 6),
          AppText.bodySmall('ar.walls.hint'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 14),
          ArPrimaryButton(
            label: (onWallB ? 'ar.walls.fit' : 'ar.walls.next').getString(context),
            icon: onWallB ? ArIcons.check : ArIcons.next,
            busy: setup.measuring,
            onPressed: !enough ? null : (onWallB ? ctrl.fitWallCorner : ctrl.nextWall),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ArSecondaryButton(
                  label: 'ar.walls.undo'.getString(context),
                  onPressed: (n == 0 && !onWallB) ? null : ctrl.undoWallTap,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: ArSecondaryButton(label: 'ar.common.back'.getString(context), onPressed: ctrl.cancelWallTaps)),
            ],
          ),
        ],
      ),
    );
  }
}

class _TapCount extends StatelessWidget {
  const _TapCount({required this.label, required this.count, required this.active});
  final String label;
  final int count;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final done = count >= WallFitter.minTaps;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: AppText.bodyMedium(label, weight: active ? FontWeight.w800 : FontWeight.w500, color: active ? FeColors.ink : FeColors.ink2),
          ),
          for (var i = 0; i < WallFitter.maxTaps; i++)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < count ? (done ? FeColors.success : FeColors.primary) : FeColors.line,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Long baseline: tap a wall's base 2–5 m from corner 1 to fix the heading.
class _BaselineCard extends ConsumerWidget {
  const _BaselineCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arSetupProvider.notifier);
    final measuring = ref.watch(arSetupProvider.select((s) => s.measuring));
    return ArCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium('ar.baseline.title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium('ar.baseline.body'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 8),
          AppText.bodySmall('ar.baseline.hint'.getString(context), color: FeColors.ink2),
          if (measuring) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 3, color: FeColors.primary, backgroundColor: FeColors.line),
          ],
          const SizedBox(height: 14),
          ArSecondaryButton(label: 'ar.common.back'.getString(context), onPressed: ctrl.cancelBaseline),
        ],
      ),
    );
  }
}

class _DemoButton extends StatelessWidget {
  const _DemoButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: FeArColors.placedFg,
        side: const BorderSide(color: FeColors.warning, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: const Icon(ArIcons.demo, size: 16),
      label: AppText.label(label, color: FeArColors.placedFg, weight: FontWeight.w700),
    );
  }
}

/// The setup card while scanning: one slim bar, so the camera stays clear.
class _CollapsedCardBar extends StatelessWidget {
  const _CollapsedCardBar({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ArGlassChip(text: 'ar.setup.double_tap_focus'.getString(context), icon: ArIcons.focus),
        ),
        const SizedBox(height: 8),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.keyboard_arrow_up_rounded, color: FeColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppText.label('ar.setup.show_steps'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HideCardChip extends StatelessWidget {
  const _HideCardChip({required this.onHide});
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onHide,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: FeColors.ink2),
              const SizedBox(width: 4),
              AppText.caption('ar.setup.hide_steps'.getString(context), color: FeColors.ink2, weight: FontWeight.w700),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ar/alignment_estimator.dart';
import '../../../core/ar/ar_engine.dart' show ArTracking;
import '../../../core/ar/corner_matcher.dart';
import '../../../core/ar/marker_code.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_setup_controller.dart';
import '../../../state/providers.dart' show arPackStoreProvider;
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';

/// The setup coach (owner, 2026-10-06: "nothing really works … always 'that
/// corner didn't place the model'"): ONE instruction at a time on the
/// camera, in large text, with the reason and the next step for every
/// failure. It replaces the stack of chips (target, snapped, room scan,
/// tracking) and the setup toasts that piled up over the corner the user
/// was aiming at.
///
/// [setupCueFor] is a pure function of [SetupCoachInputs] so each step's
/// wording is unit-tested; [ArSetupCoachStrip] feeds it from the providers.
///
/// ```mermaid
/// flowchart TD
///   T{tracking ok?} -- no --> TL[Hold still / more light]
///   T -- yes --> S{step}
///   S -- start --> P[Pick the corner on the plan]
///   S -- cornerA --> PR{problem?}
///   PR -- yes --> W[reason + next step]
///   PR -- no --> SC{scan < 60%?}
///   SC -- yes --> SW[Move slowly across the walls — n%]
///   SC -- no --> SN{snapped?}
///   SN -- yes --> U[Tap Use this corner]
///   SN -- no --> WA[Walk to #n, then aim where the walls meet]
///   S -- cornerB --> B[Second corner, 3 m+ away, arrow]
///   S -- locked/aligned --> OK[Model placed — walk around · Re-align]
/// ```

enum SetupCueIcon { scan, walk, aim, hold, tap, second, done, warn, dark, board, plan }

enum SetupCueTone { info, progress, success, warning }

/// A button the strip itself offers.
enum SetupCueAction { none, realign, wallTaps }

/// Everything the coach looks at, flattened so tests need no providers.
class SetupCoachInputs {
  const SetupCoachInputs({
    required this.step,
    this.tracking = ArTracking.tracking,
    this.trackingReason,
    this.scanPercent,
    this.snapped = false,
    this.snappedShape,
    this.snappedAngle,
    this.problem,
    this.problemShape,
    this.wallsMissing = false,
    this.tooCloseB = false,
    this.noMatchB = false,
    this.matchedB = false,
    this.ambiguousB = false,
    this.wantsBaseline = false,
    this.quality = AlignmentQuality.none,
    this.targetPin,
    this.targetLabel,
    this.targetKind,
    this.secondPin,
    this.secondLabel,
    this.secondBearingDeg,
    this.secondDistanceM,
    this.aimingFor = Duration.zero,
    this.wallIndex = 0,
    this.demo = false,
  });

  final ArSetupStep step;
  final String tracking;
  final String? trackingReason;

  /// Room-scan coverage 0–100, or null when the device doesn't report it.
  final int? scanPercent;
  final bool snapped;
  final String? snappedShape;
  final int? snappedAngle;
  final ArCornerProblem? problem;
  final String? problemShape;
  final bool wallsMissing;
  final bool tooCloseB;
  final bool noMatchB;
  final bool matchedB;
  final bool ambiguousB;
  final bool wantsBaseline;
  final AlignmentQuality quality;
  final int? targetPin;
  final String? targetLabel;
  final String? targetKind;
  final int? secondPin;
  final String? secondLabel;

  /// Turn needed to face corner 2 (+ = to the right), once placed.
  final double? secondBearingDeg;
  final double? secondDistanceM;

  /// How long the corner-A step has been aiming without a snap.
  final Duration aimingFor;
  final int wallIndex;
  final bool demo;

  factory SetupCoachInputs.from(ArSetupState setup, ArSessionState s, {Duration aimingFor = Duration.zero}) {
    final a = setup.chosenA;
    final b = setup.suggestedB;
    double? bearing;
    double? dist;
    final cam = s.cameraTile;
    final fwd = s.forwardTileXz;
    if (b != null && cam != null && fwd != null && fwd.length > 1e-6) {
      final v = b.posTile.xz - cam.xz;
      dist = v.length;
      if (dist > 0.2) {
        // Plan x right, z down: a positive cross product is clockwise on the
        // plan, i.e. a turn to the right.
        final cross = fwd.x * v.y - fwd.y * v.x;
        bearing = math.atan2(cross, fwd.dot(v)) * 180 / math.pi;
      }
    }
    return SetupCoachInputs(
      step: setup.step,
      tracking: s.tracking,
      trackingReason: s.trackingReason,
      scanPercent: (s.capabilities?.scanOverlay ?? false) && s.scan != null ? s.scan!.percent : null,
      snapped: setup.snapped != null,
      snappedShape: setup.snapped == null ? null : CornerMatcher.shapeOf(setup.snapped!.kind),
      snappedAngle: setup.snapped?.angleDeg.round(),
      problem: setup.cornerProblem,
      problemShape: setup.problemShape,
      wallsMissing: setup.wallsMissing,
      tooCloseB: setup.tooCloseB,
      noMatchB: setup.noMatchB,
      matchedB: setup.matchedB != null,
      ambiguousB: setup.ambiguousB.length >= 2,
      wantsBaseline: setup.wantsBaseline,
      quality: s.quality,
      targetPin: setup.pinOf(a),
      targetLabel: a?.label,
      targetKind: a?.kind,
      secondPin: setup.pinOf(b),
      secondLabel: b?.label,
      secondBearingDeg: bearing,
      secondDistanceM: dist,
      aimingFor: aimingFor,
      wallIndex: setup.wallIndex,
      demo: s.demo,
    );
  }
}

/// One instruction: an i18n key with its args, plus how to show it.
class SetupCue {
  const SetupCue(
    this.key, {
    this.args = const [],
    this.icon = SetupCueIcon.aim,
    this.tone = SetupCueTone.info,
    this.progress,
    this.arrowDeg,
    this.action = SetupCueAction.none,
    this.guideStep = 2,
  });

  final String key;
  final List<Object> args;
  final SetupCueIcon icon;
  final SetupCueTone tone;

  /// 0–1 for a progress bar (room scan).
  final double? progress;

  /// Rotate a "go this way" arrow by this many degrees (+ = right).
  final double? arrowDeg;
  final SetupCueAction action;

  /// Which of the guide's three steps this belongs to (0 stand in the room,
  /// 1 scan, 2 corners) — the "?" button opens the guide there.
  final int guideStep;
}

/// Room-scan coverage below this asks for more sweeping before aiming
/// (snaps need both walls and the floor measured near the corner).
const kCoachScanReadyPercent = 60;

/// Seconds of "walk to the corner" before the coach switches to "aim".
const kCoachWalkSeconds = 6;

/// The single instruction for this moment. Order matters: tracking first
/// (nothing works without it), then a problem the user must act on, then
/// the step's happy path.
SetupCue setupCueFor(SetupCoachInputs i) {
  // Tracking lost or weak: the reason decides the advice.
  if (!i.demo && (i.tracking == ArTracking.limited || i.tracking == ArTracking.initializing)) {
    return switch (i.trackingReason) {
      'insufficientLight' => const SetupCue('ar.coach.cue.too_dark', icon: SetupCueIcon.dark, tone: SetupCueTone.warning, guideStep: 1),
      'excessiveMotion' => const SetupCue('ar.coach.cue.too_fast', icon: SetupCueIcon.hold, tone: SetupCueTone.warning, guideStep: 1),
      'insufficientFeatures' => const SetupCue('ar.coach.cue.plain_walls', icon: SetupCueIcon.scan, tone: SetupCueTone.warning, guideStep: 1),
      _ when i.tracking == ArTracking.initializing => const SetupCue('ar.coach.cue.starting', icon: SetupCueIcon.hold, guideStep: 1),
      _ => const SetupCue('ar.coach.cue.tracking_lost', icon: SetupCueIcon.hold, tone: SetupCueTone.warning, guideStep: 1),
    };
  }

  switch (i.step) {
    case ArSetupStep.choose:
      return const SetupCue('ar.coach.cue.choose', icon: SetupCueIcon.plan, guideStep: 0);
    case ArSetupStep.start:
      return SetupCue(
        'ar.coach.cue.pick',
        args: [i.targetPin ?? 1],
        icon: SetupCueIcon.plan,
        guideStep: 0,
      );
    case ArSetupStep.cornerA:
      final problem = i.problem;
      if (problem != null) {
        final inside = i.problemShape == 'inside';
        return switch (problem) {
          ArCornerProblem.otherShapeNearby => SetupCue(
              inside ? 'ar.coach.cue.shape_inside' : 'ar.coach.cue.shape_outside',
              icon: SetupCueIcon.warn,
              tone: SetupCueTone.warning,
            ),
          ArCornerProblem.noneOfShape => const SetupCue(
              'ar.coach.cue.wrong_model',
              icon: SetupCueIcon.warn,
              tone: SetupCueTone.warning,
              guideStep: 0,
            ),
          ArCornerProblem.notPlaced => const SetupCue('ar.coach.cue.not_placed', icon: SetupCueIcon.warn, tone: SetupCueTone.warning),
        };
      }
      if (i.snapped) {
        return SetupCue(
          i.snappedShape == 'inside' ? 'ar.coach.cue.snapped_inside' : 'ar.coach.cue.snapped_outside',
          args: [i.snappedAngle ?? 90],
          icon: SetupCueIcon.tap,
          tone: SetupCueTone.success,
        );
      }
      if (i.wallsMissing) {
        return const SetupCue('ar.coach.cue.no_walls', icon: SetupCueIcon.warn, tone: SetupCueTone.warning, action: SetupCueAction.wallTaps, guideStep: 1);
      }
      final pct = i.scanPercent;
      if (!i.demo && pct != null && pct < kCoachScanReadyPercent) {
        return SetupCue('ar.coach.cue.scan', args: [pct], icon: SetupCueIcon.scan, tone: SetupCueTone.progress, progress: pct / 100, guideStep: 1);
      }
      if (i.aimingFor.inSeconds < kCoachWalkSeconds) {
        return SetupCue(
          i.targetKind == 'inside' ? 'ar.coach.cue.walk_inside' : 'ar.coach.cue.walk_column',
          args: [i.targetPin ?? 1],
          icon: SetupCueIcon.walk,
        );
      }
      return SetupCue(
        i.targetKind == 'inside' ? 'ar.coach.cue.aim_inside' : 'ar.coach.cue.aim_column',
        icon: SetupCueIcon.aim,
      );
    case ArSetupStep.cornerB:
      if (i.ambiguousB) return const SetupCue('ar.coach.cue.which', icon: SetupCueIcon.tap);
      if (i.matchedB && i.tooCloseB) {
        return const SetupCue('ar.coach.cue.too_close', icon: SetupCueIcon.warn, tone: SetupCueTone.warning);
      }
      if (i.matchedB) return const SetupCue('ar.coach.cue.b_found', icon: SetupCueIcon.tap, tone: SetupCueTone.success);
      if (i.noMatchB) {
        return SetupCue('ar.coach.cue.b_no_match', args: [i.secondPin ?? 2], icon: SetupCueIcon.warn, tone: SetupCueTone.warning);
      }
      if (i.tooCloseB) {
        return const SetupCue('ar.coach.cue.too_close', icon: SetupCueIcon.warn, tone: SetupCueTone.warning);
      }
      if (i.wantsBaseline) return const SetupCue('ar.coach.cue.baseline', icon: SetupCueIcon.walk);
      if (i.wallsMissing) {
        return const SetupCue('ar.coach.cue.no_walls', icon: SetupCueIcon.warn, tone: SetupCueTone.warning, action: SetupCueAction.wallTaps, guideStep: 1);
      }
      if (i.secondPin != null && i.secondDistanceM != null) {
        return SetupCue(
          'ar.coach.cue.second_dir',
          args: [i.secondPin!, i.secondDistanceM!.toStringAsFixed(1)],
          icon: SetupCueIcon.second,
          arrowDeg: i.secondBearingDeg,
        );
      }
      return SetupCue('ar.coach.cue.second', args: [i.secondPin ?? 2], icon: SetupCueIcon.second);
    case ArSetupStep.wallTaps:
      return SetupCue('ar.coach.cue.wall_taps', args: [i.wallIndex + 1], icon: SetupCueIcon.tap, guideStep: 1);
    case ArSetupStep.baseline:
      return const SetupCue('ar.coach.cue.baseline', icon: SetupCueIcon.walk);
    case ArSetupStep.boardScan:
      return const SetupCue('ar.coach.cue.board', icon: SetupCueIcon.board);
    case ArSetupStep.boardLock:
      return const SetupCue('ar.coach.cue.hold', icon: SetupCueIcon.hold, tone: SetupCueTone.progress);
    case ArSetupStep.aligned:
    case ArSetupStep.locked:
      return const SetupCue('ar.coach.cue.placed', icon: SetupCueIcon.done, tone: SetupCueTone.success, action: SetupCueAction.realign);
    case ArSetupStep.mismatch:
      return const SetupCue('ar.coach.cue.mismatch', icon: SetupCueIcon.warn, tone: SetupCueTone.warning, action: SetupCueAction.realign);
    case ArSetupStep.nudge:
      return const SetupCue('ar.coach.cue.nudge', icon: SetupCueIcon.aim);
    case ArSetupStep.leaveBoard:
    case ArSetupStep.register:
      return const SetupCue('ar.coach.cue.leave_board', icon: SetupCueIcon.board, tone: SetupCueTone.success);
  }
}

IconData _iconFor(SetupCueIcon i) => switch (i) {
      SetupCueIcon.scan => ArIcons.roomScan,
      SetupCueIcon.walk => ArIcons.next,
      SetupCueIcon.aim => ArIcons.crosshair,
      SetupCueIcon.hold => ArIcons.focus,
      SetupCueIcon.tap => ArIcons.check,
      SetupCueIcon.second => ArIcons.corner,
      SetupCueIcon.done => ArIcons.celebrate,
      SetupCueIcon.warn => ArIcons.warning,
      SetupCueIcon.dark => ArIcons.torch,
      SetupCueIcon.board => ArIcons.board,
      SetupCueIcon.plan => ArIcons.plan,
    };

Color _toneColor(SetupCueTone t) => switch (t) {
      SetupCueTone.info => FeColors.primary,
      SetupCueTone.progress => FeColors.primary,
      SetupCueTone.success => FeColors.success,
      SetupCueTone.warning => FeColors.warning,
    };

/// The one status area at the top of the camera during setup: the current
/// instruction (large), a detail line (the target pin, what snapped, a
/// one-off notice), the scan bar or a direction arrow, an action when the
/// step has one, and "?" for the guide at this step.
class ArSetupCoachStrip extends ConsumerStatefulWidget {
  const ArSetupCoachStrip({super.key});

  @override
  ConsumerState<ArSetupCoachStrip> createState() => _ArSetupCoachStripState();
}

class _ArSetupCoachStripState extends ConsumerState<ArSetupCoachStrip> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);
  Timer? _tick;
  DateTime? _aimSince;
  ArSetupStep? _step;
  var _noticeSeq = 0;
  String? _notice;
  List<Object> _noticeArgs = const [];
  Timer? _noticeTimer;

  @override
  void dispose() {
    _pulse.dispose();
    _tick?.cancel();
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _track(ArSetupState setup) {
    if (setup.step != _step || setup.snapped != null) {
      _step = setup.step;
      _aimSince = setup.step == ArSetupStep.cornerA && setup.snapped == null ? DateTime.now() : null;
      _tick?.cancel();
      _tick = _aimSince == null
          ? null
          : Timer(const Duration(seconds: kCoachWalkSeconds), () {
              if (mounted) setState(() {});
            });
    }
    if (setup.noticeSeq != _noticeSeq) {
      _noticeSeq = setup.noticeSeq;
      _notice = setup.noticeKey;
      _noticeArgs = setup.noticeArgs;
      _noticeTimer?.cancel();
      _noticeTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _notice = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(arSetupProvider);
    final s = ref.watch(arSessionProvider);
    _track(setup);
    final aiming = _aimSince == null ? Duration.zero : DateTime.now().difference(_aimSince!);
    final cue = setupCueFor(SetupCoachInputs.from(setup, s, aimingFor: aiming));
    final detail = _detail(context, setup, s);
    return ArCoachStripView(
      cue: cue,
      detail: detail,
      pulse: _pulse,
      onHelp: () => showArSetupGuide(context, highlight: cue.guideStep),
      onAction: switch (cue.action) {
        SetupCueAction.realign => () => ref.read(arSetupProvider.notifier).reAlign(),
        SetupCueAction.wallTaps => () => ref.read(arSetupProvider.notifier).startWallTaps(),
        SetupCueAction.none => null,
      },
    );
  }

  /// The second line: a one-off notice wins, then what this step is about —
  /// the target pin ("#2 · Column · NW corner"), the matched corner, the
  /// board being locked, the taps so far.
  String? _detail(BuildContext context, ArSetupState setup, ArSessionState s) {
    if (_notice != null) return arTr(context, _notice!, _noticeArgs);
    switch (setup.step) {
      case ArSetupStep.start:
      case ArSetupStep.cornerA:
        final a = setup.chosenA;
        if (a == null) return null;
        final n = setup.pinOf(a);
        return n == null ? a.label : arTr(context, 'ar.corner.chip_a', [n, a.label]);
      case ArSetupStep.cornerB:
        final m = setup.matchedB;
        return m?.label;
      case ArSetupStep.boardLock:
        final code = setup.lockingCode;
        if (code == null) return null;
        return arTr(context, 'ar.lock.locking_onto', [s.floor?.markerByCode(code)?.label ?? MarkerCode.display(code)]);
      case ArSetupStep.wallTaps:
        return arTr(context, 'ar.walls.chip', [setup.wallIndex + 1, setup.currentTaps.length]);
      default:
        return null;
    }
  }
}

/// The strip's look, separate from the providers (widget tests).
class ArCoachStripView extends StatelessWidget {
  const ArCoachStripView({super.key, required this.cue, this.detail, this.pulse, this.onHelp, this.onAction});

  final SetupCue cue;
  final String? detail;
  final Animation<double>? pulse;
  final VoidCallback? onHelp;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    final tone = _toneColor(cue.tone);
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    final icon = Icon(_iconFor(cue.icon), color: tone, size: st.iconSize(22));
    final animatedIcon = pulse == null
        ? icon
        : AnimatedBuilder(
            animation: pulse!,
            builder: (_, child) => Transform.scale(scale: 0.9 + 0.15 * pulse!.value, child: child),
            child: icon,
          );
    return Container(
      key: const ValueKey('ar-coach-strip'),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: st.surface(strong: true),
        borderRadius: BorderRadius.circular(16),
        border: st.border() ?? Border(left: BorderSide(color: tone, width: 4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: animatedIcon),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppText.titleMedium(
                      arTr(context, cue.key, cue.args),
                      key: const ValueKey('ar-coach-text'),
                      color: st.fg,
                      weight: st.weight(FontWeight.w700),
                      style: st.text(titleStyle),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 3),
                      AppText.bodySmall(
                        detail!,
                        color: st.fgMuted,
                        style: st.text(Theme.of(context).textTheme.bodySmall),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (cue.arrowDeg != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6, top: 2),
                  // A map direction, not text: never mirrored for RTL.
                  child: Transform.rotate(
                    key: const ValueKey('ar-coach-arrow'),
                    angle: cue.arrowDeg! * math.pi / 180,
                    child: Icon(Icons.navigation_rounded, color: st.fg, size: 30),
                  ),
                ),
              IconButton(
                key: const ValueKey('ar-coach-help'),
                tooltip: 'ar.coach.help'.getString(context),
                onPressed: onHelp,
                icon: Icon(ArIcons.help, color: st.fg, size: st.iconSize(22)),
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ],
          ),
          if (cue.progress != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: cue.progress!.clamp(0.0, 1.0),
                  minHeight: 6,
                  color: tone,
                  backgroundColor: st.fgMuted.withValues(alpha: 0.25),
                ),
              ),
            ),
          ],
          if (onAction != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('ar-coach-action'),
                onPressed: onAction,
                style: TextButton.styleFrom(minimumSize: const Size(0, 44), foregroundColor: st.fg),
                icon: Icon(cue.action == SetupCueAction.realign ? ArIcons.realign : ArIcons.crosshair, size: 18),
                label: AppText.label(
                  (cue.action == SetupCueAction.realign ? 'ar.coach.action_realign' : 'ar.coach.action_wall_taps').getString(context),
                  color: st.fg,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- the guide

const _guideSteps = [
  (ArIcons.door, 'ar.setup_guide.step1_title', 'ar.setup_guide.step1_body'),
  (ArIcons.roomScan, 'ar.setup_guide.step2_title', 'ar.setup_guide.step2_body'),
  (ArIcons.corner, 'ar.setup_guide.step3_title', 'ar.setup_guide.step3_body'),
];

/// Saved once "Don't show again" is ticked (same `ar_prefs` store as the
/// first-time tips).
const kSetupGuidePref = 'setupGuide:v1';

/// The three-step guide: before the first corner, and from "?" at any time
/// with [highlight] marking where the user is now.
Future<void> showArSetupGuide(BuildContext context, {int? highlight, bool offerDontShow = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: FeColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => ArSetupGuide(highlight: highlight, offerDontShow: offerDontShow),
  );
}

class ArSetupGuide extends ConsumerStatefulWidget {
  const ArSetupGuide({super.key, this.highlight, this.offerDontShow = false});
  final int? highlight;
  final bool offerDontShow;

  @override
  ConsumerState<ArSetupGuide> createState() => _ArSetupGuideState();
}

class _ArSetupGuideState extends ConsumerState<ArSetupGuide> {
  var _dontShow = false;

  Future<void> _close() async {
    if (_dontShow) {
      try {
        await ref.read(arPackStoreProvider).setArPref(kSetupGuidePref, '1');
      } catch (_) {
        // A missing store (tests, a locked DB) only means it shows again.
      }
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        key: const ValueKey('ar-setup-guide'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.title('ar.setup_guide.title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 14),
          for (var i = 0; i < _guideSteps.length; i++) ...[
            _GuideRow(
              number: i + 1,
              icon: _guideSteps[i].$1,
              title: _guideSteps[i].$2.getString(context),
              body: _guideSteps[i].$3.getString(context),
              current: widget.highlight == i,
            ),
            const SizedBox(height: 10),
          ],
          if (widget.offerDontShow)
            CheckboxListTile(
              key: const ValueKey('ar-guide-dont-show'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _dontShow,
              onChanged: (v) => setState(() => _dontShow = v ?? false),
              title: AppText.bodyMedium('ar.setup_guide.dont_show'.getString(context)),
            ),
          const SizedBox(height: 6),
          ArPrimaryButton(label: 'ar.setup_guide.go'.getString(context), icon: ArIcons.check, onPressed: _close),
        ],
      ),
    );
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({required this.number, required this.icon, required this.title, required this.body, required this.current});
  final int number;
  final IconData icon;
  final String title;
  final String body;
  final bool current;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: current ? FeColors.primary.withValues(alpha: 0.08) : null,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: current ? FeColors.primary : FeColors.ink2.withValues(alpha: 0.2), width: current ? 2 : 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: current ? FeColors.primary : FeColors.ink2.withValues(alpha: 0.15),
            child: AppText.label('$number', color: current ? FeColors.panel : FeColors.ink, weight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: FeColors.primary),
                    const SizedBox(width: 6),
                    Expanded(child: AppText.titleSmall(title, weight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 4),
                AppText.bodySmall(body, color: FeColors.ink2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

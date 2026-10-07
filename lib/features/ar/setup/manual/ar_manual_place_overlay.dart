import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/ar/manual_place_math.dart';
import '../../../../state/ar_manual_place_controller.dart';
import '../../../../theme/fe_ar_colors.dart';
import '../../../../theme/fe_colors.dart';
import '../../../../widgets/app_text.dart';
import '../../ar_ui.dart';
import '../../widgets/ar_chrome.dart';
import 'ar_manual_painter.dart';

/// "Place by hand" icons, here so a renamed glyph is a one-line fix.
abstract final class ManualIcons {
  static const hand = LucideIcons.hand;
  static const undo = LucideIcons.undo2;
  static const redo = LucideIcons.redo2;
  static const wall = LucideIcons.brickWall;
  static const corner = LucideIcons.magnet;
  static const nudge = LucideIcons.move;
  static const height = LucideIcons.chevronsUpDown;
  static const more = LucideIcons.ellipsis;
  static const lock = LucideIcons.lock;
  static const trueSize = LucideIcons.scaling;
  static const reset = LucideIcons.rotateCcw;
  static const turnLeft = LucideIcons.rotateCcw;
  static const turnRight = LucideIcons.rotateCw;
  static const left = LucideIcons.arrowLeft;
  static const right = LucideIcons.arrowRight;
  static const up = LucideIcons.arrowUp;
  static const down = LucideIcons.arrowDown;
  static const unpin = LucideIcons.pinOff;
  static const fine = LucideIcons.crosshair;
}

/// The "Place by hand" screen over the camera (hosted by the session screen
/// instead of the setup overlay while [ArManualPlaceState.active]).
///
/// Gestures on the camera view: one finger drags the model on the floor;
/// two fingers twist (soft-snapping to the walls) and pinch (50–200 %,
/// sticky at 100 %), or — dragged straight up/down — change the height;
/// long-press toggles fine mode; double-tap resets. Tools: undo/redo, snap
/// to wall, snap corner, nudge pad, height, More (fine mode, true size,
/// stretch to fit). Large targets (48 px+), plain words, RTL-aware.
class ArManualPlaceOverlay extends ConsumerStatefulWidget {
  const ArManualPlaceOverlay({super.key, required this.tablet, required this.topInset, this.landscape = false});

  final bool tablet;
  final bool landscape;

  /// Below the session's top bar (back, badge, Demo banner).
  final double topInset;

  @override
  ConsumerState<ArManualPlaceOverlay> createState() => _ArManualPlaceOverlayState();
}

enum _Gesture { none, move, two }

class _ArManualPlaceOverlayState extends ConsumerState<ArManualPlaceOverlay> {
  var _gesture = _Gesture.none;
  Offset _twoStart = Offset.zero;

  ArManualPlaceController get _ctrl => ref.read(arManualPlaceProvider.notifier);

  int? _handleAt(Offset p, ArManualPlaceState m) {
    if (!m.cornerMode) return null;
    int? best;
    var bestD = ArManualPainter.handleHitRadius;
    for (var i = 0; i < m.screen.corners.length; i++) {
      final c = m.screen.corners[i];
      if (c == null) continue;
      final d = (Offset(c.$1, c.$2) - p).distance;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _onScaleStart(ScaleStartDetails d) {
    final m = ref.read(arManualPlaceProvider);
    if (d.pointerCount >= 2) {
      _gesture = _Gesture.two;
      _twoStart = d.localFocalPoint;
      _ctrl.twoStart();
    } else {
      _gesture = _Gesture.move;
      _ctrl.moveStart(d.localFocalPoint.dx, d.localFocalPoint.dy, corner: _handleAt(d.localFocalPoint, m));
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    switch (_gesture) {
      case _Gesture.move:
        _ctrl.moveUpdate(d.localFocalPoint.dx, d.localFocalPoint.dy);
      case _Gesture.two:
        final delta = d.localFocalPoint - _twoStart;
        _ctrl.twoUpdate(rotationRad: d.rotation, scale: d.scale, dxPx: delta.dx, dyPx: delta.dy);
      case _Gesture.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // Flutter ends and restarts the gesture whenever a finger lands or
    // lifts, so each finger count is its own start/update/end.
    switch (_gesture) {
      case _Gesture.move:
        _ctrl.moveEnd();
      case _Gesture.two:
        _ctrl.twoEnd();
      case _Gesture.none:
        break;
    }
    _gesture = _Gesture.none;
  }

  @override
  Widget build(BuildContext context) {
    final m = ref.watch(arManualPlaceProvider);
    final st = ArChromeStyle.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom + 12;
    final landscape = widget.landscape;
    final maxPanelWidth = widget.tablet ? 520.0 : double.infinity;

    final canvas = Positioned.fill(
      child: Semantics(
        label: 'ar.manual.canvas_label'.getString(context),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onDoubleTap: _ctrl.reset,
          onLongPress: _ctrl.toggleFine,
          child: CustomPaint(
            painter: ArManualPainter(
              screen: m.screen,
              cornerMode: m.cornerMode,
              grabbed: m.grabbedCorner,
              fine: m.fine,
              sunlight: st.sunlight,
            ),
          ),
        ),
      ),
    );

    final panel = switch (m.panel) {
      ManualPanel.nudge => _NudgePanel(onNudge: _ctrl.nudge),
      ManualPanel.height => _HeightPanel(state: m, ctrl: _ctrl),
      ManualPanel.more => _MorePanel(state: m, ctrl: _ctrl),
      ManualPanel.none => null,
    };
    final readout = m.pose == null ? null : _Readout(pose: m.pose!, rotationDeg: m.rotationDeg);
    final tools = _ToolBar(state: m, ctrl: _ctrl);
    final other = ArOnCameraButton(
      label: 'ar.manual.other_method'.getString(context),
      height: 54,
      onPressed: () => _ctrl.cancel(),
    );
    final lockButton = ArPrimaryButton(
      label: 'ar.manual.lock'.getString(context),
      icon: ManualIcons.lock,
      busy: m.locking,
      onPressed: m.pose == null ? null : () => _ctrl.lock(),
    );
    final size = MediaQuery.sizeOf(context);

    // The coach line and the scale badge, under the session's top bar. In
    // landscape the readout goes up here too (the bottom row is one line),
    // and an open panel takes the end side, so nothing overlaps.
    const sidePanelWidth = 340.0;
    final topColumn = PositionedDirectional(
      top: widget.topInset,
      start: 12,
      end: landscape && panel != null ? 12 + sidePanelWidth + 8 : 12,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.tablet || landscape ? 560 : double.infinity),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CoachLine(state: m),
              if (m.notTrueSize) ...[
                const SizedBox(height: 8),
                _ScaleBadge(onTrueSize: _ctrl.trueSize),
              ],
              if (landscape && readout != null) ...[
                const SizedBox(height: 8),
                Center(child: readout),
              ],
            ],
          ),
        ),
      ),
    );

    if (landscape) {
      const barHeight = 64.0;
      return Stack(
        children: [
          canvas,
          topColumn,
          if (panel != null)
            PositionedDirectional(
              top: widget.topInset,
              end: 12,
              width: sidePanelWidth,
              bottom: bottom + barHeight + 8,
              child: Align(alignment: Alignment.bottomCenter, child: SingleChildScrollView(child: panel)),
            ),
          PositionedDirectional(
            start: 12,
            end: 12,
            bottom: bottom,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: tools),
                const SizedBox(width: 8),
                SizedBox(width: 130, child: other),
                const SizedBox(width: 8),
                SizedBox(width: 180, child: lockButton),
              ],
            ),
          ),
        ],
      );
    }

    // Portrait: readout, panel, tools, then Lock. The panel gets whatever
    // height is left between the top column and the fixed rows, so it never
    // covers the coach line or the scale badge on a small phone.
    const readoutH = 44.0, toolsH = 64.0, lockH = 54.0, gaps = 3 * 8.0;
    final topReserve = widget.topInset + 64 + (m.notTrueSize ? 76 : 0);
    final panelMax = (size.height - topReserve - bottom - readoutH - toolsH - lockH - gaps - 8).clamp(96.0, size.height * 0.45);
    final bottomColumn = PositionedDirectional(
      start: 12,
      end: 12,
      bottom: bottom,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxPanelWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (readout != null) Center(child: readout),
              if (panel != null) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: panelMax.toDouble()),
                  child: SingleChildScrollView(child: panel),
                ),
              ],
              const SizedBox(height: 8),
              tools,
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(flex: 2, child: other),
                  const SizedBox(width: 8),
                  Expanded(flex: 3, child: lockButton),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    return Stack(children: [canvas, topColumn, bottomColumn]);
  }
}

/// The guided coach line: one plain instruction for the step the user is
/// on, plus "Fine" while fine mode is on.
class _CoachLine extends StatelessWidget {
  const _CoachLine({required this.state});
  final ArManualPlaceState state;

  @override
  Widget build(BuildContext context) {
    final step = state.pose == null ? 0 : ManualCoachStep.values.indexOf(state.coach).clamp(1, 4) - 1;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: ArGlassChip(text: state.coachKey.getString(context), icon: ManualIcons.hand, strong: true),
          ),
        ),
        if (!state.cornerMode && state.pose != null) ...[
          const SizedBox(width: 8),
          ArStepDots(count: 4, index: step),
        ],
        if (state.fine) ...[
          const SizedBox(width: 8),
          ArGlassChip(text: 'ar.manual.fine'.getString(context), icon: ManualIcons.fine, iconColor: FeColors.warning),
        ],
      ],
    );
  }
}

/// "Not true size — measurements are approximate", with "True size".
class _ScaleBadge extends StatelessWidget {
  const _ScaleBadge({required this.onTrueSize});
  final VoidCallback onTrueSize;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FeArColors.placedBg,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      shadowColor: Colors.black38,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 6, 6),
        child: Row(
          children: [
            const Icon(ArIcons.warning, size: 18, color: FeArColors.placedFg),
            const SizedBox(width: 8),
            Expanded(
              child: AppText.bodySmall(
                'ar.manual.not_true_size'.getString(context),
                color: FeArColors.placedFg,
                weight: FontWeight.w700,
                maxLines: 3,
              ),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: onTrueSize,
              style: FilledButton.styleFrom(
                backgroundColor: FeColors.ink,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(ManualIcons.trueSize, size: 16, color: Colors.white),
              label: AppText.label('ar.manual.true_size'.getString(context), color: Colors.white, weight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Scale 112% · Rot 87° · Height +0.02 m".
class _Readout extends StatelessWidget {
  const _Readout({required this.pose, required this.rotationDeg});
  final ManualPose pose;
  final int rotationDeg;

  @override
  Widget build(BuildContext context) {
    final h = pose.heightM;
    final height = arTr(context, 'ar.unit.m', ['${h < 0 ? '−' : '+'}${h.abs().toStringAsFixed(2)}']);
    var text = arTr(context, 'ar.manual.readout', [pose.scalePct.round(), rotationDeg, height]);
    if (pose.isStretched) {
      text = '$text · ${arTr(context, 'ar.manual.stretch_readout', [(pose.stretchX * 100).round(), (pose.stretchZ * 100).round()])}';
    }
    return ArGlassChip(text: text, strong: true);
  }
}

class _ToolBar extends StatelessWidget {
  const _ToolBar({required this.state, required this.ctrl});
  final ArManualPlaceState state;
  final ArManualPlaceController ctrl;

  @override
  Widget build(BuildContext context) {
    final placed = state.pose != null;
    final st = ArChromeStyle.of(context);
    Widget tool(IconData icon, String key, VoidCallback? onTap, {bool active = false}) => Expanded(
          child: _Tool(icon: icon, label: key.getString(context), onTap: placed ? onTap : null, active: active),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: st.surface(strong: true), borderRadius: BorderRadius.circular(18), border: st.border()),
      child: Row(
        children: [
          tool(ManualIcons.undo, 'ar.manual.undo', state.canUndo ? ctrl.undo : null),
          tool(ManualIcons.redo, 'ar.manual.redo', state.canRedo ? ctrl.redo : null),
          tool(ManualIcons.wall, 'ar.manual.snap_wall', ctrl.snapToWall),
          tool(ManualIcons.corner, 'ar.manual.snap_corner', ctrl.toggleCornerMode, active: state.cornerMode),
          tool(ManualIcons.nudge, 'ar.manual.nudge', () => ctrl.openPanel(ManualPanel.nudge), active: state.panel == ManualPanel.nudge),
          tool(ManualIcons.height, 'ar.manual.height', () => ctrl.openPanel(ManualPanel.height), active: state.panel == ManualPanel.height),
          tool(ManualIcons.more, 'ar.manual.more', () => ctrl.openPanel(ManualPanel.more), active: state.panel == ManualPanel.more),
        ],
      ),
    );
  }
}

/// A tool: icon over a short label, at least 48 × 56.
class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, required this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    final fg = active ? st.activeFg : st.icon;
    final colour = onTap == null ? fg.withValues(alpha: st.sunlight ? 0.55 : 0.4) : fg;
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: active,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: active ? st.activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: st.iconSize(20), color: colour),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AppText.caption(label, color: colour, weight: st.weight(FontWeight.w600), maxLines: 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A white panel card above the tool bar.
class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ArCard(padding: const EdgeInsets.all(12), radius: 18, child: child);
}

/// ±1 cm / ±1° steps. The arrows are the camera's directions (left is the
/// user's left), so the pad keeps its physical layout in Arabic too.
class _NudgePanel extends StatelessWidget {
  const _NudgePanel({required this.onNudge});
  final void Function(ManualNudge) onNudge;

  @override
  Widget build(BuildContext context) {
    Widget b(ManualNudge n, IconData icon, String key) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Semantics(
              button: true,
              label: key.getString(context),
              excludeSemantics: true,
              child: SizedBox(
                height: 48,
                child: TextButton(
                  onPressed: () => onNudge(n),
                  style: TextButton.styleFrom(
                    backgroundColor: FeArColors.manualBg,
                    foregroundColor: FeColors.ink,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 18),
                      FittedBox(fit: BoxFit.scaleDown, child: AppText.caption(key.getString(context), color: FeColors.ink, maxLines: 1)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
    return _PanelCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.caption('ar.manual.nudge_hint'.getString(context), color: FeColors.ink2, weight: FontWeight.w600),
          const SizedBox(height: 6),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Row(children: [
                  b(ManualNudge.turnLeft, ManualIcons.turnLeft, 'ar.manual.nudge_turn_left'),
                  b(ManualNudge.away, ManualIcons.up, 'ar.manual.nudge_away'),
                  b(ManualNudge.turnRight, ManualIcons.turnRight, 'ar.manual.nudge_turn_right'),
                  b(ManualNudge.up, ManualIcons.up, 'ar.manual.nudge_up'),
                ]),
                Row(children: [
                  b(ManualNudge.left, ManualIcons.left, 'ar.manual.nudge_left'),
                  b(ManualNudge.toward, ManualIcons.down, 'ar.manual.nudge_toward'),
                  b(ManualNudge.right, ManualIcons.right, 'ar.manual.nudge_right'),
                  b(ManualNudge.down, ManualIcons.down, 'ar.manual.nudge_down'),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeightPanel extends StatelessWidget {
  const _HeightPanel({required this.state, required this.ctrl});
  final ArManualPlaceState state;
  final ArManualPlaceController ctrl;

  @override
  Widget build(BuildContext context) {
    final h = state.pose?.heightM ?? 0;
    final label = arTr(context, 'ar.unit.m', ['${h < 0 ? '−' : '+'}${h.abs().toStringAsFixed(2)}']);
    return _PanelCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.bodySmall(arTr(context, 'ar.manual.height_label', [label]), color: FeColors.ink, weight: FontWeight.w700),
          AppText.caption('ar.manual.height_hint'.getString(context), color: FeColors.ink2),
          Slider(
            value: h.clamp(-0.5, 0.5).toDouble(),
            min: -0.5,
            max: 0.5,
            divisions: 100,
            label: label,
            onChangeStart: (_) => ctrl.sliderStart(),
            onChanged: state.pose == null ? null : ctrl.setHeight,
            onChangeEnd: (_) => ctrl.sliderEnd(),
          ),
        ],
      ),
    );
  }
}

class _MorePanel extends StatelessWidget {
  const _MorePanel({required this.state, required this.ctrl});
  final ArManualPlaceState state;
  final ArManualPlaceController ctrl;

  @override
  Widget build(BuildContext context) {
    final pose = state.pose;
    final last = state.lastSize;
    Widget row(String key, bool value, ValueChanged<bool> onChanged, {String? subKey}) => MergeSemantics(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.bodyMedium(key.getString(context), weight: FontWeight.w700),
                    if (subKey != null) AppText.caption(subKey.getString(context), color: FeColors.ink2, maxLines: 3),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        );
    return _PanelCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('ar.manual.fine_mode', state.fine, (_) => ctrl.toggleFine(), subKey: 'ar.manual.fine_sub'),
          const Divider(height: 16),
          Row(
            children: [
              Expanded(
                child: ArSecondaryButton(
                  label: 'ar.manual.true_size'.getString(context),
                  icon: ManualIcons.trueSize,
                  onPressed: pose == null || pose.isTrueSize ? null : ctrl.trueSize,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ArSecondaryButton(label: 'ar.manual.reset'.getString(context), icon: ManualIcons.reset, onPressed: ctrl.reset),
              ),
            ],
          ),
          if (state.pinnedCorner != null) ...[
            const SizedBox(height: 8),
            ArSecondaryButton(label: 'ar.manual.unpin'.getString(context), icon: ManualIcons.unpin, onPressed: ctrl.unpin),
          ],
          if (last != null) ...[
            const SizedBox(height: 8),
            ArSecondaryButton(
              label: arTr(context, 'ar.manual.last_size', ['${(last.scale * 100).round()}%']),
              icon: ManualIcons.trueSize,
              onPressed: ctrl.useLastSize,
            ),
          ],
          const Divider(height: 16),
          row('ar.manual.stretch', state.stretchOn, ctrl.setStretchOn, subKey: 'ar.manual.stretch_sub'),
          if (state.stretchOn && pose != null) ...[
            AppText.caption(arTr(context, 'ar.manual.stretch_x', ['${(pose.stretchX * 100).round()}%']), color: FeColors.ink),
            Slider(
              value: pose.stretchX,
              min: ManualLimits.minStretch,
              max: ManualLimits.maxStretch,
              onChangeStart: (_) => ctrl.sliderStart(),
              onChanged: (v) => ctrl.setStretch(x: v),
              onChangeEnd: (_) => ctrl.sliderEnd(),
            ),
            AppText.caption(arTr(context, 'ar.manual.stretch_z', ['${(pose.stretchZ * 100).round()}%']), color: FeColors.ink),
            Slider(
              value: pose.stretchZ,
              min: ManualLimits.minStretch,
              max: ManualLimits.maxStretch,
              onChangeStart: (_) => ctrl.sliderStart(),
              onChanged: (v) => ctrl.setStretch(z: v),
              onChangeEnd: (_) => ctrl.sliderEnd(),
            ),
          ],
        ],
      ),
    );
  }
}

/// The workspace's offer after a hand placement: "Refine with a corner"
/// (snap one real corner; the measured fit then replaces the hand one).
class ArManualRefineBanner extends ConsumerWidget {
  const ArManualRefineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arManualPlaceProvider.notifier);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Material(
        color: FeArColors.placedBg,
        borderRadius: BorderRadius.circular(16),
        elevation: 6,
        shadowColor: Colors.black38,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
          child: Row(
            children: [
              const Icon(ManualIcons.hand, size: 18, color: FeArColors.placedFg),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.bodySmall(
                  'ar.manual.refine_hint'.getString(context),
                  color: FeArColors.placedFg,
                  weight: FontWeight.w700,
                  maxLines: 3,
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: ctrl.refineWithCorner,
                style: FilledButton.styleFrom(
                  backgroundColor: FeColors.ink,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: AppText.label('ar.manual.refine'.getString(context), color: Colors.white, weight: FontWeight.w700),
              ),
              IconButton(
                tooltip: 'ar.common.close'.getString(context),
                onPressed: ctrl.dismissRefine,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: const Icon(ArIcons.close, size: 18, color: FeArColors.placedFg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

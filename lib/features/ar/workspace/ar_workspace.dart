import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ar/reanchor_rule.dart' show ReanchorReason;
import '../../../state/ar_permissions.dart';
import '../../../state/ar_prefs_controller.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_setup_controller.dart';
import '../../../state/ar_view_models.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/tech_popup.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import '../widgets/ar_demo_scene.dart';
import '../widgets/ar_mini_plan.dart';
import '../widgets/ar_status.dart';
import '../widgets/ar_visuals.dart';
import 'ar_discipline_legend.dart';
import 'ar_drill_panel.dart';
import 'ar_floating_labels.dart';
import 'ar_menu_panel.dart';
import 'ar_mode_panel.dart';

/// The AR workspace (AR-58; canvas TabWork / PhWork): modes decide what a
/// tap does, the selection control decides how it selects, tools act on
/// the view, and the action card (iPad) or sheet (phone) shows what is
/// selected with its actions. One widget tree per layout, the same state
/// underneath, so every action is reachable in two taps on both.
class ArWorkspace extends ConsumerStatefulWidget {
  const ArWorkspace({super.key, required this.tablet, required this.viewSize, required this.onBack, this.landscape = false});

  final bool tablet;

  /// A phone on its side ([ArLayout.landscapePhone]): rails on both edges
  /// and a collapsible side card instead of the bottom sheet.
  final bool landscape;
  final Size viewSize;
  final VoidCallback onBack;

  @override
  ConsumerState<ArWorkspace> createState() => _ArWorkspaceState();
}

class _ArWorkspaceState extends ConsumerState<ArWorkspace> {
  final _lasso = <Offset>[];

  /// Landscape phone: the side card folded to a pill, for more camera.
  var _cardFolded = false;

  ArWorkspaceController get _ws => ref.read(arWorkspaceProvider.notifier);

  // ------------------------------------------------------------- gestures

  void _onTapUp(TapUpDetails d) {
    final s = ref.read(arSessionProvider);
    final ws = ref.read(arWorkspaceProvider);
    if (ws.panel != ArPanel.none) {
      _ws.closePanel();
      return;
    }
    ArFeature? demoHit;
    if (s.demo) {
      final f = Offset(d.localPosition.dx / widget.viewSize.width, d.localPosition.dy / widget.viewSize.height);
      demoHit = s.isPlaced ? arDemoFeature(s.features, ArDemoScene.demoHit(f)) : null;
    }
    _ws.tap(d.localPosition.dx, d.localPosition.dy, demoHit: demoHit).then((_) {
      if (!mounted) return;
      final after = ref.read(arWorkspaceProvider);
      if (after.lastPickMissed && !after.measuring) {
        showTechPopup(context, message: 'ar.work.nothing_there'.getString(context));
      } else if (!after.lastPickMissed) {
        ArHaptics.snap();
      }
    });
  }

  void _onPanStart(DragStartDetails d) => setState(() => _lasso
    ..clear()
    ..add(d.localPosition));

  void _onPanUpdate(DragUpdateDetails d) => setState(() => _lasso.add(d.localPosition));

  void _onPanEnd(DragEndDetails _) {
    final s = ref.read(arSessionProvider);
    final pts = List<Offset>.of(_lasso);
    setState(_lasso.clear);
    if (pts.length < 3) return;
    final demoHits = <ArFeature>[];
    if (s.demo && s.isPlaced) {
      final fractions = [for (final p in pts) Offset(p.dx / widget.viewSize.width, p.dy / widget.viewSize.height)];
      for (final gid in ArDemoScene.demoLasso(fractions)) {
        final f = arDemoFeature(s.features, gid);
        if (f != null) demoHits.add(f);
      }
    }
    _ws.lasso([for (final p in pts) (p.dx, p.dy)], demoHits: demoHits);
    ArHaptics.snap();
  }

  Future<void> _capture() async {
    final s = ref.read(arSessionProvider);
    final path = await ref.read(arSessionProvider.notifier).capture();
    if (!mounted) return;
    ArHaptics.snap();
    showTechPopup(
      context,
      message: path != null
          ? 'ar.work.photo_saved'.getString(context)
          : (s.demo ? 'ar.demo.photo'.getString(context) : 'ar.work.photo_failed'.getString(context)),
      isError: path == null && !s.demo,
    );
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(arSessionProvider);
    final ws = ref.watch(arWorkspaceProvider);
    final lasso = ws.selectMode == ArSelectMode.lasso && !ws.measuring;
    final layer = Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _onTapUp,
        onPanStart: lasso ? _onPanStart : null,
        onPanUpdate: lasso ? _onPanUpdate : null,
        onPanEnd: lasso ? _onPanEnd : null,
        child: CustomPaint(painter: _LassoPainter(List<Offset>.of(_lasso))),
      ),
    );
    final phoneTop = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        layer,
        // Tag chips at the elements: under every control, over the view.
        Positioned.fill(
          child: ArFloatingLabels(
            viewSize: widget.viewSize,
            topInset: widget.tablet ? 72 : phoneTop + (widget.landscape ? 64 : 110),
            bottomInset: widget.tablet ? widget.viewSize.height * 0.3 : (widget.landscape ? 12 : widget.viewSize.height * 0.5),
          ),
        ),
        ..._locateOverlay(context, s, ws),
        if (ws.drilling) Positioned.fill(child: ArDrillCrosshair(viewSize: widget.viewSize)),
        if (ws.measuring) _measureChip(context, s, ws),
        // The fit is drifting (the session's re-anchor rule): the model is
        // dimmed and this asks for a corner or board before anyone trusts it.
        if (s.recheck != null)
          Positioned(
            top: widget.tablet
                ? 128
                : (widget.landscape ? phoneTop + 118 : _phoneBelowLegend(context, s) + (ws.measuring ? 56 : 4)),
            left: widget.landscape ? 96 : 12,
            right: widget.landscape ? 96 : 68,
            child: Center(child: _RecheckBanner(prompt: s.recheck!, onRecheck: _reSnap)),
          ),
        if (ws.lassoBusy || ws.picking)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 3, color: FeArColors.snap, backgroundColor: Colors.transparent),
          ),
        if (widget.tablet)
          ..._tablet(context, s, ws)
        else if (widget.landscape)
          ..._landscapePhone(context, s, ws)
        else
          ..._phone(context, s, ws),
        if (ws.panel == ArPanel.menu || ws.panel == ArPanel.layers)
          widget.tablet
              ? Positioned.fill(child: ArMenuPanelTablet(onClose: _ws.closePanel))
              : Positioned.fill(
                  child: ArMenuPanelPhone(
                    onClose: _ws.closePanel,
                    initialTab: ws.panel,
                    maxWidth: widget.landscape ? 520 : null,
                  ),
                ),
        if (ws.panel == ArPanel.more && !widget.tablet) Positioned.fill(child: _MoreTools(onClose: _ws.closePanel)),
      ],
    );
  }

  // ---------------------------------------------------------------- iPad

  List<Widget> _tablet(BuildContext context, ArSessionState s, ArWorkspaceState ws) {
    final floor = s.floor;
    final place = [floor?.floorName, s.args?.spaceName].whereType<String>().where((x) => x.isNotEmpty).join(' · ');
    return [
      PositionedDirectional(
        start: 20,
        top: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _GlassPill(icon: ArIcons.back, text: place, onTap: widget.onBack, directional: true),
            const SizedBox(height: 12),
            _ModeRail(mode: ws.mode, onMode: _ws.setMode),
          ],
        ),
      ),
      Positioned(
        top: 20,
        left: 0,
        right: 0,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ArSessionBadge(onTap: () => _ws.openPanel(ArPanel.menu)),
              const SizedBox(width: 10),
              const ArSyncChip(),
              if (s.demo) ...[
                const SizedBox(width: 10),
                const ArDemoBanner(),
              ],
            ],
          ),
        ),
      ),
      PositionedDirectional(
        end: 20,
        top: 20,
        bottom: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ArGlassButton(icon: ArIcons.menu, label: 'ar.menu.title'.getString(context), size: 52, onTap: () => _ws.openPanel(ArPanel.menu)),
            const SizedBox(height: 10),
            Flexible(child: SingleChildScrollView(child: _ToolRail(ws: ws, session: s))),
          ],
        ),
      ),
      PositionedDirectional(
        start: 20,
        bottom: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SelectionRail(mode: ws.selectMode, onMode: _ws.setSelectMode),
            const SizedBox(height: 12),
            _CaptureButton(size: 68, onTap: _capture),
          ],
        ),
      ),
      PositionedDirectional(
        start: 230,
        end: 130,
        bottom: 20,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.viewSize.height * 0.42),
          child: ArCard(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: SingleChildScrollView(child: ArModePanel(tablet: true, onBackToSetup: _backToSetup)),
          ),
        ),
      ),
      // Under the badge, between the mode rail and the tool rail (and clear
      // of the corner plan when it's open).
      PositionedDirectional(
        start: 210,
        end: ws.planInCorner && s.plan != null ? 390 : 120,
        top: 72,
        child: const ArDisciplineLegend(center: true),
      ),
      if (ws.planInCorner && s.plan != null)
        PositionedDirectional(
          end: 110,
          top: 20,
          width: 260,
          height: 180,
          child: _cornerPlan(s),
        ),
    ];
  }

  // --------------------------------------------------------------- phone

  /// Phone: the legend sits under the top row (and the Demo banner); what
  /// used to start there moves below it.
  double _phoneLegendTop(BuildContext context, ArSessionState s) => MediaQuery.paddingOf(context).top + 12 + (s.demo ? 96 : 56);

  double _phoneBelowLegend(BuildContext context, ArSessionState s) =>
      _phoneLegendTop(context, s) + (s.features.isEmpty ? 8 : 52);

  List<Widget> _phone(BuildContext context, ArSessionState s, ArWorkspaceState ws) {
    final top = MediaQuery.paddingOf(context).top + 12;
    return [
      PositionedDirectional(
        start: 12,
        end: 12,
        top: top,
        child: Row(
          children: [
            ArGlassButton(icon: ArIcons.back, label: 'ar.common.back'.getString(context), onTap: widget.onBack),
            const SizedBox(width: 8),
            Expanded(
              child: Center(child: ArSessionBadge(compact: true, withSync: true, onTap: () => _ws.openPanel(ArPanel.menu))),
            ),
            const SizedBox(width: 8),
            ArGlassButton(icon: ArIcons.menu, label: 'ar.menu.title'.getString(context), onTap: () => _ws.openPanel(ArPanel.menu)),
          ],
        ),
      ),
      if (s.demo)
        Positioned(top: top + 56, left: 0, right: 0, child: const Center(child: ArDemoBanner())),
      // Stops short of the tool column on the end edge.
      PositionedDirectional(
        start: 12,
        end: 68,
        top: _phoneLegendTop(context, s),
        child: const ArDisciplineLegend(),
      ),
      PositionedDirectional(
        end: 12,
        top: top + (s.demo ? 96 : 64),
        child: Column(
          children: [
            ArGlassButton(icon: ArIcons.reSnap, label: 'ar.tool.resnap'.getString(context), onTap: _reSnap),
            const SizedBox(height: 8),
            ArGlassButton(
              icon: ArIcons.layers,
              label: 'ar.tool.layers'.getString(context),
              active: ws.panel == ArPanel.layers,
              onTap: () => _ws.openPanel(ArPanel.layers),
            ),
            const SizedBox(height: 8),
            ArGlassButton(icon: ArIcons.measure, label: 'ar.tool.measure'.getString(context), active: ws.measuring, onTap: _ws.toggleMeasure),
            const SizedBox(height: 8),
            ArGlassButton(icon: ArIcons.drill, label: 'ar.tool.drill_long'.getString(context), active: ws.drilling, onTap: _toggleDrill),
            const SizedBox(height: 8),
            _torchButton(context, ws),
            const SizedBox(height: 8),
            _focusButton(context),
            const SizedBox(height: 8),
            ArGlassButton(icon: ArIcons.more, label: 'ar.tool.more'.getString(context), active: ws.panel == ArPanel.more, onTap: () => _ws.openPanel(ArPanel.more)),
          ],
        ),
      ),
      if (ws.planInCorner && s.plan != null)
        PositionedDirectional(
          start: 12,
          top: _phoneBelowLegend(context, s),
          width: 180,
          height: 128,
          child: _cornerPlan(s),
        ),
      Positioned.fill(child: _PhoneSheet(onCapture: _capture, onBackToSetup: _backToSetup)),
    ];
  }

  Widget _cornerPlan(ArSessionState s) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(color: FeColors.panel, borderRadius: BorderRadius.circular(16)),
    child: ArMiniPlan(
      plan: s.plan,
      markers: s.floor?.activeMarkers ?? const [],
      camera: s.cameraTile,
      heading: s.forwardTileXz,
      target: s.target?.centre,
      focus: s.cameraTile?.xz ?? s.target?.centre.xz,
      focusRadiusM: 7,
      showSpaceNames: false,
    ),
  );

  void _reSnap() => ref.read(arSetupProvider.notifier).reSnap();

  /// Restarts autofocus: ARCore/ARKit have no focus-at-point, so this is the
  /// fix for a camera that settled blurred (device test 2026-09-27).
  Widget _focusButton(BuildContext context, {double size = 48}) => ArGlassButton(
    icon: ArIcons.focus,
    label: 'ar.tool.focus'.getString(context),
    size: size,
    onTap: () => arRefocus(ref),
  );

  Widget _torchButton(BuildContext context, ArWorkspaceState ws, {double size = 48}) => ArGlassButton(
    icon: ws.torch ? ArIcons.torch : ArIcons.torchOff,
    label: arTorchLabel(context, ws, available: ref.read(arSessionProvider).capabilities?.torch ?? false),
    size: size,
    active: ws.torch,
    onTap: () => arToggleTorch(context, ref),
  );

  // ------------------------------------------------------ landscape phone

  /// A phone on its side (≈ 800–930 × 360–430): back, badge and menu on
  /// top; modes down the start edge, tools down the end edge (both scroll
  /// if the phone is very short); the mode card on the end side, foldable to
  /// a pill; capture and Single/Multi/Lasso at the bottom start.
  List<Widget> _landscapePhone(BuildContext context, ArSessionState s, ArWorkspaceState ws) {
    final pad = MediaQuery.paddingOf(context);
    final top = pad.top + 8;
    final start = 12.0 + math.max(pad.left, pad.right);
    final end = start;
    final bottom = pad.bottom + 10;
    final railTop = top + 58;
    final cardWidth = math.min(360.0, widget.viewSize.width * 0.4);
    final cardEnd = end + 60;
    return [
      PositionedDirectional(
        start: start,
        end: end,
        top: top,
        child: Row(
          children: [
            ArGlassButton(icon: ArIcons.back, label: 'ar.common.back'.getString(context), onTap: widget.onBack),
            const SizedBox(width: 8),
            Expanded(
              child: Center(
                child: Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ArSessionBadge(compact: true, withSync: true, onTap: () => _ws.openPanel(ArPanel.menu)),
                    if (s.demo) const ArDemoBanner(),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            ArGlassButton(icon: ArIcons.menu, label: 'ar.menu.title'.getString(context), onTap: () => _ws.openPanel(ArPanel.menu)),
          ],
        ),
      ),
      PositionedDirectional(
        start: start,
        top: railTop,
        bottom: bottom,
        child: SingleChildScrollView(child: _CompactModeRail(mode: ws.mode, onMode: _ws.setMode)),
      ),
      PositionedDirectional(
        end: end,
        top: railTop,
        bottom: bottom,
        child: SingleChildScrollView(
          child: Column(
            children: [
              ArGlassButton(icon: ArIcons.reSnap, label: 'ar.tool.resnap'.getString(context), size: 44, onTap: _reSnap),
              const SizedBox(height: 6),
              ArGlassButton(icon: ArIcons.layers, label: 'ar.tool.layers'.getString(context), size: 44, active: ws.panel == ArPanel.layers, onTap: () => _ws.openPanel(ArPanel.layers)),
              const SizedBox(height: 6),
              ArGlassButton(icon: ArIcons.measure, label: 'ar.tool.measure'.getString(context), size: 44, active: ws.measuring, onTap: _ws.toggleMeasure),
              const SizedBox(height: 6),
              ArGlassButton(icon: ArIcons.drill, label: 'ar.tool.drill_long'.getString(context), size: 44, active: ws.drilling, onTap: _toggleDrill),
              const SizedBox(height: 6),
              _torchButton(context, ws, size: 44),
              const SizedBox(height: 6),
              _focusButton(context, size: 44),
              const SizedBox(height: 6),
              ArGlassButton(icon: ArIcons.more, label: 'ar.tool.more'.getString(context), size: 44, active: ws.panel == ArPanel.more, onTap: () => _ws.openPanel(ArPanel.more)),
            ],
          ),
        ),
      ),
      PositionedDirectional(
        start: start + 72,
        end: cardEnd + (_cardFolded ? 150 : cardWidth) + 8,
        top: railTop,
        child: const ArDisciplineLegend(),
      ),
      if (ws.planInCorner && s.plan != null)
        PositionedDirectional(
          start: start + 72,
          top: railTop + (s.features.isEmpty ? 0 : 50),
          width: 170,
          height: 116,
          child: _cornerPlan(s),
        ),
      PositionedDirectional(
        start: start + 72,
        bottom: bottom,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CaptureButton(size: 52, onTap: _capture),
            const SizedBox(width: 8),
            ArSelectionPill(mode: ws.selectMode, onMode: _ws.setSelectMode),
          ],
        ),
      ),
      if (_cardFolded)
        PositionedDirectional(
          end: cardEnd,
          bottom: bottom,
          child: ArGlassChip(
            text: arModeLabel(context, ws.mode),
            icon: ArIcons.collapse,
            strong: true,
            onTap: () => setState(() => _cardFolded = false),
          ),
        )
      else
        PositionedDirectional(
          end: cardEnd,
          top: railTop,
          bottom: bottom,
          width: cardWidth,
          child: ArCard(
            radius: 20,
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: IconButton(
                    tooltip: 'ar.work.fold_card'.getString(context),
                    icon: const Icon(ArIcons.expand, size: 18),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                    onPressed: () => setState(() => _cardFolded = true),
                  ),
                ),
                Expanded(child: SingleChildScrollView(child: ArModePanel(tablet: false, onBackToSetup: _backToSetup))),
              ],
            ),
          ),
        ),
    ];
  }

  void _toggleDrill() {
    ArHaptics.snap();
    _ws.toggleDrill();
  }

  void _backToSetup() => ref.read(arSetupProvider.notifier).reAlign(keepObservations: true);

  // -------------------------------------------------------------- locate

  List<Widget> _locateOverlay(BuildContext context, ArSessionState s, ArWorkspaceState ws) {
    final target = s.target;
    if (target == null || !s.isPlaced || ws.mode != ArMode.locate) return const [];
    final distance = _distanceTo(s, target);
    final label = distance == null ? target.displayName : '${target.displayName} · ${arMetres(context, distance)}';
    // Demo: the sample target is drawn in view; label it where it is.
    if (s.demo) {
      return [
        Positioned(
          left: widget.viewSize.width * 0.58,
          top: widget.viewSize.height * 0.52 - 40,
          child: IgnorePointer(child: _TargetLabel(target: target, subtitle: _distanceLine(context, distance))),
        ),
      ];
    }
    final screen = s.targetScreen;
    if (s.targetOnScreen && screen != null) {
      return [
        Positioned(
          left: (screen.$1 - 80).clamp(8, widget.viewSize.width - 168).toDouble(),
          top: (screen.$2 - 76).clamp(8, widget.viewSize.height - 80).toDouble(),
          child: IgnorePointer(child: _TargetLabel(target: target, subtitle: _distanceLine(context, distance))),
        ),
      ];
    }
    final angle = _offscreenAngle(s, target, screen);
    if (angle == null) return const [];
    return [ArEdgeArrow(angle: angle, label: label, viewSize: widget.viewSize)];
  }

  String _distanceLine(BuildContext context, double? d) =>
      d == null ? 'ar.locate.through_walls'.getString(context) : arTr(context, 'ar.locate.distance', [arMetres(context, d)]);

  double? _distanceTo(ArSessionState s, ArFeature f) {
    final cam = s.cameraTile;
    if (cam == null) return null;
    return cam.distanceTo(f.centre);
  }

  /// Screen direction to an off-screen target: from its reported screen
  /// point when the engine gives one, else from the camera heading.
  double? _offscreenAngle(ArSessionState s, ArFeature target, (double, double)? screen) {
    if (screen != null) {
      final c = Offset(widget.viewSize.width / 2, widget.viewSize.height / 2);
      return math.atan2(screen.$2 - c.dy, screen.$1 - c.dx);
    }
    final cam = s.cameraTile;
    final fwd = s.forwardTileXz;
    if (cam == null || fwd == null) return null;
    final to = target.centre.xz - cam.xz;
    final bearing = math.atan2(fwd.x * to.y - fwd.y * to.x, fwd.x * to.x + fwd.y * to.y);
    return -math.pi / 2 + bearing;
  }

  Widget _measureChip(BuildContext context, ArSessionState s, ArWorkspaceState ws) {
    final uncertainty = math.max(0.01, s.fit?.maxResidualM ?? 0.01);
    final text = ws.measureM != null
        ? arTr(context, 'ar.measure.result', [arMetres(context, ws.measureM!), arCentimetres(context, uncertainty, plusMinus: true)])
        : (ws.measureFrom == null ? 'ar.measure.first'.getString(context) : 'ar.measure.second'.getString(context));
    return Positioned(
      top: widget.tablet ? (s.features.isEmpty ? 80 : 128) : _phoneBelowLegend(context, s) + 4,
      left: 0,
      right: 0,
      child: Center(
        child: ArGlassChip(text: text, icon: ArIcons.measure, strong: true, onTap: _ws.toggleMeasure),
      ),
    );
  }
}

class _LassoPainter extends CustomPainter {
  _LassoPainter(this.points);
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..addPolygon(points, false);
    canvas.drawPath(
      path,
      Paint()
        ..color = FeArColors.snap
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(Path()..addPolygon(points, true), Paint()..color = FeArColors.snap.withValues(alpha: 0.12));
  }

  @override
  bool shouldRepaint(covariant _LassoPainter old) => old.points.length != points.length;
}

class _TargetLabel extends StatelessWidget {
  const _TargetLabel({required this.target, required this.subtitle});
  final ArFeature target;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final d = ArDiscipline.of(target.discipline);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: FeColors.danger, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The discipline's colour, ringed white so amber or red reads
              // on the red label.
              Container(
                padding: const EdgeInsets.all(1.5),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: ArLegendDot(colour: arDisciplineColor(d), filled: d != ArDiscipline.walls, size: 9),
              ),
              const SizedBox(width: 6),
              Flexible(child: AppText.titleSmall(target.displayName, color: Colors.white, weight: FontWeight.w800)),
            ],
          ),
          AppText.caption(subtitle, color: Colors.white),
        ],
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.icon, required this.text, required this.onTap, this.directional = false});
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final bool directional;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    final iconSize = st.iconSize(16);
    return Material(
      color: st.surface(),
      shape: st.shape(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              directional
                  ? ArDirectionalIcon(icon, size: iconSize, color: st.icon)
                  : Icon(icon, size: iconSize, color: st.icon),
              const SizedBox(width: 8),
              AppText.bodyMedium(
                text,
                color: st.icon,
                weight: st.weight(FontWeight.w600),
                style: st.text(Theme.of(context).textTheme.bodyMedium),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iPad's mode rail: text labels, the active mode in brand blue.
class _ModeRail extends StatelessWidget {
  const _ModeRail({required this.mode, required this.onMode});
  final ArMode mode;
  final ValueChanged<ArMode> onMode;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: st.surface(), borderRadius: BorderRadius.circular(18), border: st.border()),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in ArMode.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Material(
                  color: m == mode ? FeColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onMode(m),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48, minWidth: 132),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(
                        children: [
                          Icon(arModeIcon(m), size: st.iconSize(17), color: m == mode ? Colors.white : st.fg),
                          const SizedBox(width: 10),
                          AppText.bodyMedium(
                            arModeLabel(context, m),
                            color: m == mode ? Colors.white : st.fg,
                            weight: st.weight(FontWeight.w600),
                            style: st.text(Theme.of(context).textTheme.bodyMedium),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData arModeIcon(ArMode m) => switch (m) {
  ArMode.locate => ArIcons.locate,
  ArMode.verify => ArIcons.verify,
  ArMode.progress => ArIcons.progress,
  ArMode.snags => ArIcons.snags,
  ArMode.forms => ArIcons.forms,
};

String arModeLabel(BuildContext context, ArMode m) => 'ar.mode.${m.name}'.getString(context);

/// iPad's labelled tool rail with the opacity slider built in.
class _ToolRail extends ConsumerWidget {
  const _ToolRail({required this.ws, required this.session});
  final ArWorkspaceState ws;
  final ArSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final setup = ref.read(arSetupProvider.notifier);
    final st = ArChromeStyle.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: st.surface(), borderRadius: BorderRadius.circular(18), border: st.border()),
      child: Column(
        children: [
          _Tool(icon: ArIcons.reSnap, label: 'ar.tool.resnap'.getString(context), onTap: setup.reSnap),
          if (ref.watch(arInstallAllowedProvider))
            _Tool(icon: ArIcons.board, label: 'ar.tool.board'.getString(context), onTap: setup.saveBoardFromWork),
          _Tool(icon: ArIcons.section, label: 'ar.tool.section'.getString(context), active: ws.layers.section, onTap: ctrl.toggleSection),
          _Tool(icon: ArIcons.xray, label: 'ar.tool.xray'.getString(context), active: ws.layers.xray, onTap: ctrl.toggleXray),
          _Tool(icon: ArIcons.measure, label: 'ar.tool.measure'.getString(context), active: ws.measuring, onTap: ctrl.toggleMeasure),
          _Tool(icon: ArIcons.drill, label: 'ar.tool.drill'.getString(context), active: ws.drilling, onTap: ctrl.toggleDrill),
          _Tool(icon: ArIcons.layers, label: 'ar.tool.layers'.getString(context), active: ws.panel == ArPanel.layers, onTap: () => ctrl.openPanel(ArPanel.layers)),
          _Tool(
            icon: ArIcons.grid,
            label: 'ar.tool.grid'.getString(context),
            active: session.gridVisible,
            onTap: () => ref.read(arSessionProvider.notifier).setGridVisible(!session.gridVisible),
          ),
          _Tool(
            icon: ws.torch ? ArIcons.torch : ArIcons.torchOff,
            label: 'ar.tool.torch'.getString(context),
            active: ws.torch,
            dimmed: !(session.capabilities?.torch ?? false),
            onTap: () => arToggleTorch(context, ref),
          ),
          _Tool(icon: ArIcons.focus, label: 'ar.tool.focus'.getString(context), onTap: () => arRefocus(ref)),
          const SizedBox(height: 6),
          AppText.caption(
            'ar.tool.opacity'.getString(context),
            color: st.fg,
            weight: st.sunlight ? FontWeight.w700 : null,
            style: st.text(Theme.of(context).textTheme.labelSmall),
          ),
          SizedBox(
            height: 140,
            width: 60,
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: ws.layers.opacity,
                min: 0.1,
                max: 1,
                activeColor: FeColors.primaryLight,
                inactiveColor: st.sunlight ? Colors.white54 : Colors.white24,
                semanticFormatterCallback: (v) => '${(v * 100).round()}%',
                onChanged: ctrl.setOpacity,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, required this.onTap, this.active = false, this.dimmed = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  /// Shown but not available yet (the torch before the engine has one).
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    final fg = active ? st.activeFg : (dimmed ? (st.sunlight ? Colors.white60 : Colors.white38) : st.icon);
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: Material(
        color: active ? st.activeBg : Colors.transparent,
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
                Icon(icon, size: st.iconSize(22), color: fg),
                const SizedBox(height: 3),
                AppText.caption(
                  label,
                  color: fg,
                  weight: st.sunlight ? FontWeight.w700 : null,
                  style: st.text(Theme.of(context).textTheme.labelSmall),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// iPad: Single / Multi / Lasso as a visible vertical control.
class _SelectionRail extends StatelessWidget {
  const _SelectionRail({required this.mode, required this.onMode});
  final ArSelectMode mode;
  final ValueChanged<ArSelectMode> onMode;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: st.surface(), borderRadius: BorderRadius.circular(18), border: st.border()),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in ArSelectMode.values)
              Material(
                color: m == mode ? st.activeBg : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onMode(m),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44, minWidth: 116),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    child: Row(
                      children: [
                        Icon(arSelectIcon(m), size: st.iconSize(16), color: m == mode ? st.activeFg : st.fg),
                        const SizedBox(width: 8),
                        AppText.bodySmall(
                          'ar.select.${m.name}'.getString(context),
                          color: m == mode ? st.activeFg : st.fg,
                          weight: st.weight(FontWeight.w600),
                          style: st.text(Theme.of(context).textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData arSelectIcon(ArSelectMode m) => switch (m) {
  ArSelectMode.single => ArIcons.single,
  ArSelectMode.multi => ArIcons.multi,
  ArSelectMode.lasso => ArIcons.lasso,
};

/// Phone: Single | Multi | Lasso as one pill.
class ArSelectionPill extends StatelessWidget {
  const ArSelectionPill({super.key, required this.mode, required this.onMode});
  final ArSelectMode mode;
  final ValueChanged<ArSelectMode> onMode;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: st.surface(), borderRadius: BorderRadius.circular(14), border: st.border()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ArSelectMode.values)
            Material(
              color: m == mode ? st.activeBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onMode(m),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  alignment: Alignment.center,
                  child: AppText.bodySmall(
                    'ar.select.${m.name}'.getString(context),
                    color: m == mode ? st.activeFg : st.fg,
                    weight: st.weight(FontWeight.w600),
                    style: st.text(Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({required this.size, required this.onTap});
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'ar.work.capture'.getString(context),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ArChromeStyle.of(context).surface(),
            border: Border.all(color: Colors.white, width: size > 60 ? 4 : 3),
          ),
          child: const Icon(ArIcons.capture, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

enum _SheetExtent { peek, half, full }

/// Phone: the bottom sheet (peek, half, full) with the mode tab bar at its
/// foot, and the capture + selection row floating just above it.
class _PhoneSheet extends ConsumerStatefulWidget {
  const _PhoneSheet({required this.onCapture, required this.onBackToSetup});
  final VoidCallback onCapture;
  final VoidCallback onBackToSetup;

  @override
  ConsumerState<_PhoneSheet> createState() => _PhoneSheetState();
}

class _PhoneSheetState extends ConsumerState<_PhoneSheet> {
  var _extent = _SheetExtent.half;
  double _drag = 0;

  /// The extent before Drill check folded the sheet, restored after.
  _SheetExtent? _beforeDrill;

  double _height(double screen) => switch (_extent) {
    _SheetExtent.peek => 196,
    _SheetExtent.half => math.min(410, screen * 0.48),
    _SheetExtent.full => screen * 0.84,
  };

  void _settle(double velocity) {
    setState(() {
      if (velocity < -300 || _drag < -60) {
        _extent = _extent == _SheetExtent.peek ? _SheetExtent.half : _SheetExtent.full;
      } else if (velocity > 300 || _drag > 60) {
        _extent = _extent == _SheetExtent.full ? _SheetExtent.half : _SheetExtent.peek;
      }
      _drag = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Drill check aims with the view's centre: at "half" the sheet's top
    // edge sits right on the crosshair, so fold it to peek (its verdict card
    // comes first and still shows) and put it back afterwards.
    ref.listen<bool>(arWorkspaceProvider.select((w) => w.drilling), (prev, next) {
      if (next && prev != true) {
        _beforeDrill = _extent;
        setState(() => _extent = _SheetExtent.peek);
      } else if (!next && prev == true && _beforeDrill != null) {
        final back = _beforeDrill!;
        _beforeDrill = null;
        setState(() => _extent = back);
      }
    });
    final ws = ref.watch(arWorkspaceProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final screen = MediaQuery.sizeOf(context).height;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final h = (_height(screen) - _drag).clamp(150.0, screen * 0.9).toDouble() + bottomInset;
    return Stack(
      children: [
        AnimatedPositionedDirectional(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          start: 12,
          bottom: h + 12,
          child: Row(
            children: [
              _CaptureButton(size: 56, onTap: widget.onCapture),
              const SizedBox(width: 8),
              ArSelectionPill(mode: ws.selectMode, onMode: ctrl.setSelectMode),
            ],
          ),
        ),
        AnimatedPositioned(
          duration: _drag == 0 ? const Duration(milliseconds: 220) : Duration.zero,
          curve: Curves.easeOutCubic,
          left: 0,
          right: 0,
          bottom: 0,
          height: h,
          child: Material(
            color: FeColors.panel,
            elevation: 12,
            shadowColor: Colors.black38,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
                  onVerticalDragEnd: (d) => _settle(d.velocity.pixelsPerSecond.dy),
                  onTap: () => setState(() {
                    _extent = switch (_extent) {
                      _SheetExtent.peek => _SheetExtent.half,
                      _SheetExtent.half => _SheetExtent.full,
                      _SheetExtent.full => _SheetExtent.peek,
                    };
                  }),
                  child: SizedBox(
                    height: 26,
                    width: double.infinity,
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 5,
                        decoration: BoxDecoration(color: FeArColors.onGlassMuted, borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: ArModePanel(tablet: false, onBackToSetup: widget.onBackToSetup),
                  ),
                ),
                _TabBar(mode: ws.mode, onMode: ctrl.setMode),
                SizedBox(height: bottomInset),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.mode, required this.onMode});
  final ArMode mode;
  final ValueChanged<ArMode> onMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: FeColors.line))),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Row(
        children: [
          for (final m in ArMode.values)
            Expanded(
              child: Semantics(
                button: true,
                selected: m == mode,
                label: arModeLabel(context, m),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onMode(m),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(arModeIcon(m), size: 20, color: m == mode ? FeColors.primary : FeColors.ink2),
                        const SizedBox(height: 3),
                        AppText.caption(
                          arModeLabel(context, m),
                          color: m == mode ? FeColors.primary : FeColors.ink2,
                          weight: FontWeight.w600,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Phone "More": the tools that don't fit on the edge.
class _MoreTools extends ConsumerWidget {
  const _MoreTools({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    final s = ref.watch(arSessionProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final setup = ref.read(arSetupProvider.notifier);
    final sunlight = ref.watch(arPrefsProvider.select((p) => p.sunlight));
    return GestureDetector(
      onTap: onClose,
      child: ColoredBox(
        color: Colors.black26,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 70),
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 230,
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 24),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: FeColors.panel, borderRadius: BorderRadius.circular(18)),
                child: SingleChildScrollView(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (ref.watch(arInstallAllowedProvider))
                      _MoreRow(icon: ArIcons.board, label: 'ar.tool.board_long'.getString(context), onTap: () {
                        onClose();
                        setup.saveBoardFromWork();
                      }),
                    _MoreRow(
                      icon: ArIcons.section,
                      label: arTr(context, 'ar.tool.section_at', [arMetres(context, ws.layers.sectionHeightM)]),
                      selected: ws.layers.section,
                      onTap: ctrl.toggleSection,
                    ),
                    _MoreRow(
                      icon: ArIcons.xray,
                      label: 'ar.layers.xray'.getString(context),
                      selected: ws.layers.xray,
                      onTap: ctrl.toggleXray,
                    ),
                    _MoreRow(
                      icon: ArIcons.grid,
                      label: 'ar.tool.grid_long'.getString(context),
                      selected: s.gridVisible,
                      onTap: () => ref.read(arSessionProvider.notifier).setGridVisible(!s.gridVisible),
                    ),
                    _MoreRow(
                      icon: ArIcons.plan,
                      label: 'ar.menu.floor_plan'.getString(context),
                      selected: ws.planInCorner,
                      onTap: ctrl.togglePlanInCorner,
                    ),
                    _MoreRow(
                      icon: ArIcons.sunlight,
                      label: 'ar.menu.sunlight'.getString(context),
                      selected: sunlight,
                      onTap: () => ref.read(arPrefsProvider.notifier).setSunlight(!sunlight),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: AppText.caption(
                        arTr(context, 'ar.tool.opacity_value', ['${(ws.layers.opacity * 100).round()}']),
                        color: FeColors.ink2,
                      ),
                    ),
                    Slider(
                      value: ws.layers.opacity,
                      min: 0.1,
                      max: 1,
                      activeColor: FeColors.primary,
                      onChanged: ctrl.setOpacity,
                    ),
                  ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.icon, required this.label, required this.onTap, this.selected = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? FeColors.primary : FeColors.ink),
            const SizedBox(width: 12),
            Expanded(child: AppText.bodyMedium(label, weight: FontWeight.w600, color: selected ? FeColors.primary : FeColors.ink)),
            if (selected) const Icon(ArIcons.check, size: 16, color: FeColors.primary),
          ],
        ),
      ),
    );
  }
}

/// Compact vertical mode rail for a phone on its side: icon over a short
/// label, 56 px wide, so the camera keeps the middle of the screen.
class _CompactModeRail extends StatelessWidget {
  const _CompactModeRail({required this.mode, required this.onMode});
  final ArMode mode;
  final ValueChanged<ArMode> onMode;

  @override
  Widget build(BuildContext context) {
    final st = ArChromeStyle.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: st.surface(), borderRadius: BorderRadius.circular(16), border: st.border()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ArMode.values)
            Semantics(
              button: true,
              selected: m == mode,
              label: arModeLabel(context, m),
              child: Material(
                color: m == mode ? FeColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onMode(m),
                  child: SizedBox(
                    width: 58,
                    height: 50,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(arModeIcon(m), size: 18, color: m == mode ? Colors.white : st.fg),
                        const SizedBox(height: 2),
                        AppText.caption(
                          arModeLabel(context, m),
                          color: m == mode ? Colors.white : st.fg,
                          weight: st.weight(FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Torch" / "Torch on" / "Torch — coming in a later update".
String arTorchLabel(BuildContext context, ArWorkspaceState ws, {required bool available}) => !available
    ? 'ar.tool.torch_soon'.getString(context)
    : (ws.torch ? 'ar.tool.torch_on' : 'ar.tool.torch').getString(context);

/// Flips the torch; says so when this build's engine has no torch yet.
Future<void> arToggleTorch(BuildContext context, WidgetRef ref) async {
  ArHaptics.snap();
  final ok = await ref.read(arWorkspaceProvider.notifier).toggleTorch();
  if (!ok && context.mounted) {
    showTechPopup(context, message: 'ar.tool.torch_soon'.getString(context));
  }
}

/// "Re-check a corner or board": the session's re-anchor rule fired
/// (tracking lost, relocalised, or a long walk since the last reference).
/// Shown until a new corner or board clears it; the button starts a re-snap.
class _RecheckBanner extends StatelessWidget {
  const _RecheckBanner({required this.prompt, required this.onRecheck});
  final ArRecheckPrompt prompt;
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final text = switch (prompt.reason) {
      ReanchorReason.walkedFar => arTr(context, 'ar.recheck.walked', [prompt.walkedM.round()]),
      ReanchorReason.relocalized => 'ar.recheck.relocalized'.getString(context),
      ReanchorReason.trackingLost => 'ar.recheck.tracking_lost'.getString(context),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Material(
        color: FeArColors.placedBg,
        borderRadius: BorderRadius.circular(16),
        elevation: 6,
        shadowColor: Colors.black38,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 6, 6),
          child: Row(
            children: [
              const Icon(ArIcons.warning, size: 18, color: FeArColors.placedFg),
              const SizedBox(width: 8),
              Expanded(child: AppText.bodySmall(text, color: FeArColors.placedFg, weight: FontWeight.w700, maxLines: 3)),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: onRecheck,
                style: FilledButton.styleFrom(
                  backgroundColor: FeColors.ink,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(ArIcons.reSnap, size: 16, color: Colors.white),
                label: AppText.label('ar.work.recheck_action'.getString(context), color: Colors.white, weight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Double-tap on the camera and the Focus buttons: restart autofocus.
Future<void> arRefocus(WidgetRef ref) async {
  ArHaptics.snap();
  final ok = await ref.read(arSessionProvider.notifier).refocus();
  if (ok) ref.read(arSessionProvider.notifier).toast('ar.toast.refocusing');
}

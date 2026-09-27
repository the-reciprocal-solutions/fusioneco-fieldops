import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../state/ar_engine_extras.dart';
import '../../../state/ar_labels.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import '../widgets/ar_demo_scene.dart';
import '../widgets/ar_sunlight.dart';
import 'ar_discipline_legend.dart';
import 'ar_mode_panel.dart' show arPushFromSession;

/// Tag chips over the camera at each labelled element (the Locate target
/// outside Locate, the selection, snag pins): discipline dot + short name,
/// with a leader to the element. Positions come from the engine's
/// `projectTile` (through [ArEngineExtras], a no-op until the engine has
/// it), refreshed at most 5 times a second — the pose rate — and dropped
/// when the element is behind the camera or off screen. Demo mode places
/// them on its painted sample room instead.
///
/// Sits *under* the workspace chrome in the stack, so a chip never covers a
/// control; chips themselves take taps (select / open the snag).
class ArFloatingLabels extends ConsumerStatefulWidget {
  const ArFloatingLabels({super.key, required this.viewSize, this.topInset = 0, this.bottomInset = 0});

  final Size viewSize;

  /// Chips are kept clear of the top chrome and the bottom sheet/card.
  final double topInset;
  final double bottomInset;

  @override
  ConsumerState<ArFloatingLabels> createState() => _ArFloatingLabelsState();
}

class _ArFloatingLabelsState extends ConsumerState<ArFloatingLabels> {
  static const _interval = Duration(milliseconds: 200);

  List<ArPlacedLabel> _placed = const [];
  Timer? _timer;
  var _busy = false;
  var _again = false;
  var _at = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
  }

  @override
  void didUpdateWidget(covariant ArFloatingLabels old) {
    super.didUpdateWidget(old);
    if (old.viewSize != widget.viewSize || old.topInset != widget.topInset || old.bottomInset != widget.bottomInset) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Throttled to [_interval] with a trailing run (the pose the phone came
  /// to rest at is the one that must be labelled), one projection in flight.
  void _schedule() {
    if (!mounted) return;
    if (_busy) {
      _again = true;
      return;
    }
    if (_timer?.isActive ?? false) return;
    final wait = _interval - DateTime.now().difference(_at);
    if (wait <= Duration.zero) {
      unawaited(_run());
    } else {
      _timer = Timer(wait, () => unawaited(_run()));
    }
  }

  Future<void> _run() async {
    if (!mounted) return;
    _busy = true;
    _at = DateTime.now();
    try {
      final placed = await _compute();
      if (!mounted) return;
      setState(() => _placed = placed);
    } finally {
      _busy = false;
      if (_again && mounted) {
        _again = false;
        _schedule();
      }
    }
  }

  Future<List<ArPlacedLabel>> _compute() async {
    final s = ref.read(arSessionProvider);
    final ws = ref.read(arWorkspaceProvider);
    if (!s.isPlaced || s.stage != ArSessionStage.work || ws.drilling || ws.measuring) return const [];
    final anchors = ArLabels.anchorsFor(
      selection: ws.selection,
      target: s.target,
      // In Locate the big red target label (and its edge arrow) is drawn by
      // the workspace from `targetScreen` already.
      targetDrawnElsewhere: ws.mode == ArMode.locate,
      snagPins: ws.snagPins,
      showSnags: ws.mode == ArMode.snags || ws.layers.colourBy == ArColourBy.snags,
    );
    if (anchors.isEmpty) return const [];
    final view = widget.viewSize;
    final List<ArScreenPoint?> points;
    if (s.demo) {
      points = [
        for (final a in anchors)
          switch (a.feature == null ? null : ArDemoScene.demoAnchor(a.feature!.globalId)) {
            final Offset f? => ArScreenPoint(f.dx * view.width + s.nudgeM * 600, f.dy * view.height),
            null => null,
          },
      ];
    } else {
      final projected = await ref.read(arWorkspaceProvider.notifier).extras.projectTile([for (final a in anchors) a.posTile]);
      if (projected == null) return const [];
      points = projected;
    }
    final safe = Rect.fromLTRB(8, widget.topInset, view.width - 8, view.height - widget.bottomInset);
    if (safe.height < ArLabels.labelHeight) return const [];
    return ArLabels.layout(anchors: anchors, points: points, view: view, safe: safe);
  }

  Future<void> _tap(ArPlacedLabel l) async {
    ArHaptics.snap();
    final snag = l.anchor.snagId;
    if (snag != null) {
      await arPushFromSession(context, ref, Routes.snagDetail(snag));
      return;
    }
    final f = l.anchor.feature;
    if (f != null) ref.read(arWorkspaceProvider.notifier).selectOnly(f);
  }

  @override
  Widget build(BuildContext context) {
    // Re-place on pose (5 Hz), refit, target, selection, pins and mode.
    ref.listen(
      arSessionProvider.select((s) => (s.cameraAr, s.cameraForwardAr, s.fit, s.target, s.stage, s.nudgeM, s.features)),
      (_, _) => _schedule(),
    );
    ref.listen(
      arWorkspaceProvider.select((w) => (w.selection, w.snagPins, w.mode, w.drilling, w.measuring, w.layers.colourBy)),
      (_, _) => _schedule(),
    );
    if (_placed.isEmpty) return const SizedBox.shrink();
    final colourBy = ref.watch(arWorkspaceProvider.select((w) => w.mode == ArMode.progress ? ArColourBy.progress : w.layers.colourBy));
    return Stack(
      children: [
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _LeaderPainter(_placed)))),
        for (final l in _placed)
          Positioned.fromRect(
            rect: l.rect,
            child: _LabelChip(label: l, coloured: colourBy == ArColourBy.discipline, onTap: () => _tap(l)),
          ),
      ],
    );
  }
}

class _LabelChip extends StatelessWidget {
  const _LabelChip({required this.label, required this.coloured, required this.onTap});

  final ArPlacedLabel label;
  final bool coloured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = label.anchor;
    final st = ArChromeStyle.of(context);
    final (Color border, IconData? icon) = switch (a.kind) {
      ArLabelKind.target => (FeColors.danger, ArIcons.locate),
      ArLabelKind.selected => (FeColors.primaryLight, null),
      ArLabelKind.snag => (FeColors.danger, ArIcons.snags),
    };
    return Semantics(
      button: true,
      label: a.title,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: st.surface(strong: true),
            borderRadius: BorderRadius.circular(10),
            // The kind colour (red target/snag, blue selection) is the
            // label's meaning, so Sunlight keeps it — just thicker — rather
            // than the plain white outline.
            border: Border.all(color: border, width: st.sunlight ? 2.5 : 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: st.iconSize(13), color: border),
                const SizedBox(width: 5),
              ],
              ArLegendDot(colour: arDisciplineColor(a.discipline, coloured: coloured), filled: a.discipline != ArDiscipline.walls, size: 9),
              const SizedBox(width: 6),
              Flexible(
                child: AppText.caption(
                  a.title,
                  color: st.fg,
                  weight: st.weight(FontWeight.w700),
                  style: st.text(Theme.of(context).textTheme.labelSmall),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin leader from each chip to its element, with a dot on the element.
class _LeaderPainter extends CustomPainter {
  _LeaderPainter(this.labels);
  final List<ArPlacedLabel> labels;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    final halo = Paint()..color = Colors.black.withValues(alpha: 0.35);
    for (final l in labels) {
      final from = l.rect.center.dy < l.point.dy ? l.rect.bottomCenter : l.rect.topCenter;
      canvas.drawLine(from, l.point, line);
      canvas.drawCircle(l.point, 5, halo);
      canvas.drawCircle(l.point, 3.2, Paint()..color = l.anchor.kind == ArLabelKind.selected ? FeColors.primaryLight : FeColors.danger);
    }
  }

  @override
  bool shouldRepaint(covariant _LeaderPainter old) => !identical(old.labels, labels);
}

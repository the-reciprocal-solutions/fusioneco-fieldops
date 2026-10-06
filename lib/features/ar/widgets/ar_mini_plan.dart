import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/ar/corner_matcher.dart';
import '../../../core/ar/vec.dart';
import '../../../state/ar_view_models.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';

/// A numbered stop on the plan (install run walking order).
class ArPlanStop {
  const ArPlanStop({required this.number, required this.pos, required this.done, this.next = false});
  final int number;
  final Vec3 pos;
  final bool done;
  final bool next;
}

/// The mini plan (S1, TabSnap's side card, the models preview, I1 and I2):
/// walls, columns, rooms and doors from `GET /floors/:id/plan`, with the
/// overlay that step needs — numbered corner choices (stars for the best),
/// grid lines with bubbles, boards, the ghost board, the walking route, the
/// user's position and heading, and the target.
///
/// Plan coordinates are the tile frame's XZ with x to the right and z
/// downward, like the web plan (CONTRACT C6), so the phone and the office
/// see the same picture. RTL doesn't mirror it: a plan is a map, not text.
///
/// Readable at phone size (first iPhone run 2026-10-06: a 140 px plan of a
/// data-centre floor drew dozens of overlapping element tags and corner pins
/// 3–8 on top of each other):
/// - element (equipment) tags are off unless [showEquipmentNames];
/// - room names and pins never overlap — a pin that would collide with one
///   already drawn becomes a small dot (zoom in to number it);
/// - the selected corner carries its shape: an L of two walls for an inside
///   corner, a filled block for a column / outside corner;
/// - [zoomable] adds pinch-zoom and drag (double-tap resets); [onExpand]
///   adds a full-screen button.
class ArMiniPlan extends StatefulWidget {
  const ArMiniPlan({
    super.key,
    this.plan,
    this.corners = const [],
    this.selectedCornerId,
    this.cornerNumbers,
    this.matchShape,
    this.gridLines = const [],
    this.markers = const [],
    this.highlightMarkerCode,
    this.ghost,
    this.camera,
    this.heading,
    this.target,
    this.stops = const [],
    this.focus,
    this.focusRadiusM = 8,
    this.onTapCorner,
    this.stars = 3,
    this.background = FeArColors.planPaper,
    this.showSpaceNames = true,
    this.showEquipmentNames = false,
    this.zoomable = false,
    this.onExpand,
    this.expandTooltip,
  });

  final ArPlan? plan;

  /// In rank order: the first is "1", the first [stars] get a star.
  final List<CornerCandidate> corners;
  final String? selectedCornerId;

  /// The number to print on each corner's pin, by corner id, when the list
  /// drawn is not the whole numbered list (default: position + 1).
  final Map<String, int>? cornerNumbers;

  /// `inside | outside`: only corners of this shape are offered (the others
  /// are drawn faint and can't be tapped) — after a snap of that shape.
  final String? matchShape;
  final List<ArGridLine> gridLines;
  final List<ArMarkerInfo> markers;
  final String? highlightMarkerCode;
  final Vec3? ghost;
  final Vec3? camera;
  final Vec2? heading;
  final Vec3? target;
  final List<ArPlanStop> stops;

  /// Zoom to this plan point instead of the whole floor.
  final Vec2? focus;
  final double focusRadiusM;
  final ValueChanged<CornerCandidate>? onTapCorner;
  final int stars;
  final Color background;
  final bool showSpaceNames;

  /// Element tags on equipment ("STTCC-EB-00-EMV01-EE-…"): unreadable at
  /// phone size, so off unless asked for.
  final bool showEquipmentNames;
  final bool zoomable;
  final VoidCallback? onExpand;
  final String? expandTooltip;

  /// A focus radius that frames [focus] and its few nearest [corners]
  /// (a room, not 18 m of floor): between [minM] and [maxM].
  static double fitRadius(
    Vec2 focus,
    List<CornerCandidate> corners, {
    int neighbours = 3,
    double minM = 3.5,
    double maxM = 9,
  }) {
    final d = [for (final c in corners) c.posTile.xz.distanceTo(focus)]..sort();
    final others = d.where((x) => x > 0.05).toList();
    if (others.isEmpty) return minM;
    final reach = others[math.min(neighbours, others.length) - 1];
    return (reach + 1.5).clamp(minM, maxM).toDouble();
  }

  @override
  State<ArMiniPlan> createState() => _ArMiniPlanState();
}

class _ArMiniPlanState extends State<ArMiniPlan> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  static const _maxZoom = 8.0;
  var _zoom = 1.0;
  var _pan = Offset.zero;
  var _startZoom = 1.0;

  @override
  void didUpdateWidget(covariant ArMiniPlan old) {
    super.didUpdateWidget(old);
    // A new focus (another corner picked) re-frames from scratch.
    final a = old.focus, b = widget.focus;
    if ((a == null) != (b == null) || (a != null && b != null && a.distanceTo(b) > 0.01)) {
      _zoom = 1;
      _pan = Offset.zero;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  _PlanFrame _frame(Size size) {
    final base = _baseFrame(widget, size);
    // Pinch-zoom about the view centre, then the drag.
    final cx = size.width / 2, cz = size.height / 2;
    return _PlanFrame(
      scale: base.scale * _zoom,
      ox: (base.ox - cx) * _zoom + cx + _pan.dx,
      oz: (base.oz - cz) * _zoom + cz + _pan.dy,
    );
  }

  void _onTap(TapUpDetails details, Size size) {
    final cb = widget.onTapCorner;
    if (cb == null || widget.corners.isEmpty) return;
    final pins = _layoutPins(widget, _frame(size), size);
    _PinSpot? best;
    var bestD = double.infinity;
    for (final p in pins) {
      if (p.dim) continue;
      // Numbered pins are generous targets; a dot needs a closer tap.
      final reach = p.full ? 30.0 : 14.0;
      final d = (p.at - details.localPosition).distance;
      if (d < reach && d < bestD) {
        bestD = d;
        best = p;
      }
    }
    if (best != null) cb(best.corner);
  }

  void _onScaleStart(ScaleStartDetails d) => _startZoom = _zoom;

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    final next = (_startZoom * d.scale).clamp(1.0, _maxZoom).toDouble();
    final c = Offset(size.width / 2, size.height / 2);
    final f = d.localFocalPoint;
    setState(() {
      // Keep the plan point under the fingers still while zooming.
      _pan = f - c - (f - c - _pan) * (next / _zoom) + d.focalPointDelta;
      _zoom = next;
      if (_zoom <= 1.0001) _pan = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight.isFinite ? constraints.maxHeight : constraints.maxWidth * 0.66);
        final paint = RepaintBoundary(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CustomPaint(
              size: size,
              painter: _PlanPainter(
                widget: widget,
                frame: _frame(size),
                pulse: _pulse.value,
                labelStyle: (text.labelSmall ?? const TextStyle()).copyWith(color: FeColors.ink2, fontWeight: FontWeight.w600),
                numberStyle: (text.labelSmall ?? const TextStyle()).copyWith(fontWeight: FontWeight.w800),
                gridStyle: (text.labelMedium ?? const TextStyle()).copyWith(color: FeArColors.gridline, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        );
        return SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: widget.onTapCorner == null ? null : (d) => _onTap(d, size),
                onScaleStart: widget.zoomable ? _onScaleStart : null,
                onScaleUpdate: widget.zoomable ? (d) => _onScaleUpdate(d, size) : null,
                onDoubleTap: widget.zoomable && _zoom > 1
                    ? () => setState(() {
                          _zoom = 1;
                          _pan = Offset.zero;
                        })
                    : null,
                child: paint,
              ),
              if (widget.onExpand != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Material(
                    color: FeColors.panel.withValues(alpha: 0.92),
                    shape: const CircleBorder(),
                    child: IconButton(
                      key: const ValueKey('ar-plan-expand'),
                      tooltip: widget.expandTooltip,
                      icon: const Icon(Icons.open_in_full, size: 18, color: FeColors.ink),
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      padding: EdgeInsets.zero,
                      onPressed: widget.onExpand,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The unzoomed frame: [ArMiniPlan.focus] ± its radius, else the plan's
/// bounds, else everything drawn.
_PlanFrame _baseFrame(ArMiniPlan widget, Size size) {
  double minX, minZ, maxX, maxZ;
  final f = widget.focus;
  if (f != null) {
    minX = f.x - widget.focusRadiusM;
    maxX = f.x + widget.focusRadiusM;
    minZ = f.y - widget.focusRadiusM;
    maxZ = f.y + widget.focusRadiusM;
  } else if (widget.plan != null) {
    minX = widget.plan!.minX;
    minZ = widget.plan!.minZ;
    maxX = widget.plan!.maxX;
    maxZ = widget.plan!.maxZ;
  } else {
    final pts = <Vec2>[
      for (final c in widget.corners) c.posTile.xz,
      for (final m in widget.markers) m.posTile.xz,
      for (final s in widget.stops) s.pos.xz,
    ];
    if (pts.isEmpty) {
      minX = 0;
      minZ = 0;
      maxX = 10;
      maxZ = 10;
    } else {
      minX = pts.map((p) => p.x).reduce(math.min) - 2;
      maxX = pts.map((p) => p.x).reduce(math.max) + 2;
      minZ = pts.map((p) => p.y).reduce(math.min) - 2;
      maxZ = pts.map((p) => p.y).reduce(math.max) + 2;
    }
  }
  const pad = 14.0;
  final w = math.max(0.1, maxX - minX);
  final d = math.max(0.1, maxZ - minZ);
  final scale = math.min((size.width - pad * 2) / w, (size.height - pad * 2) / d);
  final ox = (size.width - w * scale) / 2 - minX * scale;
  final oz = (size.height - d * scale) / 2 - minZ * scale;
  return _PlanFrame(scale: scale, ox: ox, oz: oz);
}

class _PlanFrame {
  const _PlanFrame({required this.scale, required this.ox, required this.oz});
  final double scale;
  final double ox;
  final double oz;

  Offset toScreen(double x, double z) => Offset(x * scale + ox, z * scale + oz);
}

/// Where a corner's pin lands on screen and how it is drawn.
class _PinSpot {
  const _PinSpot({required this.corner, required this.number, required this.at, required this.full, required this.dim, required this.selected, required this.index});
  final CornerCandidate corner;
  final int number;
  final Offset at;

  /// A numbered pin (false: a small dot, because a numbered pin would cover
  /// another one).
  final bool full;

  /// Not the shape the user snapped: faint and not tappable.
  final bool dim;
  final bool selected;
  final int index;

  double get radius => selected ? 12 : (full ? 9 : 3.5);
}

const _selectedR = 12.0;
const _pinR = 9.0;

/// The unzoomed pin layout, for tests.
@visibleForTesting
List<({String id, int number, Offset at, bool full, bool dim})> debugLayoutPins(ArMiniPlan w, Size size) => [
      for (final p in _layoutPins(w, _baseFrame(w, size), size))
        (id: p.corner.id, number: p.number, at: p.at, full: p.full, dim: p.dim),
    ];

/// Lays the corner pins out without overlaps: the selected corner first,
/// then the snapped shape's corners, then rank order. A pin that would
/// overlap one already placed becomes a dot. Pins off the view are dropped.
List<_PinSpot> _layoutPins(ArMiniPlan w, _PlanFrame frame, Size size) {
  bool dimFor(CornerCandidate c) => w.matchShape != null && CornerMatcher.shapeOf(c.kind) != w.matchShape;
  final order = List<int>.generate(w.corners.length, (i) => i);
  int prio(int i) {
    final c = w.corners[i];
    if (c.id == w.selectedCornerId) return 0;
    return dimFor(c) ? 2 : 1;
  }

  order.sort((a, b) {
    final p = prio(a).compareTo(prio(b));
    return p != 0 ? p : a.compareTo(b);
  });
  final placed = <_PinSpot>[];
  final out = <_PinSpot>[];
  for (final i in order) {
    final c = w.corners[i];
    final at = frame.toScreen(c.posTile.x, c.posTile.z);
    if (at.dx < -4 || at.dy < -4 || at.dx > size.width + 4 || at.dy > size.height + 4) continue;
    final selected = c.id == w.selectedCornerId;
    final r = selected ? _selectedR : _pinR;
    final clash = !selected && placed.any((p) => (p.at - at).distance < p.radius + r + 2);
    final spot = _PinSpot(
      corner: c,
      number: w.cornerNumbers?[c.id] ?? i + 1,
      at: at,
      full: !clash,
      dim: dimFor(c),
      selected: selected,
      index: i,
    );
    if (!clash) placed.add(spot);
    out.add(spot);
  }
  return out;
}

class _PlanPainter extends CustomPainter {
  _PlanPainter({
    required this.widget,
    required this.frame,
    required this.pulse,
    required this.labelStyle,
    required this.numberStyle,
    required this.gridStyle,
  });

  final ArMiniPlan widget;
  final _PlanFrame frame;
  final double pulse;
  final TextStyle labelStyle;
  final TextStyle numberStyle;
  final TextStyle gridStyle;

  Offset _p(double x, double z) => frame.toScreen(x, z);

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRRect(r, Paint()..color = widget.background);

    // Pins first, so room names keep clear of them.
    final pins = _layoutPins(widget, frame, size);
    final taken = <Rect>[
      for (final p in pins)
        if (p.full) Rect.fromCircle(center: p.at, radius: p.radius + 3),
    ];
    final plan = widget.plan;
    if (plan != null) _paintPlan(canvas, plan, taken);
    _paintGrid(canvas, size);
    _paintRoute(canvas);
    _paintMarkers(canvas);
    _paintGhost(canvas);
    _paintTarget(canvas);
    _paintCorners(canvas, pins);
    _paintCamera(canvas);
    canvas.restore();
  }

  void _paintPlan(Canvas canvas, ArPlan plan, List<Rect> taken) {
    final wallW = math.max(2.0, frame.scale * 0.2);
    final spaceFill = Paint()..color = FeColors.panel;
    for (final s in plan.spaces) {
      if (s.polygon.length < 3) continue;
      final path = Path()..moveTo(_p(s.polygon.first.x, s.polygon.first.y).dx, _p(s.polygon.first.x, s.polygon.first.y).dy);
      for (final v in s.polygon.skip(1)) {
        final o = _p(v.x, v.y);
        path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas.drawPath(path, spaceFill);
    }
    final equip = Paint()..color = FeArColors.manualBg;
    final equipLine = Paint()
      ..color = FeColors.ink2.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final e in plan.equipment) {
      if (e.polygon.length < 3) continue;
      final path = _poly(e.polygon, close: true);
      canvas.drawPath(path, equip);
      canvas.drawPath(path, equipLine);
    }
    final wall = Paint()
      ..color = FeArColors.planWall
      ..style = PaintingStyle.stroke
      ..strokeWidth = wallW
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;
    for (final w in plan.walls) {
      if (w.length < 2) continue;
      canvas.drawPath(_poly(w), wall);
    }
    final door = Paint()
      ..color = FeColors.panel
      ..strokeWidth = wallW + 1.5
      ..strokeCap = StrokeCap.butt;
    final swing = Paint()
      ..color = FeColors.ink2.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final d in plan.doors) {
      if (d.length < 2) continue;
      final a = _p(d[0].x, d[0].y);
      final b = _p(d[1].x, d[1].y);
      canvas.drawLine(a, b, door);
      final radius = (b - a).distance;
      canvas.drawArc(Rect.fromCircle(center: a, radius: radius), (b - a).direction, math.pi / 2, false, swing);
    }
    final column = Paint()..color = FeArColors.planWall;
    for (final c in plan.columns) {
      if (c.length < 3) continue;
      canvas.drawPath(_poly(c, close: true), column);
    }
    if (widget.showSpaceNames && frame.scale > 6) {
      for (final s in plan.spaces) {
        _textClear(canvas, s.name, _p(s.labelAt.x, s.labelAt.y), labelStyle, taken);
      }
    }
    if (widget.showEquipmentNames && frame.scale > 6) {
      for (final e in plan.equipment) {
        if (e.polygon.isEmpty) continue;
        var cx = 0.0, cz = 0.0;
        for (final v in e.polygon) {
          cx += v.x;
          cz += v.y;
        }
        _textClear(canvas, e.name, _p(cx / e.polygon.length, cz / e.polygon.length), labelStyle.copyWith(fontSize: 9), taken);
      }
    }
  }

  /// A centred label, skipped when it would overlap a pin or another label.
  void _textClear(Canvas canvas, String s, Offset at, TextStyle style, List<Rect> taken) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 110);
    final rect = Rect.fromCenter(center: at, width: tp.width + 4, height: tp.height + 2);
    if (taken.any((r) => r.overlaps(rect))) return;
    taken.add(rect);
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  Path _poly(List<Vec2> pts, {bool close = false}) {
    final first = _p(pts.first.x, pts.first.y);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final v in pts.skip(1)) {
      final o = _p(v.x, v.y);
      path.lineTo(o.dx, o.dy);
    }
    if (close) path.close();
    return path;
  }

  void _paintGrid(Canvas canvas, Size size) {
    if (widget.gridLines.isEmpty) return;
    final paint = Paint()
      ..color = FeArColors.gridline
      ..strokeWidth = 1.6;
    for (final g in widget.gridLines) {
      final a = _p(g.p0.x, g.p0.y);
      final b = _p(g.p1.x, g.p1.y);
      _dashDot(canvas, a, b, paint);
      // Bubble at the end that is inside the view, near an edge.
      final bubble = _clampInside(a, size) ? a : b;
      canvas.drawCircle(bubble, 8, Paint()..color = widget.background);
      canvas.drawCircle(
        bubble,
        8,
        Paint()
          ..color = FeArColors.gridline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      _text(canvas, g.name, bubble, gridStyle.copyWith(fontSize: 9), center: true);
    }
  }

  bool _clampInside(Offset p, Size s) => p.dx >= 6 && p.dy >= 6 && p.dx <= s.width - 6 && p.dy <= s.height - 6;

  void _dashDot(Canvas canvas, Offset a, Offset b, Paint paint) {
    final total = (b - a).distance;
    if (total < 1) return;
    final dir = (b - a) / total;
    const pattern = [10.0, 4.0, 2.0, 4.0];
    var t = 0.0;
    var i = 0;
    while (t < total) {
      final len = pattern[i % 4];
      if (i % 2 == 0) {
        canvas.drawLine(a + dir * t, a + dir * math.min(total, t + len), paint);
      }
      t += len;
      i++;
    }
  }

  void _paintRoute(Canvas canvas) {
    final stops = widget.stops;
    if (stops.isEmpty) return;
    final line = Paint()
      ..color = FeColors.primary.withValues(alpha: 0.35)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < stops.length; i++) {
      final a = _p(stops[i - 1].pos.x, stops[i - 1].pos.z);
      final b = _p(stops[i].pos.x, stops[i].pos.z);
      canvas.drawLine(a, b, line);
    }
    for (final s in stops) {
      final c = _p(s.pos.x, s.pos.z);
      final color = s.done ? FeColors.success : (s.next ? FeColors.primary : FeArColors.notStartedDot);
      if (s.next) {
        canvas.drawCircle(c, 11 + 8 * pulse, Paint()..color = FeColors.primary.withValues(alpha: 0.25 * (1 - pulse)));
      }
      canvas.drawCircle(c, 10, Paint()..color = color);
      canvas.drawCircle(
        c,
        10,
        Paint()
          ..color = FeColors.panel
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _text(canvas, s.done ? '✓' : '${s.number}', c, numberStyle.copyWith(color: FeColors.panel, fontSize: 10), center: true);
    }
  }

  void _paintMarkers(Canvas canvas) {
    for (final m in widget.markers) {
      if (m.isSpare) continue;
      final c = _p(m.posTile.x, m.posTile.z);
      final highlight = m.code == widget.highlightMarkerCode;
      final color = m.status == 'active'
          ? FeColors.success
          : (m.usableForAlignment ? FeColors.warning : FeArColors.notStartedDot);
      if (highlight) {
        canvas.drawCircle(c, 10 + 8 * pulse, Paint()..color = FeColors.warning.withValues(alpha: 0.3 * (1 - pulse)));
      }
      final rect = Rect.fromCenter(center: c, width: 10, height: 10);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), Paint()..color = color);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()
          ..color = FeColors.panel
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  void _paintGhost(Canvas canvas) {
    final g = widget.ghost;
    if (g == null) return;
    final c = _p(g.x, g.z);
    final paint = Paint()
      ..color = FeColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rect = Rect.fromCenter(center: c, width: 14 + 4 * pulse, height: 14 + 4 * pulse);
    canvas.drawRect(rect, paint);
  }

  void _paintTarget(Canvas canvas) {
    final t = widget.target;
    if (t == null) return;
    final c = _p(t.x, t.z);
    canvas.drawCircle(c, 9 + 10 * pulse, Paint()..color = FeColors.danger.withValues(alpha: 0.25 * (1 - pulse)));
    canvas.drawCircle(c, 7, Paint()..color = FeColors.danger);
    canvas.drawCircle(
      c,
      7,
      Paint()
        ..color = FeColors.panel
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _paintCorners(Canvas canvas, List<_PinSpot> pins) {
    // Dots under numbered pins, the selected corner on top.
    final ordered = [
      ...pins.where((p) => !p.full),
      ...pins.where((p) => p.full && !p.selected),
      ...pins.where((p) => p.selected),
    ];
    for (final p in ordered) {
      final c = p.at;
      final color = p.dim ? FeArColors.notStartedDot : FeColors.primary;
      if (!p.full) {
        canvas.drawCircle(c, 3.5, Paint()..color = color);
        continue;
      }
      if (p.selected) {
        _paintShape(canvas, p.corner, c);
        canvas.drawCircle(c, 16 + 6 * pulse, Paint()..color = FeColors.primary.withValues(alpha: 0.22 * (1 - pulse)));
        canvas.drawCircle(c, _selectedR, Paint()..color = FeColors.primary);
        canvas.drawCircle(
          c,
          _selectedR,
          Paint()
            ..color = FeColors.panel
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
        _text(canvas, '${p.number}', c, numberStyle.copyWith(color: FeColors.panel), center: true);
      } else {
        canvas.drawCircle(c, _pinR, Paint()..color = FeColors.panel);
        canvas.drawCircle(
          c,
          _pinR,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = p.dim ? 1.2 : 2,
        );
        _text(canvas, '${p.number}', c, numberStyle.copyWith(color: color, fontSize: 9), center: true);
      }
      if (p.index < widget.stars && !p.dim) {
        _text(canvas, '★', c + const Offset(10, -10), numberStyle.copyWith(color: FeColors.warning, fontSize: 10), center: true);
      }
    }
  }

  /// The selected corner's shape, drawn under its pin so the user knows
  /// what to look for: an inside corner is two walls meeting (an L along
  /// the walls, room side), a column / outside corner is a solid block.
  ///
  /// Face normals point out of the material toward free space, so an inside
  /// corner's walls run along +faceA and +faceB, and a column's body lies
  /// toward −faceA and −faceB (same rule as the ghost-board fallback).
  void _paintShape(Canvas canvas, CornerCandidate corner, Offset c) {
    final a = Offset(corner.faceA.x, corner.faceA.y);
    final b = Offset(corner.faceB.x, corner.faceB.y);
    if (a.distance < 1e-6 || b.distance < 1e-6) return;
    final ua = a / a.distance, ub = b / b.distance;
    if (corner.kind == 'inside') {
      final wall = Paint()
        ..color = FeColors.ink
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.square;
      canvas.drawLine(c, c + ua * 26, wall);
      canvas.drawLine(c, c + ub * 26, wall);
    } else {
      const s = 20.0;
      final block = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo((c - ua * s).dx, (c - ua * s).dy)
        ..lineTo((c - ua * s - ub * s).dx, (c - ua * s - ub * s).dy)
        ..lineTo((c - ub * s).dx, (c - ub * s).dy)
        ..close();
      canvas.drawPath(block, Paint()..color = FeColors.ink.withValues(alpha: 0.75));
    }
  }

  void _paintCamera(Canvas canvas) {
    final cam = widget.camera;
    if (cam == null) return;
    final c = _p(cam.x, cam.z);
    final h = widget.heading;
    if (h != null && h.length > 1e-6) {
      final dir = Offset(h.x, h.y) / h.length;
      final left = Offset(-dir.dy, dir.dx);
      final cone = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo((c + dir * 34 + left * 16).dx, (c + dir * 34 + left * 16).dy)
        ..lineTo((c + dir * 34 - left * 16).dx, (c + dir * 34 - left * 16).dy)
        ..close();
      canvas.drawPath(cone, Paint()..color = FeColors.primary.withValues(alpha: 0.18));
    }
    canvas.drawCircle(c, 8, Paint()..color = FeColors.panel);
    canvas.drawCircle(c, 5.5, Paint()..color = FeColors.primary);
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style, {bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 140);
    final o = center ? at - Offset(tp.width / 2, tp.height / 2) : at;
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(covariant _PlanPainter old) =>
      old.pulse != pulse ||
      old.widget != widget ||
      old.frame.scale != frame.scale ||
      old.frame.ox != frame.ox ||
      old.frame.oz != frame.oz;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import 'ar_sunlight.dart';

/// The snap pin in the middle of the view (§2.3). Idle it breathes; when a
/// corner is snapped it tightens, turns solid and draws the two detected
/// wall faces as thin lines, so the user *sees* that the phone found the
/// edge before they tap.
class ArSnapPin extends StatefulWidget {
  const ArSnapPin({super.key, required this.snapped, this.faceAngles});

  final bool snapped;

  /// Screen-space directions of the two faces (radians), when snapped.
  final (double, double)? faceAngles;

  @override
  State<ArSnapPin> createState() => _ArSnapPinState();
}

class _ArSnapPinState extends State<ArSnapPin> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          size: const Size(180, 180),
          painter: _SnapPinPainter(t: _c.value, snapped: widget.snapped, faces: widget.faceAngles),
        ),
      ),
    );
  }
}

class _SnapPinPainter extends CustomPainter {
  _SnapPinPainter({required this.t, required this.snapped, this.faces});
  final double t;
  final bool snapped;
  final (double, double)? faces;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (snapped && faces != null) {
      final face = Paint()
        ..color = FeArColors.snap.withValues(alpha: 0.85)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      for (final a in [faces!.$1, faces!.$2]) {
        canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * 80, face);
      }
      canvas.drawLine(
        c + const Offset(0, -86),
        c + const Offset(0, 86),
        Paint()
          ..color = FeArColors.snap
          ..strokeWidth = 3,
      );
    }
    final halo = snapped ? 30.0 : 34 + 8 * t;
    canvas.drawCircle(
      c,
      halo,
      Paint()
        ..color = FeArColors.snap.withValues(alpha: snapped ? 0.6 : 0.35 + 0.2 * (1 - t))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(c, 16, Paint()..color = snapped ? FeColors.primary : FeColors.primary.withValues(alpha: 0.7));
    canvas.drawCircle(
      c,
      16,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final cross = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c + const Offset(0, -9), c + const Offset(0, 9), cross);
    canvas.drawLine(c + const Offset(-9, 0), c + const Offset(9, 0), cross);
  }

  @override
  bool shouldRepaint(covariant _SnapPinPainter old) => old.t != t || old.snapped != snapped || old.faces != faces;
}

/// M3's hold-still ring: a rounded frame around the board that fills as the
/// lock completes, plus bracket corners that turn green on lock.
class ArLockRing extends StatelessWidget {
  const ArLockRing({super.key, required this.progress, this.width = 170, this.height = 216, this.ok = true});

  final double progress;
  final double width;
  final double height;

  /// False while the coaching chips say something is wrong: the ring greys.
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: progress.clamp(0, 1).toDouble()),
        duration: const Duration(milliseconds: 120),
        builder: (context, v, _) => CustomPaint(
          size: Size(width, height),
          painter: _LockRingPainter(progress: v, ok: ok),
        ),
      ),
    );
  }
}

class _LockRingPainter extends CustomPainter {
  _LockRingPainter({required this.progress, required this.ok});
  final double progress;
  final bool ok;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(4);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(22));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final done = progress >= 1;
    final color = !ok ? FeArColors.onGlassMuted : (done ? FeColors.success : FeArColors.snap);
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
    final c = rect.center;
    final cross = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, 5, Paint()..color = color);
    canvas.drawLine(c + const Offset(0, -20), c + const Offset(0, -10), cross);
    canvas.drawLine(c + const Offset(0, 10), c + const Offset(0, 20), cross);
    canvas.drawLine(c + const Offset(-20, 0), c + const Offset(-10, 0), cross);
    canvas.drawLine(c + const Offset(10, 0), c + const Offset(20, 0), cross);
  }

  @override
  bool shouldRepaint(covariant _LockRingPainter old) => old.progress != progress || old.ok != ok;
}

/// M4's radar: you in the middle, facing up; the next board as an amber dot
/// in its real direction. [bearingRad] is the angle from "ahead", clockwise.
class ArRadar extends StatefulWidget {
  const ArRadar({super.key, required this.bearingRad, this.size = 72});

  final double? bearingRad;
  final double size;

  @override
  State<ArRadar> createState() => _ArRadarState();
}

class _ArRadarState extends State<ArRadar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _RadarPainter(bearing: widget.bearingRad, sweep: _c.value),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.bearing, required this.sweep});
  final double? bearing;
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    canvas.drawCircle(c, r, Paint()..color = FeArColors.manualBg);
    canvas.drawCircle(
      c,
      r * 0.66,
      Paint()
        ..color = FeColors.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      c,
      r * sweep,
      Paint()
        ..color = FeColors.primary.withValues(alpha: 0.18 * (1 - sweep))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(c, 5, Paint()..color = FeColors.primary);
    final b = bearing;
    if (b == null) return;
    final tip = c + Offset(math.sin(b), -math.cos(b)) * (r * 0.72);
    canvas.drawLine(
      c,
      tip,
      Paint()
        ..color = FeColors.primary
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(tip, 6, Paint()..color = FeArColors.placedDot);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => old.bearing != bearing || old.sweep != sweep;
}

/// The install celebration: a one-shot confetti burst from the check mark.
/// Short (1.6 s) and never blocking — the next-board button is live under it.
class ArCelebration extends StatefulWidget {
  const ArCelebration({super.key, this.pieces = 70});

  final int pieces;

  @override
  State<ArCelebration> createState() => _ArCelebrationState();
}

class _ArCelebrationState extends State<ArCelebration> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..forward();
  late final List<_Piece> _pieces = List.generate(widget.pieces, (i) {
    final r = math.Random(i * 7919 + 13);
    return _Piece(
      angle: -math.pi / 2 + (r.nextDouble() - 0.5) * math.pi * 1.3,
      speed: 240 + r.nextDouble() * 320,
      spin: (r.nextDouble() - 0.5) * 12,
      size: 5 + r.nextDouble() * 6,
      color: FeArColors.confetti[i % FeArColors.confetti.length],
      round: r.nextBool(),
    );
  });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => _c.isCompleted
            ? const SizedBox.shrink()
            : CustomPaint(size: Size.infinite, painter: _ConfettiPainter(t: _c.value, pieces: _pieces)),
      ),
    );
  }
}

class _Piece {
  const _Piece({
    required this.angle,
    required this.speed,
    required this.spin,
    required this.size,
    required this.color,
    required this.round,
  });
  final double angle;
  final double speed;
  final double spin;
  final double size;
  final Color color;
  final bool round;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.t, required this.pieces});
  final double t;
  final List<_Piece> pieces;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.32);
    final seconds = t * 1.6;
    for (final p in pieces) {
      final dx = math.cos(p.angle) * p.speed * seconds;
      final dy = math.sin(p.angle) * p.speed * seconds + 520 * seconds * seconds;
      final pos = origin + Offset(dx, dy);
      final paint = Paint()..color = p.color.withValues(alpha: (1 - t).clamp(0, 1).toDouble());
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * seconds);
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.size / 2, paint);
      } else {
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55), paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
}

/// The Locate arrow at the edge of the view when the target is off screen
/// (§1.1). [angle] is the screen direction to the target (0 = right,
/// clockwise, radians); the arrow sits on the ellipse inside the view.
class ArEdgeArrow extends StatelessWidget {
  const ArEdgeArrow({super.key, required this.angle, required this.label, required this.viewSize});

  final double angle;
  final String label;
  final Size viewSize;

  @override
  Widget build(BuildContext context) {
    final rx = viewSize.width / 2 - 56;
    final ry = viewSize.height / 2 - 120;
    final c = Offset(viewSize.width / 2, viewSize.height / 2);
    final pos = c + Offset(math.cos(angle) * rx, math.sin(angle) * ry);
    return Positioned(
      left: pos.dx - 44,
      top: pos.dy - 44,
      width: 88,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: angle,
              child: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(color: FeColors.danger, shape: BoxShape.circle),
                child: const CustomPaint(painter: _ArrowPainter()),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: ArChromeStyle.of(context).surface(strong: true),
                borderRadius: BorderRadius.circular(8),
                border: ArChromeStyle.of(context).border(),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (ArChromeStyle.of(context).text(Theme.of(context).textTheme.labelSmall) ??
                        Theme.of(context).textTheme.labelSmall)
                    ?.copyWith(color: Colors.white, fontWeight: ArChromeStyle.of(context).weight(FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final path = Path()
      ..moveTo(c.dx + 14, c.dy)
      ..lineTo(c.dx - 8, c.dy - 11)
      ..lineTo(c.dx - 3, c.dy)
      ..lineTo(c.dx - 8, c.dy + 11)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) => false;
}

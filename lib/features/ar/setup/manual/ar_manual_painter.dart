import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../state/ar_manual_place_controller.dart' show ManualScreen;
import '../../../../theme/fe_ar_colors.dart';
import '../../../../theme/fe_colors.dart';

/// Draws "Place by hand" over the camera: the model's outline on the floor,
/// the centre puck to grab, and in the corner tool the model's corner
/// handles, the room corners the phone found and the magnet ring. All
/// positions come from the engine's projection ([ManualScreen]); nothing is
/// drawn for a point behind the camera.
class ArManualPainter extends CustomPainter {
  ArManualPainter({
    required this.screen,
    required this.cornerMode,
    required this.grabbed,
    required this.fine,
    required this.sunlight,
  });

  final ManualScreen screen;
  final bool cornerMode;
  final int? grabbed;
  final bool fine;
  final bool sunlight;

  /// Radius of the centre puck's ring (logical px).
  static const puckRadius = 30.0;

  /// Corner handle radius; the touch target is larger ([handleHitRadius]).
  static const handleRadius = 13.0;
  static const handleHitRadius = 36.0;

  Offset? _o((double, double, bool)? p) => p == null ? null : Offset(p.$1, p.$2);

  @override
  void paint(Canvas canvas, Size size) {
    final line = sunlight ? Colors.white : FeArColors.snap;
    final shadow = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = sunlight ? 6 : 4.5
      ..strokeJoin = StrokeJoin.round;
    final stroke = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = sunlight ? 3.5 : 2.5
      ..strokeJoin = StrokeJoin.round;

    // Outline: every edge whose two ends are in front of the camera.
    final pts = [for (final p in screen.outline) _o(p)];
    if (pts.length >= 2) {
      final path = Path();
      final fill = Path();
      var fillable = true;
      for (var i = 0; i < pts.length; i++) {
        final a = pts[i], b = pts[(i + 1) % pts.length];
        if (a == null) fillable = false;
        if (a == null || b == null) continue;
        path
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy);
      }
      if (fillable) {
        fill.addPolygon([for (final p in pts) p!], true);
        canvas.drawPath(fill, Paint()..color = line.withValues(alpha: 0.10));
      }
      canvas.drawPath(path, shadow);
      canvas.drawPath(path, stroke);
    }

    // Centre puck: a ring with four ticks ("grab here").
    final c = _o(screen.pivot);
    if (c != null) {
      final ring = fine ? FeColors.warning : line;
      canvas.drawCircle(c, puckRadius, shadow);
      canvas.drawCircle(
        c,
        puckRadius,
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = fine ? 2 : 3,
      );
      canvas.drawCircle(c, puckRadius - 3, Paint()..color = ring.withValues(alpha: 0.18));
      canvas.drawCircle(c, 5, Paint()..color = ring);
      final tick = Paint()
        ..color = ring
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      for (var k = 0; k < 4; k++) {
        final a = k * math.pi / 2;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * (puckRadius + 4), c + d * (puckRadius + 11), tick);
      }
    }

    if (!cornerMode) return;

    // Room corners the phone found: green crosses on the floor.
    final room = Paint()
      ..color = FeArColors.installed
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final r in screen.roomCorners) {
      final p = _o(r);
      if (p == null) continue;
      canvas.drawCircle(p, 11, Paint()..color = Colors.black45);
      canvas.drawLine(p - const Offset(8, 0), p + const Offset(8, 0), room);
      canvas.drawLine(p - const Offset(0, 8), p + const Offset(0, 8), room);
    }

    // The room corner the dragged corner will land on.
    final m = _o(screen.magnet);
    if (m != null) {
      canvas.drawCircle(
        m,
        22,
        Paint()
          ..color = FeArColors.installed
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    // Model corner handles.
    for (var i = 0; i < screen.corners.length; i++) {
      final p = _o(screen.corners[i]);
      if (p == null) continue;
      final active = i == grabbed;
      final r = active ? handleRadius + 5 : handleRadius;
      canvas.drawCircle(p, r + 2, Paint()..color = Colors.black45);
      canvas.drawCircle(p, r, Paint()..color = active ? line : Colors.white);
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..color = active ? Colors.white : line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    // The pinned corner (sizes grow out from it).
    final pin = _o(screen.pinned);
    if (pin != null) {
      canvas.drawCircle(pin, 7, Paint()..color = FeColors.warning);
      canvas.drawCircle(
        pin,
        17,
        Paint()
          ..color = FeColors.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(ArManualPainter old) =>
      !identical(old.screen, screen) ||
      old.cornerMode != cornerMode ||
      old.grabbed != grabbed ||
      old.fine != fine ||
      old.sunlight != sunlight;
}

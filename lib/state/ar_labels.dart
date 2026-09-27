import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../core/ar/vec.dart';
import 'ar_engine_extras.dart' show ArScreenPoint;
import 'ar_view_models.dart';
import 'ar_workspace_controller.dart';

/// Floating labels over the camera (P-010 "projectTile for Flutter-drawn pin
/// labels"): a small chip with the element's tag and discipline colour at
/// the element's projected screen position, for the Locate target, the
/// selection and the snag pins. The native view is headless (CHANNEL.md:
/// it never draws text), so labels are Flutter's, placed from the engine's
/// `projectTile` at pose rate. Everything here is pure, so it's tested
/// without an engine.

enum ArLabelKind { target, selected, snag }

class ArLabelAnchor {
  const ArLabelAnchor({
    required this.id,
    required this.kind,
    required this.title,
    required this.posTile,
    required this.discipline,
    this.feature,
    this.snagId,
  });

  final String id;
  final ArLabelKind kind;
  final String title;
  final Vec3 posTile;
  final ArDiscipline discipline;
  final ArFeature? feature;
  final String? snagId;
}

/// A label placed on screen: [rect] is the chip, [point] the element.
class ArPlacedLabel {
  const ArPlacedLabel({required this.anchor, required this.rect, required this.point});

  final ArLabelAnchor anchor;
  final Rect rect;
  final Offset point;
}

abstract final class ArLabels {
  /// A floor with 40 selected elements must not become a wall of chips.
  static const maxLabels = 8;

  static const labelHeight = 30.0;

  /// The element's tag when it has a short one ("AHU-03", "IV-12"), else its
  /// name, else its IFC type: what a technician reads off the plant itself.
  static String shortName(ArFeature f) {
    for (final key in const ['Tag', 'Mark', 'Reference']) {
      final v = f.prop(key);
      if (v != null && v.length <= 18) return v;
    }
    final name = f.displayName.trim();
    return name.length <= 26 ? name : '${name.substring(0, 25)}…';
  }

  /// Where a label hangs: runs (pipes, ducts, trays) at their middle, where
  /// the eye follows them; boxes (equipment, valves) at the top centre.
  static Vec3 anchorPoint(ArFeature f) {
    final c = f.centre;
    return f.isRun ? c : Vec3(c.x, math.max(f.bboxMin.y, f.bboxMax.y), c.z);
  }

  /// The labels to draw, strongest first: the target (unless the Locate
  /// overlay already draws its big red label), the selection, then snag
  /// pins. Duplicates collapse onto the strongest kind; capped at
  /// [maxLabels].
  static List<ArLabelAnchor> anchorsFor({
    required List<ArFeature> selection,
    required ArFeature? target,
    required bool targetDrawnElsewhere,
    List<ArSnagPin> snagPins = const [],
    bool showSnags = true,
  }) {
    final out = <ArLabelAnchor>[];
    final seen = <String>{};
    String key(ArFeature f) => '${f.buildId}#${f.featureId}';
    void add(ArFeature f, ArLabelKind kind) {
      if (out.length >= maxLabels || !seen.add(key(f))) return;
      out.add(ArLabelAnchor(
        id: '${kind.name}:${key(f)}',
        kind: kind,
        title: shortName(f),
        posTile: anchorPoint(f),
        discipline: ArDiscipline.of(f.discipline),
        feature: f,
      ));
    }

    if (target != null) {
      if (targetDrawnElsewhere) {
        seen.add(key(target));
      } else {
        add(target, ArLabelKind.target);
      }
    }
    for (final f in selection) {
      add(f, ArLabelKind.selected);
    }
    if (showSnags) {
      for (final p in snagPins) {
        final f = p.feature;
        if (out.length >= maxLabels) break;
        if (!seen.add(key(f))) continue;
        final c = f.centre;
        out.add(ArLabelAnchor(
          id: 'snag:${p.snagId}',
          kind: ArLabelKind.snag,
          title: p.title.trim().isEmpty ? shortName(f) : p.title.trim(),
          // Where `setPins` draws the snag diamond: 20 cm over the element.
          posTile: Vec3(c.x, math.max(f.bboxMin.y, f.bboxMax.y) + 0.2, c.z),
          discipline: ArDiscipline.of(f.discipline),
          feature: f,
          snagId: p.snagId,
        ));
      }
    }
    return out;
  }

  /// A chip's width from its text: a dot, the text, padding. Measured
  /// roughly on purpose (the layout runs at 5 Hz); the chip itself sizes to
  /// its text and ellipsises beyond [maxWidth].
  static double estimateWidth(String title, {double maxWidth = 190}) =>
      (38 + title.length * 7.4).clamp(64, maxWidth).toDouble();

  /// Places each anchor's chip just above its projected point. Anchors that
  /// are behind the camera, off screen or unplaced are dropped (no edge
  /// arrows here: the Locate target keeps its own). Overlaps are resolved in
  /// priority order by stepping the weaker chip up, then down; a chip that
  /// still collides is dropped rather than drawn over another.
  static List<ArPlacedLabel> layout({
    required List<ArLabelAnchor> anchors,
    required List<ArScreenPoint?> points,
    required Size view,
    Rect? safe,
  }) {
    final area = safe ?? (Offset.zero & view);
    final placed = <ArPlacedLabel>[];
    for (var i = 0; i < anchors.length && i < points.length; i++) {
      final p = points[i];
      if (p == null || !p.onScreen) continue;
      if (!p.x.isFinite || !p.y.isFinite) continue;
      if (p.x < 0 || p.y < 0 || p.x > view.width || p.y > view.height) continue;
      if (!area.contains(Offset(p.x, p.y))) continue;
      final a = anchors[i];
      final w = estimateWidth(a.title);
      Rect at(double dy) {
        final left = (p.x - w / 2).clamp(area.left, math.max(area.left, area.right - w)).toDouble();
        final top = (p.y - labelHeight - 12 + dy).clamp(area.top, math.max(area.top, area.bottom - labelHeight)).toDouble();
        return Rect.fromLTWH(left, top, w, labelHeight);
      }

      Rect? chosen;
      for (final dy in const [0.0, -34.0, -68.0, 46.0, 80.0]) {
        final r = at(dy);
        if (!placed.any((o) => o.rect.inflate(2).overlaps(r))) {
          chosen = r;
          break;
        }
      }
      if (chosen == null) continue;
      placed.add(ArPlacedLabel(anchor: a, rect: chosen, point: Offset(p.x, p.y)));
    }
    return placed;
  }
}

import 'package:flutter/material.dart';

/// Tier 2 (semantic) status/priority/condition/SLA hues, ported from the web
/// technician portal's `app/globals.css` light (`:root`) block
/// (`fusion-eco-client` repo). Computed here via [HSLColor] rather than
/// hand-transcribed hex, so the contrast guarantee the source documents
/// can't drift from a copy/paste slip.
///
/// `theme_extensions.dart` composes these raw hues into the soft-pastel
/// [FeChipStyle] pills the app's chips already use (background/foreground/
/// border), rather than the web's solid-fill-plus-white-text badge look —
/// keeps the existing chip visual language, just sourced from one true hue
/// per status/priority instead of the old duplicated Tailwind palette.
/// 2026-11-03: the main hues follow the owner's colourful design sheet
/// (text-safe 600 shades of its swatches); the rest keep the web's values.
abstract final class FeStatusHues {
  static Color _hsl(double h, double s, double l) =>
      HSLColor.fromAHSL(1, h, s / 100, l / 100).toColor();

  // ---- work-order / task lifecycle status --------------------------------
  static final open = const Color(0xFF2563EB);
  static final inProgress = const Color(0xFFD97706);
  static final onHold = const Color(0xFF7C3AED);
  static final completed = const Color(0xFF059669);
  static final cancelled = _hsl(220, 9, 40);
  static final overdue = const Color(0xFFDC2626);
  static final draft = _hsl(220, 9, 42);

  // ---- priority ------------------------------------------------------------
  static final priorityLow = const Color(0xFF16A34A);
  static Color get priorityMedium => inProgress; // one shared hue, source-identical
  static final priorityHigh = const Color(0xFFEA580C);
  static final priorityCritical = const Color(0xFFDC2626);

  // ---- asset condition (V4 lifecycle + twin overlays) ---------------------
  static Color get conditionExcellent => completed;
  static final conditionGood = _hsl(122, 40, 33);
  static final conditionFair = _hsl(45, 93, 30);
  static final conditionPoor = _hsl(25, 88, 40);
  static Color get conditionCritical => priorityCritical;

  // ---- SLA state ------------------------------------------------------------
  static Color get slaOk => completed;
  static Color get slaAtRisk => inProgress;
  static Color get slaBreached => priorityCritical;
}

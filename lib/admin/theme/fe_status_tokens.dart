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
abstract final class FeStatusHues {
  static Color _hsl(double h, double s, double l) =>
      HSLColor.fromAHSL(1, h, s / 100, l / 100).toColor();

  // ---- work-order / task lifecycle status --------------------------------
  static final open = _hsl(217, 91, 45);
  static final inProgress = _hsl(38, 92, 32);
  static final onHold = _hsl(271, 60, 48);
  static final completed = _hsl(152, 61, 28);
  static final cancelled = _hsl(220, 9, 40);
  static final overdue = _hsl(0, 74, 42);
  static final draft = _hsl(220, 9, 42);

  // ---- priority ------------------------------------------------------------
  static final priorityLow = _hsl(152, 45, 32);
  static Color get priorityMedium => inProgress; // one shared hue, source-identical
  static final priorityHigh = _hsl(21, 90, 42);
  static final priorityCritical = _hsl(0, 79, 40);

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

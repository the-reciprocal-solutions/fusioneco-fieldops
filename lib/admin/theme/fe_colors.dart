import 'package:flutter/material.dart';

/// Tier 2 (semantic) neutrals and brand color for the "Navy Professional"
/// light redesign — off-white surfaces, navy ink, a blue CTA accent.
/// Replaces the earlier dark-slate/emerald palette this file briefly
/// carried: the dark theme read as too heavy/gloomy for a field app used
/// outdoors, so this reverts to light while keeping the token-driven
/// architecture (only values changed, not names or shape).
///
/// Status/priority/condition/SLA colors live in `fe_status_tokens.dart`
/// instead — they're a distinct, larger semantic group in the source file.
abstract final class FeColors {
  // ---- 2026-11-04 teal redesign (owner's design-system sheet v1.0) ----------
  static const primary = Color(0xFF0E7A6B); // brand teal
  static const onPrimary = Colors.white;

  /// Lighter teal — a gradient partner where a flat brand fill needs a
  /// second stop (hero cards, progress ring).
  static const primaryLight = Color(0xFF14A08C);

  /// Secondary brand hue (blue) — the second gradient stop of hero cards.
  static const secondary = Color(0xFF0B5ED7);

  /// Scaffold background — the lightest surface in the app.
  static const page = Color(0xFFF8FAFC);

  /// The soft mint wash behind page headers (under the header art).
  static const headerTop = Color(0xFFCFEFE8);
  static const headerBottom = Color(0xFFE3F3F4);

  /// A selected control's fill: readable with any label colour.
  static const selectedTint = Color(0xFFD6F0EA);

  /// Card/panel surface — pure white, one step brighter than [page].
  static const panel = Color(0xFFFFFFFF);
  static const line = Color(0xFFE2E8F0);
  static const ink = Color(0xFF0F172A); // navy — main text/icon color
  static const ink2 = Color(0xFF64748B); // muted text

  /// The web's "Preventive Maintenance Dashboard" module accent — indigo,
  /// scoped to that one dashboard module, NOT the app-wide brand color.
  static const dashboardAccent = Color(0xFF6366F1);
  static const dashboardAccent2 = Color(0xFF818CF8);
  static const dashboardAccentSoft = Color(0xFFEEF2FF);

  static const success = Color(0xFF16A34A);
  static const successSoft = Color(0xFFECFDF5);
  static const warning = Color(0xFFF59E0B);
  static const warningSoft = Color(0xFFFFFBEB);
  static const danger = Color(0xFFEF4444);
  static const dangerSoft = Color(0xFFFEF2F2);
  static const info = Color(0xFF0EA5E9);
  static const infoSoft = Color(0xFFF0F9FF);

  /// Severity scale of the design sheet (critical/high/medium/low).
  static const critical = Color(0xFFEF4444);
  static const high = Color(0xFFF97316);
  static const medium = Color(0xFFF59E0B);
  static const low = Color(0xFF22C55E);

  /// AI teammates in conversations — violet. Only for AI.
  static const ai = Color(0xFF7C3AED);
  static const aiSoft = Color(0xFFF5F3FF);
  static const aiLine = Color(0xFFDDD6FE);

  /// Icon-tile colours, cycled across menu rows and tiles so each module
  /// reads as its own colour (blue, orange, green, violet, red, amber, sky, pink).
  static const tilePalette = <Color>[
    Color(0xFF0B5ED7),
    Color(0xFFF97316),
    Color(0xFF16A34A),
    Color(0xFF7C3AED),
    Color(0xFFEF4444),
    Color(0xFFF59E0B),
    Color(0xFF0EA5E9),
    Color(0xFFEC4899),
  ];
  static Color tile(int i) => tilePalette[i % tilePalette.length];
}

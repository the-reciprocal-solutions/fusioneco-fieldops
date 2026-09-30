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
  static const primary = Color(0xFF0369A1); // CTA/brand blue
  static const onPrimary = Colors.white;

  /// Lighter blue — a gradient partner where a flat brand fill needs a
  /// second stop (hero avatar, progress ring).
  static const primaryLight = Color(0xFF0EA5E9); // sky-500

  /// Scaffold background — the lightest surface in the app.
  static const page = Color(0xFFF8FAFC);

  /// Card/panel surface — pure white, one step brighter than [page].
  static const panel = Color(0xFFFFFFFF);
  static const line = Color(0xFFE2E8F0);
  static const ink = Color(0xFF0F172A); // navy — main text/icon color
  static const ink2 = Color(0xFF64748B); // muted text

  /// The web's "Preventive Maintenance Dashboard" module accent
  /// (`--brand`/`--brand-2`/`--brand-soft` in globals.css) — indigo, scoped
  /// to that one dashboard module, NOT the app-wide brand color. Reach for
  /// this only where a screen deliberately mirrors that module's look; use
  /// [primary] everywhere else.
  static const dashboardAccent = Color(0xFF6366F1);
  static const dashboardAccent2 = Color(0xFF818CF8);
  static const dashboardAccentSoft = Color(0xFFEEF2FF);

  static const success = Color(0xFF10B981);
  static const successSoft = Color(0xFFECFDF5);
  static const warning = Color(0xFFF59E0B);
  static const warningSoft = Color(0xFFFFFBEB);
  static const danger = Color(0xFFEF4444);
  static const dangerSoft = Color(0xFFFEF2F2);
  static const info = Color(0xFF3B82F6);
  static const infoSoft = Color(0xFFEFF6FF);

  /// AI teammates in conversations (agent avatar ring, "AI" tag, working
  /// card) — violet, matching the web's agent accent. Only for AI.
  static const ai = Color(0xFF7C3AED);
  static const aiSoft = Color(0xFFF5F3FF);
  static const aiLine = Color(0xFFDDD6FE);

  // This app is light-only. If a dark variant is ever wanted again, this
  // file's git history has the exact Modern Enterprise Dark values to
  // restore instead of re-deriving them.
}

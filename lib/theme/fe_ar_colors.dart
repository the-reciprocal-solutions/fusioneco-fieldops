import 'package:flutter/material.dart';

import 'fe_colors.dart';

/// Colours for the AR overlay (docs/ar-setup-and-gamma-parity.md §2.9, canvas
/// rows 6–8). Everything the AR screens draw *over the camera* needs its own
/// small palette: the app's light "Navy Professional" surfaces are for pages,
/// while AR chrome floats on a live, often dark and busy video feed, so it
/// uses translucent navy glass with light text, plus a few signal colours
/// that read on any wall (snap cyan, gridline orange).
///
/// Badge colours follow the honesty rule in §2.7: amber = placed, green =
/// locked (measured), grey = adjusted by hand, red = the site disagrees with
/// the model. Never reuse [lockedBg] for anything that was not measured.
abstract final class FeArColors {
  // ---- glass chrome over the camera --------------------------------------
  /// `rgba(15,23,42,.62)` — rails, round buttons, the selection pill.
  static const glass = Color(0x9E0F172A);

  /// `rgba(15,23,42,.72)` — callouts and chips that sit over busy video.
  static const glassStrong = Color(0xB80F172A);

  /// White at 12% — secondary buttons that sit directly on the camera.
  static const glassLight = Color(0x1FFFFFFF);
  static const onGlass = Color(0xFFE2E8F0);
  static const onGlassMuted = Color(0xFFCBD5E1);

  // ---- Sunlight mode (high contrast) -------------------------------------
  /// `#0B0F14` at ~92 % — opaque enough that a sunlit wall can't bleed
  /// through, yet the camera still reads as "behind" the control.
  static const sunlightSurface = Color(0xEB0B0F14);
  static const onSunlight = Color(0xFFFFFFFF);
  static const sunlightOutline = Color(0xFFFFFFFF);

  // ---- signal colours in the scene ---------------------------------------
  /// The snap pin's halo and the detected wall faces.
  static const snap = Color(0xFF38BDF8);

  /// Model edges once placed (architecture drawn as lines, §6.6).
  static const edge = Color(0xFF22D3EE);

  /// Structural grid lines drawn on the slab (GAMMA's orange dash-dot).
  static const gridline = Color(0xFFFB923C);

  // ---- discipline legend -------------------------------------------------
  /// An opaque colour from a feature-state tint (`arDisciplineRgb`, 0xRRGGBB).
  /// The legend reads the discipline palette from the tints the model is
  /// drawn with, so a chip can never disagree with the overlay.
  static Color fromRgb(int rgb) => Color(0xFF000000 | (rgb & 0xFFFFFF));

  /// Structure keeps its layer look (ghosted slate); its legend dot matches.
  static const structure = Color(0xFF94A3B8);

  /// A dot for "not colouring by discipline right now" (progress, system…).
  static const legendNeutral = Color(0xFF64748B);

  // ---- drill check -------------------------------------------------------
  static const drillSafe = FeColors.success;
  static const drillCaution = FeColors.warning;
  static const drillDanger = FeColors.danger;

  // ---- honest badges (§2.7) ---------------------------------------------
  static const lockedBg = FeColors.successSoft;
  static const lockedFg = Color(0xFF065F46);
  static const lockedIcon = Color(0xFF059669);
  static const placedBg = FeColors.warningSoft;
  static const placedFg = Color(0xFF92400E);
  static const placedDot = FeColors.warning;
  static const manualBg = Color(0xFFF1F5F9);
  static const manualFg = Color(0xFF334155);
  static const mismatchBg = FeColors.dangerSoft;
  static const mismatchFg = Color(0xFFB91C1C);

  // ---- progress status (four-eyes, AR-50) --------------------------------
  static const notStartedBg = Color(0xFFF1F5F9);
  static const notStartedFg = Color(0xFF334155);
  static const notStartedDot = Color(0xFF94A3B8);
  static const installed = Color(0xFF22C55E);
  static const installedFg = Color(0xFF047857);
  static const verified = Color(0xFF15803D);
  static const snagBorder = Color(0xFFFCA5A5);
  static const snagPin = Color(0xFF7F1D1D);

  // ---- the Demo-mode camera stand-in (matches the canvas mock-ups) -------
  static const cameraCeiling = Color(0xFF2A2E33);
  static const cameraWallSide = Color(0xFF30353B);
  static const cameraWall = Color(0xFF3E444B);
  static const cameraFloor = Color(0xFF24282D);
  static const cameraTrim = Color(0xFF5B636C);
  static const cameraDoor = Color(0xFF2A2F34);
  static const cameraDoorFrame = Color(0xFF5A616A);
  static const cameraEquipment = Color(0xFF2F6B4F);
  static const cameraEquipmentTop = Color(0xFF3D8A66);
  static const boardPaper = Color(0xFFF4F4F2);
  static const boardInk = Color(0xFF111111);

  /// A calm slate for the placeholder when no camera is available at all.
  static const planPaper = Color(0xFFF1F5F9);
  static const planWall = Color(0xFF334155);

  /// Confetti for the install celebration. Brand blues, the success green and
  /// a warm amber so it reads as a party rather than a status colour.
  static const confetti = <Color>[
    FeColors.primary,
    FeColors.primaryLight,
    FeColors.success,
    FeColors.warning,
    Color(0xFFF472B6),
    Color(0xFFA78BFA),
  ];
}

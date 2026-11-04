import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'fe_colors.dart';
import 'theme_extensions.dart';

/// Light-only. 2026-11-04: the owner's teal redesign (brand teal #0E7A6B +
/// blue #0B5ED7, Inter, picture headers, glass cards, coloured icon tiles).
/// It ships no dark variant.
abstract final class AppTheme {
  static ThemeData build() {
    final primaryContainer = Color.alphaBlend(
      FeColors.primary.withValues(alpha: 0.10),
      FeColors.panel,
    );
    final secondaryContainer = Color.alphaBlend(
      FeColors.ink2.withValues(alpha: 0.10),
      FeColors.panel,
    );

    final scheme = ColorScheme(
      brightness: Brightness.light,
      primary: FeColors.primary,
      onPrimary: FeColors.onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: FeColors.primary,
      // A muted neutral, not a second "dark chrome" surface — the header no
      // longer paints a dark bar by default, see FeHeader.
      secondary: FeColors.secondary,
      onSecondary: Colors.white,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: FeColors.ink,
      // The web dashboard module's own accent (see FeColors.dashboardAccent
      // doc comment) — a real, distinct hue, appropriate for the scheme's
      // tertiary role rather than a stand-in for the brand color.
      tertiary: FeColors.dashboardAccent,
      onTertiary: Colors.white,
      error: FeColors.danger,
      onError: Colors.white,
      errorContainer: FeColors.dangerSoft,
      onErrorContainer: FeColors.danger,
      surface: FeColors.panel,
      onSurface: FeColors.ink,
      onSurfaceVariant: FeColors.ink2,
      surfaceContainerLowest: FeColors.panel,
      surfaceContainerLow: FeColors.page,
      surfaceContainer: FeColors.page,
      outline: FeColors.line,
      outlineVariant: FeColors.line.withValues(alpha: 0.6),
      scrim: const Color(0x80000000),
      shadow: const Color(0x0D000000),
      inverseSurface: FeColors.ink,
      onInverseSurface: Colors.white,
    );

    final text = _textTheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: FeColors.page,
      canvasColor: FeColors.panel,
      splashFactory: InkRipple.splashFactory,
      textTheme: text,
      // A sane default matching FeHeader's standard variant, kept as a
      // fallback for any bare AppBar() that isn't routed through FeHeader —
      // FeHeader itself always sets its own colors explicitly and never
      // reads this. See widgets/fe_header.dart.
      appBarTheme: AppBarTheme(
        backgroundColor: FeColors.headerTop,
        foregroundColor: FeColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 56,
        centerTitle: false,
        titleTextStyle: text.titleMedium?.copyWith(color: FeColors.ink),
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: FeColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: FeColors.primary.withValues(alpha: 0.5),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.8),
          elevation: 0,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: text.labelLarge,
          animationDuration: const Duration(milliseconds: 120),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: FeColors.panel,
          foregroundColor: FeColors.ink,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          side: BorderSide(color: FeColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: text.labelLarge,
          animationDuration: const Duration(milliseconds: 120),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: FeColors.primary,
          textStyle: text.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: FeColors.panel,
        constraints: const BoxConstraints(minHeight: 40),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: text.bodyMedium?.copyWith(color: FeColors.ink2),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: FeColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: FeColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: FeColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: FeColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: FeColors.danger, width: 2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: FeColors.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium?.copyWith(color: FeColors.ink2),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: FeColors.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: FeColors.panel,
        selectedColor: FeColors.selectedTint,
        checkmarkColor: FeColors.primary,
        showCheckmark: false,
        side: BorderSide(color: FeColors.line),
        shape: const StadiumBorder(),
        labelStyle: text.labelLarge?.copyWith(color: FeColors.ink),
        secondaryLabelStyle: text.labelLarge?.copyWith(color: FeColors.primary),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
      // Selected = soft teal tint + teal text (like the filter chips), not a
      // solid fill: a label that sets its own colour stays readable on it.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: FeColors.panel,
          foregroundColor: FeColors.ink,
          selectedBackgroundColor: FeColors.selectedTint,
          selectedForegroundColor: FeColors.primary,
          side: BorderSide(color: FeColors.line),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: FeColors.primary,
        foregroundColor: Colors.white,
      ),
      dividerTheme: DividerThemeData(
        color: FeColors.line,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: FeColors.primary,
        linearTrackColor: FeColors.page,
        linearMinHeight: 12,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: FeColors.line, width: 1.5),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? FeColors.primary
              : Colors.transparent,
        ),
      ),
      extensions: const <ThemeExtension<dynamic>>[
        FeStatusColors(),
        FeElevation(),
        FeSpacing(),
        FeRadii(),
        FeMetrics(),
        FeMotion(),
        FeOrderTypeColors(),
        FeAccents(),
      ],
    );
  }

  static TextTheme _textTheme() {
    const onSurface = FeColors.ink;
    const onSurfaceMuted = FeColors.ink2;
    final base = TextTheme(
      displaySmall: const TextStyle(
        fontSize: 36,
        height: 40 / 36,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.9,
        color: onSurface,
      ),
      headlineMedium: const TextStyle(
        fontSize: 28,
        height: 36 / 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: onSurface,
      ),
      headlineSmall: const TextStyle(
        fontSize: 24,
        height: 32 / 24,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      titleLarge: const TextStyle(
        fontSize: 20,
        height: 28 / 20,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      titleMedium: const TextStyle(
        fontSize: 18,
        height: 26 / 18,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      titleSmall: const TextStyle(
        fontSize: 16,
        height: 24 / 16,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      bodyLarge: const TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w400,
        color: onSurfaceMuted,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w500,
        color: onSurfaceMuted,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: FontWeight.w500,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: onSurfaceMuted,
      ),
      labelSmall: const TextStyle(
        fontSize: 10,
        height: 14 / 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: onSurfaceMuted,
      ),
    );
    return GoogleFonts.interTextTheme(base);
  }
}

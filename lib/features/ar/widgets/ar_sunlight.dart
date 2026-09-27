import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/ar_prefs_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';

/// Sunlight mode (high-contrast AR chrome). On a bright site the translucent
/// navy glass over the camera washes out: a sunlit wall behind a 62 % navy
/// pill leaves light-grey text on mid-grey. Sunlight mode swaps every piece
/// of chrome that floats on the camera for an opaque near-black surface with
/// pure white text and icons, a 1.5 px white outline, text 1.5 sp larger and
/// one weight heavier; "active" becomes solid brand blue with white. White
/// decision cards ([ArCard], the menu sheet) are already opaque and stay.
///
/// It is applied centrally: the shared chrome widgets ([ArGlassButton],
/// [ArGlassChip], [ArStatusBadge], the legend and floating-label chips, the
/// drill crosshair pill, the workspace rails) read [ArChromeStyle.of], so a
/// new call site gets it for free. The pref lives in [ArPrefsController]
/// (`ArPrefsState.sunlight`) and reaches the tree through one
/// [ArSunlightHost] at the root of each AR screen; with no host (a widget
/// test of a single control, a non-AR screen) everything reads as glass.

/// Carries the current Sunlight flag down the AR screen.
class ArSunlightScope extends InheritedWidget {
  const ArSunlightScope({super.key, required this.on, required super.child});

  final bool on;

  /// False when there is no scope above [context].
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ArSunlightScope>()?.on ?? false;

  @override
  bool updateShouldNotify(ArSunlightScope oldWidget) => oldWidget.on != on;
}

/// Watches the saved pref and provides [ArSunlightScope] to [child]. Put one
/// at the root of every screen that draws chrome over the camera.
class ArSunlightHost extends ConsumerWidget {
  const ArSunlightHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(arPrefsProvider.select((s) => s.sunlight));
    return ArSunlightScope(on: on, child: child);
  }
}

/// The colours, outline and type tweaks for chrome over the camera, glass or
/// Sunlight. One place, so a control can't be half-converted.
@immutable
class ArChromeStyle {
  const ArChromeStyle._(this.sunlight);

  static const glass = ArChromeStyle._(false);
  static const highContrast = ArChromeStyle._(true);

  final bool sunlight;

  static ArChromeStyle of(BuildContext context) => ArSunlightScope.of(context) ? highContrast : glass;

  /// Outline width in Sunlight mode.
  static const outlineWidth = 1.5;

  /// How much larger chrome text is in Sunlight mode (logical px ≈ sp).
  static const textBoost = 1.5;

  /// The pill/button/rail fill. [strong] is the denser glass used over busy
  /// video (callouts, labels); Sunlight has one opaque fill for both.
  Color surface({bool strong = false}) =>
      sunlight ? FeArColors.sunlightSurface : (strong ? FeArColors.glassStrong : FeArColors.glass);

  /// Text and icons on [surface].
  Color get fg => sunlight ? FeArColors.onSunlight : FeArColors.onGlass;

  /// Secondary text (counts, chevrons). Sunlight keeps it white: muted grey
  /// is exactly what sunlight erases.
  Color get fgMuted => sunlight ? FeArColors.onSunlight : FeArColors.onGlassMuted;

  /// Icons that are white on glass already (buttons, rails).
  Color get icon => sunlight ? FeArColors.onSunlight : Colors.white;

  /// An active/selected control: white glass-inverse normally, solid brand
  /// blue in Sunlight (a white pill with a white outline would glare).
  Color get activeBg => sunlight ? FeColors.primary : Colors.white;
  Color get activeFg => sunlight ? Colors.white : FeColors.ink;

  /// The outline around a control, or null on glass.
  BoxBorder? border({Color? colour, double? width}) => sunlight
      ? Border.all(color: colour ?? FeArColors.sunlightOutline, width: width ?? outlineWidth)
      : null;

  /// The same outline as a [BorderSide] (for [Material.shape] and buttons).
  BorderSide get side =>
      sunlight ? const BorderSide(color: FeArColors.sunlightOutline, width: outlineWidth) : BorderSide.none;

  /// A rounded shape carrying [side], for [Material] surfaces.
  OutlinedBorder shape(double radius) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: side);

  /// One weight heavier in Sunlight (w600 → w700 …, capped at w900).
  FontWeight weight(FontWeight w) {
    if (!sunlight) return w;
    final i = FontWeight.values.indexOf(w);
    return FontWeight.values[(i + 1).clamp(0, FontWeight.values.length - 1)];
  }

  /// [base] enlarged by [textBoost] in Sunlight, else null so `AppText`
  /// keeps its own role style (pass it as `style:`).
  TextStyle? text(TextStyle? base) {
    if (!sunlight || base == null) return null;
    return base.copyWith(fontSize: (base.fontSize ?? 14) + textBoost);
  }

  /// Icon sizes grow a little with the text.
  double iconSize(double size) => sunlight ? size + 2 : size;
}

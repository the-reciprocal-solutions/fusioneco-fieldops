import 'package:flutter/material.dart';

/// Which [TextTheme] role a given [AppText] pulls its base style from.
/// Mirrors the roles `AppTheme` actually defines — see theme/app_theme.dart.
enum _AppTextRole {
  plain,
  display,
  headline,
  headlineSmall,
  title,
  titleMedium,
  titleSmall,
  body,
  bodyMedium,
  bodySmall,
  label,
  labelMedium,
  caption,
}

/// The portal's one text component. Every named constructor pulls its base
/// [TextStyle] from `Theme.of(context).textTheme` at build time — so a
/// theme-wide change (line-height, letter-spacing, the Inter→Montserrat
/// font swap) reaches every screen through this one file, instead of the
/// ~240 scattered `Text(style: TextStyle(...))` call sites this replaces.
///
/// [color] and [weight] layer on top of the role's base style via
/// `copyWith` — exactly what those scattered call sites were doing by hand
/// (e.g. `theme.textTheme.titleSmall?.copyWith(color: ..., fontWeight: ...)`).
/// Pass [style] instead of a named constructor only for a one-off case with
/// no matching theme role.
class AppText extends StatelessWidget {
  const AppText(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.plain;

  /// `displaySmall` — the largest role in the theme (e.g. a dashboard hero
  /// number).
  const AppText.display(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.display;

  /// `headlineMedium`.
  const AppText.headline(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.headline;

  /// `headlineSmall`.
  const AppText.headlineSmall(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.headlineSmall;

  /// `titleLarge` — screen and dialog titles.
  const AppText.title(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.title;

  /// `titleMedium` — section headings.
  const AppText.titleMedium(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.titleMedium;

  /// `titleSmall` — card/row titles, the most common heading weight.
  const AppText.titleSmall(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.titleSmall;

  /// `bodyLarge`.
  const AppText.body(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.body;

  /// `bodyMedium` — the default paragraph/description size.
  const AppText.bodyMedium(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.bodyMedium;

  /// `bodySmall` — secondary/meta text (timestamps, helper copy).
  const AppText.bodySmall(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.bodySmall;

  /// `labelLarge` — button labels.
  const AppText.label(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.label;

  /// `labelMedium` — the uppercase, letter-spaced chip/eyebrow style.
  const AppText.labelMedium(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.labelMedium;

  /// `labelSmall` — the smallest role (fine print, badge counts).
  const AppText.caption(
    this.data, {
    super.key,
    this.style,
    this.color,
    this.weight,
    this.align,
    this.overflow,
    this.maxLines,
  }) : _role = _AppTextRole.caption;

  final String data;

  /// Escape hatch for a one-off case with no matching theme role. Layered
  /// under [color]/[weight] the same way a named role's base style is.
  final TextStyle? style;
  final Color? color;
  final FontWeight? weight;
  final TextAlign? align;
  final TextOverflow? overflow;
  final int? maxLines;

  final _AppTextRole _role;

  TextStyle? _baseStyle(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return switch (_role) {
      _AppTextRole.plain => null,
      _AppTextRole.display => text.displaySmall,
      _AppTextRole.headline => text.headlineMedium,
      _AppTextRole.headlineSmall => text.headlineSmall,
      _AppTextRole.title => text.titleLarge,
      _AppTextRole.titleMedium => text.titleMedium,
      _AppTextRole.titleSmall => text.titleSmall,
      _AppTextRole.body => text.bodyLarge,
      _AppTextRole.bodyMedium => text.bodyMedium,
      _AppTextRole.bodySmall => text.bodySmall,
      _AppTextRole.label => text.labelLarge,
      _AppTextRole.labelMedium => text.labelMedium,
      _AppTextRole.caption => text.labelSmall,
    };
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? _baseStyle(context);
    final needsOverride = color != null || weight != null;
    final effective = base != null
        ? (needsOverride ? base.copyWith(color: color, fontWeight: weight) : base)
        : (needsOverride ? TextStyle(color: color, fontWeight: weight) : null);

    return Text(
      data,
      style: effective,
      textAlign: align,
      overflow: overflow,
      maxLines: maxLines,
    );
  }
}

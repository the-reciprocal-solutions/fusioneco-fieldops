import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/fe_colors.dart';
import '../theme/theme_extensions.dart';
import 'app_text.dart';
import 'fe_header.dart';
import 'motion.dart';

/// The portal's one surface treatment: a soft, floating card. Depth comes
/// from a wide low-opacity shadow rather than a border — the "card floats a
/// millimetre off the page" look shared by every reference screen — so the
/// default has no visible border at all; pass [borderColor] only where a
/// screen genuinely needs a hairline (e.g. an already-white sheet on a white
/// background, where the shadow alone reads too weak to separate them).
///
/// [dark] paints the "hero" variant instead: the same card shape filled with
/// [FeColors.ink] and white text, used for the one or two summary cards per
/// screen that should read as the headline rather than a peer of the cards
/// around it (the dashboard's greeting card, a balance-style total).
///
/// [tint] paints a flat colour fill instead — an alert/warning card (e.g.
/// the assignment-invite panel) that needs to read as its own colour rather
/// than the neutral panel or the dark hero. Mutually exclusive with [dark].
class TechCard extends StatelessWidget {
  const TechCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
    this.onTap,
    this.accentTop,
    this.accentLeft,
    this.dark = false,
    this.tint,
    this.radius,
  }) : assert(!dark || tint == null, 'dark and tint are mutually exclusive');

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final VoidCallback? onTap;
  final Color? accentTop;

  /// A coloured strip down the start edge (alert / record severity).
  final Color? accentLeft;
  final bool dark;
  final Color? tint;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? context.radii.xl);
    // The accent stripe is a drawn band, not a thicker top border side: a
    // BoxDecoration may only round a border whose sides all match, and giving
    // one side its own width and colour makes Flutter throw mid-paint — the
    // background lands, the border does not, and the card's contents never
    // draw at all.
    final card = Container(
      decoration: BoxDecoration(
        color: dark ? FeColors.ink : (tint ?? FeColors.panel),
        borderRadius: r,
        border: borderColor == null ? null : Border.all(color: borderColor!),
        boxShadow: dark
            ? FeElevation.floating
            : (tint != null ? FeElevation.tinted(tint!) : FeElevation.soft),
      ),
      child: ClipRRect(
        borderRadius: r,
        child: _withLeft(Column(
          mainAxisSize: MainAxisSize.min,
          // Children fill the card's width, as they did when the padding was
          // the decorated box itself.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (accentTop != null)
              SizedBox(height: 4, child: ColoredBox(color: accentTop!)),
            Padding(padding: padding, child: child),
          ],
        )),
      ),
    );

    if (onTap == null) return card;
    return PressableScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: r, onTap: onTap, child: card),
      ),
    );
  }
}

extension on TechCard {
  Widget _withLeft(Widget body) => accentLeft == null
      ? body
      : IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [SizedBox(width: 4, child: ColoredBox(color: accentLeft!)), Expanded(child: body)],
          ),
        );
}

/// The portal's universal technician loader.
class TechSpinner extends StatelessWidget {
  const TechSpinner({
    super.key,
    this.size = 32,
    this.color = FeColors.primary,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                strokeWidth: 2.5,
                strokeCap: StrokeCap.round,
                valueColor: AlwaysStoppedAnimation(color),
              ),
              if (size >= 28)
                Icon(
                  LucideIcons.wrench,
                  size: size * 0.42,
                  color: color.withValues(alpha: 0.65),
                ),
            ],
          ),
        ),
      );
}

class TechEmptyState extends StatelessWidget {
  const TechEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor = FeColors.ink2,
    this.iconSize = 48,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color iconColor;
  final double iconSize;

  @override
  Widget build(BuildContext context) => TechCard(
    padding: const EdgeInsets.all(32),
    child: Column(
      children: [
        Container(
          height: iconSize + 24,
          width: iconSize + 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: iconSize * 0.6, color: iconColor),
        ),
        const SizedBox(height: 16),
        AppText.bodyMedium(
          title,
          align: TextAlign.center,
          color: FeColors.ink2,
          weight: FontWeight.w600,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          AppText.bodySmall(
            subtitle!,
            align: TextAlign.center,
          ),
        ],
      ],
    ),
  );
}

/// Pill chip used for status and priority. Colors come from FeStatusColors,
/// which is locked to the web's literal palettes and untouched by this — the
/// only thing that changed here is the chrome around those colours: a
/// softer, mostly-borderless pill instead of a hard 1px outline.
class TechChip extends StatelessWidget {
  const TechChip({
    super.key,
    required this.label,
    required this.style,
    this.uppercase = true,
    this.borderRadius,
  });

  final String label;
  final FeChipStyle style;
  final bool uppercase;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: style.background,
      borderRadius: borderRadius ?? BorderRadius.circular(999),
    ),
    child: AppText(
      uppercase ? label.toUpperCase() : label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: style.foreground,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    ),
  );
}

/// A small icon inside a soft-tinted rounded square — the "leading badge" pattern
/// used on list rows (order type, checklist state) and dashboard counters.
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    required this.style,
    this.size = 40,
    this.iconSize = 18,
  });

  final IconData icon;
  final FeBadgeStyle style;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Container(
    height: size,
    width: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: style.background, borderRadius: BorderRadius.circular(size * 0.3)),
    child: Icon(icon, size: iconSize, color: style.foreground),
  );
}

/// Screens not yet built in this phase.
class PhasePlaceholder extends StatelessWidget {
  const PhasePlaceholder({super.key, required this.title, required this.phase});

  final String title;
  final String phase;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: FeHeader(title: title),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: TechEmptyState(
        icon: Icons.construction_outlined,
        title: context.formatString(
          'widgets.placeholder_title'.getString(context),
          [title],
        ),
        subtitle: context.formatString(
          'widgets.placeholder_subtitle'.getString(context),
          [phase],
        ),
      ),
    ),
  );
}

/// A coloured hero card (brand blue → violet gradient) — the More tab's
/// profile card and other "headline" panels of the redesign.
class GradientCard extends StatelessWidget {
  const GradientCard({super.key, required this.child, this.colors = const [FeColors.primary, FeColors.secondary], this.padding = const EdgeInsets.all(16), this.onTap});

  final Widget child;
  final List<Color> colors;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(context.radii.xl);
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        boxShadow: FeElevation.tinted(colors.first),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return PressableScale(child: Material(color: Colors.transparent, child: InkWell(borderRadius: r, onTap: onTap, child: card)));
  }
}

/// A square-ish menu tile: coloured icon tile + label — the Operations grid.
class MenuTile extends StatelessWidget {
  const MenuTile({super.key, required this.label, required this.icon, required this.color, required this.onTap});

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TechCard(
        onTap: onTap,
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            IconBadge(icon: icon, style: FeBadgeStyle.of(color), size: 40, iconSize: 19),
            const SizedBox(width: 10),
            Expanded(child: AppText.titleSmall(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 14, height: 18 / 14))),
          ],
        ),
      );
}

/// Two-up grid of equal-width children (Operations tiles, KPI tiles).
class TwoUpGrid extends StatelessWidget {
  const TwoUpGrid({super.key, required this.children, this.gap = 10, this.columns = 2});
  final List<Widget> children;
  final double gap;
  final int columns;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final w = (c.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
        },
      );
}

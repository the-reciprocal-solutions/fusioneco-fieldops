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
    this.dark = false,
    this.tint,
    this.radius,
  }) : assert(!dark || tint == null, 'dark and tint are mutually exclusive');

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;
  final VoidCallback? onTap;
  final Color? accentTop;
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // Children fill the card's width, as they did when the padding was
          // the decorated box itself.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (accentTop != null)
              SizedBox(height: 4, child: ColoredBox(color: accentTop!)),
            Padding(padding: padding, child: child),
          ],
        ),
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

/// A small icon inside a soft-tinted circle — the "leading badge" pattern
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
    decoration: BoxDecoration(color: style.background, shape: BoxShape.circle),
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

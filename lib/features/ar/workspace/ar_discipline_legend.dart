import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/ar_session_controller.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';

/// The discipline legend and its one-tap filters (first device run, user
/// feedback 2026-09-26: "couldn't visually identify different discipline
/// items", "control the UI representation more easily"). One chip per
/// discipline on the loaded floor: its colour (the same tint the model is
/// drawn with, `arDisciplineRgb`), its name and how many elements it has.
/// Tap hides or shows it; long-press shows only it (tap it again, or "Show
/// all", to restore). Walls and Structure are the Layers panel's model
/// switches, so the panel and the legend always agree.

/// The legend dot's colour. Off the discipline palette (colouring by
/// progress, system or snags) the dots go neutral: a coloured dot would
/// promise a colour the model isn't drawn in.
Color arDisciplineColor(ArDiscipline d, {bool coloured = true}) {
  final rgb = d.rgb;
  if (rgb != null) return coloured ? FeArColors.fromRgb(rgb) : FeArColors.legendNeutral;
  return d == ArDiscipline.structure ? FeArColors.structure : FeArColors.edge;
}

String arDisciplineLabel(BuildContext context, ArDiscipline d) =>
    (d == ArDiscipline.otherMep ? 'ar.discipline.other_mep' : 'ar.discipline.${d.name}').getString(context);

IconData arDisciplineIcon(ArDiscipline d) => switch (d) {
  ArDiscipline.electrical => ArIcons.electrical,
  ArDiscipline.plumbing => ArIcons.plumbing,
  ArDiscipline.hvac => ArIcons.hvac,
  ArDiscipline.fire => ArIcons.fire,
  ArDiscipline.controls => ArIcons.controls,
  ArDiscipline.otherMep => ArIcons.otherMep,
  ArDiscipline.structure => ArIcons.structure,
  ArDiscipline.walls => ArIcons.walls,
};

/// Chips present on this floor, in legend order.
List<ArDiscipline> arPresentDisciplines(Map<ArDiscipline, int> counts) => [
  for (final d in ArDiscipline.values)
    if ((counts[d] ?? 0) > 0) d,
];

/// The glass chip row over the camera. One row, scrolls sideways, folds to
/// a single chip so it covers as little of the room as possible.
class ArDisciplineLegend extends ConsumerWidget {
  const ArDisciplineLegend({super.key, this.center = false});

  /// iPad: centred under the badge. Phone: from the reading edge.
  final bool center;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    // Counts change only with the feature list, not with every pose.
    ref.watch(arSessionProvider.select((s) => s.features));
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final counts = ctrl.disciplineCounts();
    final present = arPresentDisciplines(counts);
    if (present.isEmpty) return const SizedBox.shrink();
    final l = ws.layers;
    final coloured = ws.mode != ArMode.progress && l.colourBy == ArColourBy.discipline;
    final hiddenCount = present.where((d) => !l.shows(d)).length;
    final hint = 'ar.legend.hint'.getString(context);

    final chips = <Widget>[
      _GlassChip(
        semantics: 'ar.legend.title'.getString(context),
        onTap: ctrl.toggleLegend,
        shown: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(ArIcons.legend, size: 15, color: FeArColors.onGlass),
            const SizedBox(width: 6),
            AppText.bodySmall(
              ws.legendOpen || hiddenCount == 0
                  ? 'ar.legend.title'.getString(context)
                  : arTr(context, 'ar.legend.n_hidden', [hiddenCount]),
              color: FeArColors.onGlass,
              weight: FontWeight.w700,
            ),
            const SizedBox(width: 4),
            Icon(ws.legendOpen ? ArIcons.collapse : ArIcons.expand, size: 14, color: FeArColors.onGlassMuted),
          ],
        ),
      ),
      if (ws.legendOpen && hiddenCount > 0)
        _GlassChip(
          semantics: 'ar.legend.show_all'.getString(context),
          onTap: ctrl.showAllDisciplines,
          shown: true,
          light: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(ArIcons.showAll, size: 15, color: FeColors.ink),
              const SizedBox(width: 6),
              AppText.bodySmall('ar.legend.show_all'.getString(context), color: FeColors.ink, weight: FontWeight.w700),
            ],
          ),
        ),
      if (ws.legendOpen)
        for (final d in present)
          _DisciplineChip(
            discipline: d,
            count: counts[d] ?? 0,
            shown: l.shows(d),
            solo: l.isSolo(d),
            colour: arDisciplineColor(d, coloured: coloured),
            hint: hint,
            onTap: () {
              ArHaptics.snap();
              ctrl.toggleDiscipline(d);
            },
            onLongPress: () {
              ArHaptics.lock();
              ctrl.soloDiscipline(d);
            },
          ),
    ];

    final list = ListView.separated(
      scrollDirection: Axis.horizontal,
      shrinkWrap: center,
      padding: EdgeInsets.zero,
      itemCount: chips.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (_, i) => chips[i],
    );
    return SizedBox(
      height: 48,
      child: center ? Center(child: list) : list,
    );
  }
}

class _DisciplineChip extends StatelessWidget {
  const _DisciplineChip({
    required this.discipline,
    required this.count,
    required this.shown,
    required this.solo,
    required this.colour,
    required this.hint,
    required this.onTap,
    required this.onLongPress,
  });

  final ArDiscipline discipline;
  final int count;
  final bool shown;
  final bool solo;
  final Color colour;
  final String hint;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final label = arDisciplineLabel(context, discipline);
    final fg = solo ? FeColors.ink : FeArColors.onGlass;
    return _GlassChip(
      semantics: '$label · $count',
      hint: hint,
      toggled: shown,
      shown: shown,
      light: solo,
      borderColour: shown && !solo ? colour.withValues(alpha: 0.75) : null,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArLegendDot(colour: colour, filled: shown && discipline != ArDiscipline.walls),
          const SizedBox(width: 7),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
              decoration: shown ? null : TextDecoration.lineThrough,
              decorationColor: fg,
            ),
          ),
          const SizedBox(width: 6),
          AppText.caption('$count', color: solo ? FeColors.ink2 : FeArColors.onGlassMuted, weight: FontWeight.w600),
        ],
      ),
    );
  }
}

/// A legend colour dot: filled when shown, a ring when hidden (and for
/// walls, which are drawn as edges).
class ArLegendDot extends StatelessWidget {
  const ArLegendDot({super.key, required this.colour, this.filled = true, this.size = 10});

  final Color colour;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? colour : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: colour, width: 2),
      ),
    );
  }
}

/// A 36 px glass pill in a 48 px touch target (§2.9: never smaller than 48).
class _GlassChip extends StatelessWidget {
  const _GlassChip({
    required this.child,
    required this.semantics,
    required this.onTap,
    required this.shown,
    this.onLongPress,
    this.hint,
    this.toggled,
    this.light = false,
    this.borderColour,
  });

  final Widget child;
  final String semantics;
  final String? hint;
  final bool? toggled;
  final bool shown;
  final bool light;
  final Color? borderColour;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: toggled,
      label: semantics,
      hint: hint,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: shown ? 1 : 0.55,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: light ? Colors.white : FeArColors.glassStrong,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: borderColour ?? Colors.transparent, width: 1.2),
              ),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The Layers panel's discipline switches: the same filters as the legend,
/// on the white panel, with counts.
class ArDisciplineSwitches extends ConsumerWidget {
  const ArDisciplineSwitches({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    ref.watch(arSessionProvider.select((s) => s.features));
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final counts = ctrl.disciplineCounts();
    final present = arPresentDisciplines(counts);
    if (present.isEmpty) return const SizedBox.shrink();
    final l = ws.layers;
    final coloured = ws.mode != ArMode.progress && l.colourBy == ArColourBy.discipline;
    final anyHidden = present.any((d) => !l.shows(d));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in present)
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                ArLegendDot(colour: arDisciplineColor(d, coloured: coloured), filled: d != ArDiscipline.walls, size: 12),
                const SizedBox(width: 12),
                Expanded(child: AppText.bodyMedium(arDisciplineLabel(context, d), weight: FontWeight.w600)),
                AppText.caption('${counts[d] ?? 0}', color: FeColors.ink2, weight: FontWeight.w600),
                const SizedBox(width: 8),
                Switch(
                  value: l.shows(d),
                  activeThumbColor: FeColors.primary,
                  onChanged: (v) => ctrl.setDisciplineShown(d, v),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(child: AppText.caption('ar.legend.hint'.getString(context), color: FeColors.ink2)),
            if (anyHidden)
              TextButton.icon(
                onPressed: ctrl.showAllDisciplines,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(ArIcons.showAll, size: 16),
                label: AppText.label('ar.legend.show_all'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
              ),
          ],
        ),
      ],
    );
  }
}

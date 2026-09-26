import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../../../core/ar/drill_check.dart';
import '../../../state/ar_view_models.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import 'ar_discipline_legend.dart';

/// How a selected element is summarised on the action card (iPad) and the
/// sheet (phone): a discipline-coloured tile that matches its colour in the
/// model, a discipline tag, the system, and facts worked out on the phone
/// from what the floor pack already holds — height above the finished floor,
/// run length and size, and whether it is concealed (in a wall, the floor, a
/// slab, above the ceiling). User feedback 2026-09-26: "it should show more
/// value-added items — currently very basic".

/// The 44 px discipline tile; a small red locate badge when it's the target.
class ArDisciplineTile extends StatelessWidget {
  const ArDisciplineTile({super.key, required this.discipline, this.target = false, this.size = 44});

  final ArDiscipline discipline;
  final bool target;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = arDisciplineColor(discipline);
    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 4,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.withValues(alpha: 0.55), width: 1.5),
              ),
              child: Icon(arDisciplineIcon(discipline), color: c, size: size * 0.48),
            ),
          ),
          if (target)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: FeColors.danger,
                  shape: BoxShape.circle,
                  border: Border.all(color: FeColors.panel, width: 2),
                ),
                child: const Icon(ArIcons.locate, size: 10, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tile + name + one line under it, and an optional trailing widget.
class ArElementHeader extends StatelessWidget {
  const ArElementHeader({
    super.key,
    required this.feature,
    required this.title,
    this.subtitle,
    this.trailing,
    this.target = false,
  });

  final ArFeature feature;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool target;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ArDisciplineTile(discipline: ArDiscipline.of(feature.discipline), target: target),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.titleMedium(title, weight: FontWeight.w800, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null && subtitle!.isNotEmpty)
                AppText.bodySmall(subtitle!, color: FeColors.ink2, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Discipline tag, system and "Target", as small pills.
class ArElementTags extends StatelessWidget {
  const ArElementTags({super.key, required this.feature, this.target = false});

  final ArFeature feature;
  final bool target;

  @override
  Widget build(BuildContext context) {
    final d = ArDiscipline.of(feature.discipline);
    final c = arDisciplineColor(d);
    final system = feature.systemName;
    final tag = feature.prop('Tag');
    final status = feature.prop('Status');
    final planned = status != null && status.toLowerCase().contains('plan');
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _Pill(
          bg: c.withValues(alpha: 0.14),
          leading: ArLegendDot(colour: c, filled: d != ArDiscipline.walls, size: 8),
          text: arDisciplineLabel(context, d),
        ),
        if (tag != null)
          _Pill(bg: FeArColors.manualBg, leading: const Icon(ArIcons.identify, size: 12, color: FeColors.ink2), text: tag),
        if (status != null)
          _Pill(
            bg: planned ? FeColors.warningSoft : FeColors.successSoft,
            leading: Icon(planned ? ArIcons.progress : ArIcons.verify, size: 12, color: planned ? FeColors.warning : FeColors.success),
            text: status,
            fg: planned ? FeColors.warning : FeColors.success,
          ),
        if (system != null && system.trim().isNotEmpty)
          _Pill(bg: FeArColors.manualBg, leading: const Icon(ArIcons.swap, size: 12, color: FeColors.ink2), text: system),
        if (target)
          _Pill(
            bg: FeColors.dangerSoft,
            leading: const Icon(ArIcons.locate, size: 12, color: FeArColors.mismatchFg),
            text: 'ar.element.target'.getString(context),
            fg: FeArColors.mismatchFg,
          ),
      ],
    );
  }
}

/// The derived facts, plus a caution strip for a concealed service.
class ArElementFactsView extends StatelessWidget {
  const ArElementFactsView({super.key, required this.facts});

  final ArElementFacts facts;

  @override
  Widget build(BuildContext context) {
    final p = facts.placement;
    final size = facts.sizeMm;
    final items = <(IconData, String)?>[
      if (p != null && p.zone != ServiceZone.inFloor)
        facts.runLengthM != null
            ? (ArIcons.height, arTr(context, 'ar.element.height', [arMetres(context, p.centreM)]))
            : (ArIcons.height, arTr(context, 'ar.element.height_range', [arMetres(context, p.bottomM), arMetres(context, p.topM)])),
      if (facts.runLengthM != null) (ArIcons.run, arTr(context, 'ar.element.run', [arMetres(context, facts.runLengthM!)])),
      if (size.length == 1) (ArIcons.size, arTr(context, 'ar.element.diameter', [size.first])),
      if (size.length >= 2) (ArIcons.size, arTr(context, 'ar.element.size', [size[1], size[0]])),
      if (p != null && facts.discipline.isMep)
        switch (p.zone) {
          ServiceZone.inWall => (ArIcons.concealed, arTr(context, 'ar.element.in_wall', [arCentimetres(context, p.behindFaceM ?? 0)])),
          ServiceZone.inSlab => (ArIcons.concealed, 'ar.element.in_slab'.getString(context)),
          ServiceZone.aboveCeiling => (ArIcons.concealed, 'ar.element.above_ceiling'.getString(context)),
          ServiceZone.inFloor => (ArIcons.concealed, 'ar.element.in_floor'.getString(context)),
          ServiceZone.room => null,
        },
    ].whereType<(IconData, String)>().toList();
    final caution = p != null && p.concealed && facts.discipline.isMep;
    // The model author's own words for the site (IFC SiteNote / Note /
    // Description) beat the generic caution when present.
    final note = facts.feature?.prop('SiteNote') ?? facts.feature?.prop('Note');
    final maker = [facts.feature?.prop('Manufacturer'), facts.feature?.prop('ModelLabel')].whereType<String>().join(' · ');
    if (maker.isNotEmpty) items.add((ArIcons.identify, maker));
    if (items.isEmpty && !caution && note == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final (icon, text) in items) _Pill(bg: FeArColors.manualBg, leading: Icon(icon, size: 13, color: FeColors.ink2), text: text)],
          ),
        if (note != null) ...[
          const SizedBox(height: 8),
          ArHintRow(text: arTr(context, 'ar.element.site_note', [note]), icon: ArIcons.forms),
        ] else if (caution) ...[
          const SizedBox(height: 8),
          ArHintRow(text: 'ar.element.caution'.getString(context), icon: ArIcons.drill),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.bg, required this.leading, required this.text, this.fg = FeColors.ink});

  final Color bg;
  final Widget leading;
  final String text;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 5),
          Flexible(child: AppText.caption(text, color: fg, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

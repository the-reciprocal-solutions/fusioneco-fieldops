import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../core/i18n/server_text.dart';
import '../../domain/mobile_catalog.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../modules/module_spec.dart';
import 'efficiency_data.dart';
import '../../../widgets/dir_icon.dart';

/// Page key (server mobile/visibility.ts HVAC_PAGES) → icon and colour.
const _pageLook = <String, (IconData, Color)>{
  'overview': (LucideIcons.building2, Color(0xFF16A34A)),
  'insight': (LucideIcons.sparkles, Color(0xFF7C3AED)),
  'impact': (LucideIcons.chartColumn, Color(0xFF0B5ED7)),
  'report': (LucideIcons.fileText, Color(0xFF0EA5E9)),
  'comfort': (LucideIcons.wind, Color(0xFF0B5ED7)),
  'energy': (LucideIcons.zap, Color(0xFFF97316)),
  'equipment': (LucideIcons.cpu, Color(0xFF7C3AED)),
  'safety': (LucideIcons.shieldCheck, Color(0xFF16A34A)),
  'fix': (LucideIcons.circleAlert, Color(0xFFEF4444)),
  'actions': (LucideIcons.listChecks, Color(0xFFF59E0B)),
  'savings': (LucideIcons.piggyBank, Color(0xFF16A34A)),
  'live': (LucideIcons.activity, Color(0xFFEC4899)),
  'trends': (LucideIcons.trendingUp, Color(0xFF0B5ED7)),
  'data': (LucideIcons.database, Color(0xFF0EA5E9)),
  'checks': (LucideIcons.sliders, Color(0xFFF97316)),
  'settings': (LucideIcons.settings, Color(0xFF64748B)),
};

/// The four health areas sit side by side as tiles, as in the redesign.
const _areaKeys = {'comfort', 'energy', 'equipment', 'safety'};

/// Building Efficiency: the pages this user may see, in the web's groups
/// (Today, Health areas, Take action, Monitor, Setup). The catalog already
/// dropped every page switched off (effPageOn on the server).
class EfficiencyScreen extends StatelessWidget {
  const EfficiencyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Page names come from the catalog: redraw when the language changes.
    Localizations.localeOf(context);
    return Scaffold(
      appBar: FeHeader(title: 'nav.efficiency'.getString(context), subtitle: 'nav.efficiency_sub'.getString(context), art: FeArt.efficiency),
      body: CatalogView(
        builder: (context, boot) {
          final pages = boot.module('efficiency')?.pages ?? const <ModulePage>[];
          final groups = <String, List<ModulePage>>{};
          for (final p in pages) {
            groups.putIfAbsent(p.group ?? '', () => []).add(p);
          }
          void open(ModulePage p) => context.push(modulePath('efficiency', page: p.id));
          (IconData, Color) look(ModulePage p, int i) => _pageLook[p.id] ?? (LucideIcons.layoutGrid, FeColors.tile(i));
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            children: [
              _ScoreCards(pages: pages, onOpen: open),
              for (final g in groups.entries)
                if (g.value.every((p) => _areaKeys.contains(p.id)))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (g.key.isNotEmpty) SectionLabel(catalogGroup(g.key)),
                        TwoUpGrid(
                          columns: g.value.length.clamp(1, 4),
                          gap: 8,
                          children: [for (var i = 0; i < g.value.length; i++) _AreaTile(page: g.value[i], look: look(g.value[i], i), onTap: () => open(g.value[i]))],
                        ),
                      ],
                    ),
                  )
                else
                  RowGroup(
                    label: catalogGroup(g.key),
                    rows: [
                      for (var i = 0; i < g.value.length; i++)
                        NavRow(title: g.value[i].label, icon: look(g.value[i], i).$1, color: look(g.value[i], i).$2, onTap: () => open(g.value[i])),
                    ],
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _AreaTile extends StatelessWidget {
  const _AreaTile({required this.page, required this.look, required this.onTap});
  final ModulePage page;
  final (IconData, Color) look;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TechCard(
        onTap: onTap,
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Column(
          children: [
            IconBadge(icon: look.$1, style: FeBadgeStyle.of(look.$2), size: 40, iconSize: 20),
            const SizedBox(height: 8),
            SizedBox(
              height: 32,
              child: AppText.caption(page.label, align: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, color: FeColors.ink, weight: FontWeight.w700),
            ),
          ],
        ),
      );
}

/// The live score as a ring and each area's score as bars (the design's top
/// cards). Nothing shows until the site has a score: no BMS site, no card.
class _ScoreCards extends ConsumerWidget {
  const _ScoreCards({required this.pages, required this.onOpen});
  final List<ModulePage> pages;
  final void Function(ModulePage) onOpen;

  ModulePage? _page(String id) => pages.where((p) => p.id == id).firstOrNull;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sm = ref.watch(effSummaryProvider).valueOrNull;
    final score = n(sm?['score']);
    if (sm == null || score == null) return const SizedBox.shrink();
    final color = score >= 80 ? FeColors.success : (score >= 60 ? FeColors.warning : FeColors.danger);
    final overview = _page('overview');
    final insight = _page('insight');
    final areas = [
      for (final p in rowsOf({'data': sm['pillars']}))
        if (p['available'] != false && n(p['score']) != null) (serverText('eff.pillar_${p['key']}', s(p['label']) ?? '–'), n(p['score'])!),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TechCard(
            radius: 16,
            onTap: overview == null ? null : () => onOpen(overview),
            child: Row(
              children: [
                SizedBox(
                  width: 78,
                  height: 78,
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(value: (score / 100).clamp(0, 1).toDouble(), strokeWidth: 9, strokeCap: StrokeCap.round, color: color, backgroundColor: FeColors.line),
                      Center(child: AppText.titleMedium(fmtNum(score), maxLines: 1)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText.titleSmall('eff.building_health'.getString(context)),
                      if (s(sm['grade']) != null) AppText.bodySmall(statusWord(s(sm['grade'])!), color: color, weight: FontWeight.w700),
                    ],
                  ),
                ),
                if (overview != null) const DirIcon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
              ],
            ),
          ),
          if (areas.isNotEmpty) ...[
            const SizedBox(height: 12),
            TechCard(
              radius: 16,
              onTap: insight == null ? null : () => onOpen(insight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText.titleSmall(insight?.label ?? 'eff.area_scores'.getString(context)),
                  AppText.caption('eff.area_scores'.getString(context)),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final (label, value) in areas)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Column(
                              children: [
                                AppText.caption(fmtNum(value), weight: FontWeight.w700, color: FeColors.ink),
                                const SizedBox(height: 4),
                                Container(
                                  height: 8 + 56 * (value / 100).clamp(0, 1).toDouble(),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [FeColors.primaryLight, FeColors.primary]),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(height: 30, child: AppText(label, align: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9.5, height: 1.3, fontWeight: FontWeight.w500, color: FeColors.ink2))),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

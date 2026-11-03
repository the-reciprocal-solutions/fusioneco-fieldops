import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../domain/mobile_catalog.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// Page key (server mobile/visibility.ts HVAC_PAGES) → icon and colour.
const _pageLook = <String, (IconData, Color)>{
  'overview': (LucideIcons.building2, Color(0xFF10B981)),
  'insight': (LucideIcons.sparkles, Color(0xFF7C3AED)),
  'impact': (LucideIcons.chartColumn, Color(0xFF2563EB)),
  'report': (LucideIcons.fileText, Color(0xFF0EA5E9)),
  'comfort': (LucideIcons.wind, Color(0xFF2563EB)),
  'energy': (LucideIcons.zap, Color(0xFFF97316)),
  'equipment': (LucideIcons.cpu, Color(0xFF7C3AED)),
  'safety': (LucideIcons.shieldCheck, Color(0xFF10B981)),
  'fix': (LucideIcons.circleAlert, Color(0xFFEF4444)),
  'actions': (LucideIcons.listChecks, Color(0xFFF59E0B)),
  'savings': (LucideIcons.piggyBank, Color(0xFF10B981)),
  'live': (LucideIcons.activity, Color(0xFFEC4899)),
  'trends': (LucideIcons.trendingUp, Color(0xFF2563EB)),
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
    return Scaffold(
      appBar: FeHeader(title: 'nav.efficiency'.getString(context), subtitle: 'nav.efficiency_sub'.getString(context)),
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
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            children: [
              for (final g in groups.entries)
                if (g.value.every((p) => _areaKeys.contains(p.id)))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (g.key.isNotEmpty) SectionLabel(g.key),
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
                    label: g.key,
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

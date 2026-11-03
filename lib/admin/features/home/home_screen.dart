import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/network/api_exception.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../modules/module_spec.dart';
import '../modules/module_summary_screen.dart';

/// Home = the Dashboard V3 summary (FE-mobile.md Phase 3a). The doc is the
/// provider the user's brand switch picks (`prefs.dashboardEnv`), ~3.5 KB.
final dashboardProvider = FutureProvider.autoDispose.family<Json, String>((ref, env) async {
  final body = await ref.watch(apiClientProvider).get('/api/dashboard-v3', query: {'env': env});
  return dataOf(body);
});

/// Tiles from the dashboard doc (server services/dashboardV3 aggregate).
List<(String, List<Kpi>)> dashboardSections(Json d) {
  final month = (d['curr_month_units'] is List && (d['curr_month_units'] as List).isNotEmpty)
      ? Map<String, dynamic>.from((d['curr_month_units'] as List).first as Map)
      : const <String, dynamic>{};
  num count(String path, String key, String field) => countIn(at(d, path), field, key);

  return [
    ('home.site', [
      Kpi('home.sites', fmtNum(at(d, 'total_sq_ft.curr_site_count')), icon: LucideIcons.building2),
      Kpi('home.area_sqft', fmtNum(at(d, 'total_sq_ft.curr_total_sq_ft')), icon: LucideIcons.scan),
      Kpi('home.floors', fmtNum(at(d, 'center.floors')), icon: LucideIcons.layers),
      Kpi('home.occupancy', '${fmtNum(at(d, 'center.occupancy'))} / ${fmtNum(at(d, 'center.capacity'))}', tone: Tone.info, icon: LucideIcons.users),
      Kpi('home.operational', fmtPct(at(d, 'operational.pct')), tone: Tone.good, icon: LucideIcons.settings),
      Kpi('home.avg_temp', at(d, 'avg_temp.value') == null ? '–' : '${fmtNum(at(d, 'avg_temp.value'), decimals: 1)} °C', icon: LucideIcons.thermometer),
    ]),
    ('home.assets', [
      Kpi('home.assets_total', fmtNum(at(d, 'asset_health.total'))),
      Kpi('home.health_good', fmtNum(count('asset_health.breakdown', 'excellent', 'status') + count('asset_health.breakdown', 'good', 'status')), tone: Tone.good),
      Kpi('home.health_fair', fmtNum(count('asset_health.breakdown', 'fair', 'status')), tone: Tone.warn),
      Kpi('home.health_poor', fmtNum(count('asset_health.breakdown', 'poor', 'status') + count('asset_health.breakdown', 'critical', 'status')), tone: Tone.bad),
    ]),
    ('home.maintenance_risk', [
      Kpi('home.risk_critical', fmtNum(count('maintenance_risk.breakdown', 'critical', 'level')), tone: Tone.bad),
      Kpi('home.risk_high', fmtNum(count('maintenance_risk.breakdown', 'high', 'level')), tone: Tone.warn),
      Kpi('home.risk_medium', fmtNum(count('maintenance_risk.breakdown', 'medium', 'level'))),
      Kpi('home.risk_low', fmtNum(count('maintenance_risk.breakdown', 'low', 'level')), tone: Tone.good),
    ]),
    ('home.energy', [
      Kpi('home.energy_month_kwh', fmtNum(month['total_units_kwh']), icon: LucideIcons.zap),
      Kpi('home.peak_kw', fmtNum(month['peak_demand_kw']), icon: LucideIcons.gauge),
      Kpi('home.carbon_saved', at(d, 'carbon.value') == null ? '–' : '${fmtNum(at(d, 'carbon.value'))} ${s(at(d, 'carbon.unit')) ?? ''}'.trim(), tone: Tone.good, icon: LucideIcons.leaf),
      Kpi('home.epi', fmtNum(at(d, 'epi.value'), decimals: 2), icon: LucideIcons.chartColumn),
    ]),
  ];
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(loadedCatalogProvider);
    return Scaffold(
      appBar: FeHeader(
        title: 'nav.home_title'.getString(context),
        subtitle: _greeting(context),
        actions: [
          IconButton.filledTonal(
            style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.8)),
            icon: const Icon(LucideIcons.bell, size: 20),
            tooltip: 'nav.alerts'.getString(context),
            onPressed: () => context.go(Routes.alerts),
          ),
        ],
      ),
      // Owner's decision (2026-10-30, P-003): the app always shows Home and its
      // tiles, whether or not the web's Dashboard switch is on for this user.
      body: boot == null ? const TechSpinner() : _Dashboard(env: boot.dashboardEnv),
    );
  }
}

class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.env});
  final String env;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(dashboardProvider(env));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(dashboardProvider(env).future).catchError((_) => <String, dynamic>{}),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: doc.when(
          skipLoadingOnRefresh: true,
          loading: () => const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())],
          error: (e, _) => [
            TechEmptyState(
              icon: LucideIcons.circleAlert,
              title: 'module.load_error'.getString(context),
              subtitle: e is ApiFailure ? e.message : null,
            ),
          ],
          data: (d) => [
            for (final (title, kpis) in dashboardSections(d)) ...[
              Padding(padding: const EdgeInsets.only(top: 6), child: SectionLabel(title.getString(context))),
              if (title == 'home.assets' && kpis.length == 4)
                _AssetHealthCard(kpis: kpis)
              else
                TwoUpGrid(children: [for (var i = 0; i < kpis.length; i++) KpiTile(kpis[i], color: FeColors.tile(i))]),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}

String _greeting(BuildContext context) {
  final h = DateTime.now().hour;
  final key = h < 12 ? 'dashboard.greeting_morning' : (h < 17 ? 'dashboard.greeting_afternoon' : 'dashboard.greeting_evening');
  return key.getString(context);
}

/// "141 assets" as a ring split good / fair / poor, with its legend.
class _AssetHealthCard extends StatelessWidget {
  const _AssetHealthCard({required this.kpis});

  /// total, good, fair, poor — in that order (see [dashboardSections]).
  final List<Kpi> kpis;

  static double _n(String v) {
    final t = v.replaceAll(',', '').trim().toLowerCase();
    final k = t.endsWith('k');
    final n = double.tryParse(k ? t.substring(0, t.length - 1) : t) ?? 0;
    return k ? n * 1000 : n;
  }

  @override
  Widget build(BuildContext context) {
    final parts = [(kpis[1], FeColors.success), (kpis[2], FeColors.medium), (kpis[3], FeColors.danger)];
    final sum = parts.fold<double>(0, (a, p) => a + _n(p.$1.value));
    return TechCard(
      radius: 16,
      child: Row(
        children: [
          SizedBox(
            width: 116,
            height: 116,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    startDegreeOffset: -90,
                    sectionsSpace: 2,
                    centerSpaceRadius: 40,
                    sections: sum == 0
                        ? [PieChartSectionData(value: 1, color: FeColors.line, radius: 14, showTitle: false)]
                        : [for (final (k, c) in parts) PieChartSectionData(value: _n(k.value), color: c, radius: 14, showTitle: false)],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppText.titleMedium(kpis[0].value, maxLines: 1),
                    AppText.caption(kpiLabel(context, kpis[0].label), maxLines: 1),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: [
                for (final (k, c) in parts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        SizedBox(width: 40, child: AppText.titleSmall(k.value, maxLines: 1)),
                        Expanded(child: AppText.bodySmall(kpiLabel(context, k.label), maxLines: 2, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

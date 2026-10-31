import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_exception.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
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
      Kpi('home.sites', fmtNum(at(d, 'total_sq_ft.curr_site_count'))),
      Kpi('home.area_sqft', fmtNum(at(d, 'total_sq_ft.curr_total_sq_ft'))),
      Kpi('home.floors', fmtNum(at(d, 'center.floors'))),
      Kpi('home.occupancy', '${fmtNum(at(d, 'center.occupancy'))} / ${fmtNum(at(d, 'center.capacity'))}', tone: Tone.info),
      Kpi('home.operational', fmtPct(at(d, 'operational.pct')), tone: Tone.good),
      Kpi('home.avg_temp', at(d, 'avg_temp.value') == null ? '–' : '${fmtNum(at(d, 'avg_temp.value'), decimals: 1)} °C'),
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
      Kpi('home.energy_month_kwh', fmtNum(month['total_units_kwh'])),
      Kpi('home.peak_kw', fmtNum(month['peak_demand_kw'])),
      Kpi('home.carbon_saved', at(d, 'carbon.value') == null ? '–' : '${fmtNum(at(d, 'carbon.value'))} ${s(at(d, 'carbon.unit')) ?? ''}'.trim(), tone: Tone.good),
      Kpi('home.epi', fmtNum(at(d, 'epi.value'), decimals: 2)),
    ]),
  ];
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(loadedCatalogProvider);
    return Scaffold(
      appBar: FeHeader(title: 'nav.home'.getString(context)),
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
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8, top: 8),
                child: AppText.label(title.getString(context).toUpperCase(), color: FeColors.ink2),
              ),
              LayoutBuilder(
                builder: (context, c) {
                  final w = (c.maxWidth - 10) / 2;
                  return Wrap(spacing: 10, runSpacing: 10, children: [for (final k in kpis) SizedBox(width: w, child: KpiTile(k))]);
                },
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

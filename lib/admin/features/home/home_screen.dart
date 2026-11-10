import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/network/api_exception.dart';
import '../../catalog/catalog_guard.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../modules/module_spec.dart';
import '../modules/module_summary_screen.dart';
import '../../../widgets/dir_icon.dart';

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
    // White status-bar icons: the picture header runs behind the status bar.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        // Owner's decision (2026-10-30, P-003): the app always shows Home and its
        // tiles, whether or not the web's Dashboard switch is on for this user.
        body: boot == null ? const TechSpinner() : _Dashboard(env: boot.dashboardEnv),
      ),
    );
  }
}

class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.env});
  final String env;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(dashboardProvider(env));
    final hasAssets = ref.watch(loadedCatalogProvider)?.has('assets') ?? false;
    return RefreshIndicator(
      onRefresh: () => ref.refresh(dashboardProvider(env).future).catchError((_) => <String, dynamic>{}),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Stack(
            children: [
              const _Hero(),
              // The first tiles overlap the picture's bottom edge.
              Padding(
                padding: EdgeInsets.fromLTRB(16, _Hero.heightOf(context) - 30, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        if (title == 'home.assets' && kpis.length == 4)
                          _AssetHealthCard(kpis: kpis, title: title.getString(context), onOpen: hasAssets ? () => context.push(modulePath('assets')) : null)
                        else if (title == 'home.maintenance_risk')
                          _RiskCard(kpis: kpis, title: title.getString(context))
                        else ...[
                          // The design's site tiles sit straight under the picture.
                          if (title != 'home.site') SectionLabel(title.getString(context)),
                          TwoUpGrid(children: [for (var i = 0; i < kpis.length; i++) KpiTile(kpis[i], color: FeColors.tile(i))]),
                        ],
                        const SizedBox(height: 14),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The picture header: brand, alerts bell, greeting and the signed-in name.
class _Hero extends ConsumerWidget {
  const _Hero();

  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + 190;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(authControllerProvider).user?.name;
    return SizedBox(
      height: heightOf(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: FeColors.primary),
            // Mirrored for right-to-left: the words stay over the dark sky.
            Transform.flip(
              flipX: Directionality.of(context) == TextDirection.rtl,
              child: Image.asset(FeArt.home, fit: BoxFit.cover, alignment: Alignment.centerRight, errorBuilder: (_, _, _) => const SizedBox.shrink()),
            ),
            // Keeps the white words readable over the bright part of the sky.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: AlignmentDirectional.centerStart, end: AlignmentDirectional.centerEnd, colors: [Color(0xD9053B3A), Color(0x00053B3A)], stops: [0.45, 0.85]),
              ),
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(9)),
                          child: const Icon(LucideIcons.building2, size: 17, color: Colors.white),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: AppText.titleSmall('nav.brand'.getString(context), color: Colors.white, maxLines: 1)),
                        IconButton(
                          icon: const Icon(LucideIcons.bell, size: 22, color: Colors.white),
                          tooltip: 'nav.alerts'.getString(context),
                          onPressed: () => context.go(Routes.alerts),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    AppText.bodyMedium('${_greeting(context)},', color: Colors.white.withValues(alpha: 0.9)),
                    if (name != null && name.isNotEmpty)
                      AppText.title('$name 👋', color: Colors.white, maxLines: 1, overflow: TextOverflow.ellipsis),
                    AppText.bodySmall('nav.home_title'.getString(context), color: Colors.white.withValues(alpha: 0.85)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Critical / high / medium / low, each on its own colour.
class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.kpis, required this.title});
  final List<Kpi> kpis;
  final String title;

  @override
  Widget build(BuildContext context) {
    const colors = [FeColors.critical, FeColors.high, FeColors.medium, FeColors.low];
    return TechCard(
      radius: 16,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(2, 0, 2, 10), child: AppText.titleSmall(title)),
          TwoUpGrid(
            gap: 8,
            children: [
              for (var i = 0; i < kpis.length; i++)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: colors[i % 4].withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Icon(LucideIcons.triangleAlert, size: 20, color: colors[i % 4]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppText.titleMedium(kpis[i].value, color: colors[i % 4], maxLines: 1),
                            AppText.caption(kpiLabel(context, kpis[i].label), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
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
  const _AssetHealthCard({required this.kpis, required this.title, this.onOpen});

  /// total, good, fair, poor — in that order (see [dashboardSections]).
  final List<Kpi> kpis;
  final String title;

  /// Opens the asset list, when this user has that module.
  final VoidCallback? onOpen;

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
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(child: AppText.titleSmall(title)),
                if (onOpen != null) const DirIcon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
              ],
            ),
          ),
          Row(
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
        ],
      ),
    );
  }
}

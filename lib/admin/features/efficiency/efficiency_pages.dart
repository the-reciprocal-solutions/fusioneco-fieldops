import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/i18n/server_text.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';
import '../module/module_screen.dart';
import '../modules/chat_screen.dart' show newSessionId;
import '../modules/module_spec.dart';
import '../modules/module_summary_screen.dart' show KpiTile, toneColor;
import 'ask_ai.dart';
import 'efficiency_data.dart';

/// The 16 Building Efficiency pages (FE-mobile.md Phase 2 table). Each is a
/// view over the shared summary; Fix tracker and Site settings read their
/// own small endpoints. 3D views, the PDF report and Trends are summarised,
/// with a note that the full view is on a desktop.

/// Web route of each page (lib/hvacEfficiencyPages.ts `path` + `tab`).
const effWebPath = <String, String>{
  'overview': '/hvac/efficiency',
  'insight': '/hvac/efficiency/insight',
  'impact': '/hvac/efficiency/impact',
  'report': '/hvac/efficiency/report',
  'comfort': '/hvac/efficiency/comfort',
  'energy': '/hvac/efficiency?tab=energy',
  'equipment': '/hvac/efficiency/equipment',
  'safety': '/hvac/efficiency/safety',
  'fix': '/hvac/efficiency?tab=fix',
  'actions': '/hvac/efficiency/actions',
  'savings': '/hvac/efficiency/savings',
  'live': '/hvac/efficiency?tab=live',
  'trends': '/hvac/efficiency/trends',
  'data': '/hvac/efficiency/data-quality',
  'checks': '/hvac/efficiency/checks',
  'settings': '/hvac/efficiency/settings',
};

typedef _Body = List<Widget> Function(BuildContext context, Json summary, HvacSite site);

/// One page: header, site / window bar, then the page body over the summary.
class EffPageScreen extends ConsumerStatefulWidget {
  const EffPageScreen({super.key, required this.module, required this.pageId});
  final MobileModule module;
  final String pageId;

  @override
  ConsumerState<EffPageScreen> createState() => _EffPageScreenState();
}

class _EffPageScreenState extends ConsumerState<EffPageScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Refreshed every 2 minutes while the page is open (the web's useHvacData).
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => ref.invalidate(effSummaryProvider));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _label {
    for (final p in widget.module.pages) {
      if (p.id == widget.pageId) return p.label;
    }
    return widget.module.label;
  }

  @override
  Widget build(BuildContext context) {
    final sites = ref.watch(hvacSitesProvider);
    final site = ref.watch(effSiteProvider);
    final own = _ownBodies[widget.pageId];
    final summary = own == null ? ref.watch(effSummaryProvider) : null;

    List<Widget> body;
    if (sites.hasError) {
      body = [_error(context, sites.error)];
    } else if (sites.isLoading) {
      body = const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())];
    } else if (site == null) {
      body = [TechEmptyState(icon: LucideIcons.gauge, title: 'eff.no_sites'.getString(context))];
    } else if (own != null) {
      body = [own(site)];
    } else {
      body = summary!.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        loading: () => const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())],
        error: (e, _) => [_error(context, e)],
        data: (s) {
          if (s == null) {
            // Never leave the page blank: fetch again.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) ref.invalidate(effSummaryProvider);
            });
            return const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())];
          }
          return _bodies[widget.pageId]?.call(context, s, site) ?? [_webOnly(context, widget.pageId)];
        },
      );
    }

    return Scaffold(
      appBar: FeHeader(title: _label),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(effSummaryProvider);
          if (own == null) await ref.read(effSummaryProvider.future).catchError((_) => null);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            if (sites.valueOrNull?.isNotEmpty == true) _SiteBar(sites: sites.value!, site: site, showDays: own == null),
            ...body,
          ],
        ),
      ),
    );
  }
}

Widget _error(BuildContext context, Object? e) => Padding(
      padding: const EdgeInsets.all(16),
      child: TechEmptyState(
        icon: LucideIcons.circleAlert,
        title: 'module.load_error'.getString(context),
        subtitle: e is ApiFailure ? e.message : null,
      ),
    );

/// Site picker + 1 / 7 / 30 day window.
class _SiteBar extends ConsumerWidget {
  const _SiteBar({required this.sites, required this.site, required this.showDays});
  final List<HvacSite> sites;
  final HvacSite? site;
  final bool showDays;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(effDaysProvider);
    // Site on its own line: next to the day buttons the name was cut to "ba…".
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            child: DropdownButtonFormField<HvacSite>(
              initialValue: site,
              isExpanded: true,
              decoration: const InputDecoration(prefixIcon: Icon(LucideIcons.building2, size: 18)),
              items: [
                for (final x in sites)
                  DropdownMenuItem(value: x, child: AppText.body('${x.label}${x.connectionName == null ? '' : ' · ${x.connectionName}'}', maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (x) => x == null ? null : ref.read(effSiteProvider.notifier).pick(x),
            ),
          ),
          if (showDays) ...[
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [for (final d in const [1, 7, 30]) ButtonSegment(value: d, label: AppText('${d}d', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)))],
              selected: {days},
              onSelectionChanged: (s) => ref.read(effDaysProvider.notifier).state = s.first,
            ),
          ],
        ],
      ),
    );
  }
}

// ── shared pieces ───────────────────────────────────────────────────────────

Widget _pad(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child);

Widget _tiles(List<Kpi> kpis) => _pad(LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final k in kpis) SizedBox(width: w, child: KpiTile(k))]);
      },
    ));

Widget _gap([double h = 16]) => SizedBox(height: h);

Widget _section(BuildContext context, String key) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: AppText.label(key.getString(context).toUpperCase(), color: FeColors.ink2),
    );

/// risk → critical hue, warn → high, info → low (FeStatusColors.priority).
String _sevChip(Object? sev) => switch ('$sev') {
      'risk' => 'critical',
      'warn' => 'high',
      _ => 'low',
    };

String _sevLabel(BuildContext context, Object? sev) => 'eff.sev_${sev ?? 'info'}'.getString(context);

Tone _scoreTone(num? v) => v == null ? Tone.neutral : (v >= 85 ? Tone.good : v >= 70 ? Tone.warn : Tone.bad);

String _deg(Object? v) => v == null ? '–' : '${fmtNum(v, decimals: 1)} °C';

Widget _findingList(BuildContext context, List<Json> findings, HvacSite site, {required String pageId}) {
  if (findings.isEmpty) {
    return _pad(TechEmptyState(icon: LucideIcons.circleCheck, iconColor: FeColors.success, title: 'eff.no_findings'.getString(context)));
  }
  return Column(
    children: [
      for (final f in findings)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: _FindingCard(finding: f, onTap: () => _openFinding(context, f, site, pageId)),
        ),
    ],
  );
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({required this.finding, required this.onTap});
  final Json finding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = finding;
    final perDay = n(at(f, 'impact.perDay'));
    return TechCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TechChip(label: _sevLabel(context, f['severity']), style: context.chips.priority(_sevChip(f['severity']))),
              const SizedBox(width: 6),
              if (s(f['pillar']) != null) TechChip(label: 'eff.pillar_${f['pillar']}'.getString(context), style: context.chips.status('draft'), uppercase: false),
              const Spacer(),
              if (perDay != null && perDay > 0) AppText.caption('${fmtNum(perDay, decimals: 2)} ${s(at(f, 'impact.currency')) ?? ''}/d'),
            ],
          ),
          const SizedBox(height: 8),
          AppText.titleSmall(s(f['title']) ?? '–', maxLines: 3, overflow: TextOverflow.ellipsis),
          if (s(f['summary']) != null) ...[
            const SizedBox(height: 4),
            AppText.bodySmall(s(f['summary'])!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

void _openFinding(BuildContext context, Json f, HvacSite site, String pageId) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => FindingDetailScreen(finding: f, site: site, pageId: pageId)),
    );

// ── page bodies over the summary ────────────────────────────────────────────

final Map<String, _Body> _bodies = {
  'overview': (context, sm, site) => [
        _tiles([
          Kpi('eff.score', '${fmtNum(sm['score'])} · ${statusWord(s(sm['grade']) ?? '')}', tone: _scoreTone(n(sm['score']))),
          Kpi('eff.findings', fmtNum(rowsOf({'data': sm['findings']}).length), tone: Tone.warn),
          Kpi('eff.data_health', fmtPct(at(sm, 'kpis.dataHealthPct')), tone: _scoreTone(n(at(sm, 'kpis.dataHealthPct')))),
          Kpi('eff.cost_per_day', '${fmtNum(at(sm, 'impact.perDay'), decimals: 2)} ${s(at(sm, 'impact.currency')) ?? ''}', tone: Tone.bad),
        ]),
        _section(context, 'eff.areas'),
        for (final p in rowsOf({'data': sm['pillars']}))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TechCard(
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: AppText.titleMedium(p['available'] == false || p['score'] == null ? '–' : fmtNum(p['score']), color: toneColor(_scoreTone(n(p['score'])))),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.titleSmall(serverText('eff.pillar_${p['key']}', s(p['label']) ?? '–')),
                        AppText.bodySmall(
                          p['available'] == false || p['score'] == null ? 'eff.area_na'.getString(context) : (s(p['top']) ?? 'eff.area_clear'.getString(context)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if ((n(p['issues']) ?? 0) > 0) TechChip(label: fmtNum(p['issues']), style: context.chips.priority('high')),
                ],
              ),
            ),
          ),
        _section(context, 'eff.do_first'),
        _findingList(context, findingsOf(sm).take(3).toList(), site, pageId: 'overview'),
      ],
  'insight': (context, sm, site) {
    // The copilot list: every finding's "do now" action, most urgent first.
    final now = [
      for (final f in findingsOf(sm))
        for (final a in rowsOf({'data': f['actions']}))
          if (a['tier'] == 'now') (f, s(a['text']) ?? ''),
    ];
    return [
      _section(context, 'eff.copilot'),
      if (now.isEmpty) _pad(TechEmptyState(icon: LucideIcons.sparkles, title: 'eff.no_findings'.getString(context))),
      for (final (f, text) in now)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TechCard(
            onTap: () => _openFinding(context, f, site, 'insight'),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(LucideIcons.sparkles, size: 18, color: FeColors.ai),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [AppText.body(text, weight: FontWeight.w600), AppText.bodySmall(s(f['title']) ?? '', maxLines: 2, overflow: TextOverflow.ellipsis)],
                  ),
                ),
              ],
            ),
          ),
        ),
      _gap(),
      _pad(const DesktopNote(textKey: 'desktop.eff_3d')),
    ];
  },
  'impact': (context, sm, site) {
    final cur = s(at(sm, 'impact.currency')) ?? '';
    return [
      _tiles([
        Kpi('eff.cost_per_day', '${fmtNum(at(sm, 'impact.perDay'), decimals: 2)} $cur', tone: Tone.bad),
        Kpi('eff.cost_per_year', '${fmtNum(at(sm, 'impact.perYear'))} $cur', tone: Tone.bad),
      ]),
      _section(context, 'eff.by_category'),
      RowGroup(
        label: '',
        dividerIndent: 16,
        rows: [
          for (final c in rowsOf({'data': at(sm, 'impact.byCategory')}))
            ListTile(
              title: AppText.body('eff.cat_${c['category']}'.getString(context).endsWith(' not found') ? '${c['category']}' : 'eff.cat_${c['category']}'.getString(context)),
              subtitle: AppText.bodySmall([
                for (final q in rowsOf({'data': c['qty']})) '${fmtNum(q['value'])} ${q['unit']}/${q['per']}',
                context.formatString('eff.n_findings'.getString(context), [fmtNum(c['findings'])]),
              ].join(' · ')),
              trailing: AppText.body('${fmtNum(c['perDay'], decimals: 2)} $cur/d', weight: FontWeight.w700),
            ),
        ],
      ),
    ];
  },
  'report': (context, sm, site) => [
        _tiles([
          Kpi('eff.score', '${fmtNum(sm['score'])} · ${statusWord(s(sm['grade']) ?? '')}', tone: _scoreTone(n(sm['score']))),
          Kpi('eff.findings', fmtNum(rowsOf({'data': sm['findings']}).length), tone: Tone.warn),
          Kpi('eff.cost_per_day', '${fmtNum(at(sm, 'impact.perDay'), decimals: 2)} ${s(at(sm, 'impact.currency')) ?? ''}', tone: Tone.bad),
          Kpi('eff.data_health', fmtPct(at(sm, 'kpis.dataHealthPct'))),
        ]),
        _section(context, 'eff.headline'),
        for (final h in (sm['headline'] as List? ?? const [])) _pad(Padding(padding: const EdgeInsets.only(bottom: 8), child: AppText.body('• $h'))),
        _gap(),
        // The PDF is built in the browser (reportPdf.ts), so it stays on the desktop.
        _pad(const DesktopNote(textKey: 'desktop.eff_pdf')),
      ],
  'comfort': (context, sm, site) => [
        _pillarTiles(context, sm, 'comfort', [Kpi('eff.comfort_issues', fmtNum(at(sm, 'kpis.comfortIssues')), tone: Tone.warn)]),
        _section(context, 'eff.rooms'),
        RowGroup(
          label: '',
          dividerIndent: 16,
          rows: [
            for (final l in rowsOf({'data': at(sm, 'flow.loads')}))
              ListTile(
                title: AppText.body(s(l['label']) ?? '–'),
                subtitle: AppText.bodySmall('${'eff.target'.getString(context)} ${_deg(l['target'])}'),
                trailing: AppText.body(_deg(l['temp']), weight: FontWeight.w700, color: (n(l['issues']) ?? 0) > 0 ? FeColors.danger : FeColors.ink),
              ),
          ],
        ),
        _section(context, 'eff.findings'),
        _findingList(context, findingsOf(sm, pillar: 'comfort'), site, pageId: 'comfort'),
      ],
  'energy': (context, sm, site) => [
        _pillarTiles(context, sm, 'energy', [
          Kpi('eff.plant_delta_t', '${_deg(at(sm, 'kpis.plantDeltaT'))} / ${_deg(at(sm, 'kpis.designDeltaT'))}'),
          Kpi('eff.low_delta_t', fmtPct(at(sm, 'kpis.lowDeltaTPct'))),
        ]),
        if (sm['energy'] == null && sm['power'] == null) ...[_gap(10), _pad(AppText.bodySmall('eff.no_meters'.getString(context)))],
        _section(context, 'eff.findings'),
        _findingList(context, [...findingsOf(sm, pillar: 'energy'), ...findingsOf(sm, pillar: 'power')], site, pageId: 'energy'),
      ],
  'equipment': (context, sm, site) => [
        _pillarTiles(context, sm, 'equipment', [
          Kpi('eff.chillers_running', '${fmtNum(at(sm, 'kpis.chillersRunning'))} / ${fmtNum(at(sm, 'kpis.chillersTotal'))}', tone: Tone.good),
          Kpi('eff.not_in_auto', fmtNum(at(sm, 'kpis.notInAuto')), tone: Tone.warn),
        ]),
        _section(context, 'eff.units'),
        RowGroup(
          label: '',
          dividerIndent: 16,
          rows: [
            for (final u in [
              ...rowsOf({'data': at(sm, 'flow.chillers')}),
              ...rowsOf({'data': at(sm, 'flow.pumps')}),
              ...rowsOf({'data': at(sm, 'air.ahus')}),
            ])
              ListTile(
                title: AppText.body(s(u['label']) ?? '–'),
                subtitle: AppText.bodySmall([
                  u['running'] == true ? 'eff.running'.getString(context) : u['running'] == false ? 'eff.stopped'.getString(context) : null,
                  u['auto'] == false ? 'eff.manual'.getString(context) : null,
                  u['tripped'] == true ? 'eff.tripped'.getString(context) : null,
                  u['supply'] == null ? null : '${'eff.supply'.getString(context)} ${_deg(u['supply'])}',
                ].whereType<String>().join(' · ')),
                trailing: (n(u['issues']) ?? 0) > 0 ? TechChip(label: fmtNum(u['issues']), style: context.chips.priority('high')) : null,
              ),
          ],
        ),
        _section(context, 'eff.findings'),
        _findingList(context, findingsOf(sm, pillar: 'equipment'), site, pageId: 'equipment'),
      ],
  'safety': (context, sm, site) => [
        _pillarTiles(context, sm, 'safety', const []),
        _section(context, 'eff.findings'),
        _findingList(context, findingsOf(sm, pillar: 'safety'), site, pageId: 'safety'),
      ],
  'fix': (context, sm, site) => [
        _findingList(context, findingsOf(sm), site, pageId: 'fix'),
      ],
  'savings': (context, sm, site) {
    final priced = findingsOf(sm).where((f) => (n(at(f, 'impact.perDay')) ?? 0) > 0).toList()
      ..sort((a, b) => (n(at(b, 'impact.perDay')) ?? 0).compareTo(n(at(a, 'impact.perDay')) ?? 0));
    return [
      _tiles([Kpi('eff.cost_per_year', '${fmtNum(at(sm, 'impact.perYear'))} ${s(at(sm, 'impact.currency')) ?? ''}', tone: Tone.good)]),
      _section(context, 'eff.opportunities'),
      _findingList(context, priced, site, pageId: 'savings'),
    ];
  },
  'live': (context, sm, site) => [
        _tiles([
          Kpi('eff.plant_supply', _deg(at(sm, 'flow.plant.supply')), tone: Tone.info),
          Kpi('eff.plant_return', _deg(at(sm, 'flow.plant.ret'))),
          Kpi('eff.plant_delta_t', _deg(at(sm, 'flow.plant.deltaT'))),
          Kpi('eff.chillers_running', '${fmtNum(at(sm, 'kpis.chillersRunning'))} / ${fmtNum(at(sm, 'kpis.chillersTotal'))}', tone: Tone.good),
        ]),
        _section(context, 'eff.zones'),
        RowGroup(
          label: '',
          dividerIndent: 16,
          rows: [
            for (final l in rowsOf({'data': at(sm, 'flow.loads')}))
              ListTile(
                title: AppText.body(s(l['label']) ?? '–'),
                subtitle: AppText.bodySmall([
                  if (l['valve'] != null) '${'eff.valve'.getString(context)} ${fmtPct(l['valve'])}',
                  if (l['fan'] != null) '${'eff.fan'.getString(context)} ${fmtPct(l['fan'])}',
                ].join(' · ')),
                trailing: AppText.body(_deg(l['temp']), weight: FontWeight.w700),
              ),
          ],
        ),
        _gap(),
        _pad(const DesktopNote(textKey: 'desktop.eff_3d')),
      ],
  // Point-by-point charts need the web's picker; the phone shows where the site stands.
  'trends': (context, sm, site) => [
        _tiles([
          Kpi('eff.score', '${fmtNum(sm['score'])} · ${statusWord(s(sm['grade']) ?? '')}', tone: _scoreTone(n(sm['score']))),
          Kpi('eff.data_health', fmtPct(at(sm, 'kpis.dataHealthPct')), tone: _scoreTone(n(at(sm, 'kpis.dataHealthPct')))),
          Kpi('eff.plant_delta_t', '${_deg(at(sm, 'kpis.plantDeltaT'))} / ${_deg(at(sm, 'kpis.designDeltaT'))}'),
          Kpi('eff.chillers_running', '${fmtNum(at(sm, 'kpis.chillersRunning'))} / ${fmtNum(at(sm, 'kpis.chillersTotal'))}', tone: Tone.good),
        ]),
        _gap(),
        _pad(const DesktopNote(textKey: 'desktop.eff_trends')),
      ],
  'data': (context, sm, site) {
    final units = rowsOf({'data': at(sm, 'coverage.units')});
    double cover(Json u) {
      final cells = (u['cells'] as List? ?? const []).map((c) => n(c) ?? 0).toList();
      return cells.isEmpty ? 0 : cells.reduce((a, b) => a + b) / cells.length * 100;
    }

    return [
      _tiles([
        Kpi('eff.data_health', fmtPct(at(sm, 'health.pct')), tone: _scoreTone(n(at(sm, 'health.pct')))),
        Kpi('eff.points_live', '${fmtNum(at(sm, 'health.live'))} / ${fmtNum(at(sm, 'health.total'))}'),
        Kpi('eff.not_updating', fmtNum((at(sm, 'health.notUpdating') as List?)?.length ?? 0), tone: Tone.bad),
        Kpi('eff.flat_points', fmtNum((at(sm, 'health.flat') as List?)?.length ?? 0), tone: Tone.warn),
      ]),
      _section(context, 'eff.coverage'),
      RowGroup(
        label: '',
        dividerIndent: 16,
        rows: [
          for (final u in units)
            ListTile(
              title: AppText.body(s(u['label']) ?? '–'),
              subtitle: AppText.bodySmall(s(u['kind']) ?? ''),
              trailing: AppText.body(fmtPct(cover(u)), weight: FontWeight.w700, color: cover(u) < 90 ? FeColors.warning : FeColors.ink),
            ),
        ],
      ),
      _section(context, 'eff.punch_list'),
      RowGroup(
        label: '',
        dividerIndent: 16,
        rows: [
          for (final p in rowsOf({'data': at(sm, 'health.flat')}))
            ListTile(title: AppText.body('${p['equipment']} · ${p['point']}'), subtitle: AppText.bodySmall('eff.flat_hint'.getString(context))),
          for (final p in rowsOf({'data': at(sm, 'health.notUpdating')}))
            ListTile(title: AppText.body('${p['equipment'] ?? p['point'] ?? '–'}'), subtitle: AppText.bodySmall('eff.stale_hint'.getString(context))),
        ],
      ),
    ];
  },
  'checks': (context, sm, site) {
    final fired = <String>{for (final f in rowsOf({'data': sm['findings']})) '${f['rule']}'};
    final skipped = rowsOf({'data': sm['skipped']});
    return [
      _tiles([
        Kpi('eff.checks_firing', fmtNum(fired.length), tone: Tone.warn),
        Kpi('eff.checks_cannot_run', fmtNum(skipped.length), tone: Tone.neutral),
      ]),
      _section(context, 'eff.cannot_run'),
      RowGroup(
        label: '',
        dividerIndent: 16,
        rows: [for (final c in skipped) ListTile(title: AppText.body(s(c['check']) ?? '–'), subtitle: AppText.bodySmall(s(c['why']) ?? ''))],
      ),
    ];
  },
};

/// Pages with their own endpoint instead of the summary.
final Map<String, Widget Function(HvacSite site)> _ownBodies = {
  'actions': (site) => _ActionsBody(site: site),
  'settings': (site) => _SettingsBody(site: site),
};

Widget _pillarTiles(BuildContext context, Json sm, String pillar, List<Kpi> extra) {
  final p = pillarOf(sm, pillar);
  return _tiles([
    Kpi('eff.area_score', p == null || p['score'] == null ? '–' : fmtNum(p['score']), tone: _scoreTone(n(p?['score']))),
    Kpi('eff.issues', fmtNum(p?['issues'] ?? 0), tone: (n(p?['issues']) ?? 0) > 0 ? Tone.warn : Tone.good),
    ...extra,
  ]);
}

/// A page the phone has no body for.
Widget _webOnly(BuildContext context, String page) => _pad(const DesktopNote(textKey: 'desktop.note'));

// ── Fix tracker (/actions) ──────────────────────────────────────────────────

class _ActionsBody extends ConsumerWidget {
  const _ActionsBody({required this.site});
  final HvacSite site;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<dynamic>(
        key: ValueKey(site.key),
        future: ref.read(apiClientProvider).get('/api/fm/hvac-efficiency/actions', query: site.query),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(32), child: TechSpinner());
          if (snap.hasError) return _error(context, snap.error);
          final rows = rowsOf(snap.data);
          // ActionRow.state: open | recheck | verified | cancelled (services/hvacEfficiency/actions.ts).
          int count(String st) => rows.where((r) => r['state'] == st).length;
          return Column(
            children: [
              _tiles([
                Kpi('eff.raised', fmtNum(rows.length)),
                Kpi('eff.state_open', fmtNum(count('open')), tone: Tone.info),
                Kpi('eff.state_recheck', fmtNum(count('recheck')), tone: Tone.warn),
                Kpi('eff.state_verified', fmtNum(count('verified')), tone: Tone.good),
              ]),
              _gap(),
              if (rows.isEmpty) _pad(TechEmptyState(icon: LucideIcons.clipboardCheck, title: 'eff.no_actions'.getString(context))),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: TechCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            TechChip(label: 'eff.state_${r['state']}'.getString(context), style: context.chips.status(r['state'] == 'verified' ? 'completed' : r['state'] == 'open' ? 'in progress' : 'pending')),
                            const Spacer(),
                            AppText.caption(s(r['workOrderNumber']) ?? ''),
                          ],
                        ),
                        const SizedBox(height: 8),
                        AppText.titleSmall(s(r['title']) ?? '–', maxLines: 2, overflow: TextOverflow.ellipsis),
                        AppText.bodySmall([s(r['status']), s(r['assignedTo']), fmtDate(r['raisedAt'])].whereType<String>().join(' · ')),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

// ── Site settings (read-only; editing stays on the web) ─────────────────────

class _SettingsBody extends ConsumerWidget {
  const _SettingsBody({required this.site});
  final HvacSite site;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<dynamic>(
        key: ValueKey(site.key),
        future: ref.read(apiClientProvider).get('/api/fm/hvac-efficiency/settings', query: site.query),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(32), child: TechSpinner());
          if (snap.hasError) return _error(context, snap.error);
          final d = dataOf(snap.data);
          final values = d['settings'] is Map ? Map<String, dynamic>.from(d['settings'] as Map) : const <String, dynamic>{};
          final specs = d['specs'] is Map ? Map<String, dynamic>.from(d['specs'] as Map) : const <String, dynamic>{};
          return Column(
            children: [
              RowGroup(
                label: '',
                dividerIndent: 16,
                rows: [
                  for (final e in specs.entries)
                    if (values.containsKey(e.key) && values[e.key] is! bool)
                      ListTile(
                        title: AppText.body(s(at(e.value, 'label')) ?? e.key),
                        subtitle: s(at(e.value, 'help')) == null ? null : AppText.bodySmall(s(at(e.value, 'help'))!, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: AppText.body('${s(values[e.key]) ?? '–'} ${s(at(e.value, 'unit')) ?? ''}'.trim(), weight: FontWeight.w700),
                      ),
                ],
              ),
              _pad(const DesktopNote(textKey: 'eff.settings_on_web')),
            ],
          );
        },
      );
}

// ── one finding: evidence, causes, fix plan, Raise WO ───────────────────────

class FindingDetailScreen extends ConsumerStatefulWidget {
  const FindingDetailScreen({super.key, required this.finding, required this.site, required this.pageId});
  final Json finding;
  final HvacSite site;

  /// The page it was opened from — must still be on for this user.
  final String pageId;

  @override
  ConsumerState<FindingDetailScreen> createState() => _FindingDetailScreenState();
}

class _FindingDetailScreenState extends ConsumerState<FindingDetailScreen> {
  bool _busy = false;
  String? _raised;

  /// The server replays the same requestId instead of creating a second WO.
  final _requestId = newSessionId();

  Map<String, dynamic> get _target => {...widget.site.query, 'findingId': widget.finding['id'], 'days': ref.read(effDaysProvider)};

  /// The web's WorkOrderDialog on a phone: the server previews the work order
  /// (asset, technician), the user confirms or picks, then it is created.
  /// An asset is required (work_orders.relatedAssetId is NOT NULL on purpose,
  /// server LEARNINGS 2026-07-30); with no match the preview lists assets to pick.
  Future<void> _raise() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final raisedText = 'eff.wo_raised'.getString(context);
    try {
      final api = ref.read(apiClientProvider);
      final preview = WoPreview.fromJson(dataOf(await api.post('/api/fm/hvac-efficiency/work-order/preview', body: _target)));
      if (!mounted) return;
      final pick = await showDialog<(String, String)>(context: context, builder: (_) => RaiseWoDialog(preview: preview));
      if (pick == null || !mounted) return;
      final body = await api.post('/api/fm/hvac-efficiency/work-order', body: {
        ..._target,
        'requestId': _requestId,
        'assetId': pick.$1,
        'technicianId': pick.$2,
      });
      final d = dataOf(body);
      final ref0 = s(d['workOrderId']) ?? s(at(d, 'workOrder.workOrderId')) ?? s(d['workOrderNumber']);
      setState(() => _raised = ref0 ?? '✓');
      messenger.showSnackBar(SnackBar(content: AppText(raisedText.replaceFirst('%a', ref0 ?? ''))));
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pushed with Navigator: re-check that the page is still switched on.
    final boot = ref.watch(loadedCatalogProvider);
    final pages = boot?.module('efficiency')?.pages ?? const <ModulePage>[];
    if (boot != null && !pages.any((p) => p.id == widget.pageId)) return const UnavailableScreen();

    final f = widget.finding;
    final canRaise = pages.any((p) => p.id == 'fix') && f['workOrder'] != null;
    return Scaffold(
      appBar: FeHeader(title: 'eff.finding'.getString(context)),
      body: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 32),
        children: [
          _pad(TechCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TechChip(label: _sevLabel(context, f['severity']), style: context.chips.priority(_sevChip(f['severity']))),
                const SizedBox(height: 10),
                AppText.title(s(f['title']) ?? '–'),
                if (s(f['summary']) != null) ...[const SizedBox(height: 6), AppText.bodyMedium(s(f['summary'])!)],
                if (n(f['hours']) != null) ...[
                  const SizedBox(height: 8),
                  AppText.caption(context.formatString('eff.hours_seen'.getString(context), [fmtNum(f['hours'], decimals: 1)])),
                ],
              ],
            ),
          )),
          if (canRaise) ...[
            _gap(12),
            _pad(SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _busy || _raised != null ? null : _raise,
                icon: const Icon(LucideIcons.wrench, size: 16),
                label: AppText(_raised == null ? 'eff.raise_wo'.getString(context) : context.formatString('eff.wo_raised'.getString(context), [_raised!])),
              ),
            )),
          ],
          if (rowsOf({'data': f['evidence']}).isNotEmpty) ...[
            _gap(),
            RowGroup(
              label: 'eff.evidence'.getString(context),
              dividerIndent: 16,
              rows: [for (final e in rowsOf({'data': f['evidence']})) ListTile(title: AppText.caption(s(e['label']) ?? ''), subtitle: AppText.body(s(e['value']) ?? ''))],
            ),
          ],
          if ((f['causes'] as List?)?.isNotEmpty == true)
            RowGroup(
              label: 'eff.causes'.getString(context),
              dividerIndent: 16,
              rows: [for (final c in f['causes'] as List) ListTile(dense: true, title: AppText.body('$c'))],
            ),
          if (rowsOf({'data': f['actions']}).isNotEmpty)
            RowGroup(
              label: 'eff.fix_plan'.getString(context),
              dividerIndent: 16,
              rows: [
                for (final a in rowsOf({'data': f['actions']}))
                  ListTile(
                    dense: true,
                    leading: TechChip(label: 'eff.tier_${a['tier']}'.getString(context).endsWith(' not found') ? '${a['tier']}' : 'eff.tier_${a['tier']}'.getString(context), style: context.chips.status('draft'), uppercase: false),
                    title: AppText.body(s(a['text']) ?? ''),
                  ),
              ],
            ),
          // Each question is a paid AI call: nothing runs until one is asked.
          _pad(AskAiCard(finding: f)),
        ],
      ),
    );
  }
}

/// `POST /api/fm/hvac-efficiency/work-order/preview` (server
/// hvacEfficiency/workOrder.ts `WoPreview`), the parts the phone uses.
class WoPreview {
  const WoPreview({this.title, this.assetId, this.assets = const [], this.technicianId, this.technicians = const [], this.existing});

  final String? title;

  /// The matched asset (BMS point mapping or name), if any.
  final String? assetId;

  /// (id, label) to pick from: the matched ones, or the site's assets.
  final List<(String, String)> assets;
  final String? technicianId;
  final List<(String, String)> technicians;

  /// Already raised today for this finding: its work order number.
  final String? existing;

  factory WoPreview.fromJson(Json j) {
    final asset = j['asset'] is Map ? (j['asset'] as Map).cast<String, dynamic>() : null;
    String label(Json a) => [s(a['name']), s(a['reference'])].whereType<String>().join(' · ');
    final matched = s(asset?['id']);
    return WoPreview(
      title: s(j['title']),
      assetId: matched,
      assets: [
        if (asset != null && matched != null) (matched, label(asset)),
        for (final a in rowsOf({'data': j['assetCandidates']}))
          if (s(a['id']) != null && s(a['id']) != matched) (s(a['id'])!, label(a)),
      ],
      technicianId: s(at(j, 'technician.id')),
      technicians: [
        for (final t in rowsOf({'data': j['technicians']}))
          if (s(t['id']) != null) (s(t['id'])!, s(t['name']) ?? '–'),
      ],
      existing: s(at(j, 'existing.workOrderId')),
    );
  }
}

/// Pops (assetId, technicianId), or null when cancelled.
class RaiseWoDialog extends StatefulWidget {
  const RaiseWoDialog({super.key, required this.preview});
  final WoPreview preview;

  @override
  State<RaiseWoDialog> createState() => _RaiseWoDialogState();
}

class _RaiseWoDialogState extends State<RaiseWoDialog> {
  late String? _asset = widget.preview.assetId;
  late String? _tech = widget.preview.technicianId;

  Widget _pick(String labelKey, String hintKey, String? value, List<(String, String)> items, ValueChanged<String?> onChanged) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: labelKey.getString(context)),
        hint: AppText(hintKey.getString(context)),
        items: [
          for (final (id, label) in items) DropdownMenuItem(value: id, child: AppText(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    return AlertDialog(
      title: AppText.title('eff.raise_wo'.getString(context)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.title != null) AppText.bodyMedium(p.title!),
            if (p.existing != null) ...[
              const SizedBox(height: 8),
              AppText.caption(context.formatString('eff.wo_existing'.getString(context), [p.existing!]), color: FeColors.warning),
            ],
            const SizedBox(height: 12),
            _pick('eff.wo_asset', 'eff.wo_pick_asset', _asset, p.assets, (v) => setState(() => _asset = v)),
            if (p.assetId != null && _asset == p.assetId) ...[
              const SizedBox(height: 4),
              AppText.caption('eff.wo_asset_matched'.getString(context)),
            ],
            if (p.assets.isEmpty) ...[
              const SizedBox(height: 4),
              AppText.caption('eff.wo_no_assets'.getString(context), color: FeColors.danger),
            ],
            const SizedBox(height: 12),
            _pick('eff.wo_technician', 'eff.wo_pick_technician', _tech, p.technicians, (v) => setState(() => _tech = v)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: AppText('common.cancel'.getString(context))),
        TextButton(
          onPressed: _asset == null || _tech == null ? null : () => Navigator.pop(context, (_asset!, _tech!)),
          child: AppText('eff.raise_wo'.getString(context)),
        ),
      ],
    );
  }
}

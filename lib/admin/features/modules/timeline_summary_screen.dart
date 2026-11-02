import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';
import 'module_spec.dart';
import 'module_summary_screen.dart';

/// Timeline Revisit on the phone: today's occupancy in numbers. The web
/// replays it in 3D; the phone reads the same one-call rollup the web's
/// Occupancy dashboard uses — `GET /api/timeline/occupancy/rollup?from&to&step`
/// (server occupancyFootfall.ts `buildRollup`: footfall, entrances, floors,
/// busiest rooms and over-capacity runs at the window end).

/// Today from local midnight to now, in 15-minute steps (the server's default).
({int from, int to}) todayWindow(DateTime now) => (from: DateTime(now.year, now.month, now.day).millisecondsSinceEpoch, to: now.millisecondsSinceEpoch);

String _hm(Object? ms) {
  final v = n(ms);
  if (v == null) return '–';
  final t = DateTime.fromMillisecondsSinceEpoch(v.toInt());
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

Tone _loadTone(num? pct) => pct == null ? Tone.neutral : pct >= 100 ? Tone.bad : pct >= 80 ? Tone.warn : Tone.good;

class TimelineSummaryScreen extends ConsumerStatefulWidget {
  const TimelineSummaryScreen({super.key, required this.module, this.now});
  final MobileModule module;

  /// For tests; the real screen reads the clock.
  final DateTime? now;

  @override
  ConsumerState<TimelineSummaryScreen> createState() => _TimelineSummaryScreenState();
}

class _TimelineSummaryScreenState extends ConsumerState<TimelineSummaryScreen> {
  Json? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = todayWindow(widget.now ?? DateTime.now());
    try {
      final body = await ref.read(apiClientProvider).get('/api/timeline/occupancy/rollup', query: {'from': '${w.from}', 'to': '${w.to}', 'step': '900'});
      if (mounted) setState(() => (_data = dataOf(body), _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: FeHeader(title: widget.module.label),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            if (d == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
            if (d == null && _error != null)
              TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null),
            if (d != null) ..._body(context, d),
            const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: DesktopNote(textKey: 'desktop.timeline')),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, Json d) {
    final now = n(d['cursorOccupancy']);
    final cap = n(d['capacity']);
    final vsPrev = n(d['footfallVsPrevPct']);
    final over = rowsOf({'data': d['incidents']});
    final floors = rowsOf({'data': d['floors']})..sort((a, b) => (n(b['level']) ?? 0).compareTo(n(a['level']) ?? 0));
    final rooms = rowsOf({'data': d['topSpaces']}).where((r) => (n(r['value']) ?? 0) > 0).take(5).toList();
    final doors = rowsOf({'data': d['entrances']});
    final kpis = [
      Kpi('timeline.now', '${fmtNum(now)} / ${fmtNum(cap)}', tone: _loadTone(now == null || cap == null || cap == 0 ? null : now / cap * 100)),
      Kpi('timeline.peak', '${fmtNum(at(d, 'peak.value'))} · ${_hm(at(d, 'peak.t'))}', tone: Tone.info),
      Kpi('timeline.arrivals', vsPrev == null ? fmtNum(d['footfallTotal']) : '${fmtNum(d['footfallTotal'])} (${vsPrev > 0 ? '+' : ''}${fmtNum(vsPrev, decimals: 1)}%)'),
      Kpi('timeline.over_capacity', fmtNum(over.length), tone: over.isEmpty ? Tone.good : Tone.bad),
    ];
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LayoutBuilder(
          builder: (context, c) => Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (final k in kpis) SizedBox(width: (c.maxWidth - 10) / 2, child: KpiTile(k))],
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (floors.isNotEmpty)
        RowGroup(
          label: 'timeline.floors'.getString(context),
          dividerIndent: 16,
          rows: [
            for (final f in floors)
              ListTile(
                dense: true,
                title: AppText.body(s(f['storey']) ?? '–'),
                subtitle: AppText.caption(context.formatString('timeline.floor_line'.getString(context), [fmtNum(f['occupancy']), fmtNum(f['capacity']), fmtNum(f['rooms'])])),
                trailing: AppText.body('${fmtNum(f['pct'])}%', weight: FontWeight.w700, color: toneColor(_loadTone(n(f['pct'])))),
              ),
          ],
        ),
      if (rooms.isNotEmpty)
        RowGroup(
          label: 'timeline.busiest'.getString(context),
          dividerIndent: 16,
          rows: [
            for (final r in rooms)
              ListTile(
                dense: true,
                title: AppText.body(s(r['spaceCode']) ?? '–'),
                subtitle: AppText.caption([s(r['storey']), s(r['role'])].whereType<String>().join(' · ')),
                trailing: AppText.body(
                  '${fmtNum(r['value'])} / ${fmtNum(r['capacity'])}',
                  weight: FontWeight.w700,
                  color: (n(r['value']) ?? 0) > (n(r['capacity']) ?? double.infinity) ? FeColors.danger : FeColors.ink,
                ),
              ),
          ],
        ),
      if (over.isNotEmpty)
        RowGroup(
          label: 'timeline.over_list'.getString(context),
          dividerIndent: 16,
          rows: [
            for (final i in over.take(5))
              ListTile(
                dense: true,
                title: AppText.body(s(i['spaceCode']) ?? '–'),
                subtitle: AppText.caption('${_hm(i['from'])}–${_hm(i['to'])} · ${s(i['storey']) ?? ''}'),
                trailing: AppText.body('${fmtNum(i['peak'])} / ${fmtNum(i['capacity'])}', weight: FontWeight.w700, color: FeColors.danger),
              ),
          ],
        ),
      if (doors.isNotEmpty)
        RowGroup(
          label: 'timeline.entrances'.getString(context),
          dividerIndent: 16,
          rows: [
            for (final e in doors)
              ListTile(dense: true, title: AppText.body(s(e['name']) ?? '–'), trailing: AppText.body(fmtNum(e['count']), weight: FontWeight.w700)),
          ],
        ),
    ];
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/network/api_exception.dart';
import '../../state/providers.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'module_spec.dart';
import 'module_summary_screen.dart';
import '../../../widgets/dir_icon.dart';

/// The web's yearly PM compliance report for one building
/// (app/facility-management/preventive-maintenance/compliance-report):
///   GET /api/fm/preventive-maintenance/compliance-report?buildingId&year&pmCategory
///   → {building, year, pmCategory, total, completed, open, coveragePercent, rows:[…]}
/// (server pmComplianceReportService.ts; one row per PM cycle in the year,
/// sorted by planned date). Same filters as the web: year, and Regulatory +
/// OEM (default) / Regulatory only / OEM only. The web exports CSV / XLSX in
/// the browser; the phone shares a CSV.

const pmReportCategories = <String, String>{
  'regulatory,oem': 'pmr.cat_both',
  'regulatory': 'pmr.cat_regulatory',
  'oem': 'pmr.cat_oem',
};

/// Rows by "YYYY-MM" of their planned date, months in order; undated last.
Map<String, List<Json>> rowsByMonth(List<Json> rows) {
  final out = <String, List<Json>>{};
  for (final r in rows) {
    final t = DateTime.tryParse('${r['plannedDate'] ?? ''}')?.toLocal();
    final key = t == null ? '' : '${t.year}-${t.month.toString().padLeft(2, '0')}';
    (out[key] ??= []).add(r);
  }
  final keys = out.keys.toList()..sort((a, b) => a.isEmpty ? 1 : b.isEmpty ? -1 : a.compareTo(b));
  return {for (final k in keys) k: out[k]!};
}

/// The report as CSV, the web table's columns (PM #, Asset, Category, Status, Planned, Completed, Technician).
String pmReportCsv(List<Json> rows) {
  String cell(Object? v) {
    final t = v == null ? '' : '$v';
    return RegExp(r'[",\n\r]').hasMatch(t) ? '"${t.replaceAll('"', '""')}"' : t;
  }

  String day(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal().toIso8601String().substring(0, 10) ?? '';
  return [
    'PM #,Asset,Location,Category,Status,Planned,Completed,Technician',
    for (final r in rows)
      [r['pmScheduleId'], r['assetName'], r['location'], r['pmCategory'], r['status'], day(r['plannedDate']), day(r['completedDate']), r['technicianName']].map(cell).join(','),
  ].join('\r\n');
}

class PmReportScreen extends ConsumerStatefulWidget {
  const PmReportScreen({super.key, required this.buildingId, required this.buildingName, this.year});
  final String buildingId;
  final String buildingName;

  /// For tests; defaults to this year.
  final int? year;

  @override
  ConsumerState<PmReportScreen> createState() => _PmReportScreenState();
}

class _PmReportScreenState extends ConsumerState<PmReportScreen> {
  late int _year = widget.year ?? DateTime.now().year;
  String _cat = 'regulatory,oem';
  Json? _data;
  Object? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() => (_data = null, _error = null));
    try {
      final body = await ref.read(apiClientProvider).get('/api/fm/preventive-maintenance/compliance-report', query: {
        'buildingId': widget.buildingId,
        'year': '$_year',
        'pmCategory': _cat,
      });
      if (mounted && gen == _gen) setState(() => _data = dataOf(body));
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  void _shiftYear(int by) {
    setState(() => _year += by);
    _load();
  }

  Future<void> _share(List<Json> rows) async {
    final name = 'compliance-report-${widget.buildingName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}-$_year.csv';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(utf8.encode(pmReportCsv(rows)), name: name, mimeType: 'text/csv')],
      fileNameOverrides: [name],
      title: name,
    ));
  }

  String _error404(BuildContext context) {
    final e = _error;
    if (e is HttpFailure && e.status == 404) return 'pmr.not_available'.getString(context);
    if (e is HttpFailure && e.status == 403) return 'pmr.no_access'.getString(context);
    return e is ApiFailure ? e.message : '$e';
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final rows = rowsOf({'data': d?['rows']});
    final l = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: FeHeader(
        title: 'pmr.title'.getString(context),
        actions: [
          if (rows.isNotEmpty) IconButton(icon: const Icon(LucideIcons.share2, size: 20), tooltip: 'pmr.share'.getString(context), onPressed: () => _share(rows)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: AppText.titleMedium(s(at(d ?? const {}, 'building.name')) ?? widget.buildingName)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(icon: const DirIcon(LucideIcons.chevronLeft), tooltip: 'pmr.prev_year'.getString(context), onPressed: () => _shiftYear(-1)),
                  Expanded(child: AppText.titleSmall('$_year', align: TextAlign.center)),
                  IconButton(
                    icon: const DirIcon(LucideIcons.chevronRight),
                    tooltip: 'pmr.next_year'.getString(context),
                    onPressed: _year >= DateTime.now().year + 1 ? null : () => _shiftYear(1),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final e in pmReportCategories.entries)
                    ChoiceChip(
                      label: AppText(e.value.getString(context)),
                      selected: _cat == e.key,
                      onSelected: (_) {
                        setState(() => _cat = e.key);
                        _load();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (d == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
            if (_error != null) Padding(padding: const EdgeInsets.all(16), child: TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error404(context))),
            if (d != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LayoutBuilder(
                  builder: (context, c) => Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final k in [
                        Kpi('pmr.total', fmtNum(d['total'])),
                        Kpi('pmr.completed', fmtNum(d['completed']), tone: Tone.good),
                        Kpi('pmr.open_count', fmtNum(d['open']), tone: (n(d['open']) ?? 0) > 0 ? Tone.warn : Tone.good),
                        Kpi('pmr.rate', d['coveragePercent'] == null ? 'pmr.no_records'.getString(context) : '${fmtNum(d['coveragePercent'], decimals: 1)}%', tone: Tone.info),
                      ])
                        SizedBox(width: (c.maxWidth - 10) / 2, child: KpiTile(k)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (rows.isEmpty) Padding(padding: const EdgeInsets.all(16), child: TechEmptyState(icon: LucideIcons.calendarCheck, title: 'pmr.empty'.getString(context))),
              for (final e in rowsByMonth(rows).entries)
                RowGroup(
                  label: e.key.isEmpty ? 'pmr.no_date'.getString(context) : l.formatMonthYear(DateTime(int.parse(e.key.substring(0, 4)), int.parse(e.key.substring(5)))),
                  dividerIndent: 16,
                  rows: [
                    for (final r in e.value)
                      ListTile(
                        dense: true,
                        title: AppText.body(s(r['assetName']) ?? '–', maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: AppText.caption(
                          [
                            s(r['pmScheduleId']),
                            chipLabel(s(r['pmCategory']) ?? ''),
                            fmtDate(r['plannedDate']),
                            if (r['completedDate'] != null) '✓ ${fmtDate(r['completedDate'])}',
                            s(r['technicianName']),
                          ].whereType<String>().where((x) => x.isNotEmpty).join(' · '),
                          maxLines: 2,
                        ),
                        trailing: s(r['status']) == null ? null : TechChip(label: chipLabel(s(r['status'])!), style: context.chips.status(s(r['status'])!)),
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

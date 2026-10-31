import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';
import 'module_spec.dart';

const _pageSize = 20;

/// Any Phase 3 module: summary tiles, then the record list (paged, optional
/// search). Tapping a row opens [RecordDetailScreen]. Pull to refresh.
class ModuleSummaryScreen extends ConsumerStatefulWidget {
  const ModuleSummaryScreen({super.key, required this.module, required this.spec, this.title});

  final MobileModule module;
  final ModuleSpec spec;

  /// The page label when this is one page of a module (Facility Ops).
  final String? title;

  @override
  ConsumerState<ModuleSummaryScreen> createState() => _ModuleSummaryScreenState();
}

class _ModuleSummaryScreenState extends ConsumerState<ModuleSummaryScreen> {
  final _rows = <Json>[];
  List<Kpi>? _kpis;
  Object? _kpiError;
  Object? _listError;
  int _page = 0;
  int? _total;
  bool _loadingList = false;
  bool _done = false;
  String _search = '';
  Timer? _debounce;

  ListSpec? get _list => widget.spec.list;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([_loadKpis(), _loadList(reset: true)]);
  }

  Future<void> _loadKpis() async {
    if (widget.spec.summaries.isEmpty) return;
    final api = ref.read(apiClientProvider);
    try {
      // One request per summary source, in parallel; one failing source fails the tiles.
      final bodies = await Future.wait(widget.spec.summaries.map((s) => api.get(s.path, query: s.params)));
      final kpis = <Kpi>[
        for (var i = 0; i < bodies.length; i++) ...widget.spec.summaries[i].kpis(dataOf(bodies[i])),
      ];
      if (mounted) setState(() => (_kpis = kpis, _kpiError = null));
    } catch (e) {
      if (mounted) setState(() => _kpiError = e);
    }
  }

  Future<void> _loadList({bool reset = false}) async {
    final list = _list;
    if (list == null || _loadingList || (_done && !reset)) return;
    final page = reset ? 1 : _page + 1;
    setState(() => _loadingList = true);
    try {
      final body = await ref.read(apiClientProvider).get(list.path, query: {
        ...list.query,
        ...?list.liveQuery?.call(),
        if (list.pageQuery != null) ...list.pageQuery!(page, _pageSize),
        if (list.searchParam != null && _search.isNotEmpty) list.searchParam!: _search,
      });
      final rows = list.items?.call(body) ?? rowsOf(body);
      if (!mounted) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(rows);
        _page = page;
        _total = totalOf(body);
        // No paging on this endpoint, or the last page came back short.
        _done = list.pageQuery == null || rows.length < _pageSize || (_total != null && _rows.length >= _total!);
        _listError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _listError = e);
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search = v.trim();
      _loadList(reset: true);
    });
  }

  Future<void> _open(Json row) async {
    final r = _list!.row(row);
    // A page spec ("facility_ops:visitors") keeps its page in the record path.
    final id = widget.spec.moduleId;
    final page = id.contains(':') ? id.substring(id.indexOf(':') + 1) : null;
    final changed = await context.push<bool>(recordPath(widget.module.id, r.id, page: page), extra: row);
    if (changed == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: FeHeader(title: widget.title ?? widget.module.label, actions: [OpenOnWebButton(path: widget.module.webPath)]),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 400) _loadList();
            return false;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (widget.spec.summaries.isNotEmpty) ...[
                _KpiGrid(kpis: _kpis, error: _kpiError),
                const SizedBox(height: 16),
              ],
              if (list != null) ...[
                if (list.searchParam != null) ...[
                  TextField(
                    onChanged: _onSearch,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'common.search'.getString(context),
                      prefixIcon: const Icon(LucideIcons.search, size: 18),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_total != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, left: 4),
                    child: AppText.label(
                      context.formatString('module.records'.getString(context), [fmtNum(_total)]),
                      color: FeColors.ink2,
                    ),
                  ),
                ..._listBody(context, list),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _listBody(BuildContext context, ListSpec list) {
    if (_rows.isEmpty && _loadingList) return const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())];
    if (_rows.isEmpty && _listError != null) {
      return [
        TechEmptyState(
          icon: LucideIcons.circleAlert,
          title: 'module.load_error'.getString(context),
          subtitle: _listError is ApiFailure ? (_listError as ApiFailure).message : null,
        ),
      ];
    }
    if (_rows.isEmpty) {
      return [TechEmptyState(icon: LucideIcons.inbox, title: 'module.empty'.getString(context))];
    }
    return [
      for (final row in _rows)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: RecordCard(row: list.row(row), onTap: () => _open(row))),
      if (_loadingList) const Padding(padding: EdgeInsets.all(16), child: TechSpinner(size: 24)),
    ];
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.kpis, required this.error});
  final List<Kpi>? kpis;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return TechCard(
        child: Row(
          children: [
            const Icon(LucideIcons.circleAlert, size: 18, color: FeColors.warning),
            const SizedBox(width: 10),
            Expanded(child: AppText.bodySmall('module.summary_error'.getString(context))),
          ],
        ),
      );
    }
    final k = kpis;
    if (k == null) return const SizedBox(height: 80, child: TechSpinner(size: 24));
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final kpi in k) SizedBox(width: w, child: KpiTile(kpi))],
        );
      },
    );
  }
}

Color toneColor(Tone t) => switch (t) {
      Tone.good => FeColors.success,
      Tone.warn => FeColors.warning,
      Tone.bad => FeColors.danger,
      Tone.info => FeColors.primary,
      Tone.neutral => FeColors.ink,
    };

/// A tile label is an i18n key, or a literal (month names from the server).
String kpiLabel(BuildContext context, String label) {
  if (!label.contains('.')) return label;
  final t = label.getString(context);
  return t.endsWith(' not found') ? label : t;
}

class KpiTile extends StatelessWidget {
  const KpiTile(this.kpi, {super.key});
  final Kpi kpi;

  @override
  Widget build(BuildContext context) => TechCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText.titleMedium(kpi.value, color: toneColor(kpi.tone), maxLines: 1),
            const SizedBox(height: 2),
            AppText.caption(kpiLabel(context, kpi.label), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      );
}

class RecordCard extends StatelessWidget {
  const RecordCard({super.key, required this.row, required this.onTap});
  final RecordRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = row;
    return TechCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (r.status != null) TechChip(label: chipLabel(r.status!), style: context.chips.status(r.status)),
              if (r.status != null && r.priority != null) const SizedBox(width: 6),
              if (r.priority != null) TechChip(label: chipLabel(r.priority!), style: context.chips.priority(r.priority)),
              const Spacer(),
              if (r.ref != null) AppText.caption(r.ref!),
            ],
          ),
          if (r.status != null || r.priority != null || r.ref != null) const SizedBox(height: 8),
          AppText.titleSmall(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (r.subtitle != null || r.date != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (r.subtitle != null)
                  Expanded(child: AppText.bodySmall(r.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis))
                else
                  const Spacer(),
                if (r.date != null) ...[
                  const SizedBox(width: 8),
                  AppText.caption(fmtDate(r.date)!),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

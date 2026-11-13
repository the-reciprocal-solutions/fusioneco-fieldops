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
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'module_spec.dart';
import '../../../widgets/dir_icon.dart';

/// AMC's calendar on the phone (the web's schedule calendar). One month at a
/// time — `GET /api/fm/schedule-management/calendar?year=&month=` →
/// `{data: {"YYYY-MM": {"<day>": [item]}}}` (live 2026-11-01: 2.6 KB for a
/// month vs 349 KB for everything). A day with work gets a dot per kind;
/// tapping a day lists its items, and an item opens its schedule record.

/// Items of one month by day of month.
Map<int, List<Json>> calendarDays(Object? body, int year, int month) {
  final data = body is Map && body['data'] is Map ? body['data'] as Map : const {};
  final key = '$year-${month.toString().padLeft(2, '0')}';
  final days = data[key] is Map ? data[key] as Map : const {};
  return {
    for (final e in days.entries)
      ?int.tryParse('${e.key}'): [for (final i in e.value is List ? e.value as List : const []) if (i is Map) i.cast<String, dynamic>()],
  };
}

/// Dot colour per kind of schedule item.
Color kindHue(String? type) => switch (type) {
      'preventive' => FeColors.primary,
      'work-order' => FeColors.warning,
      'reactive' => FeColors.danger,
      'inspection' => FeColors.success,
      _ => FeColors.ink2,
    };

class AmcCalendarScreen extends ConsumerStatefulWidget {
  const AmcCalendarScreen({super.key, required this.module, this.initialMonth});
  final MobileModule module;
  final DateTime? initialMonth;

  @override
  ConsumerState<AmcCalendarScreen> createState() => _AmcCalendarScreenState();
}

class _AmcCalendarScreenState extends ConsumerState<AmcCalendarScreen> {
  late DateTime _month = DateTime((widget.initialMonth ?? DateTime.now()).year, (widget.initialMonth ?? DateTime.now()).month);
  late int? _day = _isThisMonth(_month) ? DateTime.now().day : null;
  Map<int, List<Json>>? _days;
  Object? _error;
  int _gen = 0;

  static bool _isThisMonth(DateTime m) => m.year == DateTime.now().year && m.month == DateTime.now().month;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() => (_days = null, _error = null));
    try {
      final body = await ref.read(apiClientProvider).get('/api/fm/schedule-management/calendar', query: {'year': '${_month.year}', 'month': '${_month.month}'});
      if (mounted && gen == _gen) setState(() => _days = calendarDays(body, _month.year, _month.month));
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  void _shift(int by) {
    setState(() {
      _month = DateTime(_month.year, _month.month + by);
      _day = _isThisMonth(_month) ? DateTime.now().day : null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final days = _days;
    final picked = _day == null ? const <Json>[] : (days?[_day] ?? const <Json>[]);
    final total = days?.values.fold<int>(0, (a, b) => a + b.length) ?? 0;
    return Scaffold(
      appBar: FeHeader(title: 'amc.calendar'.getString(context)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(icon: const DirIcon(LucideIcons.chevronLeft), tooltip: l.previousMonthTooltip, onPressed: () => _shift(-1)),
                  Expanded(child: AppText.titleMedium(l.formatMonthYear(_month), align: TextAlign.center)),
                  IconButton(icon: const DirIcon(LucideIcons.chevronRight), tooltip: l.nextMonthTooltip, onPressed: () => _shift(1)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AppText.caption(
                days == null ? '' : context.formatString('amc.month_total'.getString(context), [total]),
                align: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: 'module.load_error'.getString(context),
                  subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null,
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _MonthGrid(month: _month, days: days ?? const {}, picked: _day, onPick: (d) => setState(() => _day = d)),
              ),
              if (days == null) const Padding(padding: EdgeInsets.all(16), child: TechSpinner()),
              const SizedBox(height: 8),
              if (days != null && _day != null)
                picked.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: AppText.bodySmall('amc.day_empty'.getString(context), align: TextAlign.center),
                      )
                    : RowGroup(
                        label: l.formatFullDate(DateTime(_month.year, _month.month, _day!)),
                        dividerIndent: 16,
                        rows: [for (final i in picked) _ItemRow(item: i, module: widget.module)],
                      ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.days, required this.picked, required this.onPick});
  final DateTime month;
  final Map<int, List<Json>> days;
  final int? picked;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final first = l.firstDayOfWeekIndex; // 0 = Sunday
    final lead = (DateTime(month.year, month.month).weekday % 7 - first) % 7;
    final count = DateUtils.getDaysInMonth(month.year, month.month);
    final now = DateTime.now();
    final cells = <Widget>[
      for (var i = 0; i < 7; i++) Center(child: AppText.caption(l.narrowWeekdays[(first + i) % 7])),
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var d = 1; d <= count; d++) _DayCell(
        day: d,
        items: days[d] ?? const [],
        picked: d == picked,
        today: now.year == month.year && now.month == month.month && now.day == d,
        onTap: () => onPick(d),
      ),
    ];
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 0.9,
      children: cells,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.items, required this.picked, required this.today, required this.onTap});
  final int day;
  final List<Json> items;
  final bool picked;
  final bool today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kinds = {for (final i in items) s(i['type'])}.take(3).toList();
    return Semantics(
      button: true,
      selected: picked,
      label: '$day, ${items.length}',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: picked ? FeColors.primary.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(10),
            border: today ? Border.all(color: FeColors.primary) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppText.bodySmall('$day', weight: picked || today ? FontWeight.w700 : null),
              const SizedBox(height: 3),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final k in kinds)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(color: kindHue(k), shape: BoxShape.circle),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.module});
  final Json item;
  final MobileModule module;

  @override
  Widget build(BuildContext context) {
    final st = s(item['status']);
    return ListTile(
      dense: true,
      leading: Container(width: 10, height: 10, decoration: BoxDecoration(color: kindHue(s(item['type'])), shape: BoxShape.circle)),
      title: AppText.body(s(item['assetName']) ?? s(item['category']) ?? s(item['description']) ?? '–', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: AppText.caption([chipLabel(s(item['type']) ?? ''), s(item['technicianName']), s(item['location'])].whereType<String>().where((x) => x.isNotEmpty).join(' · '), maxLines: 2),
      trailing: st == null ? null : TechChip(label: chipLabel(st), style: context.chips.status(st)),
      onTap: () => context.push(recordPath(module.id, '${item['id']}')),
    );
  }
}

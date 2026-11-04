import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../domain/alert.dart';
import '../../state/alerts_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'alert_widgets.dart';

/// Alert Center on the phone (FE-mobile.md Phase 2): counts, severity /
/// building / status / mine filters, worst-first list. Live: the socket's
/// `alerts:changed` refetches it. Long-press starts a selection for bulk
/// acknowledge / resolve. Rules, teams and the simulator stay on the web.
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final _selected = <String>{};
  bool _busy = false;

  void _toggle(String key) => setState(() => _selected.contains(key) ? _selected.remove(key) : _selected.add(key));

  Future<void> _bulk(String action) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref.read(alertsRepositoryProvider).bulk(_selected.toList(), action);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: AppText(context.formatString('alerts.bulk_done'.getString(context), [r.done, r.skipped])),
      ));
      setState(_selected.clear);
      ref.read(alertsTickProvider.notifier).state++;
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(alertListProvider);
    final patches = ref.watch(alertPatchesProvider);
    final filters = ref.watch(alertFiltersProvider);
    final selecting = _selected.isNotEmpty;

    return Scaffold(
      appBar: FeHeader(
        title: selecting
            ? context.formatString('alerts.selected'.getString(context), [_selected.length])
            : 'nav.alerts'.getString(context),
        subtitle: selecting ? null : 'nav.alerts_sub'.getString(context),
        art: FeArt.alerts,
        leading: selecting
            ? IconButton(icon: const Icon(LucideIcons.x), onPressed: () => setState(_selected.clear))
            : null,
      ),
      bottomNavigationBar: selecting ? _BulkBar(busy: _busy, onAction: _bulk) : null,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.read(alertsTickProvider.notifier).state++;
          await ref.read(alertListProvider.future).catchError((_) => const AlertPage(rows: [], total: 0, summary: AlertSummary()));
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _SummaryRow(summary: list.valueOrNull?.summary),
            const SizedBox(height: 12),
            _FilterBar(filters: filters, buildings: list.valueOrNull?.summary.buildings ?? const []),
            const SizedBox(height: 12),
            ...list.when(
              skipLoadingOnRefresh: true,
              skipLoadingOnReload: true,
              loading: () => const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())],
              error: (e, _) => [
                TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: alertsErrorText(context),
                  subtitle: e is ApiFailure ? e.message : null,
                ),
              ],
              data: (page) => page.rows.isEmpty
                  ? [
                      TechEmptyState(
                        icon: LucideIcons.bellOff,
                        iconColor: FeColors.success,
                        title: 'alerts.empty_title'.getString(context),
                        subtitle: 'alerts.empty_hint'.getString(context),
                      ),
                    ]
                  : [
                      for (final a in page.rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _AlertCard(
                            alert: patchedAlert(patches, a),
                            selected: _selected.contains(a.key),
                            onTap: selecting ? () => _toggle(a.key) : () => context.push(Routes.alert(a.key)),
                            onLongPress: () => _toggle(a.key),
                          ),
                        ),
                      if (page.total > page.rows.length) ...[
                        AppText.bodySmall(
                          context.formatString('alerts.showing'.getString(context), [page.rows.length, page.total]),
                          align: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: OutlinedButton(
                            onPressed: list.isLoading ? null : () => ref.read(alertPageCountProvider.notifier).state++,
                            child: AppText('alerts.load_more'.getString(context)),
                          ),
                        ),
                      ],
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.summary});
  final AlertSummary? summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    Widget tile(String key, int? n, Color color, IconData icon) => Expanded(
          child: TechCard(
            radius: 16,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            child: Column(
              children: [
                IconBadge(icon: icon, style: FeBadgeStyle.of(color), size: 30, iconSize: 16),
                const SizedBox(height: 6),
                FittedBox(fit: BoxFit.scaleDown, child: AppText.titleMedium(n == null ? '–' : '$n', color: color == FeColors.primary ? FeColors.ink : color)),
                const SizedBox(height: 2),
                FittedBox(fit: BoxFit.scaleDown, child: AppText.caption(key.getString(context), maxLines: 1)),
              ],
            ),
          ),
        );
    return Row(
      children: [
        tile('alerts.sum_open', s?.open, FeColors.primary, LucideIcons.bell),
        const SizedBox(width: 8),
        tile('alerts.sum_critical', s?.critical, FeColors.danger, LucideIcons.triangleAlert),
        const SizedBox(width: 8),
        tile('alerts.sum_unack', s?.unacknowledged, FeColors.high, LucideIcons.clockAlert),
        const SizedBox(width: 8),
        tile('alerts.sum_mine', s?.mine, FeColors.ai, LucideIcons.user),
      ],
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filters, required this.buildings});
  final AlertFilters filters;

  /// The summary's building facet (counted without the building filter, so
  /// every choice stays listed while one is picked).
  final List<BuildingCount> buildings;

  String _buildingLabel(BuildContext context) {
    if (filters.buildings.isEmpty) return 'alerts.filter_building'.getString(context);
    if (filters.buildings.length > 1) {
      return context.formatString('alerts.filter_buildings_n'.getString(context), [filters.buildings.length]);
    }
    final id = filters.buildings.single;
    final b = buildings.where((b) => b.id == id).firstOrNull;
    return b == null ? 'alerts.filter_building'.getString(context) : _name(context, b);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void set(AlertFilters f) => ref.read(alertFiltersProvider.notifier).state = f;
    final showResolved = filters.status.contains('resolved');

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilterChip(
              label: AppText('alerts.filter_all'.getString(context), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              selected: filters.severity.isEmpty,
              onSelected: (_) => set(filters.copyWith(severity: const {})),
            ),
          ),
          for (final sev in alertSeverities)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: FilterChip(
                label: AppText.caption('alerts.severity_$sev'.getString(context), color: severityHue(sev), weight: FontWeight.w700),
                backgroundColor: severityHue(sev).withValues(alpha: 0.08),
                selectedColor: severityHue(sev).withValues(alpha: 0.22),
                side: BorderSide(color: severityHue(sev).withValues(alpha: filters.severity.contains(sev) ? 0.7 : 0.25)),
                selected: filters.severity.contains(sev),
                onSelected: (on) => set(filters.copyWith(severity: on ? {...filters.severity, sev} : ({...filters.severity}..remove(sev)))),
              ),
            ),
          // Shown once the list knows its buildings, or while one is picked.
          if (buildings.length > 1 || filters.buildings.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: FilterChip(
                avatar: const Icon(LucideIcons.building2, size: 14),
                label: AppText(_buildingLabel(context), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                selected: filters.buildings.isNotEmpty,
                onSelected: (_) async {
                  final picked = await showModalBottomSheet<Set<String>>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => _BuildingSheet(buildings: buildings, selected: filters.buildings),
                  );
                  if (picked != null) set(filters.copyWith(buildings: picked));
                },
              ),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilterChip(
              avatar: const Icon(LucideIcons.user, size: 14),
              label: AppText('alerts.filter_mine'.getString(context), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              selected: filters.mineOnly,
              onSelected: (on) => set(filters.copyWith(mineOnly: on)),
            ),
          ),
          FilterChip(
            label: AppText('alerts.filter_resolved'.getString(context), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            selected: showResolved,
            onSelected: (on) => set(filters.copyWith(
              status: on ? {...alertStatuses} : {'active', 'acknowledged'},
            )),
          ),
        ],
      ),
    );
  }
}

String _name(BuildContext context, BuildingCount b) =>
    b.id == 'none' ? 'alerts.no_building'.getString(context) : b.name;

/// Tick buildings; pops the new set (empty = every building).
class _BuildingSheet extends StatefulWidget {
  const _BuildingSheet({required this.buildings, required this.selected});
  final List<BuildingCount> buildings;
  final Set<String> selected;

  @override
  State<_BuildingSheet> createState() => _BuildingSheetState();
}

class _BuildingSheetState extends State<_BuildingSheet> {
  late final _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: AppText.titleSmall('alerts.filter_building'.getString(context))),
                    TextButton(
                      onPressed: _picked.isEmpty ? null : () => setState(_picked.clear),
                      child: AppText('alerts.filter_all_buildings'.getString(context)),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in widget.buildings)
                      CheckboxListTile(
                        dense: true,
                        value: _picked.contains(b.id),
                        title: AppText(_name(context, b)),
                        secondary: AppText.caption('${b.count}'),
                        onChanged: (on) => setState(() => on == true ? _picked.add(b.id) : _picked.remove(b.id)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, _picked),
                    child: AppText('alerts.filter_apply'.getString(context)),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.selected, required this.onTap, required this.onLongPress});

  final AlertItem alert;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final a = alert;
    return GestureDetector(
      onLongPress: onLongPress,
      child: TechCard(
        accentLeft: severityHue(a.severity),
        borderColor: selected ? FeColors.primary : null,
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(
              icon: a.severity == 'critical' || a.severity == 'high' ? LucideIcons.siren : LucideIcons.bellRing,
              style: FeBadgeStyle.of(severityHue(a.severity)),
              size: 38,
              iconSize: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SeverityChip(a.severity),
                      const SizedBox(width: 6),
                      AlertStatusChip(a.status),
                      const Spacer(),
                      if (selected) const Icon(LucideIcons.circleCheck, size: 18, color: FeColors.primary),
                      if (!selected) AppText.caption(timeAgo(context, a.lastAt)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AppText.titleSmall(a.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (a.where.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(LucideIcons.mapPin, size: 13, color: FeColors.ink2),
                        const SizedBox(width: 4),
                        Expanded(child: AppText.bodySmall(a.where, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ],
                  if (a.readingText != null || a.ackOverdue || a.assigneeName != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (a.readingText != null) _Meta(LucideIcons.activity, a.readingText!),
                        if (a.assigneeName != null) _Meta(LucideIcons.user, a.assigneeName!),
                        if (a.ackOverdue) _Meta(LucideIcons.clockAlert, 'alerts.ack_overdue'.getString(context), color: FeColors.danger),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text, {this.color = FeColors.ink2});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          AppText.caption(text, color: color),
        ],
      );
}

class _BulkBar extends StatelessWidget {
  const _BulkBar({required this.busy, required this.onAction});
  final bool busy;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => onAction('acknowledge'),
                  icon: const Icon(LucideIcons.eye, size: 16),
                  label: AppText('alerts.action_acknowledge'.getString(context)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy ? null : () => onAction('resolve'),
                  icon: const Icon(LucideIcons.check, size: 16),
                  label: AppText('alerts.action_resolve'.getString(context)),
                ),
              ),
            ],
          ),
        ),
      );
}

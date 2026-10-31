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
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'alert_widgets.dart';

/// Alert Center on the phone (FE-mobile.md Phase 2): counts, severity /
/// status / mine filters, worst-first list. Live: the socket's
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
            _FilterBar(filters: filters),
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
                      if (page.total > page.rows.length)
                        AppText.bodySmall(
                          context.formatString('alerts.showing'.getString(context), [page.rows.length, page.total]),
                          align: TextAlign.center,
                        ),
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
    Widget tile(String key, int? n, Color color) => Expanded(
          child: TechCard(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              children: [
                AppText.titleMedium(n == null ? '–' : '$n', color: color),
                const SizedBox(height: 2),
                FittedBox(fit: BoxFit.scaleDown, child: AppText.caption(key.getString(context), maxLines: 1)),
              ],
            ),
          ),
        );
    return Row(
      children: [
        tile('alerts.sum_open', s?.open, FeColors.ink),
        const SizedBox(width: 8),
        tile('alerts.sum_critical', s?.critical, FeColors.danger),
        const SizedBox(width: 8),
        tile('alerts.sum_unack', s?.unacknowledged, FeColors.warning),
        const SizedBox(width: 8),
        tile('alerts.sum_mine', s?.mine, FeColors.primary),
      ],
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filters});
  final AlertFilters filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void set(AlertFilters f) => ref.read(alertFiltersProvider.notifier).state = f;
    final showResolved = filters.status.contains('resolved');

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final sev in alertSeverities)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: FilterChip(
                label: AppText.caption('alerts.severity_$sev'.getString(context)),
                selected: filters.severity.contains(sev),
                onSelected: (on) => set(filters.copyWith(severity: on ? {...filters.severity, sev} : ({...filters.severity}..remove(sev)))),
              ),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilterChip(
              avatar: const Icon(LucideIcons.user, size: 14),
              label: AppText.caption('alerts.filter_mine'.getString(context)),
              selected: filters.mineOnly,
              onSelected: (on) => set(filters.copyWith(mineOnly: on)),
            ),
          ),
          FilterChip(
            label: AppText.caption('alerts.filter_resolved'.getString(context)),
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
        accentTop: severityHue(a.severity),
        borderColor: selected ? FeColors.primary : null,
        onTap: onTap,
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
              AppText.bodySmall(a.where, maxLines: 1, overflow: TextOverflow.ellipsis),
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

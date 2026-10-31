import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../domain/alert.dart';
import '../../state/alerts_controller.dart';
import '../../state/catalog_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/text_prompt.dart';
import '../module/module_screen.dart';
import 'alert_widgets.dart';

/// One alert: what, where, the reading, its history, and the light actions
/// (acknowledge, resolve, reopen, take, note). Opened from the list or a
/// push tap — a pushed screen, so it re-checks the catalog itself (the
/// router's redirect doesn't re-run for pushed routes; LEARNINGS 2026-10-30).
class AlertDetailScreen extends ConsumerStatefulWidget {
  const AlertDetailScreen({super.key, required this.alertKey});

  final String alertKey;

  @override
  ConsumerState<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends ConsumerState<AlertDetailScreen> {
  bool _busy = false;

  Future<void> _act(String action, {String? note}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final done = 'alerts.done_$action'.getString(context);
    try {
      final item = await ref.read(alertsRepositoryProvider).act(widget.alertKey, action, note: note);
      if (mounted) applyAlertPatch(ref, item);
      messenger.showSnackBar(SnackBar(content: AppText(done)));
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _note() async {
    final text = await promptText(
      context,
      title: 'alerts.action_note'.getString(context),
      hint: 'alerts.note_hint'.getString(context),
    );
    if (text != null && text.trim().isNotEmpty) await _act('note', note: text);
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(loadedCatalogProvider);
    if (boot != null && !boot.has('alerts')) return const UnavailableScreen();

    final detail = ref.watch(alertDetailProvider(widget.alertKey));
    final patches = ref.watch(alertPatchesProvider);
    return Scaffold(
      appBar: FeHeader(
        title: detail.valueOrNull?.alert.ref.isNotEmpty == true
            ? detail.value!.alert.ref
            : 'nav.alerts'.getString(context),
      ),
      body: detail.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        loading: () => const TechSpinner(),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: TechEmptyState(
              icon: LucideIcons.circleAlert,
              title: e is HttpFailure && e.status == 404
                  ? 'alerts.not_found'.getString(context)
                  : alertsErrorText(context),
              subtitle: e is ApiFailure ? e.message : null,
            ),
          ),
        ),
        data: (d) => _Body(
          detail: AlertDetail(alert: patchedAlert(patches, d.alert), events: d.events, canTake: d.canTake),
          busy: _busy,
          onAct: _act,
          onNote: _note,
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.detail, required this.busy, required this.onAct, required this.onNote});

  final AlertDetail detail;
  final bool busy;
  final Future<void> Function(String action, {String? note}) onAct;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    final a = detail.alert;
    final facts = <(IconData, String, String)>[
      if (a.buildingName != null) (LucideIcons.building2, 'alerts.fact_building', a.buildingName!),
      if (a.location != null && a.location!.isNotEmpty) (LucideIcons.mapPin, 'alerts.fact_location', a.location!),
      // Access alarms repeat the zone as the asset name: show it once.
      if (a.assetName != null && a.assetName != a.location && a.assetName != a.buildingName)
        (LucideIcons.package, 'alerts.fact_asset', a.assetName!),
      if (a.readingText != null) (LucideIcons.activity, 'alerts.fact_reading', a.readingText!),
      if (a.sourceLabel.isNotEmpty) (LucideIcons.radioTower, 'alerts.fact_source', a.sourceLabel),
      if (a.teamName != null) (LucideIcons.users, 'alerts.fact_team', a.teamName!),
      (LucideIcons.user, 'alerts.fact_assignee', a.assigneeName ?? 'alerts.unassigned'.getString(context)),
      if (a.workOrderRef != null) (LucideIcons.wrench, 'alerts.fact_work_order', a.workOrderRef!),
      if (a.count > 1) (LucideIcons.repeat, 'alerts.fact_repeats', '${a.count}'),
    ];

    // RowGroup brings its own 16px side inset; the top card and buttons get
    // the same inset here so every card lines up.
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              TechCard(
                accentTop: severityHue(a.severity),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SeverityChip(a.severity),
                        const SizedBox(width: 6),
                        AlertStatusChip(a.status),
                        const Spacer(),
                        AppText.caption(timeAgo(context, a.raisedAt)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AppText.title(a.title),
                    if (a.detail.isNotEmpty) ...[const SizedBox(height: 6), AppText.bodyMedium(a.detail)],
                    if (a.ackOverdue) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(LucideIcons.clockAlert, size: 16, color: FeColors.danger),
                          const SizedBox(width: 6),
                          AppText.bodySmall(
                            'alerts.ack_overdue'.getString(context),
                            color: FeColors.danger,
                            weight: FontWeight.w600,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Actions(alert: a, canTake: detail.canTake, busy: busy, onAct: onAct, onNote: onNote),
            ],
          ),
        ),
        const SizedBox(height: 16),
        RowGroup(
          label: 'alerts.details'.getString(context),
          dividerIndent: 16,
          rows: [
            for (final (icon, label, value) in facts)
              ListTile(
                dense: true,
                leading: Icon(icon, size: 18, color: FeColors.ink2),
                title: AppText.caption(label.getString(context)),
                subtitle: AppText.body(value),
              ),
          ],
        ),
        if (detail.events.isNotEmpty)
          RowGroup(
            label: 'alerts.history'.getString(context),
            dividerIndent: 16,
            rows: [
              // Newest first on a phone.
              for (final e in detail.events.reversed)
                ListTile(
                  dense: true,
                  title: AppText.body(eventLabel(context, e)),
                  subtitle: AppText.bodySmall(
                    [
                      e.userName,
                      timeAgo(context, e.at),
                      e.note,
                    ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.alert,
    required this.canTake,
    required this.busy,
    required this.onAct,
    required this.onNote,
  });

  final AlertItem alert;
  final bool canTake;
  final bool busy;
  final Future<void> Function(String action, {String? note}) onAct;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    Widget primary(String action, IconData icon) => Expanded(
      child: ElevatedButton.icon(
        onPressed: busy ? null : () => onAct(action),
        icon: Icon(icon, size: 16),
        label: AppText('alerts.action_$action'.getString(context)),
      ),
    );
    Widget secondary(String action, IconData icon, VoidCallback onTap) => Expanded(
      child: OutlinedButton.icon(
        onPressed: busy ? null : onTap,
        icon: Icon(icon, size: 16),
        label: AppText('alerts.action_$action'.getString(context)),
      ),
    );

    final status = alert.status;
    return Column(
      children: [
        Row(
          children: [
            if (status == 'active') ...[
              secondary('acknowledge', LucideIcons.eye, () => onAct('acknowledge')),
              const SizedBox(width: 12),
            ],
            if (status != 'resolved') primary('resolve', LucideIcons.check),
            if (status == 'resolved') primary('reopen', LucideIcons.rotateCcw),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (canTake) ...[secondary('take', LucideIcons.userCheck, () => onAct('take')), const SizedBox(width: 12)],
            secondary('note', LucideIcons.messageSquarePlus, onNote),
          ],
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
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
import '../../widgets/open_on_web.dart';
import '../../widgets/text_prompt.dart';
import '../module/module_screen.dart';
import 'alert_widgets.dart';

/// One alert: what, where, the reading, its history, and the actions
/// (acknowledge, resolve, reopen, take, note, assign, snooze, work order —
/// the web AlertDrawer's set). Opened from the list or a
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

  Future<void> _act(String action, {String? note, Map<String, Object?> extra = const {}, String? doneText}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final done = doneText ?? 'alerts.done_$action'.getString(context);
    try {
      final item = await ref.read(alertsRepositoryProvider).act(widget.alertKey, action, note: note, extra: extra);
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

  /// Hand it to someone who can see it (covering teams first), or unassign.
  Future<void> _assign(AlertItem a) async {
    final pick = await showModalBottomSheet<Assignee?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AssigneeSheet(alertKey: widget.alertKey, current: a.assigneeId),
    );
    if (pick == null || !mounted) return;
    if (pick.id.isEmpty) return _act('unassign');
    final done = context.formatString('alerts.done_assign'.getString(context), [pick.name]);
    await _act('assign', extra: {'userId': pick.id}, doneText: done);
  }

  Future<void> _snooze(AlertDetail d) async {
    if (d.alert.isSnoozed) return _act('unsnooze');
    final pick = await showDialog<(int, String)>(context: context, builder: (_) => _SnoozeDialog(choices: d.snoozeChoices));
    if (pick == null || !mounted) return;
    final done = context.formatString('alerts.done_snooze'.getString(context), [snoozeWord(context, pick.$1)]);
    await _act('snooze', extra: {'minutes': pick.$1, 'reason': pick.$2}, doneText: done);
  }

  /// Create (the web's form, filled in, inside the app), link by number,
  /// open, or unlink.
  Future<void> _workOrder(AlertItem a) async {
    final canOpen = a.workOrderId != null && (ref.read(loadedCatalogProvider)?.has('work_orders') ?? false);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (a.workOrderRef == null && a.workOrderId == null) ...[
              ListTile(
                leading: const Icon(LucideIcons.clipboardPlus),
                title: AppText('alerts.wo_create'.getString(ctx)),
                subtitle: AppText.caption('alerts.wo_create_hint'.getString(ctx)),
                onTap: () => Navigator.pop(ctx, 'create'),
              ),
              ListTile(
                leading: const Icon(LucideIcons.link),
                title: AppText('alerts.wo_link'.getString(ctx)),
                onTap: () => Navigator.pop(ctx, 'link'),
              ),
            ] else ...[
              if (canOpen)
                ListTile(
                  leading: const Icon(LucideIcons.wrench),
                  title: AppText(context.formatString('alerts.wo_open'.getString(ctx), [a.workOrderRef ?? ''])),
                  onTap: () => Navigator.pop(ctx, 'open'),
                ),
              ListTile(
                leading: const Icon(LucideIcons.unlink),
                title: AppText('alerts.wo_unlink'.getString(ctx)),
                onTap: () => Navigator.pop(ctx, 'unlink'),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'create':
        await openOnWeb(context, workOrderCreatePath(a), title: 'alerts.wo_create'.getString(context));
        // Saving the form links the new work order back to the alert.
        if (mounted) ref.read(alertsTickProvider.notifier).state++;
      case 'link':
        final text = await promptText(
          context,
          title: 'alerts.wo_link'.getString(context),
          hint: 'alerts.wo_link_hint'.getString(context),
        );
        if (text != null && text.trim().isNotEmpty) {
          await _act('work_order', extra: {'workOrderId': text.trim()});
        }
      case 'open':
        await context.push<bool>(recordPath('work_orders', a.workOrderId!));
      case 'unlink':
        await _act('work_order', extra: {'workOrderId': null}, doneText: 'alerts.done_wo_unlink'.getString(context));
    }
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
        data: (d) {
          final detail = d.withAlert(patchedAlert(patches, d.alert));
          return _Body(
            detail: detail,
            busy: _busy,
            onAct: _act,
            onNote: _note,
            onAssign: () => _assign(detail.alert),
            onSnooze: () => _snooze(detail),
            onWorkOrder: () => _workOrder(detail.alert),
          );
        },
      ),
    );
  }
}

typedef _ActFn = Future<void> Function(String action, {String? note, Map<String, Object?> extra, String? doneText});

class _Body extends StatelessWidget {
  const _Body({
    required this.detail,
    required this.busy,
    required this.onAct,
    required this.onNote,
    required this.onAssign,
    required this.onSnooze,
    required this.onWorkOrder,
  });

  final AlertDetail detail;
  final bool busy;
  final _ActFn onAct;
  final VoidCallback onNote;
  final VoidCallback onAssign;
  final VoidCallback onSnooze;
  final VoidCallback onWorkOrder;

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
      if (a.isSnoozed)
        (
          LucideIcons.bellOff,
          'alerts.fact_snoozed',
          [snoozeUntilText(context, a.snoozedUntil!), a.snoozeReason].whereType<String>().join(' · '),
        ),
      if (a.workOrderRef != null)
        (LucideIcons.wrench, 'alerts.fact_work_order', [a.workOrderRef!, a.workOrderStatus].whereType<String>().join(' · ')),
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
              _Actions(
                detail: detail,
                busy: busy,
                onAct: onAct,
                onNote: onNote,
                onAssign: onAssign,
                onSnooze: onSnooze,
                onWorkOrder: onWorkOrder,
              ),
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
    required this.detail,
    required this.busy,
    required this.onAct,
    required this.onNote,
    required this.onAssign,
    required this.onSnooze,
    required this.onWorkOrder,
  });

  final AlertDetail detail;
  final bool busy;
  final _ActFn onAct;
  final VoidCallback onNote;
  final VoidCallback onAssign;
  final VoidCallback onSnooze;
  final VoidCallback onWorkOrder;

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
        label: AppText('alerts.action_$action'.getString(context), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    Widget gap() => const SizedBox(width: 12);

    final alert = detail.alert;
    final status = alert.status;
    // Assign also offers "unassign", so it shows when someone is assigned even
    // if this user may not hand it on.
    final assign = alert.isOpen && (detail.canAssign || alert.assigneeId != null);
    final snooze = detail.canSnooze || alert.isSnoozed;
    final more = [
      if (detail.canTake) secondary('take', LucideIcons.userCheck, () => onAct('take')),
      secondary('note', LucideIcons.messageSquarePlus, onNote),
      if (assign) secondary('assign', LucideIcons.userPlus, onAssign),
      if (snooze)
        secondary(alert.isSnoozed ? 'unsnooze' : 'snooze', alert.isSnoozed ? LucideIcons.alarmClock : LucideIcons.bellOff, onSnooze),
      secondary('work_order', LucideIcons.clipboardList, onWorkOrder),
    ];
    return Column(
      children: [
        Row(
          children: [
            if (status == 'active') ...[secondary('acknowledge', LucideIcons.eye, () => onAct('acknowledge')), gap()],
            if (status != 'resolved') primary('resolve', LucideIcons.check),
            if (status == 'resolved') primary('reopen', LucideIcons.rotateCcw),
          ],
        ),
        // Two per row: three labels don't fit a phone's width ("Assi…").
        for (var i = 0; i < more.length; i += 2) ...[
          const SizedBox(height: 12),
          Row(children: [more[i], gap(), if (i + 1 < more.length) more[i + 1] else const Spacer()]),
        ],
      ],
    );
  }
}

/// "15 min" / "2 h" / "1 day", as the web's SNOOZE_WORD.
String snoozeWord(BuildContext context, int minutes) => minutes >= 1440
    ? context.formatString('alerts.snooze_days'.getString(context), [minutes ~/ 1440])
    : minutes >= 60
        ? context.formatString('alerts.snooze_hours'.getString(context), [minutes ~/ 60])
        : context.formatString('alerts.snooze_minutes'.getString(context), [minutes]);

/// "Until 14:30", or with the date when it isn't today.
String snoozeUntilText(BuildContext context, DateTime until) {
  final l = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final time = l.formatTimeOfDay(TimeOfDay.fromDateTime(until), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
  final sameDay = until.year == now.year && until.month == now.month && until.day == now.day;
  return context.formatString('alerts.snoozed_until'.getString(context), [sameDay ? time : '${l.formatShortDate(until)} $time']);
}

/// Pops (minutes, reason). The server wants a reason of 3+ characters.
class _SnoozeDialog extends StatefulWidget {
  const _SnoozeDialog({required this.choices});
  final List<int> choices;

  @override
  State<_SnoozeDialog> createState() => _SnoozeDialogState();
}

class _SnoozeDialogState extends State<_SnoozeDialog> {
  final _why = TextEditingController();
  late int _minutes = widget.choices.contains(60) ? 60 : widget.choices.first;

  @override
  void dispose() {
    _why.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: AppText.title('alerts.action_snooze'.getString(context)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _minutes,
              decoration: InputDecoration(labelText: 'alerts.snooze_for'.getString(context)),
              items: [for (final m in widget.choices) DropdownMenuItem(value: m, child: AppText(snoozeWord(context, m)))],
              onChanged: (v) => setState(() => _minutes = v ?? _minutes),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _why,
              autofocus: true,
              maxLength: 500,
              decoration: InputDecoration(labelText: 'alerts.snooze_why'.getString(context), hintText: 'alerts.snooze_why_hint'.getString(context)),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: AppText('common.cancel'.getString(context))),
          TextButton(
            onPressed: _why.text.trim().length < 3 ? null : () => Navigator.pop(context, (_minutes, _why.text.trim())),
            child: AppText('alerts.action_snooze'.getString(context)),
          ),
        ],
      );
}

/// People who can see this alert; pops the pick, or an empty id for "unassign".
class _AssigneeSheet extends ConsumerWidget {
  const _AssigneeSheet({required this.alertKey, required this.current});
  final String alertKey;
  final String? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(alertAssigneesProvider(alertKey));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: people.when(
          loading: () => const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(20),
            child: TechEmptyState(
              icon: LucideIcons.circleAlert,
              title: 'alerts.assignees_error'.getString(context),
              subtitle: e is ApiFailure ? e.message : null,
            ),
          ),
          data: (list) => ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: AppText.titleSmall('alerts.assign_to'.getString(context)),
              ),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: AppText.bodySmall('alerts.assignees_empty'.getString(context)),
                ),
              for (final p in list)
                ListTile(
                  leading: const Icon(LucideIcons.user),
                  title: AppText(p.name),
                  subtitle: AppText.caption([p.role, ...p.teams].where((t) => t.isNotEmpty).join(' · ')),
                  trailing: p.id == current ? const Icon(LucideIcons.check, color: FeColors.primary) : null,
                  enabled: p.id != current,
                  onTap: () => Navigator.pop(context, p),
                ),
              if (current != null)
                ListTile(
                  leading: const Icon(LucideIcons.userMinus, color: FeColors.danger),
                  title: AppText('alerts.action_unassign'.getString(context), color: FeColors.danger),
                  onTap: () => Navigator.pop(context, (id: '', name: '', role: '', teams: const <String>[])),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

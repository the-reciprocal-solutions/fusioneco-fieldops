import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/offline/sync_client.dart';
import '../../core/utils/checklist_status.dart';
import '../../core/utils/dates.dart';
import '../../domain/checklist.dart';
import '../../domain/maintenance_record.dart';
import '../../state/checklist_controller.dart';
import '../../state/order_detail_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/tech_popup.dart';
import 'checklist_item_sheet.dart';
import 'close_sheet.dart';
import '../../widgets/dir_icon.dart';

/// Keeps the manual-hours field within what the DB column can hold —
/// `DECIMAL(10,2)` on work_orders/reactive_maintenance/annual_maintenance,
/// i.e. up to 8 integer digits and 2 decimal digits (max 99999999.99).
final _manualHoursFormatter = TextInputFormatter.withFunction((
  oldValue,
  newValue,
) {
  if (newValue.text.isEmpty) return newValue;
  final match = RegExp(r'^\d{0,8}(\.\d{0,2})?$').hasMatch(newValue.text);
  return match ? newValue : oldValue;
});

/// The row shows the text before the first colon, capped at 40 characters —
/// item names carry a long "task: detail" description.
String shortChecklistTitle(String title) {
  final head = title.contains(':') ? title.split(':').first.trim() : title;
  return head.length > 40 ? '${head.substring(0, 40)}…' : head;
}

class ChecklistTab extends ConsumerWidget {
  const ChecklistTab({super.key, required this.record, required this.orderKey});

  final MaintenanceRecord record;
  final OrderKey orderKey;

  Future<void> _openItem(BuildContext context, int index) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: FeColors.panel,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(context.radii.sheet),
          ),
        ),
        builder: (context) => ChecklistItemSheet(
          orderKey: orderKey,
          index: index,
          requireFaceCapture: record.requireFaceCapture,
          requireLocation: record.requireLocation,
        ),
      );

  Future<void> _addOther(BuildContext context, WidgetRef ref) async {
    final description = await showDialog<String>(
      context: context,
      builder: (context) => const _AddOtherDialog(),
    );
    if (description == null || description.isEmpty) return;

    final outcome = await ref
        .read(checklistControllerProvider(orderKey).notifier)
        .addOther(description);
    if (outcome != null && context.mounted) {
      showTechPopup(
        context,
        message: outcome.text,
        queued: outcome.queued,
        isError: !outcome.queued,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(checklistControllerProvider(orderKey));
    final items = state.items;
    final summary = deriveChecklistSummary(items);
    // The synthetic signature item lives on `items` (the close guard and
    // `_CloseSection` below need the full list), but it is not a task the
    // technician works — it never appears as a Tasks row. Its own read-only
    // view now lives in the Details tab instead (order_detail_screen.dart).
    final visibleCount = items.where((i) => !i.isSignature).length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ProgressHeader(summary: summary),
        const SizedBox(height: 16),
        if (visibleCount == 0)
          TechEmptyState(
            icon: LucideIcons.listChecks,
            title: 'order_detail.checklist_empty_title'.getString(context),
            subtitle: 'order_detail.checklist_empty_subtitle'.getString(context),
          )
        else
          for (var index = 0; index < items.length; index++)
            if (!items[index].isSignature)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ChecklistRow(
                  item: items[index],
                  busy: state.busyIndex == index,
                  onOpen: () => _openItem(context, index),
                  onToggle: () async {
                    final outcome = await ref
                        .read(checklistControllerProvider(orderKey).notifier)
                        .toggle(index);
                    if (outcome != null && context.mounted) {
                      showTechPopup(
                        context,
                        message: outcome.text,
                        queued: outcome.queued,
                        isError: !outcome.queued,
                      );
                    }
                  },
                ),
              ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: state.addingOther ? null : () => _addOther(context, ref),
          icon: const Icon(LucideIcons.plus, size: 16),
          label: AppText('order_detail.add_other_task'.getString(context)),
        ),
        const SizedBox(height: 16),
        CloseSection(items: items, record: record, orderKey: orderKey),
      ],
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.summary});

  final ChecklistSummary summary;

  @override
  Widget build(BuildContext context) {
    final complete =
        summary.totalCount > 0 && summary.completedCount == summary.totalCount;

    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(
                icon: LucideIcons.circleCheck,
                style: context.accents.orange,
                size: 40,
                iconSize: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.titleSmall(
                      'order_detail.checklist'.getString(context),
                      weight: FontWeight.w600,
                    ),
                    AppText.caption(
                      complete
                          ? 'order_detail.all_tasks_completed'.getString(context)
                          : 'order_detail.track_progress'.getString(context),
                      color: FeColors.ink2,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: complete
                      ? context.accents.emerald.background
                      : FeColors.page,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: AppText.caption(
                  '${summary.completedCount}/${summary.totalCount}',
                  weight: FontWeight.w700,
                  color: complete ? FeColors.success : FeColors.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: summary.progress,
              minHeight: 8,
              backgroundColor: FeColors.page,
              valueColor: const AlwaysStoppedAnimation(FeColors.primary),
            ),
          ),
          const SizedBox(height: 8),
          AppText.bodySmall(
            summary.state.displayLabel(context),
            color: FeColors.ink2,
          ),
        ],
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.item,
    required this.busy,
    required this.onOpen,
    required this.onToggle,
  });

  final ChecklistItem item;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final noteCount =
        item.comments.length + (item.legacyComment == null ? 0 : 1);

    return TechCard(
      onTap: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 24,
            width: 24,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(2),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                // The signature item is a record of a fact, not a task — it
                // is never unticked after the fact (that would silently
                // break the server's signature-required close gate), so it
                // gets a plain locked mark instead of an editable checkbox.
                : item.isSignature
                ? const Icon(
                    LucideIcons.penLine,
                    size: 18,
                    color: FeColors.success,
                  )
                : Checkbox(
                    value: item.isCompleted,
                    onChanged: (_) => onToggle(),
                    visualDensity: VisualDensity.compact,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: AppText.bodyMedium(
                        shortChecklistTitle(item.title),
                        weight: FontWeight.w600,
                        color: item.isCompleted ? FeColors.ink2 : FeColors.ink,
                      ),
                    ),
                    if (item.isOther)
                      _RowChip(
                        label: 'order_detail.chip_other'.getString(context),
                        background: FeColors.page,
                        foreground: FeColors.ink2,
                      ),
                    if (item.isRunning)
                      _RowChip(
                        label: 'order_detail.chip_running'.getString(context),
                        background: FeColors.warningSoft,
                        foreground: FeColors.warning,
                        icon: LucideIcons.clock,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    if ((item.timeSpent ?? 0) > 0)
                      _Meta(
                        icon: LucideIcons.clock,
                        label: formatMinutesAsHours(item.timeSpent!),
                      ),
                    if (item.attachments.isNotEmpty)
                      _Meta(
                        icon: LucideIcons.paperclip,
                        label: '${item.attachments.length}',
                      ),
                    if (noteCount > 0)
                      _Meta(
                        icon: LucideIcons.messageSquare,
                        label: '$noteCount',
                      ),
                  ],
                ),
              ],
            ),
          ),
          const DirIcon(LucideIcons.chevronRight, size: 16, color: FeColors.ink2),
        ],
      ),
    );
  }
}

class _RowChip extends StatelessWidget {
  const _RowChip({
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsetsDirectional.only(start: 8),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 10, color: foreground),
          const SizedBox(width: 4),
        ],
        AppText(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 10,
            color: foreground,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: FeColors.ink2),
      const SizedBox(width: 4),
      AppText.caption(label, color: FeColors.ink2),
    ],
  );
}

/// Closing a record is the next phase. Until then this states what still
/// stands between the technician and being able to close it.
/// The end of the checklist: whether this job may be closed yet, and — once it
/// may — the manual-hours override and the button that opens the close sheet.
///
/// Public (not tab-private) because the Details tab shows it too — technicians
/// were looking for "close the work order" there first and not finding it
/// (see order_detail_screen.dart). Both mounts watch the same
/// `checklistControllerProvider(orderKey)`, so toggling a task in one tab
/// updates the gate state in the other immediately.
class CloseSection extends ConsumerStatefulWidget {
  const CloseSection({
    super.key,
    required this.items,
    required this.record,
    required this.orderKey,
  });

  final List<ChecklistItem> items;
  final MaintenanceRecord record;
  final OrderKey orderKey;

  @override
  ConsumerState<CloseSection> createState() => _CloseSectionState();
}

class _CloseSectionState extends ConsumerState<CloseSection> {
  final _hoursController = TextEditingController();

  @override
  void dispose() {
    _hoursController.dispose();
    super.dispose();
  }

  Future<void> _openCloseSheet() async {
    final hours = double.tryParse(_hoursController.text.trim());
    final message = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: FeColors.panel,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.radii.sheet),
        ),
      ),
      builder: (context) => CloseSheet(
        orderKey: widget.orderKey,
        record: widget.record,
        // Downtime starts when work started, which is the first checklist
        // timer — the record's own start date is only a fallback for the kinds
        // that persist one.
        predictedStart:
            getFirstChecklistStartTime(widget.items) ??
            widget.record.startedDate,
        manualHours: hours,
      ),
    );

    if (message != null && mounted) {
      final queued = message == kOfflineQueuedMessage;
      showTechPopup(context, message: message, queued: queued);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mandatory = widget.record.isChecklistMandatory;

    // Mirrors the server's close guard: at least one item done — an "Other"
    // one counts — and, when the checklist is mandatory, every listed item.
    // No open timer session either — closing a session and marking an item
    // done are separate actions. This is UX only; the server enforces the
    // real rule and its 422 wins.
    final hasOpenSession = hasAnyRunningChecklistItem(widget.items);
    final checklistWorkReady =
        hasAnyChecklistCompleted(widget.items) &&
        (!mandatory || isChecklistFullyComplete(widget.items));
    final canClose = checklistWorkReady && !hasOpenSession;

    if (widget.record.completedDate != null) {
      return TechCard(
        borderColor: FeColors.successSoft,
        child: Row(
          children: [
            const Icon(LucideIcons.circleCheck, size: 18, color: FeColors.success),
            const SizedBox(width: 12),
            Expanded(
              child: AppText('order_detail.job_closed'.getString(context)),
            ),
          ],
        ),
      );
    }

    if (!canClose) {
      return TechCard(
        borderColor: FeColors.line,
        child: Row(
          children: [
            const Icon(LucideIcons.info, size: 18, color: FeColors.ink2),
            const SizedBox(width: 12),
            Expanded(
              child: AppText.bodySmall(
                checklistWorkReady && hasOpenSession
                    ? 'order_detail.close_gate_running'.getString(context)
                    : mandatory
                        ? 'order_detail.close_gate_mandatory'.getString(context)
                        : 'order_detail.close_gate_optional'.getString(context),
                color: FeColors.ink2,
              ),
            ),
          ],
        ),
      );
    }

    return TechCard(
      borderColor: FeColors.successSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                LucideIcons.circleCheck,
                size: 18,
                color: FeColors.success,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppText.bodySmall(
                  'order_detail.job_ready_to_close'.getString(context),
                  color: FeColors.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _hoursController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_manualHoursFormatter],
            decoration: InputDecoration(
              labelText: 'order_detail.manual_hours_label'.getString(context),
              hintText: context.formatString(
                'order_detail.manual_hours_hint'.getString(context),
                [calculateChecklistsActualHours(widget.items)],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _openCloseSheet,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: FeColors.success,
            ),
            child: AppText('order_detail.completed_works_button'.getString(context)),
          ),
        ],
      ),
    );
  }
}

class _AddOtherDialog extends StatefulWidget {
  const _AddOtherDialog();

  @override
  State<_AddOtherDialog> createState() => _AddOtherDialogState();
}

class _AddOtherDialogState extends State<_AddOtherDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: FeColors.panel,
    title: AppText('order_detail.add_other_dialog_title'.getString(context)),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLines: 3,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'order_detail.add_other_hint'.getString(context),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: AppText('common.cancel'.getString(context)),
      ),
      ElevatedButton(
        onPressed: _controller.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop(_controller.text.trim()),
        child: AppText('common.add'.getString(context)),
      ),
    ],
  );
}

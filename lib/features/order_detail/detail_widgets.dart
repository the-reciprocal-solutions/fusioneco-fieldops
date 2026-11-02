import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/offline/sync_client.dart';
import '../../core/utils/checklist_status.dart';
import '../../core/utils/dates.dart';
import '../../domain/maintenance_record.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/tech_popup.dart';

/// Work-order status block. Read-only: Start and Complete live on the
/// checklist tab, which has the completion context the close flow needs.
class TimeTrackerCard extends StatefulWidget {
  const TimeTrackerCard({
    super.key,
    required this.startedDate,
    required this.completedDate,
    required this.actualHours,
    required this.queuedComplete,
  });

  final DateTime? startedDate;
  final DateTime? completedDate;
  final double? actualHours;
  final bool queuedComplete;

  @override
  State<TimeTrackerCard> createState() => _TimeTrackerCardState();
}

class _TimeTrackerCardState extends State<TimeTrackerCard> {
  Duration _elapsed = Duration.zero;

  bool get _isCompleted =>
      widget.completedDate != null || widget.queuedComplete;
  bool get _isRunning => widget.startedDate != null && !_isCompleted;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    if (!mounted || !_isRunning) return;
    setState(() => _elapsed = DateTime.now().difference(widget.startedDate!));
    Future.delayed(const Duration(seconds: 1), _tick);
  }

  @override
  void didUpdateWidget(TimeTrackerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedDate != widget.startedDate) _tick();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFE0F2FE),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  LucideIcons.clock,
                  size: 16,
                  color: Color(0xFF0284C7),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'order_detail.time_tracking'.getString(context),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: FeColors.ink,
                  ),
                ),
              ),
              _StatusBadge(
                completed: widget.completedDate != null,
                queuedComplete: widget.queuedComplete,
                started: widget.startedDate != null,
              ),
            ],
          ),
          if (_isRunning) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F9FF),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFBAE6FD)),
              ),
              child: Column(
                children: [
                  Text(
                    formatElapsed(_elapsed),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 26,
                      color: Color(0xFF0284C7),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'order_detail.time_elapsed'.getString(context),
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
          ],
          if (widget.queuedComplete && widget.completedDate == null) ...[
            const SizedBox(height: 14),
            _CompletedBanner(
              title: 'order_detail.completed_pending_sync'.getString(context),
              subtitle:
                  'order_detail.completed_pending_sync_subtitle'.getString(context),
            ),
          ],
          if (widget.completedDate != null && widget.actualHours != null) ...[
            const SizedBox(height: 14),
            _CompletedBanner(
              title: 'order_detail.total_hours'.getString(context),
              // Hours are the checklist tasks' tracked time; 0 means no task
              // timer ran (ticked without timing), not a zero-length job.
              value: widget.actualHours! > 0
                  ? context.formatString(
                      'order_detail.hours_value'.getString(context),
                      [widget.actualHours],
                    )
                  : 'order_detail.hours_not_tracked'.getString(context),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _TrackingFact(
                  label: 'order_detail.started_label'.getString(context),
                  date: widget.startedDate,
                  fallback: 'order_detail.not_started'.getString(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TrackingFact(
                  label: 'order_detail.completed_label'.getString(context),
                  date: widget.completedDate,
                  fallback: widget.queuedComplete
                      ? 'order_detail.pending_sync'.getString(context)
                      : 'order_detail.not_completed'.getString(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrackingFact extends StatelessWidget {
  const _TrackingFact({
    required this.label,
    required this.date,
    required this.fallback,
  });

  final String label;
  final DateTime? date;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(
                LucideIcons.calendar,
                size: 15,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                date == null
                    ? fallback
                    : '${formatDate(date!)}\n${formatTimeOfDay(date!)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: FeColors.ink,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.completed,
    required this.queuedComplete,
    required this.started,
  });

  final bool completed;
  final bool queuedComplete;
  final bool started;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = completed
        ? (
            'order_detail.status_completed'.getString(context),
            const Color(0xFFECFDF5),
            const Color(0xFF10B981),
          )
        : queuedComplete
        ? (
            'order_detail.completed_pending_sync'.getString(context),
            const Color(0xFFECFDF5),
            const Color(0xFF10B981),
          )
        : started
        ? (
            'order_detail.status_in_progress'.getString(context),
            const Color(0xFFEFF6FF),
            const Color(0xFF0284C7),
          )
        : (
            'order_detail.status_not_started'.getString(context),
            const Color(0xFFF1F5F9),
            const Color(0xFF64748B),
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CompletedBanner extends StatelessWidget {
  const _CompletedBanner({required this.title, this.subtitle, this.value});

  final String title;
  final String? subtitle;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (value != null) ...[
                const SizedBox(height: 2),
                Text(
                  value!,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF10B981),
                  ),
                ),
              ],
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ],
          ),
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFD1FAE5),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.check,
              size: 20,
              color: Color(0xFF10B981),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status block for the three maintenance kinds, which have no timer card.
class ChecklistSummaryCard extends StatelessWidget {
  const ChecklistSummaryCard({super.key, required this.summary});

  final ChecklistSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FeColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(context.radii.card),
        border: Border.all(color: FeColors.primary.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  'order_detail.checklist_summary_label'.getString(context),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: FeColors.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                AppText.headlineSmall(
                  summary.state.displayLabel(context),
                  color: FeColors.primary,
                  weight: FontWeight.w700,
                ),
                const SizedBox(height: 4),
                AppText.bodySmall(
                  context.formatString(
                    'order_detail.actionable_items_complete'.getString(context),
                    [summary.completedCount, summary.totalCount],
                  ),
                  color: FeColors.primary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: FeColors.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            child: AppText.caption(
              summary.state.displayLabel(context),
              color: Colors.white,
              weight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Accept/decline card. Renders nothing unless the invite is still pending.
/// Answers an invite. Returns a message worth showing the technician, or null
/// when the reply went through with nothing to say.
typedef InviteResponder = Future<String?> Function({
  required bool accept,
  String? reason,
});

class AssignmentInvitePanel extends ConsumerStatefulWidget {
  const AssignmentInvitePanel({
    super.key,
    required this.record,
    required this.respond,
  });

  final MaintenanceRecord record;

  /// Passed in rather than read from a provider: the detail screen answers
  /// through its own record controller, while the invite inbox answers through
  /// the list it has to refresh afterwards.
  final InviteResponder respond;

  @override
  ConsumerState<AssignmentInvitePanel> createState() =>
      _AssignmentInvitePanelState();
}

class _AssignmentInvitePanelState extends ConsumerState<AssignmentInvitePanel> {
  bool _responding = false;

  Future<void> _respond({required bool accept, String? reason}) async {
    setState(() => _responding = true);
    final message = await widget.respond(accept: accept, reason: reason);
    if (!mounted) return;
    setState(() => _responding = false);

    // `respond` returns null on a plain success, kOfflineQueuedMessage when
    // the reply is queued offline, or its own failure text — the only three
    // shapes it can hand back.
    final queued = message == kOfflineQueuedMessage;
    showTechPopup(
      context,
      message:
          message ??
          (accept
              ? 'order_detail.assignment_accept_message'.getString(context)
              : 'order_detail.assignment_decline_message'.getString(context)),
      queued: queued,
      isError: message != null && !queued,
    );
  }

  Future<void> _openDeclineDialog() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _DeclineDialog(),
    );
    if (reason != null && reason.isNotEmpty) {
      await _respond(accept: false, reason: reason);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.record.isAssignmentPending) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: TechCard(
        padding: const EdgeInsets.all(18),
        tint: FeColors.warningSoft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 36,
                  width: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: FeColors.warning.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    LucideIcons.triangleAlert,
                    size: 18,
                    color: FeColors.warning,
                  ),
                ),
                const SizedBox(width: 10),
                AppText.titleSmall(
                  'order_detail.assignment_offer_title'.getString(context),
                  color: FeColors.warning,
                  weight: FontWeight.w700,
                ),
              ],
            ),
            const SizedBox(height: 8),
            AppText.bodySmall(
              'order_detail.assignment_offer_body'.getString(context),
              color: FeColors.ink2,
            ),
            if (widget.record.assignmentChain.isNotEmpty) ...[
              const SizedBox(height: 12),
              _AssignmentChain(chain: widget.record.assignmentChain),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _responding ? null : () => _respond(accept: true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FeColors.success,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(LucideIcons.check, size: 16),
                  label: AppText('order_detail.accept'.getString(context)),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _responding ? null : _openDeclineDialog,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: FeColors.danger,
                    side: BorderSide(
                      color: FeColors.danger.withValues(alpha: 0.3),
                    ),
                  ),
                  icon: const Icon(LucideIcons.x, size: 16),
                  label: AppText('order_detail.decline'.getString(context)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignmentChain extends StatelessWidget {
  const _AssignmentChain({required this.chain});

  final List<AssignmentChainEntry> chain;

  @override
  Widget build(BuildContext context) {
    final ordered = [...chain]
      ..sort((a, b) => a.sequenceOrder.compareTo(b.sequenceOrder));

    return Column(
      children: [
        for (final entry in ordered)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(
                  switch (entry.status) {
                    'accepted' => LucideIcons.circleCheck,
                    'declined' => LucideIcons.circleX,
                    _ => LucideIcons.circleDashed,
                  },
                  size: 14,
                  color: switch (entry.status) {
                    'accepted' => FeColors.success,
                    'declined' => FeColors.danger,
                    _ => FeColors.warning,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.bodySmall(
                    entry.technicianName,
                    color: FeColors.warning,
                  ),
                ),
                AppText.caption(entry.status, color: FeColors.warning),
              ],
            ),
          ),
      ],
    );
  }
}

class _DeclineDialog extends StatefulWidget {
  const _DeclineDialog();

  @override
  State<_DeclineDialog> createState() => _DeclineDialogState();
}

class _DeclineDialogState extends State<_DeclineDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: FeColors.panel,
    title: AppText('order_detail.decline_dialog_title'.getString(context)),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText.bodySmall(
          'order_detail.decline_dialog_body'.getString(context),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'order_detail.decline_reason_hint'.getString(context),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: AppText('common.cancel'.getString(context)),
      ),
      ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: FeColors.danger,
          foregroundColor: Colors.white,
        ),
        onPressed: _controller.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop(_controller.text.trim()),
        child: AppText('order_detail.confirm_decline'.getString(context)),
      ),
    ],
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText.caption(label, color: FeColors.ink2),
        const SizedBox(height: 2),
        AppText.bodyMedium(value, color: FeColors.ink, weight: FontWeight.w500),
      ],
    );
  }
}

/// Public alias so the detail screen can reuse the fact cell.
class DetailFact extends StatelessWidget {
  const DetailFact({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => _Fact(label: label, value: value);
}

class DetailMetaRow extends StatelessWidget {
  const DetailMetaRow({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Icon(icon, size: 16, color: FeColors.ink2),
        const SizedBox(width: 8),
        Expanded(child: AppText.bodySmall(text, color: FeColors.ink2)),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/conversation/cadence_text.dart';
import '../../../domain/user_schedule.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import 'conv_visuals.dart';

/// A schedule, as the thread shows it under the Flow Agent's reply and as
/// My schedules lists it: "Every Monday 08:00 · Check PM compliance ·
/// next run Mon 6 Oct 08:00", last result, and (when given) Pause / Resume /
/// Delete.
class ScheduleCard extends StatelessWidget {
  const ScheduleCard({
    super.key,
    required this.schedule,
    this.onPause,
    this.onResume,
    this.onDelete,
    this.onRunNow,
    this.onOpen,
    this.busy = false,
    this.dense = false,
  });

  final UserSchedule schedule;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onDelete;

  /// "Run now" — "Try again" on a failed schedule.
  final VoidCallback? onRunNow;
  final VoidCallback? onOpen;
  final bool busy;

  /// Inside a message: no border shadow, smaller padding.
  final bool dense;

  static IconData kindIcon(ScheduleKind k) => switch (k) {
    ScheduleKind.reminder => LucideIcons.bellRing,
    ScheduleKind.agentTask => LucideIcons.sparkles,
    ScheduleKind.watch => LucideIcons.eye,
  };

  @override
  Widget build(BuildContext context) {
    final s = schedule;
    String t(String key) => key.getString(context);
    // Default intl locale, like every other date in this app: `main()`
    // never calls initializeDateFormatting, so asking DateFormat for 'ar'
    // (or even 'en') throws LocaleDataException on a real phone.
    final cadence = describeCadence(s, t);
    final (statusKey, statusColor) = switch (s.status) {
      ScheduleStatus.active => ('schedules.status.active', FeColors.success),
      ScheduleStatus.paused => ('schedules.status.paused', FeColors.warning),
      ScheduleStatus.done => ('schedules.status.done', FeColors.ink2),
      ScheduleStatus.expired => ('schedules.status.expired', FeColors.ink2),
      ScheduleStatus.failed => ('schedules.status.failed', FeColors.danger),
    };
    final last = s.lastRun;

    return Container(
      padding: EdgeInsets.all(dense ? 10 : 14),
      decoration: BoxDecoration(
        color: dense ? FeColors.aiSoft : FeColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dense ? FeColors.aiLine : FeColors.line),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(kindIcon(s.kind), size: 18, color: FeColors.ai),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText.bodySmall(cadence, color: FeColors.ai, weight: FontWeight.w800),
                      const SizedBox(height: 2),
                      AppText.bodyMedium(s.title, weight: FontWeight.w700),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    t(statusKey),
                    style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _Meta(
                  icon: LucideIcons.user,
                  text: convTr(context, 'schedules.kind.${s.kind.name}'),
                ),
                if (!s.isFinished)
                  _Meta(
                    icon: LucideIcons.clock,
                    text: convTr(context, 'schedules.next_run', [
                      s.isPaused ? t('schedules.status.paused') : describeNextRun(s.nextRunAt, t),
                    ]),
                  ),
                if (s.recordRef != null) _Meta(icon: LucideIcons.link, text: s.recordRef!),
              ],
            ),
            if (last != null && last.result != ScheduleRunResult.none) ...[
              const SizedBox(height: 8),
              _LastRun(run: last),
            ],
            if (s.canEdit && (onPause != null || onResume != null || onDelete != null || onRunNow != null)) ...[
              const SizedBox(height: 6),
              // Wrap, not Row: Pause + Run now + Delete overflow a 320 pt
              // phone in Arabic (caught by conversation_widgets_test).
              Wrap(
                spacing: 4,
                children: [
                  if (s.isPaused && onResume != null)
                    TextButton.icon(
                      onPressed: busy ? null : onResume,
                      icon: const Icon(LucideIcons.play, size: 16),
                      label: Text(t('schedules.resume')),
                    )
                  else if (!s.isFinished && onPause != null)
                    TextButton.icon(
                      onPressed: busy ? null : onPause,
                      icon: const Icon(LucideIcons.pause, size: 16),
                      label: Text(t('schedules.pause')),
                    ),
                  if (onRunNow != null && !s.isPaused && s.status != ScheduleStatus.done && s.status != ScheduleStatus.expired)
                    TextButton.icon(
                      onPressed: busy ? null : onRunNow,
                      icon: const Icon(LucideIcons.rotateCw, size: 16),
                      label: Text(
                        t(s.status == ScheduleStatus.failed ? 'schedules.try_again' : 'schedules.run_now'),
                      ),
                    ),
                  if (onDelete != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: FeColors.danger),
                      onPressed: busy ? null : onDelete,
                      icon: const Icon(LucideIcons.trash2, size: 16),
                      label: Text(t('common.delete')),
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

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: FeColors.ink2),
      const SizedBox(width: 4),
      Flexible(child: AppText.caption(text, color: FeColors.ink2)),
    ],
  );
}

class _LastRun extends StatelessWidget {
  const _LastRun({required this.run});
  final ScheduleRun run;

  @override
  Widget build(BuildContext context) {
    final (key, color, icon) = switch (run.result) {
      ScheduleRunResult.done => ('schedules.last_done', FeColors.success, LucideIcons.circleCheck),
      ScheduleRunResult.failed => ('schedules.last_failed', FeColors.danger, LucideIcons.circleAlert),
      _ => ('schedules.last_started', FeColors.info, LucideIcons.loader),
    };
    final when = run.at == null ? '' : DateFormat.MMMd().add_Hm().format(run.at!);
    final detail = run.result == ScheduleRunResult.failed ? (run.error ?? run.summary) : run.summary;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.caption(convTr(context, key, [when]), color: color),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  AppText.bodySmall(detail, maxLines: 4, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

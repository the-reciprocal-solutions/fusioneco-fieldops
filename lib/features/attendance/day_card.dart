import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/attendance/day_rules.dart';
import '../../domain/day_attendance.dart';
import '../../domain/capture.dart';
import '../../state/day_attendance_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import 'time_text.dart';
import 'day_actions.dart';

/// "My day" on the dashboard: the technician's daily attendance for payroll
/// (docs/daily-attendance-shift-plan.md). Shows the shift, whether the day has
/// started, how much grace time is left, and the one button that fits: Start my
/// day, End my day, or (on a weekly off) Start off-day work.
///
/// Reads only from the phone (the cached shift and the technician's own start /
/// end), so it is right with no signal. Hidden entirely for a technician with
/// no shift: nothing is expected of them.
class DayCard extends ConsumerStatefulWidget {
  const DayCard({super.key, this.now});

  /// For tests.
  final DateTime Function()? now;

  @override
  ConsumerState<DayCard> createState() => _DayCardState();
}

class _DayCardState extends ConsumerState<DayCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The grace countdown changes with time alone, so something must redraw it.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(dayViewProvider).valueOrNull;
    final today = view?.today;
    if (view == null || today == null || !view.hasShift) return const SizedBox.shrink();

    final now = (widget.now ?? DateTime.now)();
    final local = view.local;
    final card = view.card(now);
    if (card.phase == DayPhase.noShift) return const SizedBox.shrink();

    final shift = today.shift!;
    final tone = _tone(card);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TechCard(
        borderColor: tone.border,
        tint: tone.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(tone.icon, size: 18, color: tone.fg),
                const SizedBox(width: 10),
                Expanded(child: AppText.titleSmall('attend.card_title'.getString(context), weight: FontWeight.w800)),
                AppText.caption('${shift.name} · ${shift.startTime}–${shift.endTime}', color: FeColors.ink2),
              ],
            ),
            const SizedBox(height: 8),
            AppText.bodySmall(_headline(context, card, today, local, now), color: FeColors.ink),
            if (local != null && local.isStarted) ...[
              const SizedBox(height: 8),
              _StatusRow(local: local, today: today),
            ],
            const SizedBox(height: 12),
            _action(context, card, today, local),
          ],
        ),
      ),
    );
  }

  Widget _action(BuildContext context, DayCardState card, DayToday today, DayLocal? local) {
    if (card.canEndDay && local != null) {
      final urgent = card.phase == DayPhase.shiftEnded;
      final label = AppText('attend.end'.getString(context), weight: FontWeight.w800);
      const icon = Icon(LucideIcons.logOut, size: 18);
      void onPressed() => unawaited(endMyDay(context, ref, today, local));
      return SizedBox(
        width: double.infinity,
        child: urgent
            ? ElevatedButton.icon(onPressed: onPressed, icon: icon, label: label, style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)))
            : OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label, style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52))),
      );
    }
    if (card.canStartDay) {
      final off = card.phase == DayPhase.offDay;
      final label = AppText((off ? 'attend.start_off_day' : 'attend.start').getString(context), weight: FontWeight.w800);
      const icon = Icon(LucideIcons.logIn, size: 18);
      void onPressed() => unawaited(startMyDay(context, ref, today));
      return SizedBox(
        width: double.infinity,
        child: off
            ? OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label, style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)))
            : ElevatedButton.icon(onPressed: onPressed, icon: icon, label: label, style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52))),
      );
    }
    return const SizedBox.shrink();
  }

  String _headline(BuildContext context, DayCardState card, DayToday today, DayLocal? local, DateTime now) {
    String t(String k) => k.getString(context);
    final shift = today.shift!;
    switch (card.phase) {
      case DayPhase.noShift:
        return '';
      case DayPhase.offDay:
        return switch (card.dayType) {
          DayType.holiday =>
            '${t('attend.off_holiday')}${card.holidayName == null || card.holidayName!.isEmpty ? '' : ' · ${card.holidayName}'}',
          DayType.leave => t('attend.off_leave'),
          _ => t('attend.off_weekly'),
        };
      case DayPhase.beforeOpen:
        return t('attend.before_open')
            .replaceAll('{time}', shift.startTime)
            .replaceAll('{opens}', today.opensAt == null ? '—' : clockText(today.opensAt!));
      case DayPhase.canStart:
        final left = card.minutesToGraceEnd;
        final graceEnd = today.graceEndsAt == null ? '—' : clockText(today.graceEndsAt!);
        return '${t('attend.can_start').replaceAll('{time}', graceEnd)}'
            '${left == null ? '' : ' ${t('attend.grace_left').replaceAll('{n}', '$left')}'}';
      case DayPhase.late:
        return t('attend.late_msg').replaceAll('{time}', today.graceEndsAt == null ? '—' : clockText(today.graceEndsAt!));
      case DayPhase.veryLate:
        return t('attend.very_late_msg');
      case DayPhase.working:
        return t('attend.working').replaceAll('{time}', local?.inAt == null ? '—' : clockText(local!.inAt!));
      case DayPhase.shiftEnded:
        return t('attend.shift_ended').replaceAll('{time}', today.endsAt == null ? '—' : clockText(today.endsAt!));
      case DayPhase.autoClosed:
        return t('attend.auto_closed').replaceAll('{time}', today.endsAt == null ? '—' : clockText(today.endsAt!));
      case DayPhase.done:
        final span = local?.inAt != null && local?.outAt != null ? local!.outAt!.difference(local.inAt!) : null;
        final worked = local?.workedMinutes != null ? Duration(minutes: local!.workedMinutes!) : span;
        return '${t('attend.done')}${worked == null ? '' : ' · ${durationText(context, worked)}'}';
    }
  }

  ({Color bg, Color border, Color fg, IconData icon}) _tone(DayCardState card) => switch (card.phase) {
    DayPhase.late => (bg: FeColors.warningSoft, border: FeColors.warning.withValues(alpha: 0.4), fg: FeColors.warning, icon: LucideIcons.clock),
    DayPhase.veryLate => (bg: FeColors.dangerSoft, border: FeColors.danger.withValues(alpha: 0.4), fg: FeColors.danger, icon: LucideIcons.triangleAlert),
    DayPhase.shiftEnded || DayPhase.autoClosed => (bg: FeColors.warningSoft, border: FeColors.warning.withValues(alpha: 0.4), fg: FeColors.warning, icon: LucideIcons.clock),
    DayPhase.working || DayPhase.done => (bg: FeColors.successSoft, border: FeColors.success.withValues(alpha: 0.35), fg: FeColors.success, icon: LucideIcons.calendarCheck),
    _ => (bg: FeColors.panel, border: FeColors.line, fg: FeColors.ink2, icon: LucideIcons.calendarClock),
  };
}

/// "On time" / "Late 80 min" / "Half day" and the send state, once the day has started.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.local, required this.today});
  final DayLocal local;
  final DayToday today;

  @override
  Widget build(BuildContext context) {
    final status = local.status ?? (local.inAt == null ? null : estimateStatus(today, local.inAt!));
    final late = local.lateMinutes ?? 0;
    final (String? text, Color color) = switch (status) {
      'present' => ('attend.status_present'.getString(context), FeColors.success),
      'late' => ('attend.status_late'.getString(context).replaceAll('{n}', '$late'), FeColors.warning),
      'half_day' => ('attend.status_half_day'.getString(context), FeColors.warning),
      'absent' => ('attend.status_absent'.getString(context), FeColors.danger),
      'off_day_work' when local.reviewStatus == 'approved' => ('attend.status_off_day_work_approved'.getString(context), FeColors.success),
      'off_day_work' when local.reviewStatus == 'rejected' => ('attend.status_off_day_work_rejected'.getString(context), FeColors.danger),
      'off_day_work' => ('attend.status_off_day_work'.getString(context), FeColors.primary),
      _ => (null, FeColors.ink2),
    };
    final rejected = local.inSync == SendState.rejected || local.outSync == SendState.rejected;
    final (String sendKey, Color sendColor) = rejected
        ? ('capture.state_not_sent', FeColors.danger)
        : local.hasUnsentEnd
        ? ('capture.state_waiting', FeColors.warning)
        : ('capture.state_sent', FeColors.success);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (text != null) _Tag(text: text, color: color),
        _Tag(text: sendKey.getString(context), color: sendColor),
        if (rejected && (local.outIssue ?? local.inIssue) != null) AppText.caption(local.outIssue ?? local.inIssue!, color: FeColors.danger),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(context.radii.lg)),
    child: AppText.caption(text, color: color, weight: FontWeight.w700),
  );
}

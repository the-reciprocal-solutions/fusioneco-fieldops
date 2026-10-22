import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/attendance/day_rules.dart';
import '../../state/day_attendance_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import 'time_text.dart';
import 'day_actions.dart';

/// The shell's "check in" nudge (docs/daily-attendance-shift-plan.md): while the
/// technician is past their grace time and has not started the day, or their
/// shift has ended and they have not ended it, one tap opens the right sheet from
/// any screen. It is the in-app twin of the server's push, and the one that
/// still works with no signal: it is drawn from the phone's own clock and the
/// cached shift. Draws nothing the rest of the time.
class DayBanner extends ConsumerStatefulWidget {
  const DayBanner({super.key, this.now});

  /// For tests.
  final DateTime Function()? now;

  @override
  ConsumerState<DayBanner> createState() => _DayBannerState();
}

class _DayBannerState extends ConsumerState<DayBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
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
    final card = view.card((widget.now ?? DateTime.now)());
    final endNudge = card.phase == DayPhase.shiftEnded;
    if (!card.needsCheckIn && !endNudge) return const SizedBox.shrink();

    final veryLate = card.phase == DayPhase.veryLate;
    final text = endNudge
        ? 'attend.banner_shift_ended'.getString(context).replaceAll('{time}', today.endsAt == null ? '—' : clockText(today.endsAt!))
        : 'attend.banner_not_in'.getString(context).replaceAll('{time}', today.graceEndsAt == null ? '—' : clockText(today.graceEndsAt!));
    final fg = veryLate ? FeColors.danger : FeColors.warning;

    return Material(
      color: veryLate ? FeColors.dangerSoft : FeColors.warningSoft,
      child: InkWell(
        onTap: () {
          if (endNudge) {
            final local = view.local;
            if (local != null) unawaited(endMyDay(context, ref, today, local));
          } else {
            unawaited(startMyDay(context, ref, today));
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(endNudge ? LucideIcons.clock : LucideIcons.triangleAlert, size: 16, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.bodySmall(text, weight: FontWeight.w700, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              AppText.bodySmall(
                (endNudge ? 'attend.end' : 'attend.start').getString(context),
                color: FeColors.primary,
                weight: FontWeight.w800,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

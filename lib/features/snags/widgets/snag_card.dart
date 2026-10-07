import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/snag/snag_send_state.dart';
import '../../../domain/snag.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/common.dart';
import 'snag_visuals.dart';

/// A snag list row: photo first (a snag *is* its photo), then what, where,
/// how bad, and the three flags that change what someone does next —
/// still on this device, reported by several people, reopened.
class SnagCard extends StatelessWidget {
  const SnagCard({
    super.key,
    required this.snag,
    required this.onTap,
    this.pending = false,
    this.send,
    this.trailing,
  });

  final Snag snag;
  final VoidCallback onTap;

  /// A write for it is still queued.
  final bool pending;

  /// Where it is on its way to the server; derived from [pending] when null.
  final SnagSendStatus? send;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final hue = SnagVisuals.priorityColor(snag.priority);
    final sendStatus = send ?? snagSendStatus(snag, queued: pending, flushing: false);
    final overdue = snag.isOverdue(DateTime.now());
    return TechCard(
      onTap: onTap,
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              SnagPhoto(evidence: snag.coverPhoto, width: 76, height: 76, radius: 14),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: hue,
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                  ),
                ),
              ),
              if (snag.photos.length > 1)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      '${snag.photos.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(SnagVisuals.tradeIcon(snag.trade), size: 13, color: FeColors.ink2),
                    const SizedBox(width: 4),
                    AppText.caption(snag.displayRef, color: FeColors.ink2, weight: FontWeight.w700),
                    const Spacer(),
                    TechChip(
                      label: SnagVisuals.statusLabel(context, snag.status),
                      style: SnagVisuals.chip(SnagVisuals.statusColor(snag.status)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                AppText.titleSmall(snag.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (snag.locationLabel != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(LucideIcons.mapPin, size: 12, color: FeColors.ink2),
                      const SizedBox(width: 3),
                      Expanded(
                        child: AppText.bodySmall(
                          snag.locationLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _Flag(
                      icon: LucideIcons.circleDot,
                      label: SnagVisuals.priorityLabel(context, snag.priority),
                      color: hue,
                    ),
                    if (!sendStatus.state.isSynced)
                      _Flag(
                        icon: SnagVisuals.sendIcon(sendStatus.state),
                        label: sendStatus.labelKey.getString(context),
                        color: SnagVisuals.sendColor(sendStatus.state),
                      ),
                    if (snag.reportCount > 1)
                      _Flag(
                        icon: LucideIcons.users,
                        label: '×${snag.reportCount}',
                        color: FeColors.info,
                      ),
                    if (snag.reopenedCount > 0)
                      _Flag(
                        icon: LucideIcons.rotateCcw,
                        label: '↺${snag.reopenedCount}',
                        color: FeColors.danger,
                      ),
                    if (overdue)
                      _Flag(
                        icon: LucideIcons.alarmClock,
                        label: 'snags.overdue'.getString(context),
                        color: FeColors.danger,
                      )
                    else if (snag.dueDate != null && snag.status.isLive)
                      _Flag(
                        icon: LucideIcons.calendar,
                        label: DateFormat.MMMd().format(snag.dueDate!),
                        color: FeColors.ink2,
                      ),
                  ],
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Flag extends StatelessWidget {
  const _Flag({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      ],
    ),
  );
}

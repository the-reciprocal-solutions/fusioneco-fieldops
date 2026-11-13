import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/offline/mutation_label_text.dart';
import '../core/offline/offline_db.dart';
import '../core/offline/queue_bus.dart';
import '../state/providers.dart';
import '../core/utils/dates.dart';
import '../theme/fe_colors.dart';
import 'app_text.dart';
import 'common.dart';

/// Two different things share the local `conflicts` log, told apart by
/// [SyncConflict.dropped]:
///  - `dropped: true` — a mutation the server rejected outright while
///    replaying (a terminal 4xx). It never landed; this is the only place
///    the technician learns the work did not save.
///  - `dropped: false` — FR-4.8. The mutation DID land, but the server's
///    response said the register had moved since the technician looked at
///    it (`captureConflict`), which the write itself has no way to surface
///    on its own since it already succeeded.
/// Rendered as two visually distinct panels so "this failed" is never
/// confused with "this saved, but double-check it".
class SyncConflictPanel extends ConsumerWidget {
  const SyncConflictPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(syncConflictsProvider).valueOrNull ?? const [];
    if (conflicts.isEmpty) return const SizedBox.shrink();

    final db = ref.watch(offlineDbProvider);
    final bus = ref.watch(queueBusProvider);
    final dropped = conflicts.where((c) => c.dropped).toList();
    final flagged = conflicts.where((c) => !c.dropped).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        children: [
          if (dropped.isNotEmpty)
            _ConflictGroup(
              conflicts: dropped,
              icon: LucideIcons.triangleAlert,
              color: FeColors.danger,
              tint: FeColors.dangerSoft,
              title: 'widgets.sync_conflict_title'.getString(context),
              db: db,
              bus: bus,
            ),
          if (dropped.isNotEmpty && flagged.isNotEmpty) const SizedBox(height: 8),
          if (flagged.isNotEmpty)
            _ConflictGroup(
              conflicts: flagged,
              icon: LucideIcons.info,
              color: FeColors.warning,
              tint: FeColors.warning.withValues(alpha: 0.12),
              title: 'widgets.capture_conflict_title'.getString(context),
              db: db,
              bus: bus,
            ),
        ],
      ),
    );
  }
}

class _ConflictGroup extends StatelessWidget {
  const _ConflictGroup({
    required this.conflicts,
    required this.icon,
    required this.color,
    required this.tint,
    required this.title,
    required this.db,
    required this.bus,
  });

  final List<SyncConflict> conflicts;
  final IconData icon;
  final Color color;
  final Color tint;
  final String title;
  final OfflineDb db;
  final QueueBus bus;

  @override
  Widget build(BuildContext context) => TechCard(
        tint: tint,
        borderColor: color.withValues(alpha: 0.25),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.bodyMedium(
                    title,
                    color: color,
                    weight: FontWeight.w700,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    for (final c in conflicts) {
                      await db.deleteConflict(c.id);
                    }
                    bus.notify();
                  },
                  style: TextButton.styleFrom(foregroundColor: color),
                  child: AppText('widgets.dismiss_all'.getString(context)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final conflict in conflicts)
              _ConflictRow(
                conflict: conflict,
                color: color,
                onDismiss: () async {
                  await db.deleteConflict(conflict.id);
                  bus.notify();
                },
              ),
          ],
        ),
      );
}

class _ConflictRow extends StatelessWidget {
  const _ConflictRow({required this.conflict, required this.color, required this.onDismiss});

  final SyncConflict conflict;
  final Color color;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TechCard(
          padding: const EdgeInsets.all(12),
          radius: 12,
          borderColor: color.withValues(alpha: 0.25),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.bodyMedium(
                      mutationLabelText(context, conflict.label),
                      color: FeColors.ink,
                      weight: FontWeight.w600,
                    ),
                    const SizedBox(height: 2),
                    AppText.bodySmall(conflict.reason),
                    AppText.bodySmall(
                      formatDateTimeShort(conflict.at),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(LucideIcons.x, size: 16),
                color: FeColors.ink2,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      );
}

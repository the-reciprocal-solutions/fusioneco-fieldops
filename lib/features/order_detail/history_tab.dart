import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/utils/dates.dart';
import '../../domain/history_entry.dart';
import '../../state/order_detail_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/dir_icon.dart';

/// The web renders this as a desktop data table; on a phone it is a timeline.
class HistoryTab extends ConsumerWidget {
  const HistoryTab({super.key, required this.orderKey});

  final OrderKey orderKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(orderHistoryProvider(orderKey));

    return history.when(
      loading: () => const TechSpinner(),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: TechEmptyState(
          icon: LucideIcons.triangleAlert,
          title: 'order_detail.history_load_failed'.getString(context),
        ),
      ),
      data: (entries) => entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: TechEmptyState(
                icon: LucideIcons.history,
                title: 'order_detail.history_empty_title'.getString(context),
                subtitle:
                    'order_detail.history_empty_subtitle'.getString(context),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) =>
                  _HistoryRow(entry: entries[index]),
            ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});

  final HistoryEntry entry;

  static (IconData, Color, Color) _styleFor(String action) => switch (action) {
        'CREATED' => (LucideIcons.fileText, FeColors.infoSoft, FeColors.info),
        'STATUS_UPDATE' => (
            LucideIcons.circleCheck,
            FeColors.successSoft,
            FeColors.success
          ),
        'CHECKLIST_UPDATED' => (
            LucideIcons.circleCheck,
            FeColors.dashboardAccentSoft,
            FeColors.dashboardAccent
          ),
        'DETAILS_UPDATED' => (
            LucideIcons.pencil,
            FeColors.primary.withValues(alpha: 0.1),
            FeColors.primary
          ),
        'ASSIGNMENT_UPDATED' => (
            LucideIcons.user,
            FeColors.dashboardAccentSoft,
            FeColors.dashboardAccent
          ),
        'SCHEDULE_UPDATED' => (
            LucideIcons.calendar,
            FeColors.warningSoft,
            FeColors.warning
          ),
        'PRIORITY_UPDATED' => (
            LucideIcons.triangleAlert,
            FeColors.dangerSoft,
            FeColors.danger
          ),
        _ => (LucideIcons.layers, FeColors.page, FeColors.ink2),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, background, foreground) = _styleFor(entry.action);

    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(context.radii.md),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 12, color: foreground),
                    const SizedBox(width: 4),
                    AppText.caption(
                      entry.actionLabel,
                      color: foreground,
                      weight: FontWeight.w600,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (entry.timestamp != null)
                AppText.caption(
                  formatHistoryTimestamp(entry.timestamp!),
                  color: FeColors.ink2,
                ),
            ],
          ),
          if (entry.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            AppText.bodySmall(
              entry.description,
              color: FeColors.ink2,
            ),
          ],
          if (entry.hasValueChange) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: AppText(
                    entry.oldValue?.isNotEmpty == true ? entry.oldValue! : '—',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: FeColors.ink2,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: DirIcon(LucideIcons.arrowRight,
                      size: 12, color: FeColors.ink2),
                ),
                Flexible(
                  child: AppText.caption(
                    entry.newValue?.isNotEmpty == true ? entry.newValue! : '—',
                    overflow: TextOverflow.ellipsis,
                    color: FeColors.ink,
                    weight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(LucideIcons.user, size: 12, color: FeColors.ink2),
              const SizedBox(width: 4),
              AppText.caption(
                entry.performedByRole == null
                    ? entry.userName
                    : '${entry.userName} · ${entry.performedByRole}',
                color: FeColors.ink2,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

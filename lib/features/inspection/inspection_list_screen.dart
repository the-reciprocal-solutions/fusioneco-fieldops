import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../domain/inspection.dart';
import '../../state/inspection_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/tech_header.dart';
import 'inspection_send_flag.dart';
import '../../theme/app_font.dart';

class InspectionListScreen extends ConsumerWidget {
  const InspectionListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inspections = ref.watch(assignedInspectionsProvider);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: TechHeader(title: 'inspection.ui.list_title'.getString(context)),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(assignedInspectionsProvider.future),
          child: inspections.when(
            loading: () => const Center(child: TechSpinner()),
            error: (error, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: 'inspection.ui.list_failed'.getString(context),
                  subtitle: 'common.pull_down_to_retry'.getString(context),
                  iconColor: FeColors.danger,
                ),
              ],
            ),
            data: (items) {
              if (items.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TechEmptyState(
                      icon: LucideIcons.clipboardCheck,
                      title: 'inspection.ui.list_empty_title'.getString(context),
                      subtitle: 'inspection.ui.list_empty_subtitle'.getString(context),
                    ),
                  ],
                );
              }

              final pending = items.where((i) => i.status == 'pending').toList();
              final other = items.where((i) => i.status != 'pending').toList();

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (pending.isNotEmpty) ...[
                    AppText.bodySmall(
                      'inspection.ui.section_todo'.getString(context),
                      weight: FontWeight.w800,
                      color: FeColors.ink2,
                    ),
                    const SizedBox(height: 8),
                    for (final item in pending) ...[
                      _InspectionCard(
                        inspection: item,
                        onTap: () => context.push(Routes.inspectionDetail(item.id)),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 12),
                  ],
                  if (other.isNotEmpty) ...[
                    AppText.bodySmall(
                      'inspection.ui.section_past'.getString(context),
                      weight: FontWeight.w800,
                      color: FeColors.ink2,
                    ),
                    const SizedBox(height: 8),
                    for (final item in other) ...[
                      _InspectionCard(
                        inspection: item,
                        onTap: () => context.push(Routes.inspectionDetail(item.id)),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InspectionCard extends StatelessWidget {
  const _InspectionCard({required this.inspection, required this.onTap});

  final InspectionAssignmentSummary inspection;
  final VoidCallback onTap;

  (Color, Color) _statusColors() {
    switch (inspection.status) {
      case 'completed':
        return (FeColors.successSoft, FeColors.success);
      case 'expired':
        return (const Color(0xFFF1F5F9), FeColors.ink2);
      default:
        return (FeColors.infoSoft, FeColors.info);
    }
  }

  /// pending / completed / expired from the server; anything else shows as sent.
  String _statusLabel(BuildContext context) => switch (inspection.status) {
        'pending' || 'completed' || 'expired' =>
          'inspection.ui.status_${inspection.status}'.getString(context),
        _ => inspection.status.toUpperCase(),
      };

  @override
  Widget build(BuildContext context) {
    final (statusBg, statusFg) = _statusColors();
    final reference = inspection.referenceId.isNotEmpty
        ? inspection.referenceId
        : inspection.id.substring(0, inspection.id.length.clamp(0, 6));

    return TechCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: FeColors.infoSoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  LucideIcons.clipboardCheck,
                  size: 19,
                  color: FeColors.info,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#$reference',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: FeColors.ink2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      inspection.templateName ?? 'inspection.ui.title'.getString(context),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: FeColors.ink,
                      ),
                    ),
                    InspectionSendFlag(
                      assignmentId: inspection.id,
                      serverStatus: inspection.status,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _statusLabel(context),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: statusFg,
                    letterSpacing: context.letterSpacingFor(0.4),
                  ),
                ),
              ),
            ],
          ),
          if (inspection.dueDate != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  LucideIcons.calendar,
                  size: 13,
                  color: inspection.isOverdue ? FeColors.danger : FeColors.ink2,
                ),
                const SizedBox(width: 6),
                Text(
                  '${inspection.dueDate!.month}/${inspection.dueDate!.day}/${inspection.dueDate!.year}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: inspection.isOverdue
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: inspection.isOverdue ? FeColors.danger : FeColors.ink2,
                  ),
                ),
                if (inspection.isOverdue) ...[
                  const SizedBox(width: 8),
                  Text(
                    'inspection.ui.overdue'.getString(context),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: FeColors.danger,
                      letterSpacing: context.letterSpacingFor(0.4),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

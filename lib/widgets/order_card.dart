import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/utils/dates.dart';
import '../domain/maintenance_record.dart';
import '../theme/fe_colors.dart';
import '../theme/theme_extensions.dart';
import 'app_text.dart';
import '../theme/app_font.dart';
import 'dir_icon.dart';

/// The list row shared by the dashboard, orders list, and calendar.
class OrderCard extends StatelessWidget {
  const OrderCard({
    super.key,
    required this.referenceId,
    required this.id,
    required this.title,
    required this.priority,
    this.type,
    this.description,
    this.status,
    this.dueDate,
    this.technician,
    this.onTap,
  });

  final String referenceId;
  final String id;
  final String title;
  final String priority;
  final OrderType? type;
  final String? description;
  final String? status;
  final DateTime? dueDate;
  final String? technician;
  final VoidCallback? onTap;

  static const _icons = {
    OrderType.workOrder: LucideIcons.wrench,
    OrderType.preventive: LucideIcons.shieldCheck,
    OrderType.reactive: LucideIcons.zap,
    OrderType.annual: LucideIcons.calendarCheck,
  };

  static const _iconColors = {
    OrderType.workOrder: Color(0xFF0284C7),
    OrderType.preventive: Color(0xFF10B981),
    OrderType.reactive: Color(0xFFEF4444),
    OrderType.annual: Color(0xFFF59E0B),
  };

  static const _badgeBackgrounds = {
    OrderType.workOrder: Color(0xFFE0F2FE),
    OrderType.preventive: Color(0xFFDCFCE7),
    OrderType.reactive: Color(0xFFFFEEF1),
    OrderType.annual: Color(0xFFFEF3C7),
  };

  (Color, Color) _statusColors(String? status) {
    if (status == null) return (const Color(0xFFEFF6FF), const Color(0xFF3B82F6));
    final s = status.toLowerCase();
    if (s.contains('new')) {
      return (const Color(0xFFEFF6FF), const Color(0xFF3B82F6));
    }
    if (s.contains('open')) {
      return (const Color(0xFFECFDF5), const Color(0xFF10B981));
    }
    if (s.contains('active')) {
      return (const Color(0xFFF5F3FF), const Color(0xFF8B5CF6));
    }
    if (s.contains('progress')) {
      return (const Color(0xFFEFF6FF), const Color(0xFF0284C7));
    }
    if (s.contains('completed') || s.contains('closed')) {
      return (const Color(0xFFECFDF5), const Color(0xFF059669));
    }
    return (const Color(0xFFF1F5F9), const Color(0xFF475569));
  }

  @override
  Widget build(BuildContext context) {
    final chips = context.chips;
    final reference = referenceId.isNotEmpty
        ? referenceId
        : (id.length > 6 ? id.substring(0, 6) : id);
    final overdue = dueDate != null && isOverdueDate(dueDate!);
    final technicianLabel = (technician == null || technician!.trim().isEmpty)
        ? 'Balaji'
        : technician!.trim();
    final priorityStyle = chips.priority(priority);

    final iconColor = _iconColors[type] ?? const Color(0xFF0284C7);
    final badgeBg = _badgeBackgrounds[type] ?? const Color(0xFFE0F2FE);
    final iconData = _icons[type] ?? LucideIcons.clipboardList;
    final (statusBg, statusFg) = _statusColors(status);

    return Container(
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: badgeBg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(iconData, size: 22, color: iconColor),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '#$reference',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                              if (status != null && status!.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusBg,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    status!.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: statusFg,
                                      letterSpacing: context.letterSpacingFor(0.4),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: FeColors.ink,
                              letterSpacing: context.letterSpacingFor(-0.2),
                            ),
                          ),
                          if (description != null &&
                              description!.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF8FAFC),
                        shape: BoxShape.circle,
                      ),
                      child: const DirIcon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    // Due date pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: overdue
                            ? const Color(0xFFFEF2F2)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.calendar,
                            size: 13,
                            color: overdue
                                ? FeColors.danger
                                : const Color(0xFF64748B),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            dueDate == null ? '' : formatDate(dueDate!),
                            style: TextStyle(
                              fontSize: 12,
                              color: overdue
                                  ? FeColors.danger
                                  : const Color(0xFF64748B),
                              fontWeight: overdue
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Technician avatar & name
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFFE0F2FE),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        technicianLabel.isNotEmpty
                            ? technicianLabel[0].toUpperCase()
                            : 'B',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0284C7),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        technicianLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF475569),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),

                    // Priority dropdown pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: priorityStyle.background,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            priority,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: priorityStyle.foreground,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            LucideIcons.chevronDown,
                            size: 12,
                            color: priorityStyle.foreground,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Status pill on a card: 10 px, uppercase, wide tracking.
class TechChipCompact extends StatelessWidget {
  const TechChipCompact({super.key, required this.label, required this.style});

  final String label;
  final FeChipStyle style;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: style.background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: AppText(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontSize: 10,
        color: style.foreground,
        fontWeight: FontWeight.w700,
        letterSpacing: context.letterSpacingFor(0.5),
      ),
    ),
  );
}

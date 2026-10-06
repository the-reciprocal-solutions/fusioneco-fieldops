import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/utils/dates.dart';
import '../../domain/inspection.dart';
import '../../domain/maintenance_record.dart';
import '../inspection/inspection_send_flag.dart';
import '../../state/inspection_controller.dart';
import '../../state/orders_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/order_card.dart';

/// The chips at the top of the orders list. Generation now produces a single
/// unified Work Order for every kind (see [OrdersRepository.listAll]), so the
/// only thing left to switch between is that unified list and Inspections,
/// which are a separate source (their own repository/provider) not modelled
/// as a [MaintenanceRecord] at all.
enum _TypeFilter {
  all,
  workOrder,
  inspection;

  String label(BuildContext context) => switch (this) {
        _TypeFilter.all => 'orders.filter_type_all'.getString(context),
        _TypeFilter.workOrder =>
          'orders.filter_type_work_order'.getString(context),
        _TypeFilter.inspection =>
          'orders.filter_type_inspection'.getString(context),
      };
}

/// Inspections have no priority/status/date filters wired up (no source
/// fields to filter on beyond these three), so unlike [OrdersState
/// .visibleRecords] this only ever applies the search box — matching
/// "search only filters within the selected filter" for the Inspection tab.
List<InspectionAssignmentSummary> _filterInspections(
  List<InspectionAssignmentSummary> items,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return items;
  return items.where((i) {
    final name = (i.templateName ?? '').toLowerCase();
    final location = (i.templateLocation ?? '').toLowerCase();
    final refId = i.referenceId.toLowerCase();
    return name.contains(q) || location.contains(q) || refId.contains(q);
  }).toList();
}

class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  final _searchController = TextEditingController();
  _TypeFilter _selectedFilter = _TypeFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSelectFilter(_TypeFilter filter) {
    if (filter == _selectedFilter) return;
    // Both chips left are just a view over already-loaded data — the
    // controller only ever fetches the one unified work-order list, so
    // switching chips has nothing to (re)request.
    setState(() => _selectedFilter = filter);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ordersControllerProvider);
    final controller = ref.read(ordersControllerProvider.notifier);

    final showOrders = _selectedFilter != _TypeFilter.inspection;
    final showInspections =
        _selectedFilter == _TypeFilter.all || _selectedFilter == _TypeFilter.inspection;
    final visible = showOrders ? state.visibleRecords : const <MaintenanceRecord>[];

    final inspectionsAsync = ref.watch(assignedInspectionsProvider);
    final visibleInspections = showInspections
        ? _filterInspections(inspectionsAsync.valueOrNull ?? const [], state.searchQuery)
        : const <InspectionAssignmentSummary>[];

    // First load only — once either source has something on screen, a
    // background refresh (pull-to-refresh, queue flush) no longer blanks the
    // list, same as the pre-existing orders-only behavior below.
    final ordersLoading = showOrders && state.loading && state.records.isEmpty;
    final inspectionsLoading =
        showInspections && inspectionsAsync.isLoading && !inspectionsAsync.hasValue;
    final stillLoadingEverything =
        (ordersLoading || inspectionsLoading) && visible.isEmpty && visibleInspections.isEmpty;

    ref.listen(ordersControllerProvider.select((s) => s.searchQuery), (
      _,
      query,
    ) {
      if (query.isEmpty && _searchController.text.isNotEmpty) {
        _searchController.clear();
      }
    });

    return Scaffold(
      backgroundColor: FeColors.page,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Top bar: Orders title, subtitle, and a Calendar shortcut.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'orders.title'.getString(context),
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: FeColors.ink,
                            letterSpacing: -0.5,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'orders.subtitle'.getString(context),
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: FeColors.ink2,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _CircleActionButton(
                    icon: LucideIcons.calendarDays,
                    tooltip: 'common.calendar'.getString(context),
                    onTap: () => context.push(Routes.calendar),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // All / Work Orders / Inspections — the only two sources left
              // to switch between now that generation collapses every
              // maintenance kind into a single unified Work Order.
              _TypeFilterRow(
                selected: _selectedFilter,
                onSelect: _onSelectFilter,
              ),
              const SizedBox(height: 14),

              // Single, always-visible search bar — the only filter left,
              // since the technician endpoint already scopes the list to
              // this technician's own work.
              Container(
                decoration: BoxDecoration(
                  color: FeColors.panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: controller.setSearchQuery,
                  decoration: InputDecoration(
                    hintText: 'orders.search_hint'.getString(context),
                    hintStyle: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 14,
                    ),
                    prefixIcon: const Icon(
                      LucideIcons.search,
                      size: 18,
                      color: Color(0xFF64748B),
                    ),
                    suffixIcon: state.searchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(LucideIcons.x, size: 16),
                            onPressed: () {
                              _searchController.clear();
                              controller.setSearchQuery('');
                            },
                          ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              if (stillLoadingEverything)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: TechSpinner(),
                )
              else if (showOrders &&
                  !showInspections &&
                  state.error != null &&
                  state.records.isEmpty)
                TechEmptyState(
                  icon: LucideIcons.triangleAlert,
                  title: 'orders.load_failed'.getString(context),
                  subtitle: state.error,
                )
              else if (showInspections &&
                  !showOrders &&
                  inspectionsAsync.hasError &&
                  visibleInspections.isEmpty)
                TechEmptyState(
                  icon: LucideIcons.triangleAlert,
                  title: 'orders.load_failed'.getString(context),
                )
              else if (visible.isEmpty && visibleInspections.isEmpty)
                TechEmptyState(
                  icon: LucideIcons.clipboardList,
                  title: 'orders.empty_title'.getString(context),
                  subtitle: 'orders.empty_subtitle'.getString(context),
                )
              else ...[
                for (final record in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: OrderCard(
                      id: record.id,
                      type: record.type,
                      referenceId: record.referenceId ?? '',
                      title: record.cardTitle,
                      description: record.cardDescription,
                      priority: record.displayPriority,
                      status: record.displayStatus,
                      dueDate: record.effectiveDate,
                      technician: record.technicianName,
                      onTap: () => context.push(
                        Routes.orderDetail(record.type.slug, record.id),
                      ),
                    ),
                  ),
                for (final inspection in visibleInspections)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _InspectionOrderCard(
                      inspection: inspection,
                      onTap: () => context.push(
                        Routes.inspectionDetail(inspection.id),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FeColors.panel,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, size: 19, color: FeColors.ink),
        ),
      ),
    );
  }
}

/// The All/Work Orders/Inspections chip row at the top of the orders list.
class _TypeFilterRow extends StatelessWidget {
  const _TypeFilterRow({required this.selected, required this.onSelect});

  final _TypeFilter selected;
  final ValueChanged<_TypeFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final filter in _TypeFilter.values) ...[
            _TypeFilterChip(
              label: filter.label(context),
              selected: filter == selected,
              onTap: () => onSelect(filter),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _TypeFilterChip extends StatelessWidget {
  const _TypeFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? FeColors.primary : FeColors.panel,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? FeColors.primary : const Color(0xFFE2E8F0),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : FeColors.ink2,
            ),
          ),
        ),
      ),
    );
  }
}

/// The Inspection-flavored equivalent of [OrderCard] — same badge/reference/
/// status/title layout, but with the priority and technician rows dropped
/// (an [InspectionAssignmentSummary] has neither field to show).
class _InspectionOrderCard extends StatelessWidget {
  const _InspectionOrderCard({required this.inspection, this.onTap});

  final InspectionAssignmentSummary inspection;
  final VoidCallback? onTap;

  (Color, Color) _statusColors(String status) {
    switch (status) {
      case 'completed':
        return (FeColors.successSoft, FeColors.success);
      case 'expired':
        return (const Color(0xFFF1F5F9), const Color(0xFF475569));
      default:
        return (FeColors.infoSoft, const Color(0xFF3B82F6));
    }
  }

  @override
  Widget build(BuildContext context) {
    final reference = inspection.referenceId;
    final overdue = inspection.isOverdue;
    final (statusBg, statusFg) = _statusColors(inspection.status);

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
                      decoration: const BoxDecoration(
                        color: FeColors.infoSoft,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.clipboardCheck,
                        size: 22,
                        color: Color(0xFF3B82F6),
                      ),
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
                                  inspection.status.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: statusFg,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            inspection.templateName ?? 'Inspection',
                            style: const TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: FeColors.ink,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (inspection.templateLocation != null &&
                              inspection.templateLocation!.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              inspection.templateLocation!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                          InspectionSendFlag(
                            assignmentId: inspection.id,
                            serverStatus: inspection.status,
                          ),
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
                      child: const Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
                if (inspection.dueDate != null) ...[
                  const SizedBox(height: 14),
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
                          color: overdue ? FeColors.danger : const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          formatDate(inspection.dueDate!),
                          style: TextStyle(
                            fontSize: 12,
                            color: overdue ? FeColors.danger : const Color(0xFF64748B),
                            fontWeight: overdue ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

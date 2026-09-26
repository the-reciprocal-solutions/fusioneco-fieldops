import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/network/envelope.dart';
import '../../core/utils/checklist_status.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/external_launch.dart';
import '../../domain/maintenance_record.dart';
import '../../state/auth_controller.dart';
import '../../state/checklist_controller.dart';
import '../../state/order_detail_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/photo_viewer.dart';
import '../ar/widgets/ar_entry_widgets.dart';
import 'checklist_item_sheet.dart' show SignatureImageAndCaption;
import 'checklist_tab.dart';
import 'detail_widgets.dart';
import 'documents_tab.dart';
// import 'record_voice_note.dart'; // only used by the hidden voice note sheet below
import 'history_tab.dart';
import 'order_chat_sheet.dart';

class OrderDetailScreen extends ConsumerStatefulWidget {
  const OrderDetailScreen({
    super.key,
    required this.orderType,
    required this.orderId,
  });

  final String orderType;
  final String orderId;

  static String headerTitleFor(OrderType type, BuildContext context) =>
      switch (type) {
        OrderType.workOrder =>
          'order_detail.header_work_order'.getString(context),
        OrderType.preventive =>
          'order_detail.header_preventive'.getString(context),
        OrderType.reactive =>
          'order_detail.header_reactive'.getString(context),
        OrderType.annual => 'order_detail.header_annual'.getString(context),
      };

  static String detailTitleFor(MaintenanceRecord record, BuildContext context) =>
      switch (record.type) {
        OrderType.workOrder => record.titleField ?? '',
        OrderType.preventive =>
          record.assetName ?? 'order_detail.header_preventive'.getString(context),
        OrderType.reactive =>
          firstNonEmpty([record.assetName, record.subRequest]) ??
              'order_detail.header_reactive'.getString(context),
        OrderType.annual =>
          record.assetName ?? 'order_detail.header_annual'.getString(context),
      };

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  late final OrderKey _key = (
    type: OrderType.fromSlug(widget.orderType),
    id: widget.orderId,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(orderDetailControllerProvider(_key).notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final key = _key;
    final detail = ref.watch(orderDetailControllerProvider(key));

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF8FAFC),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(
              LucideIcons.arrowLeft,
              color: Color(0xFF0F172A),
              size: 22,
            ),
            tooltip: 'common.back'.getString(context),
            onPressed: () => context.pop(),
          ),
          title: Text(
            OrderDetailScreen.headerTitleFor(key.type, context),
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
              letterSpacing: -0.3,
            ),
          ),
          actions: [
            if (ref.watch(authControllerProvider).permissions.isAiAgent &&
                detail.hasValue)
              _ChatTriggerButton(
                onPressed: () => showOrderChatSheet(
                  context,
                  orderKey: key,
                  assetName: detail.requireValue.record.assetName,
                ),
              ),
            const SizedBox(width: 8),
          ],
          bottom: detail.hasValue
              ? _DetailTabBar(
                  // The synthetic signature item rides in `checklists` (see
                  // `checklist_status.dart`) but is not a task the
                  // technician works, so it is excluded here too — the same
                  // way `deriveChecklistSummary`/`isChecklistFullyComplete`
                  // already exclude it via `isOther`.
                  tasksLabel: key.type == OrderType.workOrder
                      ? context.formatString(
                          'order_detail.tasks_count'.getString(context),
                          [
                            detail.requireValue.record.checklists
                                .where((i) => !i.isSignature)
                                .length,
                          ],
                        )
                      : 'order_detail.checklist'.getString(context),
                )
              : null,
        ),
        body: detail.when(
          loading: () => const Center(child: TechSpinner()),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: TechEmptyState(
              icon: LucideIcons.circleAlert,
              title: 'order_detail.load_failed_title'.getString(context),
              subtitle: 'order_detail.load_failed_subtitle'.getString(context),
            ),
          ),
          data: (data) => TabBarView(
            children: [
              _DetailsTab(detail: data, orderKey: key),
              ChecklistTab(record: data.record, orderKey: key),
              HistoryTab(orderKey: key),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailTabBar extends StatelessWidget implements PreferredSizeWidget {
  const _DetailTabBar({required this.tasksLabel});

  final String tasksLabel;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFFF8FAFC),
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
    child: Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: TabBar(
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: const Color(0xFF0284C7),
          borderRadius: BorderRadius.circular(12),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: const Color(0xFF64748B),
        labelStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
        tabs: [
          Tab(text: 'order_detail.tab_details'.getString(context)),
          Tab(text: tasksLabel),
          Tab(text: 'order_detail.tab_history'.getString(context)),
        ],
      ),
    ),
  );
}

class _DetailsTab extends ConsumerWidget {
  const _DetailsTab({required this.detail, required this.orderKey});

  final OrderDetail detail;
  final OrderKey orderKey;

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

  static const _badgeBgs = {
    OrderType.workOrder: Color(0xFFE0F2FE),
    OrderType.preventive: Color(0xFFDCFCE7),
    OrderType.reactive: Color(0xFFFFEEF1),
    OrderType.annual: Color(0xFFFEF3C7),
  };

  // Record voice note — hidden for now, along with its call site above.
  // void _showVoiceNoteSheet(BuildContext context, String? audioUrl) {
  //   showModalBottomSheet<void>(
  //     context: context,
  //     backgroundColor: FeColors.panel,
  //     shape: const RoundedRectangleBorder(
  //       borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  //     ),
  //     builder: (context) => SafeArea(
  //       child: Padding(
  //         padding: const EdgeInsets.all(20),
  //         child: Column(
  //           mainAxisSize: MainAxisSize.min,
  //           crossAxisAlignment: CrossAxisAlignment.start,
  //           children: [
  //             const Text(
  //               'Record Voice Note',
  //               style: TextStyle(
  //                 fontSize: 18,
  //                 fontWeight: FontWeight.w800,
  //                 color: Color(0xFF0F172A),
  //               ),
  //             ),
  //             const SizedBox(height: 14),
  //             RecordVoiceNote(
  //               orderKey: orderKey,
  //               audioUrl: audioUrl,
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //   );
  // }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = detail.record;
    final checklistItems = ref.watch(checklistControllerProvider(orderKey)).items;
    final permissions = ref.watch(authControllerProvider).permissions;
    final iconData = _icons[record.type] ?? LucideIcons.wrench;
    final iconColor = _iconColors[record.type] ?? const Color(0xFF0284C7);
    final badgeBg = _badgeBgs[record.type] ?? const Color(0xFFE0F2FE);

    return RefreshIndicator(
      onRefresh: ref
          .read(orderDetailControllerProvider(orderKey).notifier)
          .refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Hero Order Identity Card with soft airy cyan/sky blue gradient
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white,
                  Colors.white,
                  Color(0xFFEFF6FF),
                  Color(0xFFE0F2FE),
                ],
                stops: [0.0, 0.45, 0.75, 1.0],
              ),
              border: Border.all(color: const Color(0xFFF1F5F9)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: badgeBg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(iconData, size: 22, color: iconColor),
                    ),
                    if (record.priority != null && record.priority!.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          record.priority!,
                          style: const TextStyle(
                            color: Color(0xFFD97706),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  OrderDetailScreen.detailTitleFor(record, context),
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                    letterSpacing: -0.3,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  record.referenceId ?? '',
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    // != false (not == true): an unset/null flag keeps the
                    // button visible, matching web's ViewInTwinButton polarity.
                    if (ref.watch(authControllerProvider).permissions.isDigitalTwin !=
                        false)
                      Expanded(
                        child: _ActionPillButton(
                          icon: LucideIcons.box,
                          label: 'order_detail.view_in_3d'.getString(context),
                          onTap: () {
                            if (record.assetId != null) {
                              context.push(
                                '${Routes.twin(record.assetId!)}?name=${Uri.encodeComponent(OrderDetailScreen.detailTitleFor(record, context))}',
                              );
                            }
                          },
                        ),
                      ),
                    // UC-5 — a defect found during this job that is not part of
                    // it becomes its own snag, linked back here, instead of
                    // quietly widening this order's scope. Only a work order's
                    // id is passed as the link: the snag's `workOrderId` points
                    // at `work_orders`, not at PM/RM records.
                    if (ref.watch(authControllerProvider).permissions.isDigitalTwin != false)
                      const SizedBox(width: 12),
                    Expanded(
                      child: _ActionPillButton(
                        icon: LucideIcons.flag,
                        label: 'snags.raise_snag'.getString(context),
                        onTap: () => context.push(
                          Routes.snagNew(
                            assetId: record.assetId,
                            assetName: record.assetName,
                            workOrderId: record.type == OrderType.workOrder ? record.id : null,
                            context: 'operations',
                          ),
                        ),
                      ),
                    ),
                    // Record voice note — hidden for now.
                    // const SizedBox(width: 12),
                    // Expanded(
                    //   child: _ActionPillButton(
                    //     icon: LucideIcons.mic,
                    //     label: 'Record voice note',
                    //     onTap: () => _showVoiceNoteSheet(context, record.notesAudioUrl),
                    //   ),
                    // ),
                  ],
                ),
                // AR Locate (docs/ar-bim-overlay.md §1.1): the job's asset
                // drawn where it really is, with this order on top. The AR
                // screens find the asset's floor; only a work order's id rides
                // along (the AR Forms mode opens its checklist). Shown only when
                // this client has AR and the asset's floor has a published AR
                // model — "View in 3D" above stays the default way in.
                if (record.assetId != null)
                  SizedBox(
                    width: double.infinity,
                    child: ShowInArButton(
                      assetId: record.assetId,
                      workOrderId: record.type == OrderType.workOrder ? record.id : null,
                      compact: true,
                      margin: const EdgeInsets.only(top: 10),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Time Tracker / Checklist Summary Card
          if (record.type == OrderType.workOrder)
            TimeTrackerCard(
              startedDate: record.startedDate,
              completedDate: record.completedDate,
              actualHours: record.actualHours,
              queuedComplete: detail.queuedComplete,
            )
          else
            ChecklistSummaryCard(
              summary: deriveChecklistSummary(record.checklists),
            ),
          const SizedBox(height: 14),

          // Close action — mirrors the one at the bottom of the Tasks tab.
          // Technicians were looking for "close the work order" here first
          // and not finding it, so it's surfaced in both places now.
          CloseSection(items: checklistItems, record: record, orderKey: orderKey),
          const SizedBox(height: 14),

          // Signature section — only once the technician has actually signed
          // off (a still-open record shows nothing here, not an empty
          // section). The synthetic sign-off item no longer appears as a
          // Tasks row (see `checklist_tab.dart`); this is its only visible
          // place now, positioned right after the time-tracking/completion
          // card since a signature is itself a completion fact, matching
          // where the web shows its read-only "Signed confirmation" panel
          // relative to checklist/completion state.
          if (findSignatureItem(record.checklists) case final signature?) ...[
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    LucideIcons.penLine,
                    size: 18,
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'order_detail.signature_label'.getString(context),
                  style: const TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFF1F5F9)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SignatureImageAndCaption(item: signature),
            ),
            const SizedBox(height: 14),
          ],

          // Assignment Invite Panel if pending
          AssignmentInvitePanel(
            record: record,
            respond: ({required accept, reason}) => ref
                .read(orderDetailControllerProvider(orderKey).notifier)
                .respondToInvite(accept: accept, reason: reason),
          ),

          // Metadata Information Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFF1F5F9)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                _MetaItemRow(
                  icon: LucideIcons.mapPin,
                  label: 'order_detail.location_label'.getString(context),
                  value:
                      record.location ??
                      'order_detail.location_fallback'.getString(context),
                ),
                const Divider(height: 28, color: Color(0xFFF1F5F9)),
                _MetaItemRow(
                  icon: LucideIcons.calendar,
                  label: 'order_detail.due_date_label'.getString(context),
                  value: _dateValueFor(record, context),
                ),
                const Divider(height: 28, color: Color(0xFFF1F5F9)),
                _MetaItemRow(
                  icon: LucideIcons.user,
                  label: 'order_detail.assigned_to_label'.getString(context),
                  value:
                      record.technicianName != null &&
                          record.technicianName!.isNotEmpty
                      ? record.technicianName!
                      : 'order_detail.technician_fallback'.getString(context),
                ),
                if (record.type == OrderType.annual &&
                    record.contractValue != null) ...[
                  const Divider(height: 28, color: Color(0xFFF1F5F9)),
                  _MetaItemRow(
                    icon: LucideIcons.banknote,
                    label: 'order_detail.contract_value_label'.getString(context),
                    value: formatCurrencyFromBase(
                      record.contractValue,
                      permissions,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Description Card
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFF1F5F9)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
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
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.fileText,
                        size: 18,
                        color: Color(0xFF475569),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'order_detail.description_label'.getString(context),
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  record.description != null && record.description!.isNotEmpty
                      ? record.description!
                      : 'order_detail.description_fallback'.getString(context),
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF64748B),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),

          // Admin notes — free text an admin can set when creating the
          // record (distinct from the per-checklist-item notes a technician
          // adds while working the job, shown in the Tasks tab). Hidden
          // entirely rather than showing a fallback: most records have none.
          if (record.notes != null && record.notes!.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFF1F5F9)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 10,
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
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF1F5F9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          LucideIcons.stickyNote,
                          size: 18,
                          color: Color(0xFF475569),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'order_detail.admin_notes_label'.getString(context),
                        style: const TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    record.notes!,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: Color(0xFF64748B),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Documents section — folded into Details instead of its own tab.
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  LucideIcons.paperclip,
                  size: 18,
                  color: Color(0xFF475569),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'order_detail.tab_documents'.getString(context),
                style: const TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DocumentsTab(assetId: record.assetId),

          // Admin attachments — files an admin attached when creating the
          // record (distinct from [DocumentsTab] above, which is asset-scoped
          // documents, and from a checklist item's own attachments below).
          // Hidden entirely when empty, same as the Notes card.
          if (record.attachments.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    LucideIcons.paperclip,
                    size: 18,
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'order_detail.admin_attachments_title'.getString(context),
                  style: const TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _AdminAttachmentsList(urls: record.attachments),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static String _dateValueFor(MaintenanceRecord record, BuildContext context) {
    if (record.type == OrderType.annual) {
      final start = asDate(record.raw['startDate']);
      final end = asDate(record.raw['endDate']);
      if (start != null && end != null) {
        return '${formatDate(start)} – ${formatDate(end)}';
      }
    }
    return record.effectiveDate == null
        ? 'order_detail.date_fallback'.getString(context)
        : formatDate(record.effectiveDate!);
  }
}

class _ActionPillButton extends StatelessWidget {
  const _ActionPillButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: 0.97,
      child: Material(
        color: const Color(0xFFF0F9FF),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFBAE6FD)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: const Color(0xFF0284C7)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF0284C7),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _kImageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

/// Renders the admin-set `attachments` array as a plain list of open-able
/// rows. These are not guaranteed to be photos — an admin can attach any
/// file type — so each row opens in the in-app photo viewer only when the
/// extension says it's an image, and otherwise hands off to the system app
/// via [launchExternalUrl].
class _AdminAttachmentsList extends StatelessWidget {
  const _AdminAttachmentsList({required this.urls});

  final List<String> urls;

  static bool _isImage(String url) {
    final ext = url.split('.').last.toLowerCase().split('?').first;
    return _kImageExtensions.contains(ext);
  }

  static String _nameOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final segment = path.split('/').last;
    return segment.isEmpty ? url : segment;
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final url in urls) ...[
        _AttachmentRow(
          url: url,
          onTap: () => _isImage(url)
              ? showPhotoViewer(context, urls: [url], initial: url)
              : launchExternalUrl(url),
        ),
        if (url != urls.last) const SizedBox(height: 8),
      ],
    ],
  );
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({required this.url, required this.onTap});

  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF1F5F9)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFF0F9FF),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _AdminAttachmentsList._isImage(url)
                    ? LucideIcons.image
                    : LucideIcons.file,
                size: 17,
                color: const Color(0xFF0284C7),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _AdminAttachmentsList._nameOf(url),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              LucideIcons.chevronRight,
              size: 16,
              color: Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MetaItemRow extends StatelessWidget {
  const _MetaItemRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFFF1F5F9),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: const Color(0xFF64748B)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
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
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFF475569),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The AppBar action that opens [showOrderChatSheet]. Kept a plain icon on
/// purpose (no pill, no filled circular background — an explicit product
/// choice) but given a slow, soft "breathing" glow behind it so a technician
/// notices the AI assistant is there without it reading as a badge or alert.
///
/// The glow is a radial gradient disc, not a flat circle: it fades to fully
/// transparent at its edge, so at rest (small/faint) it barely reads as
/// anything, and at its peak (larger/brighter) it still looks like soft light
/// behind the icon rather than a button skin.
class _ChatTriggerButton extends StatefulWidget {
  const _ChatTriggerButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_ChatTriggerButton> createState() => _ChatTriggerButtonState();
}

class _ChatTriggerButtonState extends State<_ChatTriggerButton>
    with SingleTickerProviderStateMixin {
  // One slow breathe in, breathe out per ~4.4s — deliberately unhurried so it
  // reads as ambient rather than urgent.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 48,
    child: Stack(
      alignment: Alignment.center,
      children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            final t = _pulse.value;
            return Container(
              width: 30 + 12 * t,
              height: 30 + 12 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    FeColors.primary.withValues(alpha: 0.16 + 0.14 * t),
                    FeColors.primary.withValues(alpha: 0),
                  ],
                ),
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'order_detail.ask_about_order'.getString(context),
          icon: const Icon(
            LucideIcons.sparkles,
            color: Color(0xFF0F172A),
            size: 20,
          ),
          onPressed: widget.onPressed,
        ),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../domain/maintenance_record.dart';
import '../../state/invites_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../theme/app_font.dart';
import '../../widgets/dir_icon.dart';

/// Every invite the technician has not answered in one place, matching the design.
class InvitesScreen extends ConsumerWidget {
  const InvitesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(invitesControllerProvider);

    return Scaffold(
      backgroundColor: FeColors.page,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: ref.read(invitesControllerProvider.notifier).refresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Top Bar with Assignments title, subtitle, and Calendar circular action button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'invites.title'.getString(context),
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: FeColors.ink,
                          letterSpacing: context.letterSpacingFor(-0.5),
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'invites.subtitle'.getString(context),
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: FeColors.ink2,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  Material(
                    color: FeColors.panel,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => context.push(Routes.calendar),
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
                        child: const Icon(
                          LucideIcons.calendarDays,
                          size: 19,
                          color: FeColors.ink,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              invites.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: TechSpinner(),
                ),
                error: (error, _) => TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: 'invites.error_title'.getString(context),
                  subtitle: 'common.pull_down_to_retry'.getString(context),
                ),
                data: (records) => records.isEmpty
                    ? TechEmptyState(
                        icon: LucideIcons.clipboardCheck,
                        title: 'invites.empty_title'.getString(context),
                        subtitle: 'invites.empty_subtitle'.getString(context),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < records.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: StaggeredEntrance(
                                index: i,
                                child: _AssignmentCard(record: records[i]),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssignmentCard extends ConsumerStatefulWidget {
  const _AssignmentCard({required this.record});

  final MaintenanceRecord record;

  @override
  ConsumerState<_AssignmentCard> createState() => _AssignmentCardState();
}

class _AssignmentCardState extends ConsumerState<_AssignmentCard> {
  bool _responding = false;
  bool _accepting = false;

  Future<void> _respond({required bool accept, String? reason}) async {
    // Captured before the await: a successful respond() refreshes the invite
    // list and drops this record, unmounting this card mid-flight. The
    // ScaffoldMessenger is tied to the screen's Scaffold, not this card, so
    // it stays valid — grabbing it now is what lets the confirmation still
    // show after this widget is gone.
    final messenger = ScaffoldMessenger.of(context);
    final acceptedMessage = 'invites.accept_success_message'.getString(
      context,
    );
    final declinedMessage = 'invites.decline_success_message'.getString(
      context,
    );
    setState(() {
      _responding = true;
      _accepting = accept;
    });
    final message = await ref
        .read(invitesControllerProvider.notifier)
        .respond(widget.record, accept: accept, reason: reason);
    if (mounted) setState(() => _responding = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message ?? (accept ? acceptedMessage : declinedMessage),
        ),
      ),
    );
  }

  Future<void> _openDeclineDialog() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _DeclineDialog(),
    );
    if (reason != null && reason.isNotEmpty) {
      await _respond(accept: false, reason: reason);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final metadataParts = [
      if ((record.referenceId ?? '').isNotEmpty) record.referenceId!,
      record.displayLocation,
      record.displayPriority,
    ].where((s) => s.trim().isNotEmpty).toList();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            record.cardTitle,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: FeColors.ink,
              letterSpacing: context.letterSpacingFor(-0.3),
              height: 1.25,
            ),
          ),
          const SizedBox(height: 6),

          // Subtitle Metadata Line
          Text(
            metadataParts.join('  ·  '),
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 14),

          // Yellow Callout Box
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFFEF3C7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFEF3C7),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.triangleAlert,
                        size: 16,
                        color: Color(0xFFD97706),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'invites.offer_title'.getString(context),
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFD97706),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'invites.offer_description'.getString(context),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF64748B),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(
                      LucideIcons.circleDashed,
                      size: 16,
                      color: Color(0xFFD97706),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        (record.technicianName != null &&
                                record.technicianName!.isNotEmpty)
                            ? record.technicianName!
                            : 'Balaji',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF475569),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'invites.pending_badge'.getString(context),
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFD97706),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Accept & Decline Action Buttons
          Row(
            children: [
              Expanded(
                child: PressableScale(
                  scale: 0.97,
                  child: Material(
                    color: const Color(0xFF10B981),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _responding ? null : () => _respond(accept: true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        alignment: Alignment.center,
                        child: _responding && _accepting
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    LucideIcons.check,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'invites.accept_button'.getString(
                                      context,
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PressableScale(
                  scale: 0.97,
                  child: Material(
                    color: FeColors.panel,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _responding ? null : _openDeclineDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFFCA5A5)),
                        ),
                        child: _responding && !_accepting
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    Color(0xFFEF4444),
                                  ),
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    LucideIcons.x,
                                    color: Color(0xFFEF4444),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'invites.decline_button'.getString(
                                      context,
                                    ),
                                    style: const TextStyle(
                                      color: Color(0xFFEF4444),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Open the task link
          GestureDetector(
            onTap: () =>
                context.push(Routes.orderDetail(record.type.slug, record.id)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DirIcon(
                  LucideIcons.arrowRight,
                  size: 16,
                  color: Color(0xFF0284C7),
                ),
                const SizedBox(width: 8),
                Text(
                  'invites.open_task_link'.getString(context),
                  style: const TextStyle(
                    color: Color(0xFF0284C7),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeclineDialog extends StatefulWidget {
  const _DeclineDialog();

  @override
  State<_DeclineDialog> createState() => _DeclineDialogState();
}

class _DeclineDialogState extends State<_DeclineDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: FeColors.panel,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    title: Text(
      'invites.decline_dialog_title'.getString(context),
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'invites.decline_dialog_description'.getString(context),
          style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'invites.decline_reason_hint'.getString(context),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text('common.cancel'.getString(context)),
      ),
      ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: FeColors.danger,
          foregroundColor: Colors.white,
        ),
        onPressed: _controller.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop(_controller.text.trim()),
        child: Text('invites.confirm_decline_button'.getString(context)),
      ),
    ],
  );
}

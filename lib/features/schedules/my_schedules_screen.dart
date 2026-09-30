import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/conversation/conversation_links.dart';
import '../../core/network/api_exception.dart';
import '../../domain/user_schedule.dart';
import '../../state/schedules_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/tech_popup.dart';
import '../conversation/widgets/schedule_card.dart';

/// `/schedules?focus=<id>` — My schedules (orchestrator spec O3): what runs,
/// when next, how the last run went, and Pause / Resume / Delete. Created
/// from a thread ("@agent remind me every Monday at 8…"); tapping one opens
/// that thread. Online only — offline it says so and offers pull-to-retry.
class MySchedulesScreen extends ConsumerStatefulWidget {
  const MySchedulesScreen({super.key, this.focusId});
  final String? focusId;

  @override
  ConsumerState<MySchedulesScreen> createState() => _MySchedulesScreenState();
}

class _MySchedulesScreenState extends ConsumerState<MySchedulesScreen> {
  final _busy = <String>{};

  Future<void> _act(UserSchedule s, Future<ApiFailure?> Function() op) async {
    setState(() => _busy.add(s.id));
    final failure = await op();
    if (!mounted) return;
    setState(() => _busy.remove(s.id));
    if (failure != null) {
      showTechPopup(
        context,
        message: failure is NetworkFailure ? 'schedules.offline'.getString(context) : failure.message,
        isError: true,
      );
    }
  }

  Future<void> _delete(UserSchedule s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('schedules.delete_title'.getString(ctx)),
        content: Text('common.cannot_be_undone'.getString(ctx)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.cancel'.getString(ctx))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: FeColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('common.delete'.getString(ctx)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _act(s, () => ref.read(schedulesControllerProvider.notifier).delete(s));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(schedulesControllerProvider);
    final controller = ref.read(schedulesControllerProvider.notifier);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'schedules.title'.getString(context)),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: async.when(
          loading: () => const Center(child: TechSpinner()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TechEmptyState(
                icon: e is NetworkFailure ? LucideIcons.cloudOff : LucideIcons.circleAlert,
                title: e is NetworkFailure
                    ? 'schedules.offline'.getString(context)
                    : 'schedules.load_failed'.getString(context),
                subtitle: 'common.pull_down_to_retry'.getString(context),
              ),
            ],
          ),
          data: (rows) => rows.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TechEmptyState(
                      icon: LucideIcons.calendarClock,
                      title: 'schedules.empty_title'.getString(context),
                      subtitle: 'schedules.empty_subtitle'.getString(context),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final s = rows[i];
                    final origin = s.entity != null && s.entityId != null
                        ? threadRoute(s.entity!, s.entityId!, messageId: s.originMessageId)
                        : null;
                    return Container(
                      decoration: widget.focusId == s.id
                          ? BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: FeColors.ai, width: 2),
                            )
                          : null,
                      child: ScheduleCard(
                        schedule: s,
                        busy: _busy.contains(s.id),
                        onOpen: origin == null ? null : () => context.push(origin),
                        onPause: () => _act(s, () => controller.setPaused(s, true)),
                        onResume: () => _act(s, () => controller.setPaused(s, false)),
                        onDelete: () => _delete(s),
                        onRunNow: () => _act(s, () => controller.runNow(s)),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

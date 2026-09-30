import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/conversation/conversation_links.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/notification_route.dart';
import '../../domain/app_notification.dart';
import '../../state/notifications_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/motion.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Opening the list is what clears the bell. Read stays per-notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationsControllerProvider.notifier).markAllSeen();
    });
  }

  Future<void> _open(AppNotification notification) async {
    final controller = ref.read(notificationsControllerProvider.notifier);
    if (!notification.isRead) {
      await controller.markRead(notification.id);
    }
    if (!mounted) return;

    final route = routeForNotification(notification);
    if (route == null) return;
    // A tab inside the shell is switched to, not stacked on top of this
    // screen — see Routes.shellBranches.
    if (Routes.isShellBranch(route)) {
      context.go(route);
    } else {
      context.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationsControllerProvider);
    final notifications = state.valueOrNull?.notifications ?? const [];
    final anyUnread = notifications.any((n) => !n.isRead);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: 'common.notifications'.getString(context),
        actions: [
          if (anyUnread)
            TextButton.icon(
              onPressed: ref
                  .read(notificationsControllerProvider.notifier)
                  .markAllRead,
              icon: const Icon(LucideIcons.checkCheck, size: 16),
              label: AppText(
                'notifications.mark_all_read'.getString(context),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: ref.read(notificationsControllerProvider.notifier).refresh,
        child: state.when(
          loading: () => const Center(child: TechSpinner()),
          error: (error, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TechEmptyState(
                icon: LucideIcons.circleAlert,
                title: 'notifications.error_title'.getString(context),
                subtitle: 'common.pull_down_to_retry'.getString(context),
              ),
            ],
          ),
          data: (data) => data.notifications.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TechEmptyState(
                      icon: LucideIcons.bell,
                      title: 'notifications.empty_title'.getString(context),
                      subtitle: 'notifications.empty_subtitle'.getString(
                        context,
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: data.notifications.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final notification = data.notifications[index];
                    return StaggeredEntrance(
                      index: index,
                      child: _NotificationTile(
                        notification: notification,
                        onTap: () => _open(notification),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  /// The four types the server sends, each with its own colour and icon —
  /// matching the web so the two portals read the same way.
  ({Color background, Color border, Color accent, IconData icon}) get _tone {
    // Conversations and schedules (docs/conversations-and-schedules.md):
    // AI teammates in violet, people mentioning you in the brand blue.
    final family = noticeFamily(notification.entityType, category: notification.category);
    switch (family) {
      case NoticeFamily.scheduleFailed:
        return (background: FeColors.dangerSoft, border: FeColors.dangerSoft, accent: FeColors.danger, icon: LucideIcons.calendarX);
      case NoticeFamily.scheduleDone:
        return (background: FeColors.aiSoft, border: FeColors.aiSoft, accent: FeColors.ai, icon: LucideIcons.calendarCheck);
      case NoticeFamily.scheduleStarted:
        return (background: FeColors.aiSoft, border: FeColors.aiSoft, accent: FeColors.ai, icon: LucideIcons.calendarClock);
      case NoticeFamily.agentReply:
        return (background: FeColors.aiSoft, border: FeColors.aiSoft, accent: FeColors.ai, icon: LucideIcons.sparkles);
      case NoticeFamily.mention:
        return (background: FeColors.infoSoft, border: FeColors.infoSoft, accent: FeColors.primary, icon: LucideIcons.atSign);
      case NoticeFamily.conversation:
        return (background: FeColors.infoSoft, border: FeColors.infoSoft, accent: FeColors.primary, icon: LucideIcons.messageSquare);
      case NoticeFamily.other:
        break;
    }
    return switch (notification.type) {
        'warning' => (
          background: FeColors.warningSoft,
          border: FeColors.warningSoft,
          accent: FeColors.warning,
          icon: LucideIcons.circleAlert,
        ),
        'success' => (
          background: FeColors.successSoft,
          border: FeColors.successSoft,
          accent: FeColors.success,
          icon: LucideIcons.circleCheck,
        ),
        'error' => (
          background: FeColors.dangerSoft,
          border: FeColors.dangerSoft,
          accent: FeColors.danger,
          icon: LucideIcons.circleAlert,
        ),
        _ => (
          background: FeColors.infoSoft,
          border: FeColors.infoSoft,
          accent: FeColors.info,
          icon: LucideIcons.info,
        ),
      };
  }

  @override
  Widget build(BuildContext context) {
    final tone = _tone;
    final read = notification.isRead;

    return PressableScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(context.radii.xl),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              // A read notification drops back to plain white; unread keeps
              // a soft tint of the type colour, so the list can be triaged
              // at a glance without a hard outline doing the work.
              color: read ? FeColors.panel : tone.background,
              borderRadius: BorderRadius.circular(context.radii.xl),
              boxShadow: read
                  ? FeElevation.soft
                  : FeElevation.tinted(tone.accent),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 40,
                  width: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tone.accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(tone.icon, size: 18, color: tone.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: AppText.titleSmall(
                              notification.title,
                              weight: read ? FontWeight.w500 : FontWeight.w700,
                            ),
                          ),
                          if (!read)
                            Container(
                              height: 8,
                              width: 8,
                              decoration: BoxDecoration(
                                color: tone.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                      if (notification.message.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        AppText.bodySmall(
                          notification.message,
                          color: FeColors.ink2,
                        ),
                      ],
                      if (notification.createdAt != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              LucideIcons.clock,
                              size: 12,
                              color: FeColors.ink2,
                            ),
                            const SizedBox(width: 6),
                            AppText.caption(
                              formatDateTimeShort(notification.createdAt!),
                              color: FeColors.ink2,
                            ),
                          ],
                        ),
                      ],
                    ],
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

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/notifications/notice_list.dart';
import '../../core/push/push_content.dart';
import '../../core/push/push_service.dart';
import '../../core/utils/notification_route.dart';
import '../../domain/app_notification.dart';
import '../../state/notifications_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/motion.dart';
import 'notification_card.dart';
import 'notification_sheets.dart';
import 'notification_visuals.dart';

/// The bell: every notification, grouped into tabs (All, Work, Snags,
/// Permits, Messages and AI teammates, Schedules and reminders, Other) with
/// unread counts, split into Today / Earlier. Swipe right to mark read, left
/// to archive (with Undo). Each card opens its screen — or, for a type with
/// no screen here, a sheet with everything it says. Live: a new one arrives
/// over the socket (`socket_controller.dart`) and lands on top.
///
/// [initialGroup] opens a tab (a digest push), [openId] opens one
/// notification's details sheet (a tap that had nowhere else to go).
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key, this.initialGroup, this.openId});

  final String? initialGroup;
  final String? openId;

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  NoticeGroup? _group;
  bool _openedFromLink = false;

  @override
  void initState() {
    super.initState();
    _group = NoticeGroup.fromWire(widget.initialGroup);
    // Opening the list is what clears the bell. Read stays per-notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationsControllerProvider.notifier).markAllSeen();
    });
  }

  NotificationsController get _controller => ref.read(notificationsControllerProvider.notifier);

  Future<void> _open(AppNotification notification) async {
    if (!notification.isRead) {
      // Not awaited: the screen should open at once, the read lands behind it.
      _controller.markRead(notification.id);
    }
    final route = routeForNotification(notification);
    if (route == null) {
      await showNotificationDetails(context, notification, now: DateTime.now());
      return;
    }
    if (!mounted) return;
    // A tab inside the shell is switched to, not stacked on top of this
    // screen — see Routes.shellBranches.
    if (Routes.isShellBranch(route)) {
      context.go(route);
    } else {
      context.push(route);
    }
  }

  Future<void> _action(AppNotification n, PushAction action) async {
    final push = ref.read(pushServiceProvider);
    switch (action) {
      case PushAction.acceptInvite:
        _controller.markRead(n.id);
        await push.acceptInvite(n.asPushData());
      case PushAction.declineInvite:
        // A decline needs a reason, which the inbox asks for.
        context.go(Routes.invites);
      case PushAction.reply:
        await showReplySheet(context, n, send: (text) async {
          final outcome = await push.postReply(n.asPushData(), text);
          _controller.markRead(n.id);
          return outcome;
        });
      case PushAction.scan:
        context.push(Routes.scan);
      default:
        await _open(n);
    }
  }

  Future<bool> _confirmSwipe(AppNotification n, DismissDirection direction) async {
    if (direction == DismissDirection.startToEnd) {
      // Mark read keeps the card (it just loses its tint).
      await _controller.markRead(n.id);
      return false;
    }
    final messenger = ScaffoldMessenger.of(context);
    final archived = 'notifications.archived'.getString(context);
    final undo = 'notifications.undo'.getString(context);
    final failed = 'notifications.archive_failed'.getString(context);
    final ok = await _controller.archive(n.id);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: AppText(ok ? archived : failed, color: FeColors.onPrimary),
        action: ok ? SnackBarAction(label: undo, onPressed: () => _controller.unarchive(n)) : null,
      ),
    );
    // The controller already took the row out (or put it back on failure).
    return false;
  }

  void _maybeOpenFromLink(List<AppNotification> items) {
    final id = widget.openId;
    if (_openedFromLink || id == null) return;
    _openedFromLink = true;
    AppNotification? match;
    for (final n in items) {
      if (n.id == id) match = n;
    }
    if (match == null) return;
    final n = match;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.markRead(n.id);
      showNotificationDetails(context, n, now: DateTime.now());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationsControllerProvider);
    final data = state.valueOrNull;
    final counts = data?.counts ?? const <NoticeGroup, GroupCount>{};
    final visible = inGroup(data?.notifications ?? const [], _group);
    final anyUnread = visible.any((n) => !n.isRead);
    if (data != null) _maybeOpenFromLink(data.notifications);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: 'common.notifications'.getString(context),
        actions: [
          if (anyUnread)
            TextButton.icon(
              onPressed: () => _controller.markAllRead(group: _group),
              icon: const Icon(LucideIcons.checkCheck, size: 16),
              label: AppText('notifications.mark_all_read'.getString(context)),
            ),
        ],
      ),
      body: Column(
        children: [
          _GroupChips(
            selected: _group,
            counts: counts,
            totalUnread: data?.unreadTotal ?? 0,
            onSelect: (g) => setState(() => _group = g),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _controller.refresh,
              child: state.when(
                loading: () => const Center(child: TechSpinner()),
                error: (error, _) => ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TechEmptyState(
                      icon: LucideIcons.circleAlert,
                      title: 'notifications.error_title'.getString(context),
                      subtitle: 'common.pull_to_retry'.getString(context),
                    ),
                  ],
                ),
                data: (_) => visible.isEmpty ? _Empty(group: _group) : _list(context, visible),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<AppNotification> items) {
    final now = DateTime.now();
    final sections = sectioned(items, now);
    final children = <Widget>[];
    var index = 0;
    for (final s in sections) {
      children.add(Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 8, 4, 8),
        child: AppText.label(
          (s.section == NoticeSection.today ? 'notifications.section_today' : 'notifications.section_earlier')
              .getString(context),
          color: FeColors.ink2,
          weight: FontWeight.w700,
        ),
      ));
      for (final n in s.items) {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: StaggeredEntrance(
            index: index++,
            child: Dismissible(
              key: ValueKey('notice-${n.id}'),
              background: _SwipeBackground(
                icon: LucideIcons.checkCheck,
                label: 'notifications.swipe_read'.getString(context),
                color: FeColors.success,
                alignStart: true,
              ),
              secondaryBackground: _SwipeBackground(
                icon: LucideIcons.archive,
                label: 'notifications.swipe_archive'.getString(context),
                color: FeColors.ink2,
                alignStart: false,
              ),
              confirmDismiss: (direction) => _confirmSwipe(n, direction),
              child: NotificationCard(
                notification: n,
                now: now,
                onTap: () => _open(n),
                onAction: (a) => _action(n, a),
              ),
            ),
          ),
        ));
      }
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: children,
    );
  }
}

class _GroupChips extends StatelessWidget {
  const _GroupChips({
    required this.selected,
    required this.counts,
    required this.totalUnread,
    required this.onSelect,
  });

  final NoticeGroup? selected;
  final Map<NoticeGroup, GroupCount> counts;
  final int totalUnread;
  final void Function(NoticeGroup?) onSelect;

  @override
  Widget build(BuildContext context) {
    final groups = <NoticeGroup?>[null, ...NoticeGroup.values];
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final g = groups[i];
          final unread = g == null ? totalUnread : (counts[g]?.unread ?? 0);
          final total = g == null ? null : counts[g]?.total;
          final isSelected = g == selected;
          return ChoiceChip(
            selected: isSelected,
            onSelected: (_) => onSelect(g),
            showCheckmark: false,
            avatar: Icon(groupIcon(g), size: 16, color: isSelected ? FeColors.onPrimary : FeColors.ink2),
            selectedColor: FeColors.primary,
            backgroundColor: FeColors.panel,
            side: BorderSide(color: isSelected ? FeColors.primary : FeColors.line),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText(
                  groupLabel(context, g),
                  color: isSelected ? FeColors.onPrimary : (total == 0 ? FeColors.ink2 : FeColors.ink),
                  weight: FontWeight.w600,
                ),
                if (unread > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: isSelected ? FeColors.onPrimary : FeColors.danger,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: AppText.caption(
                      unread > 99 ? '99+' : '$unread',
                      color: isSelected ? FeColors.primary : FeColors.onPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.icon, required this.label, required this.color, required this.alignStart});

  final IconData icon;
  final String label;
  final Color color;
  final bool alignStart;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: alignStart ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            AppText.label(label, color: color, weight: FontWeight.w700),
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.group});

  final NoticeGroup? group;

  @override
  Widget build(BuildContext context) {
    final key = group?.wire ?? 'all';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        TechEmptyState(
          icon: group == null ? LucideIcons.bellOff : groupIcon(group),
          title: 'notifications.empty_${key}_title'.getString(context),
          subtitle: 'notifications.empty_${key}_subtitle'.getString(context),
        ),
      ],
    );
  }
}

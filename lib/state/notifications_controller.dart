import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notifications/notice_list.dart';
import '../core/push/local_notifications.dart';
import '../core/push/native_push_actions.dart';
import '../core/push/push_content.dart';
import '../domain/app_notification.dart';
import 'providers.dart';

class NotificationsState {
  const NotificationsState({
    this.notifications = const [],
    this.unseenCount = 0,
    this.serverCounts = const {},
  });

  /// The newest page (all tabs), archived rows already left out.
  final List<AppNotification> notifications;
  final int unseenCount;

  /// The server's per-tab totals (empty on an older server).
  final Map<NoticeGroup, GroupCount> serverCounts;

  /// True when the server understands `group` filters (it sent counts).
  bool get groupAware => serverCounts.isNotEmpty;

  /// Per-tab counts for the chips: the server's when it sent them (they
  /// cover more than the loaded page), else counted from what is loaded.
  Map<NoticeGroup, GroupCount> get counts => groupAware ? serverCounts : countByGroup(notifications);

  int get unreadTotal => counts.values.fold(0, (sum, c) => sum + c.unread);

  NotificationsState copyWith({
    List<AppNotification>? notifications,
    int? unseenCount,
    Map<NoticeGroup, GroupCount>? serverCounts,
  }) =>
      NotificationsState(
        notifications: notifications ?? this.notifications,
        unseenCount: unseenCount ?? this.unseenCount,
        serverCounts: serverCounts ?? this.serverCounts,
      );
}

/// The notifications list behind the bell. Loads the newest 100 across all
/// tabs (a technician's notifications are a few a day; 100 covers weeks), so
/// switching tabs is instant and offline-friendly; the chips' counts come
/// from the server and cover everything.
class NotificationsController extends AsyncNotifier<NotificationsState> {
  static const pageSize = 100;
  var _disposed = false;

  @override
  Future<NotificationsState> build() {
    ref.onDispose(() => _disposed = true);
    return _load();
  }

  Future<NotificationsState> _load() async {
    final page = await ref.read(notificationsRepositoryProvider).list(limit: pageSize);
    return NotificationsState(
      notifications: [for (final n in page.notifications) if (!n.archived) n],
      unseenCount: page.unseenCount,
      serverCounts: page.groupCounts,
    );
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(_load);
    if (_disposed) return;
    state = next;
  }

  /// Opening the list is what "seen" means — it clears the bell's count while
  /// leaving each notification unread until it is actually opened.
  Future<void> markAllSeen() async {
    // The screen asks for this on its first frame, while the list is very
    // likely still loading. Waiting for it means the badge actually clears
    // instead of silently doing nothing on the one open that matters.
    if (state.isLoading) {
      await future.catchError((_) => const NotificationsState());
    }
    final current = state.valueOrNull;
    if (current == null || current.unseenCount == 0) return;

    state = AsyncData(current.copyWith(unseenCount: 0));
    // The app icon number follows the bell.
    NativePushActions.setBadge(0);
    try {
      await ref.read(notificationsRepositoryProvider).markAllSeen();
    } catch (_) {
      // The count is cosmetic; a failed call is not worth interrupting anyone.
    }
    ref.invalidate(unseenNotificationCountProvider);
  }

  Future<void> markRead(String id) async {
    final n = _find(id);
    if (n == null || n.isRead) return;
    _replace(id, n.copyWith(isRead: true, isSeen: true), unreadDelta: -1);
    LocalNotifications.cancelFor(n.asPushData());
    try {
      await ref.read(notificationsRepositoryProvider).markRead(id);
    } catch (_) {
      await refresh();
    }
  }

  /// All read, or one tab's ([group]).
  Future<void> markAllRead({NoticeGroup? group}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    // Per tab only when the server can do per tab; an older server would
    // mark every tab read (see NotificationsRepository.markAllRead).
    final scoped = group != null && current.groupAware ? group : null;
    final next = [
      for (final n in current.notifications)
        if (scoped == null || n.group == scoped) n.copyWith(isRead: true, isSeen: true) else n,
    ];
    state = AsyncData(current.copyWith(
      notifications: next,
      serverCounts: {
        for (final e in current.serverCounts.entries)
          e.key: scoped == null || e.key == scoped ? (total: e.value.total, unread: 0) : e.value,
      },
    ));
    if (scoped == null) {
      LocalNotifications.cancelAll();
    } else {
      for (final n in current.notifications.where((n) => n.group == scoped && !n.isRead)) {
        LocalNotifications.cancelFor(n.asPushData());
      }
    }
    try {
      await ref.read(notificationsRepositoryProvider).markAllRead(group: scoped);
    } catch (_) {
      await refresh();
    }
  }

  /// Swipe away. Returns false when the server can't archive (an older
  /// server, or offline) — the row comes back and the screen says so.
  Future<bool> archive(String id) async {
    final current = state.valueOrNull;
    final n = _find(id);
    if (current == null || n == null) return false;
    state = AsyncData(current.copyWith(
      notifications: [for (final x in current.notifications) if (x.id != id) x],
      serverCounts: _adjust(current.serverCounts, n.group, total: -1, unread: n.isRead ? 0 : -1),
    ));
    LocalNotifications.cancelFor(n.asPushData());
    try {
      await ref.read(notificationsRepositoryProvider).archive(id);
      return true;
    } catch (_) {
      await refresh();
      return false;
    }
  }

  /// Undo of [archive]: put the row back where it was.
  Future<void> unarchive(AppNotification n) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final rows = [...current.notifications, n.copyWith(archived: false, isRead: true)]
      ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    state = AsyncData(current.copyWith(
      notifications: rows,
      serverCounts: _adjust(current.serverCounts, n.group, total: 1, unread: 0),
    ));
    try {
      await ref.read(notificationsRepositoryProvider).unarchive(n.id);
    } catch (_) {
      await refresh();
    }
  }

  /// A `new_notification` arriving over the socket while the app is open.
  /// Prepended rather than refetched — the payload is the whole notification
  /// (with its extras since 2026-10-10).
  void prepend(AppNotification notification) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.notifications.any((n) => n.id == notification.id)) return;

    state = AsyncData(current.copyWith(
      notifications: [notification, ...current.notifications],
      unseenCount: current.unseenCount + 1,
      serverCounts: _adjust(current.serverCounts, notification.group, total: 1, unread: notification.isRead ? 0 : 1),
    ));
  }

  AppNotification? _find(String id) {
    for (final n in state.valueOrNull?.notifications ?? const <AppNotification>[]) {
      if (n.id == id) return n;
    }
    return null;
  }

  void _replace(String id, AppNotification next, {int unreadDelta = 0}) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(
      notifications: [for (final n in current.notifications) n.id == id ? next : n],
      serverCounts: _adjust(current.serverCounts, next.group, total: 0, unread: unreadDelta),
    ));
  }

  static Map<NoticeGroup, GroupCount> _adjust(
    Map<NoticeGroup, GroupCount> counts,
    NoticeGroup group, {
    required int total,
    required int unread,
  }) {
    if (counts.isEmpty) return counts;
    final c = counts[group] ?? (total: 0, unread: 0);
    return {
      ...counts,
      group: (total: (c.total + total).clamp(0, 1 << 30), unread: (c.unread + unread).clamp(0, 1 << 30)),
    };
  }
}

final notificationsControllerProvider =
    AsyncNotifierProvider<NotificationsController, NotificationsState>(
  NotificationsController.new,
);

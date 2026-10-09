import '../core/network/api_client.dart';
import '../core/network/envelope.dart';
import '../core/push/push_content.dart';
import '../domain/app_notification.dart';

class NotificationsPage {
  const NotificationsPage({
    required this.notifications,
    required this.unseenCount,
    this.unreadCount = 0,
    this.groupCounts = const {},
  });

  final List<AppNotification> notifications;

  /// "Seen" means the bell has been opened since they arrived — distinct from
  /// "read", which means a specific notification was tapped.
  final int unseenCount;
  final int unreadCount;

  /// Per tab: total and unread (server 2026-10-10 `groupCounts`; empty on an
  /// older server, and the screen then counts what it loaded).
  final Map<NoticeGroup, ({int total, int unread})> groupCounts;
}

class NotificationsRepository {
  NotificationsRepository(this._api);

  final ApiClient _api;

  /// Newest first. [group] narrows to one tab, [unread] to unread ones.
  /// An older server ignores the filters and the extra keys (the screen
  /// then filters what it got).
  Future<NotificationsPage> list({int limit = 10, NoticeGroup? group, bool unread = false}) async {
    final response = await _api.get('/api/notifications', query: {
      'limit': limit,
      if (group != null) 'group': group.wire,
      if (unread) 'unread': 'true',
    });
    final data = unwrapMap(response.data);
    final rows = data['notifications'];
    return NotificationsPage(
      notifications: rows is List
          ? rows
              .whereType<Map>()
              .map((row) => AppNotification.fromJson(
                    Map<String, dynamic>.from(row),
                  ))
              .toList()
          : const [],
      unseenCount: asInt(data['unseenCount']) ?? 0,
      unreadCount: asInt(data['unreadCount']) ?? 0,
      groupCounts: parseGroupCounts(data['groupCounts']),
    );
  }

  static Map<NoticeGroup, ({int total, int unread})> parseGroupCounts(Object? raw) {
    if (raw is! Map) return const {};
    final out = <NoticeGroup, ({int total, int unread})>{};
    for (final g in NoticeGroup.values) {
      final v = raw[g.wire];
      if (v is Map) out[g] = (total: asInt(v['total']) ?? 0, unread: asInt(v['unread']) ?? 0);
    }
    return out;
  }

  Future<void> markAllSeen() => _api.post('/api/notifications/mark-seen');

  Future<void> markRead(String id) =>
      _api.post('/api/notifications/mark-read/$id');

  /// All read, or only one tab's ([group]). An older server ignores the
  /// filter and marks everything — the screen only offers the per-tab button
  /// when the server sent `groupCounts` (i.e. understands it).
  Future<void> markAllRead({NoticeGroup? group}) => _api.post(
        '/api/notifications/mark-read/all',
        query: group == null ? null : {'group': group.wire},
      );

  /// Hide from the list (also marks it read). Online only: a swipe is
  /// undoable and cheap to redo, not worth a queued write.
  Future<void> archive(String id) => _api.post('/api/notifications/archive/$id');

  Future<void> unarchive(String id) => _api.post('/api/notifications/unarchive/$id');

  /// Hands the device's FCM (Firebase Cloud Messaging) token to the server so
  /// it can push to this device. Called on login and on token refresh.
  Future<void> registerDevice({required String token, required String platform}) =>
      _api.post('/api/notifications/register-device', data: {
        'token': token,
        'platform': platform,
      });

  /// Best-effort on logout — stops pushes reaching a device no longer signed in.
  Future<void> unregisterDevice(String token) =>
      _api.post('/api/notifications/unregister-device', data: {'token': token});
}

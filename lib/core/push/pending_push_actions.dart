import 'package:shared_preferences/shared_preferences.dart';

/// "Mark read" pressed on a tray notification while the app wasn't running
/// (or was in the background). That button deliberately does not open the
/// app, so it runs where there is no signed-in session, no Dio client and no
/// offline queue: the Android background isolate of flutter_local_notifications,
/// or the iOS action callback in `AppDelegate.swift`. It parks the
/// notification id here, and the app sends them on its next start or resume
/// ([PushService.flushPendingReads]). The tray entry is gone at once; the
/// bell catches up when the app next runs.
///
/// iOS writes the same list natively (UserDefaults key
/// `flutter.<key>` = the shared_preferences store), see AppDelegate.swift.
class PendingPushActions {
  PendingPushActions._();

  /// shared_preferences prefixes keys with `flutter.` on disk; the iOS side
  /// writes `flutter.fe_pending_push_reads` directly, as a comma list.
  static const key = 'fe_pending_push_reads';
  static const _max = 200;

  static Future<void> addRead(String notificationId) async {
    final id = notificationId.trim();
    if (id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Another isolate (or the iOS app delegate) may have written since this
      // isolate's cache was filled.
      await prefs.reload();
      final ids = _decode(prefs.getString(key));
      if (ids.contains(id)) return;
      ids.add(id);
      await prefs.setString(key, ids.skip(ids.length > _max ? ids.length - _max : 0).join(','));
    } catch (_) {
      // Best-effort: the worst case is the row stays unread in the bell.
    }
  }

  /// Takes (and clears) everything parked.
  static Future<List<String>> takeReads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ids = _decode(prefs.getString(key));
      if (ids.isNotEmpty) await prefs.remove(key);
      return ids;
    } catch (_) {
      return const [];
    }
  }

  /// Puts back ids that could not be sent (offline), for the next try.
  static Future<void> restoreReads(List<String> ids) async {
    for (final id in ids) {
      await addRead(id);
    }
  }

  static List<String> _decode(String? raw) =>
      (raw ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

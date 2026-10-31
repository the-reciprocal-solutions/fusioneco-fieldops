import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/admin_user.dart';

/// Non-secret session data, readable synchronously so the first frame already
/// knows whether someone is signed in. Opened once in main().
class SessionStore {
  SessionStore._(this._prefs);

  static Future<SessionStore> open() async =>
      SessionStore._(await SharedPreferences.getInstance());

  static const _userKey = 'session_user';

  /// True while an admin is signed in on this phone. For the push background
  /// isolate, which has no providers; reloads because that isolate's prefs
  /// cache can be older than the main isolate's writes.
  static Future<bool> signedInOnDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs.getString(_userKey) ?? '').isNotEmpty;
  }

  final SharedPreferences _prefs;

  AdminUser? readUser() {
    final raw = _prefs.getString(_userKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? AdminUser.fromJson(json) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeUser(AdminUser user) =>
      _prefs.setString(_userKey, jsonEncode(user.toJson()));

  /// The Building Efficiency site last picked, as `connectionId|site` — the
  /// web keeps the same choice in `hvac-eff:last-site`.
  static const _effSiteKey = 'hvac-eff:last-site';

  String? readEffSite() => _prefs.getString(_effSiteKey);

  Future<void> writeEffSite(String key) => _prefs.setString(_effSiteKey, key);

  /// Sign-out: the user and their site choice (another user may sign in next).
  Future<void> clear() async {
    await _prefs.remove(_userKey);
    await _prefs.remove(_effSiteKey);
  }
}

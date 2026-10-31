import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets only. Lives in the platform keystore — iOS Keychain / Android
/// EncryptedSharedPreferences — never in prefs.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  // Own names, not FieldOps' `token` / `refresh_token`: both sides live in
  // one app now, and the technician side's background sync would otherwise
  // try to renew an admin's refresh token at /api/auth/technician-refresh.
  static const _tokenKey = 'admin_token';

  /// The server's rotating refresh token (POST /api/auth/mobile/refresh).
  /// Not cached in memory: every renewal reads the keystore afresh.
  static const _refreshTokenKey = 'admin_refresh_token';

  final FlutterSecureStorage _storage;
  String? _cachedToken;

  Future<String?> readToken() async {
    _cachedToken ??= await _storage.read(key: _tokenKey);
    return _cachedToken;
  }

  Future<void> writeToken(String token) async {
    _cachedToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> readRefreshToken() async {
    final v = await _storage.read(key: _refreshTokenKey);
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> writeRefreshToken(String token) => _storage.write(key: _refreshTokenKey, value: token);

  /// Sign-out: the access token and the refresh token.
  Future<void> clear() async {
    _cachedToken = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }
}

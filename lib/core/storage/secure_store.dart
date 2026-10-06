import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const _tokenKey = 'token';

  /// NFR-10 — one id per install, outliving any sign-out/sign-in cycle
  /// (unlike [_tokenKey], never touched by [clear]) so every check this
  /// phone ever queues or sends can be traced back to the device it came
  /// from, not just the technician who happened to be signed in.
  static const _deviceIdKey = 'device_id';

  /// FR-4.1/NFR-1 — the SQLCipher passphrase for `OfflineDb`, which holds
  /// cached assets, the mutation queue and queued photo blobs. Generated
  /// once per install and kept in the platform keystore (Android
  /// EncryptedSharedPreferences / iOS Keychain) — never in the database
  /// file itself, or on the wire, or in app code.
  static const _dbPassphraseKey = 'offline_db_passphrase';

  /// Long sessions (2026-10-06, docs/architecture.md "Session"): the
  /// server's rotating refresh token. Never cached in memory — the Android
  /// background engine has its own [SecureStore] and may rotate it, so every
  /// renewal reads the keystore afresh.
  static const _refreshTokenKey = 'refresh_token';

  /// Fallback ONLY for a server that does not issue refresh tokens yet (an
  /// older deployment answers the login without `refreshToken`): the
  /// sign-in name + password, kept in the platform keystore (iOS Keychain /
  /// Android EncryptedSharedPreferences), never in prefs or the DB, so the
  /// app can sign itself back in when the 24h token runs out. Deleted the
  /// moment a refresh token arrives, on sign-out, and when the server
  /// refuses it.
  static const _legacyLoginKey = 'legacy_login';

  final FlutterSecureStorage _storage;
  String? _cachedToken;

  Future<String?> readToken() async {
    _cachedToken ??= await _storage.read(key: _tokenKey);
    return _cachedToken;
  }

  /// Bypasses the in-memory copy — after another engine may have renewed it.
  Future<String?> readTokenFresh() async {
    _cachedToken = await _storage.read(key: _tokenKey);
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

  Future<void> writeRefreshToken(String? token) async {
    if (token == null || token.isEmpty) {
      await _storage.delete(key: _refreshTokenKey);
    } else {
      await _storage.write(key: _refreshTokenKey, value: token);
    }
  }

  Future<({String username, String password})?> readLegacyLogin() async {
    final raw = await _storage.read(key: _legacyLoginKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['u'] is String && m['p'] is String) {
        return (username: m['u'] as String, password: m['p'] as String);
      }
    } catch (_) {}
    return null;
  }

  Future<void> writeLegacyLogin(String username, String password) =>
      _storage.write(key: _legacyLoginKey, value: jsonEncode({'u': username, 'p': password}));

  Future<void> clearLegacyLogin() => _storage.delete(key: _legacyLoginKey);

  /// Anything that can renew the session without the technician typing.
  Future<bool> hasRenewalCredential() async =>
      await readRefreshToken() != null || await readLegacyLogin() != null;

  /// Returns the existing passphrase, or mints and stores a fresh 256-bit
  /// one on first launch. Losing this (a keystore wipe, an uninstall) makes
  /// the existing database file unreadable rather than silently corrupting
  /// it — `OfflineDb.open()` falling over in that case means "start a fresh
  /// queue," the same outcome as a plain uninstall already has today.
  /// FR-4.4 — read-only twin of [getOrCreateDbPassphrase] for the background
  /// sync engine, which must never create a passphrase of its own.
  Future<String?> readDbPassphrase() async {
    final existing = await _storage.read(key: _dbPassphraseKey);
    return existing == null || existing.isEmpty ? null : existing;
  }

  Future<String> getOrCreateDbPassphrase() async {
    final existing = await _storage.read(key: _dbPassphraseKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final passphrase = base64UrlEncode(bytes);
    await _storage.write(key: _dbPassphraseKey, value: passphrase);
    return passphrase;
  }

  /// Returns this install's device id, minting a fresh one on first launch.
  Future<String> getOrCreateDeviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final id = const Uuid().v4();
    await _storage.write(key: _deviceIdKey, value: id);
    return id;
  }

  /// Sign-out: the access token and everything that could renew it. The
  /// device id and the DB passphrase stay.
  Future<void> clear() async {
    _cachedToken = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _legacyLoginKey);
  }
}

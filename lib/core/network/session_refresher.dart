// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../app/env.dart';
import '../storage/secure_store.dart';

/// What one attempt to renew the session came to.
enum RenewOutcome {
  /// A new access token is in [SecureStore]; retry the request.
  renewed,

  /// The server said no (refresh token revoked/expired, password changed,
  /// account gone) or there is nothing to renew with. Only this one may end
  /// the session and show the sign-in screen.
  rejected,

  /// No answer, or the server could not decide right now (no signal, 5xx).
  /// Keep every token; the caller treats the request as offline so a write
  /// queues instead of being lost.
  unavailable,
}

/// The renewal seam [ApiClient] calls on a 401 (and before a request whose
/// access token has already run out). Tests hand in a fake.
abstract interface class SessionRenewer {
  /// Single-flight: callers that arrive while a renewal runs share it.
  Future<RenewOutcome> renew();

  /// True when there is something to renew with, so a request is worth
  /// holding back for a renewal before it is even sent.
  Future<bool> canRenew();

  /// Fires once per successful renewal (the socket reconnects with the new
  /// token).
  Stream<void> get onRenewed;
}

/// `POST` with no interceptors, so a renewal can never recurse into the 401
/// handler that asked for it. [status] null = no answer at all.
abstract interface class RenewTransport {
  Future<({int? status, Object? data})> post(String path, Map<String, dynamic> body);
}

class DioRenewTransport implements RenewTransport {
  DioRenewTransport({required String Function() baseUrl, required Future<String> Function() deviceId})
      : _baseUrl = baseUrl,
        _deviceId = deviceId;

  final String Function() _baseUrl;
  final Future<String> Function() _deviceId;
  Dio? _dio;

  @override
  Future<({int? status, Object? data})> post(String path, Map<String, dynamic> body) async {
    final dio = _dio ??= Dio(BaseOptions(
      connectTimeout: Env.connectTimeout,
      receiveTimeout: Env.receiveTimeout,
      sendTimeout: Env.receiveTimeout,
      headers: {'Content-Type': 'application/json'},
      validateStatus: (_) => true,
    ));
    dio.options.baseUrl = _baseUrl();
    try {
      final r = await dio.post<Object?>(
        path,
        data: body,
        options: Options(headers: {'X-Device-Id': await _deviceId()}),
      );
      return (status: r.statusCode, data: r.data);
    } on DioException {
      return (status: null, data: null);
    }
  }
}

/// Keeps a technician signed in until they sign out (owner, 2026-10-06:
/// "it asks for a password every time").
///
/// 1. **Refresh token** (server ≥ 2026-10-06): `POST /api/auth/technician-refresh`
///    trades the stored refresh token for a new access + refresh pair. The
///    server rotates it on every use and revokes it on sign-out.
/// 2. **Legacy fallback** (an older server that never sent a refresh token):
///    sign in again with the name + password kept in the keystore at login.
///    Removed as soon as the server issues a refresh token.
///
/// Only a definite "no" from the server is [RenewOutcome.rejected]; no signal
/// or a 5xx is [RenewOutcome.unavailable] and keeps everything.
class SessionRefresher implements SessionRenewer {
  SessionRefresher({required SecureStore store, required RenewTransport transport})
      : _store = store,
        _transport = transport;

  static const refreshPath = '/api/auth/technician-refresh';
  static const loginPath = '/api/auth/technician-login';
  static const logoutPath = '/api/auth/technician-logout';

  /// Requests that must never trigger a renewal themselves.
  static bool isAuthPath(String path) =>
      path.contains(refreshPath) || path.contains(loginPath) || path.contains(logoutPath);

  final SecureStore _store;
  final RenewTransport _transport;
  final _renewed = StreamController<void>.broadcast();
  Future<RenewOutcome>? _inflight;

  @override
  Stream<void> get onRenewed => _renewed.stream;

  @override
  Future<bool> canRenew() => _store.hasRenewalCredential();

  @override
  Future<RenewOutcome> renew() {
    final running = _inflight;
    if (running != null) return running;
    final next = _renew().whenComplete(() => _inflight = null);
    _inflight = next;
    return next;
  }

  Future<RenewOutcome> _renew() async {
    final refresh = await _store.readRefreshToken();
    if (refresh != null) {
      final r = await _transport.post(refreshPath, {'refreshToken': refresh});
      final status = r.status;
      if (status == 200) return await _accept(r.data) ? _done() : RenewOutcome.unavailable;
      if (status == 400 || status == 401 || status == 403) return RenewOutcome.rejected;
      // 404: the server lost the route (rolled back) — try the fallback.
      if (status != 404) return RenewOutcome.unavailable;
    }

    final login = await _store.readLegacyLogin();
    if (login == null) return RenewOutcome.rejected;
    final r = await _transport.post(loginPath, {
      'username': login.username,
      'password': login.password,
      'refresh': true,
    });
    final status = r.status;
    if (status == 200) return await _accept(r.data) ? _done() : RenewOutcome.unavailable;
    if (status != null && status >= 400 && status < 500) {
      // Wrong password now (changed on the web) or the account is gone.
      await _store.clearLegacyLogin();
      return RenewOutcome.rejected;
    }
    return RenewOutcome.unavailable;
  }

  RenewOutcome _done() {
    _renewed.add(null);
    return RenewOutcome.renewed;
  }

  /// Stores the new pair; false when the body is not one.
  Future<bool> _accept(Object? data) async {
    if (data is! Map) return false;
    final token = data['token']?.toString();
    if (token == null || token.isEmpty) return false;
    await _store.writeToken(token);
    final refresh = data['refreshToken']?.toString();
    if (refresh != null && refresh.isNotEmpty) {
      await _store.writeRefreshToken(refresh);
      await _store.clearLegacyLogin();
    }
    return true;
  }

  /// Best-effort server-side revoke on a manual sign-out. Never throws.
  Future<void> revoke() async {
    final refresh = await _store.readRefreshToken();
    if (refresh == null) return;
    try {
      await _transport.post(logoutPath, {'refreshToken': refresh}).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

/// Seconds until a JWT's `exp`, or null when [token] is not a JWT with one.
/// Read on the device only to renew *before* sending (never trusted for auth).
int? jwtSecondsLeft(String? token, {DateTime? now}) {
  if (token == null) return null;
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final exp = payload is Map ? payload['exp'] : null;
    if (exp is! num) return null;
    final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return exp.toInt() - nowSec;
  } catch (_) {
    return null;
  }
}

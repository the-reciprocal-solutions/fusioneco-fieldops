// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../storage/secure_store.dart';

enum RenewOutcome {
  /// A new access + refresh token pair is stored.
  renewed,

  /// The server refused the refresh token (revoked, expired, reused): sign in again.
  rejected,

  /// No answer (offline, 5xx): keep the tokens, try later.
  unavailable,
}

/// Trades the stored refresh token for a new pair at
/// `POST /api/auth/mobile/refresh` (FE-mobile.md 0.2). Same contract as
/// technician_portal's SessionRefresher, admin endpoint.
///
/// Single-flight: when several requests hit 401 at once they share one
/// renewal, because the server rotates the refresh token on every use.
class SessionRenewer {
  SessionRenewer({required SecureStore store, required String Function() baseUrl, Dio? dio})
      : _store = store,
        _baseUrl = baseUrl,
        // A bare client: no auth interceptor, so a renewal can never recurse.
        _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 20)));

  final SecureStore _store;
  final String Function() _baseUrl;
  final Dio _dio;
  Future<RenewOutcome>? _inFlight;

  Future<bool> canRenew() async => await _store.readRefreshToken() != null;

  Future<RenewOutcome> renew() => _inFlight ??= _renew().whenComplete(() => _inFlight = null);

  Future<RenewOutcome> _renew() async {
    final refreshToken = await _store.readRefreshToken();
    if (refreshToken == null) return RenewOutcome.rejected;
    try {
      final res = await _dio.post<dynamic>(
        '${_baseUrl()}/api/auth/mobile/refresh',
        data: {'refreshToken': refreshToken},
        options: Options(validateStatus: (s) => s != null),
      );
      final body = res.data;
      final status = res.statusCode ?? 0;
      if (status == 200 && body is Map && body['accessToken'] is String && body['refreshToken'] is String) {
        await _store.writeRefreshToken(body['refreshToken'] as String);
        await _store.writeToken(body['accessToken'] as String);
        return RenewOutcome.renewed;
      }
      if (status == 401) return RenewOutcome.rejected;
      return RenewOutcome.unavailable;
    } on DioException {
      return RenewOutcome.unavailable;
    }
  }
}

/// Seconds until a JWT's `exp`, or null when it can't be read.
int? jwtSecondsLeft(String? token, {DateTime? now}) {
  if (token == null) return null;
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final exp = payload is Map ? payload['exp'] : null;
    if (exp is! num) return null;
    return exp.toInt() - (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  } catch (_) {
    return null;
  }
}

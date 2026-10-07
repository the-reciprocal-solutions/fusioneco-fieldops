// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../app/env.dart';
import '../storage/secure_store.dart';
import 'api_exception.dart';
import 'session_refresher.dart';

const kMutationIdHeader = 'X-Client-Mutation-Id';

/// NFR-10 — a stable per-install id, so a queued/synced check is
/// attributable to the device it was captured on as well as the person
/// signed in at the time (the `Authorization` bearer token, which the
/// server already resolves to a technician). Read once and cached in
/// memory for the life of the client; [SecureStore.getOrCreateDeviceId]
/// mints it once per install and it outlives every sign-out.
const kDeviceIdHeader = 'X-Device-Id';

/// Marks a request already retried after a session renewal, so a second 401
/// can't loop (and isn't read as "session over" — see [ApiClient]).
const _kRenewedRetry = 'feRenewedRetry';

/// Dio wrapper carrying the two things the server cares about: a bearer token and
/// a stable mutation id for idempotent replays.
///
/// **401 = renew, not sign out** (2026-10-06, owner: "logs in automatically
/// until they manually log out"). A 401 on a request that carried a token asks
/// [SessionRenewer] for a new access token and replays the request once
/// (same body, same `X-Client-Mutation-Id`, a cloned `FormData`). Only a
/// renewal the server *refuses* fires [onSessionExpired]. A renewal that
/// can't reach the server turns the 401 into a connection error, so
/// `SyncClient` queues the write instead of losing it. A request whose token
/// has visibly run out is renewed before it is sent, so big uploads don't go
/// out twice.
class ApiClient {
  ApiClient({required SecureStore secureStore, String? baseUrl, SessionRenewer? renewer})
      : _secureStore = secureStore,
        _uuid = const Uuid() {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ?? Env.defaultApiBaseUrl,
        connectTimeout: Env.connectTimeout,
        receiveTimeout: Env.receiveTimeout,
        sendTimeout: Env.sendTimeout,
        headers: {'Content-Type': 'application/json'},
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    _renewer = renewer ??
        SessionRefresher(
          store: secureStore,
          transport: DioRenewTransport(baseUrl: () => _dio.options.baseUrl, deviceId: _deviceId),
        );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          var token = await _secureStore.readToken();
          if (_mayRenew(options) && (jwtSecondsLeft(token) ?? 1) <= 0 && await _renewer.canRenew()) {
            // Already expired: renew first rather than spend a round trip
            // (and a re-sent upload) on a certain 401. Whatever the outcome,
            // send — the 401 path below decides what it means.
            await _renewer.renew();
            token = await _secureStore.readToken();
          }
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          options.headers[kDeviceIdHeader] ??= await _deviceId();
          if (options.method != 'GET' &&
              !options.headers.containsKey(kMutationIdHeader)) {
            options.headers[kMutationIdHeader] = _uuid.v4();
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          final status = e.response?.statusCode;
          if (status == 428) _locationRequired.add(null);
          if (status != 401) return handler.next(e);

          final options = e.requestOptions;
          // The retry after a fresh renewal still got 401: that route refuses
          // this user for some other reason; the session itself is fine.
          if (options.extra[_kRenewedRetry] == true) return handler.next(e);
          if (!_mayRenew(options) || !options.headers.containsKey('Authorization')) {
            _sessionExpired.add(null);
            return handler.next(e);
          }

          switch (await _renewer.renew()) {
            case RenewOutcome.renewed:
              try {
                return handler.resolve(await _retry(options));
              } on DioException catch (again) {
                return handler.next(again);
              }
            case RenewOutcome.unavailable:
              return handler.next(DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: e.error,
                message: 'Session renewal could not reach the server',
              ));
            case RenewOutcome.rejected:
              _sessionExpired.add(null);
              return handler.next(e);
          }
        },
      ),
    );
  }

  late final Dio _dio;
  late final SessionRenewer _renewer;
  final SecureStore _secureStore;
  final Uuid _uuid;
  final _sessionExpired = StreamController<void>.broadcast();
  final _locationRequired = StreamController<void>.broadcast();
  Future<String>? _deviceIdFuture;

  bool _mayRenew(RequestOptions o) => !SessionRefresher.isAuthPath(o.path);

  Future<Response<dynamic>> _retry(RequestOptions o) {
    final data = o.data;
    return _dio.fetch<dynamic>(o.copyWith(
      // A FormData stream can be sent only once.
      data: data is FormData ? data.clone() : data,
      extra: {...o.extra, _kRenewedRetry: true},
    ));
  }

  /// Fires once per successful silent renewal (the socket reconnects with
  /// the new token).
  Stream<void> get onSessionRenewed => _renewer.onRenewed;

  /// A token that is not visibly expired — renewing first when it is and
  /// that's possible. For the few places that hand the token to something
  /// other than this client (the socket, the twin WebView).
  Future<String?> freshToken() async {
    final token = await _secureStore.readToken();
    if ((jwtSecondsLeft(token) ?? 1) > 30) return token;
    if (await _renewer.canRenew() && await _renewer.renew() == RenewOutcome.renewed) {
      return _secureStore.readToken();
    }
    return token;
  }

  /// Best-effort server-side revoke of the refresh token on a manual
  /// sign-out (before the keystore is cleared). Never throws.
  Future<void> revokeSession() async {
    final r = _renewer;
    if (r is SessionRefresher) await r.revoke();
  }

  /// Fetched (and minted, on first-ever call) once per app run, not once
  /// per request — every request after the first reuses the same in-flight
  /// or completed future instead of hitting secure storage again.
  Future<String> _deviceId() =>
      _deviceIdFuture ??= _secureStore.getOrCreateDeviceId();

  Dio get raw => _dio;
  Stream<void> get onSessionExpired => _sessionExpired.stream;

  /// Fires on every HTTP 428 (`LOCATION_REQUIRED`) — the server-side gate in
  /// `middleware/auth.ts` rejecting a mutating request because the
  /// technician's last GPS fix is stale. Mirrors `onSessionExpired`'s shape.
  Stream<void> get onLocationRequired => _locationRequired.stream;
  String get baseUrl => _dio.options.baseUrl;

  set baseUrl(String value) => _dio.options.baseUrl = value;

  String newMutationId() => _uuid.v4();

  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? receiveTimeout,
  }) =>
      _run(() => _dio.get(
            path,
            queryParameters: query,
            options: Options(receiveTimeout: receiveTimeout),
          ));

  Future<Response<dynamic>> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    String? mutationId,
    Duration? receiveTimeout,
  }) =>
      _run(() => _dio.post(
            path,
            data: data,
            queryParameters: query,
            options: _mutationOptions(mutationId, receiveTimeout),
          ));

  Future<Response<dynamic>> put(
    String path, {
    dynamic data,
    String? mutationId,
  }) =>
      _run(() => _dio.put(
            path,
            data: data,
            options: _mutationOptions(mutationId, null),
          ));

  Future<Response<dynamic>> patch(
    String path, {
    dynamic data,
    String? mutationId,
  }) =>
      _run(() => _dio.patch(
            path,
            data: data,
            options: _mutationOptions(mutationId, null),
          ));

  Future<Response<dynamic>> delete(
    String path, {
    dynamic data,
    String? mutationId,
  }) =>
      _run(() => _dio.delete(
            path,
            data: data,
            options: _mutationOptions(mutationId, null),
          ));

  Future<Response<dynamic>> request(
    String method,
    String path, {
    dynamic data,
    String? mutationId,
  }) {
    switch (method.toLowerCase()) {
      case 'post':
        return post(path, data: data, mutationId: mutationId);
      case 'put':
        return put(path, data: data, mutationId: mutationId);
      case 'patch':
        return patch(path, data: data, mutationId: mutationId);
      case 'delete':
        return delete(path, data: data, mutationId: mutationId);
      default:
        return get(path);
    }
  }

  Options _mutationOptions(String? mutationId, Duration? receiveTimeout) => Options(
        headers: mutationId == null ? null : {kMutationIdHeader: mutationId},
        receiveTimeout: receiveTimeout,
      );

  Future<Response<dynamic>> _run(Future<Response<dynamic>> Function() send) async {
    try {
      return await send();
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  void dispose() {
    _sessionExpired.close();
    _locationRequired.close();
  }
}

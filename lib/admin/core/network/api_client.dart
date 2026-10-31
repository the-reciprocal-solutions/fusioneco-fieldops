// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'dart:async';

import 'package:dio/dio.dart';

import '../../app/env.dart';
import '../storage/secure_store.dart';
import 'api_exception.dart';
import 'session_renewer.dart';

/// Marks a request already retried after a renewal, so a second 401 can't loop.
const _kRenewedRetry = 'feRenewedRetry';

/// Dio wrapper: adds the bearer token, maps errors to [ApiFailure].
///
/// **401 = renew, not sign out** (FE-mobile.md 0.2, same as technician_portal's
/// ApiClient). A 401 on a request that carried a token asks [SessionRenewer]
/// for a new access token and replays the request once. Only a renewal the
/// server *refuses* fires [onSessionExpired]. A renewal that can't reach the
/// server becomes a connection error, so the screen shows "offline" instead
/// of signing the user out. A token that has visibly run out is renewed
/// before the request is sent.
class ApiClient {
  /// [adapter] is for tests: a fake transport instead of the network.
  ApiClient({required SecureStore secureStore, String? baseUrl, SessionRenewer? renewer, HttpClientAdapter? adapter})
      : _secureStore = secureStore {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ?? Env.defaultApiBaseUrl,
        connectTimeout: Env.connectTimeout,
        receiveTimeout: Env.receiveTimeout,
        headers: {'Content-Type': 'application/json'},
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    if (adapter != null) _dio.httpClientAdapter = adapter;
    _renewer = renewer ?? SessionRenewer(store: secureStore, baseUrl: () => _dio.options.baseUrl);

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          var token = await _secureStore.readToken();
          if ((jwtSecondsLeft(token) ?? 1) <= 0 && await _renewer.canRenew()) {
            // Already expired: renew first rather than spend a round trip on a
            // certain 401. Whatever the outcome, send — onError decides.
            await _renewer.renew();
            token = await _secureStore.readToken();
          }
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          if (e.response?.statusCode != 401) return handler.next(e);
          final options = e.requestOptions;
          // The retry after a fresh renewal still got 401: that route refuses
          // this user for another reason; the session itself is fine.
          if (options.extra[_kRenewedRetry] == true) return handler.next(e);
          if (!options.headers.containsKey('Authorization')) return handler.next(e);

          switch (await _renewer.renew()) {
            case RenewOutcome.renewed:
              try {
                options.extra[_kRenewedRetry] = true;
                options.headers['Authorization'] = 'Bearer ${await _secureStore.readToken()}';
                return handler.resolve(await _dio.fetch<dynamic>(options));
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
  final _sessionExpired = StreamController<void>.broadcast();

  /// Fires when the server refuses to renew the session.
  Stream<void> get onSessionExpired => _sessionExpired.stream;

  /// Renews outside a request — the socket's handshake was refused. A refusal
  /// ends the session exactly as a refused renewal on a request does.
  Future<RenewOutcome> renewSession() async {
    final outcome = await _renewer.renew();
    if (outcome == RenewOutcome.rejected) _sessionExpired.add(null);
    return outcome;
  }

  /// The access token, renewed first if it ends within [margin]: for a web
  /// page in the app (lib/features/web/), which gets this one copy and can't
  /// renew it itself.
  Future<String?> freshToken({Duration margin = const Duration(minutes: 2)}) async {
    final token = await _secureStore.readToken();
    if ((jwtSecondsLeft(token) ?? 0) <= margin.inSeconds && await _renewer.canRenew()) {
      final outcome = await renewSession();
      if (outcome != RenewOutcome.renewed) return outcome == RenewOutcome.rejected ? null : token;
      return _secureStore.readToken();
    }
    return token;
  }

  /// The API host, for the socket (mounted at the root, not under /api).
  String get baseUrl => _dio.options.baseUrl;

  /// [timeout] overrides the receive timeout for a call known to be slow.
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) =>
      _send(() => _dio.get(path, queryParameters: query, options: timeout == null ? null : Options(receiveTimeout: timeout)));

  Future<dynamic> post(String path, {Object? body}) =>
      _send(() => _dio.post(path, data: body));

  /// `POST /api/upload/file` (multipart) → the stored file's URL.
  Future<String> uploadFile(List<int> bytes, String fileName) async {
    final res = await _send(() => _dio.post('/api/upload/file', data: FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: fileName)}), options: Options(receiveTimeout: Env.uploadTimeout)));
    final url = res is Map ? (res['data'] is Map ? res['data']['url'] : res['url']) : null;
    if (url is! String || url.isEmpty) throw const UnknownFailure("The upload didn't complete. Please try again.");
    return url;
  }

  Future<dynamic> _send(Future<Response<dynamic>> Function() call) async {
    try {
      return (await call()).data;
    } on DioException catch (e) {
      throw mapDioException(e);
    } catch (e) {
      throw UnknownFailure(e.toString());
    }
  }
}

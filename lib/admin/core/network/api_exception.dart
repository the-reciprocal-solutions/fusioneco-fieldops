import 'package:dio/dio.dart';

import '../i18n/server_text.dart';

sealed class ApiFailure implements Exception {
  const ApiFailure(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The request never reached a server (no response object).
class NetworkFailure extends ApiFailure {
  const NetworkFailure([super.message = 'No connection']);
}

/// The server answered with an error status.
class HttpFailure extends ApiFailure {
  const HttpFailure({required this.status, required String message, this.body})
      : super(message);

  final int status;
  final dynamic body;

  bool get isUnauthorized => status == 401;

  /// 402 `LICENSE_*` — the web shows its locked screen (lib/apis/config.ts).
  bool get isLicenseLocked => status == 402;

  /// 403 — outside the user's building scope or role.
  bool get isForbidden => status == 403;
}

class UnknownFailure extends ApiFailure {
  const UnknownFailure([super.message = 'Something went wrong']);
}

ApiFailure mapDioException(DioException e) {
  final response = e.response;
  if (response == null) {
    // Never Dio's own text: it is written for developers ("took longer than
    // 0:00:30.000000 … raise RequestOptions.receiveTimeout").
    return NetworkFailure(switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        serverText('error.timeout', 'The server took too long to answer. Please try again in a moment.'),
      _ => serverText('error.no_connection', 'Could not reach the server. Check your connection and try again.'),
    });
  }
  final data = response.data;
  final status = response.statusCode ?? 0;
  var message = status >= 500
      ? serverText('error.server_down', 'Server is temporarily unavailable. Please try again in a moment.')
      : serverText('error.generic', 'Something went wrong. Please try again.');

  if (data is Map) {
    final raw = data['message'] ?? data['error'];
    if (raw is String && raw.isNotEmpty) message = raw;
  } else if (data is String && data.isNotEmpty && !_looksLikeMarkup(data)) {
    message = data;
  }

  return HttpFailure(status: status, message: message, body: data);
}

/// A 502/504 from the reverse proxy answers with an HTML page — never show
/// that markup as error text.
bool _looksLikeMarkup(String data) {
  final trimmed = data.trimLeft().toLowerCase();
  return trimmed.startsWith('<!doctype') || trimmed.startsWith('<html');
}

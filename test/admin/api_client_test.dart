import 'dart:convert';
import 'dart:typed_data';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/network/api_exception.dart';
import 'package:technician_portal/admin/core/network/session_renewer.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A server in a function: (method, path, auth header) → (status, json body).
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this.handle);
  final (int, Object?) Function(String method, String path, String? auth) handle;
  final calls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    calls.add('${o.method} ${o.path}');
    final (status, json) = handle(o.method, o.path, o.headers['Authorization'] as String?);
    if (status == 0) throw DioException.connectionError(requestOptions: o, reason: 'offline');
    return ResponseBody.fromString(jsonEncode(json), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// An unsigned JWT with the given `exp` (only the payload is read).
String _jwt(int exp) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'exp': exp})}.sig';
}

final _fresh = _jwt(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600);

Future<(ApiClient, SecureStore, _FakeServer)> _client({
  required (int, Object?) Function(String auth) data,
  required (int, Object?) Function() refresh,
  String? token,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = SecureStore();
  await store.writeToken(token ?? 'old');
  await store.writeRefreshToken('r1');
  final server = _FakeServer((method, path, auth) => path.endsWith('/api/auth/mobile/refresh') ? refresh() : data(auth ?? ''));
  final renewerDio = Dio()..httpClientAdapter = server;
  final api = ApiClient(
    secureStore: store,
    baseUrl: 'http://api',
    adapter: server,
    renewer: SessionRenewer(store: store, baseUrl: () => 'http://api', dio: renewerDio),
  );
  return (api, store, server);
}

void main() {
  test('401 → renew once → replay with the new token', () async {
    final (api, store, server) = await _client(
      data: (auth) => auth == 'Bearer $_fresh' ? (200, {'ok': true}) : (401, {'message': 'expired'}),
      refresh: () => (200, {'accessToken': _fresh, 'refreshToken': 'r2'}),
    );
    expect(await api.get('/api/x'), {'ok': true});
    expect(await store.readRefreshToken(), 'r2');
    expect(server.calls, ['GET /api/x', 'POST http://api/api/auth/mobile/refresh', 'GET /api/x']);
  });

  test('refresh refused → session expired fires, the 401 surfaces', () async {
    final (api, _, _) = await _client(data: (_) => (401, {'message': 'expired'}), refresh: () => (401, {'code': 'REFRESH_REJECTED'}));
    var expired = false;
    api.onSessionExpired.listen((_) => expired = true);
    await expectLater(api.get('/api/x'), throwsA(isA<HttpFailure>().having((f) => f.status, 'status', 401)));
    await Future<void>.delayed(Duration.zero);
    expect(expired, isTrue);
  });

  test('refresh unreachable → offline error, NOT signed out', () async {
    final (api, store, _) = await _client(data: (_) => (401, {'message': 'expired'}), refresh: () => (0, null));
    var expired = false;
    api.onSessionExpired.listen((_) => expired = true);
    await expectLater(api.get('/api/x'), throwsA(isA<NetworkFailure>()));
    await Future<void>.delayed(Duration.zero);
    expect(expired, isFalse);
    expect(await store.readRefreshToken(), 'r1');
  });

  test('a second 401 after renewal is the route refusing, not the session', () async {
    final (api, _, server) = await _client(
      data: (_) => (401, {'message': 'nope'}),
      refresh: () => (200, {'accessToken': _fresh, 'refreshToken': 'r2'}),
    );
    await expectLater(api.get('/api/x'), throwsA(isA<HttpFailure>()));
    expect(server.calls.where((c) => c.contains('refresh')).length, 1);
  });

  test('an expired access token is renewed before the request goes out', () async {
    final (api, _, server) = await _client(
      token: _jwt(1000),
      data: (auth) => auth == 'Bearer $_fresh' ? (200, {'ok': true}) : (401, null),
      refresh: () => (200, {'accessToken': _fresh, 'refreshToken': 'r2'}),
    );
    expect(await api.get('/api/x'), {'ok': true});
    expect(server.calls.first, contains('refresh'));
  });

  test('concurrent 401s share one renewal (the server rotates on every use)', () async {
    var refreshes = 0;
    final (api, _, _) = await _client(
      data: (auth) => auth == 'Bearer $_fresh' ? (200, {'ok': true}) : (401, null),
      refresh: () {
        refreshes++;
        return (200, {'accessToken': _fresh, 'refreshToken': 'r$refreshes'});
      },
    );
    await Future.wait([api.get('/a'), api.get('/b'), api.get('/c')]);
    expect(refreshes, 1);
  });

  test('jwtSecondsLeft reads exp', () {
    expect(jwtSecondsLeft(_jwt(2000), now: DateTime.fromMillisecondsSinceEpoch(1000 * 1000)), 1000);
    expect(jwtSecondsLeft('not-a-jwt'), isNull);
  });
}

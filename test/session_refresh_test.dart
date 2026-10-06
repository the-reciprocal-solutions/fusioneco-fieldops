import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/network/api_client.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/network/session_refresher.dart';
import 'package:technician_portal/core/storage/secure_store.dart';

/// Long sessions (2026-10-06): a 401 renews silently and retries; only a
/// refused renewal ends the session; no signal never does.

class _FakeTransport implements RenewTransport {
  final calls = <String>[];
  final answers = <String, ({int? status, Object? data})>{};
  Completer<void>? gate;

  @override
  Future<({int? status, Object? data})> post(String path, Map<String, dynamic> body) async {
    calls.add(path);
    if (gate != null) await gate!.future;
    return answers[path] ?? (status: null, data: null);
  }
}

String _jwt({required int expInSec}) {
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expInSec;
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'id': 't1', 'exp': exp})}.sig';
}

/// Answers each request from [handler] (status, json body) and records it.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final (int, Object?) Function(RequestOptions o) handler;
  final seen = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    seen.add(o);
    final (status, data) = handler(o);
    return ResponseBody.fromString(jsonEncode(data ?? {}), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

class _FakeRenewer implements SessionRenewer {
  _FakeRenewer(this.store, this.outcome);
  final SecureStore store;
  RenewOutcome outcome;
  int calls = 0;
  final _renewed = StreamController<void>.broadcast();

  @override
  Future<bool> canRenew() async => true;

  @override
  Stream<void> get onRenewed => _renewed.stream;

  @override
  Future<RenewOutcome> renew() async {
    calls++;
    if (outcome == RenewOutcome.renewed) await store.writeToken('NEW');
    return outcome;
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('SessionRefresher', () {
    test('refresh token → new pair stored, legacy sign-in removed', () async {
      final store = SecureStore();
      await store.writeRefreshToken('ftr1.old');
      await store.writeLegacyLogin('ravi', 'pw');
      final t = _FakeTransport()
        ..answers[SessionRefresher.refreshPath] = (status: 200, data: {'token': 'A2', 'refreshToken': 'ftr1.new'});
      final r = SessionRefresher(store: store, transport: t);

      expect(await r.renew(), RenewOutcome.renewed);
      expect(await store.readToken(), 'A2');
      expect(await store.readRefreshToken(), 'ftr1.new');
      expect(await store.readLegacyLogin(), isNull);
    });

    test('server refuses the refresh token → rejected (sign in again)', () async {
      final store = SecureStore();
      await store.writeRefreshToken('ftr1.old');
      final t = _FakeTransport()..answers[SessionRefresher.refreshPath] = (status: 401, data: {'code': 'REFRESH_REJECTED'});
      expect(await SessionRefresher(store: store, transport: t).renew(), RenewOutcome.rejected);
    });

    test('no signal or a 5xx → unavailable, and the refresh token is kept', () async {
      final store = SecureStore();
      await store.writeRefreshToken('ftr1.old');
      final t = _FakeTransport();
      final r = SessionRefresher(store: store, transport: t);
      expect(await r.renew(), RenewOutcome.unavailable);
      t.answers[SessionRefresher.refreshPath] = (status: 503, data: {'code': 'REFRESH_UNAVAILABLE'});
      expect(await r.renew(), RenewOutcome.unavailable);
      expect(await store.readRefreshToken(), 'ftr1.old');
    });

    test('older server (no refresh route): signs back in with the keystore login', () async {
      final store = SecureStore();
      await store.writeLegacyLogin('ravi', 'pw');
      final t = _FakeTransport()..answers[SessionRefresher.loginPath] = (status: 200, data: {'token': 'A24h'});
      expect(await SessionRefresher(store: store, transport: t).renew(), RenewOutcome.renewed);
      expect(await store.readToken(), 'A24h');
      expect(t.calls, [SessionRefresher.loginPath]);
      expect(await store.readLegacyLogin(), isNotNull, reason: 'still no refresh token: keep it');
    });

    test('keystore login refused (password changed) → rejected and forgotten', () async {
      final store = SecureStore();
      await store.writeLegacyLogin('ravi', 'old-pw');
      final t = _FakeTransport()..answers[SessionRefresher.loginPath] = (status: 400, data: {'message': 'Invalid Credentials'});
      expect(await SessionRefresher(store: store, transport: t).renew(), RenewOutcome.rejected);
      expect(await store.readLegacyLogin(), isNull);
    });

    test('nothing to renew with → rejected without a network call', () async {
      final t = _FakeTransport();
      expect(await SessionRefresher(store: SecureStore(), transport: t).renew(), RenewOutcome.rejected);
      expect(t.calls, isEmpty);
    });

    test('concurrent 401s share one renewal', () async {
      final store = SecureStore();
      await store.writeRefreshToken('ftr1.old');
      final t = _FakeTransport()
        ..gate = Completer<void>()
        ..answers[SessionRefresher.refreshPath] = (status: 200, data: {'token': 'A2', 'refreshToken': 'ftr1.new'});
      final r = SessionRefresher(store: store, transport: t);
      final a = r.renew();
      final b = r.renew();
      t.gate!.complete();
      expect(await Future.wait([a, b]), [RenewOutcome.renewed, RenewOutcome.renewed]);
      expect(t.calls.length, 1);
    });

    test('sign-out clears the refresh token and the keystore login', () async {
      final store = SecureStore();
      await store.writeToken('A');
      await store.writeRefreshToken('ftr1.x');
      await store.writeLegacyLogin('ravi', 'pw');
      await store.clear();
      expect(await store.readTokenFresh(), isNull);
      expect(await store.hasRenewalCredential(), isFalse);
    });
  });

  group('jwtSecondsLeft', () {
    test('reads exp; null for non-JWTs', () {
      expect(jwtSecondsLeft(_jwt(expInSec: 100))! > 90, isTrue);
      expect(jwtSecondsLeft(_jwt(expInSec: -5))! < 0, isTrue);
      expect(jwtSecondsLeft('not-a-jwt'), isNull);
      expect(jwtSecondsLeft(null), isNull);
    });
  });

  group('ApiClient on 401', () {
    late SecureStore store;
    setUp(() async {
      store = SecureStore();
      await store.writeToken('OLD');
    });

    ApiClient client(_FakeRenewer renewer, _Adapter adapter) {
      final api = ApiClient(secureStore: store, baseUrl: 'http://test', renewer: renewer);
      api.raw.httpClientAdapter = adapter;
      return api;
    }

    test('renews and replays once with the new token and the SAME mutation id', () async {
      final adapter = _Adapter((o) => o.headers['Authorization'] == 'Bearer NEW' ? (200, {'ok': true}) : (401, {}));
      final renewer = _FakeRenewer(store, RenewOutcome.renewed);
      final api = client(renewer, adapter);
      var expired = 0;
      api.onSessionExpired.listen((_) => expired++);

      final res = await api.post('/api/x', data: {'a': 1}, mutationId: 'm-1');
      expect(res.data, {'ok': true});
      expect(renewer.calls, 1);
      expect(adapter.seen.length, 2);
      expect(adapter.seen.map((o) => o.headers[kMutationIdHeader]).toSet(), {'m-1'});
      await Future<void>.delayed(Duration.zero);
      expect(expired, 0, reason: 'a renewed session is not a sign-out');
    });

    test('renewal refused → HttpFailure 401 and onSessionExpired (sign-in screen)', () async {
      final api = client(_FakeRenewer(store, RenewOutcome.rejected), _Adapter((_) => (401, {})));
      var expired = 0;
      api.onSessionExpired.listen((_) => expired++);
      await expectLater(api.get('/api/x'), throwsA(isA<HttpFailure>().having((e) => e.status, 'status', 401)));
      await Future<void>.delayed(Duration.zero);
      expect(expired, 1);
    });

    test('renewal unreachable → NetworkFailure (the write queues), session kept', () async {
      final api = client(_FakeRenewer(store, RenewOutcome.unavailable), _Adapter((_) => (401, {})));
      var expired = 0;
      api.onSessionExpired.listen((_) => expired++);
      await expectLater(api.post('/api/x', data: {}), throwsA(isA<NetworkFailure>()));
      await Future<void>.delayed(Duration.zero);
      expect(expired, 0);
    });

    test('still 401 after a fresh renewal: plain error, no loop, no sign-out', () async {
      final adapter = _Adapter((_) => (401, {}));
      final renewer = _FakeRenewer(store, RenewOutcome.renewed);
      final api = client(renewer, adapter);
      var expired = 0;
      api.onSessionExpired.listen((_) => expired++);
      await expectLater(api.get('/api/x'), throwsA(isA<HttpFailure>()));
      expect(renewer.calls, 1);
      expect(adapter.seen.length, 2);
      await Future<void>.delayed(Duration.zero);
      expect(expired, 0);
    });

    test('an already-expired token is renewed before sending (no wasted upload)', () async {
      await store.writeToken(_jwt(expInSec: -60));
      final adapter = _Adapter((o) => o.headers['Authorization'] == 'Bearer NEW' ? (200, {'ok': 1}) : (401, {}));
      final renewer = _FakeRenewer(store, RenewOutcome.renewed);
      final api = client(renewer, adapter);
      await api.post('/api/upload/file', data: FormData.fromMap({'f': 'x'}));
      expect(adapter.seen.length, 1);
      expect(renewer.calls, 1);
    });

    test('a multipart upload is replayed with a fresh FormData', () async {
      final adapter = _Adapter((o) => o.headers['Authorization'] == 'Bearer NEW' ? (200, {'url': 'u'}) : (401, {}));
      final api = client(_FakeRenewer(store, RenewOutcome.renewed), adapter);
      final res = await api.post('/api/upload/image', data: FormData.fromMap({'image': MultipartFile.fromBytes([1, 2, 3], filename: 'a.jpg')}));
      expect(res.data, {'url': 'u'});
      expect(identical(adapter.seen[0].data, adapter.seen[1].data), isFalse);
    });
  });
}

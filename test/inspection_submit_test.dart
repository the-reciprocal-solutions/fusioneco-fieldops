// 2026-10-06 iPhone report "inspections are not getting submitted".
// Pins (1) the submit URL/method/payload against the server's route table,
// its location-gate exemption and the web portal's call, and (2) what the
// real SyncClient + InspectionRepository do with each server answer.
// The server, DB and connectivity are fakes (same harness as snag_outbox_test).
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/inspection/inspection_send_state.dart';
import 'package:technician_portal/core/network/api_client.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/core/offline/queue_bus.dart';
import 'package:technician_portal/core/offline/sync_client.dart';
import 'package:technician_portal/data/inspection_repository.dart';

// ---------------------------------------------------------------- fakes

class _Conn implements Connectivity {
  bool online = true;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [online ? ConnectivityResult.wifi : ConnectivityResult.none];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Handler = Object Function(String method, String path, dynamic data);

class _FakeApi implements ApiClient {
  _FakeApi(this.handler);
  _Handler handler;
  final calls = <String>[];
  final bodies = <dynamic>[];
  var _n = 0;

  @override
  String newMutationId() => 'm${++_n}';

  Future<Response<dynamic>> _do(String method, String path, dynamic data) async {
    calls.add('$method $path');
    bodies.add(data);
    final body = handler(method, path, data);
    return Response(requestOptions: RequestOptions(path: path), data: body, statusCode: 200);
  }

  @override
  Future<Response<dynamic>> get(String path, {Map<String, dynamic>? query, Duration? receiveTimeout}) =>
      _do('GET', path, null);

  @override
  Future<Response<dynamic>> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    String? mutationId,
    Duration? receiveTimeout,
  }) => _do('POST', path, data);

  @override
  Future<Response<dynamic>> request(String method, String path, {dynamic data, String? mutationId}) =>
      _do(method.toUpperCase(), path, data);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDb implements OfflineDb {
  final queue = <PendingMutation>[];
  final conflicts = <String>[];
  final meta = <String, String>{};

  @override
  Future<void> enqueue(PendingMutation m) async => queue.add(m);
  @override
  Future<List<PendingMutation>> listMutations() async => List.of(queue);
  @override
  Future<void> deleteMutation(String id) async => queue.removeWhere((m) => m.clientMutationId == id);
  @override
  Future<void> bumpAttempts(String id, int attempts) async {
    final i = queue.indexWhere((m) => m.clientMutationId == id);
    if (i < 0) return;
    final m = queue[i];
    queue[i] = PendingMutation(
      clientMutationId: m.clientMutationId,
      method: m.method,
      url: m.url,
      body: m.body,
      label: m.label,
      attempts: attempts,
      createdAt: m.createdAt,
      entityType: m.entityType,
      entityId: m.entityId,
    );
  }

  @override
  Future<bool> tryAcquireFlushLease(String owner) async => true;
  @override
  Future<void> releaseFlushLease(String owner) async {}
  @override
  Future<void> addConflict({required String label, required String url, required String reason, bool dropped = true}) async =>
      conflicts.add('$label: $reason');
  @override
  Future<CachedEntity?> readCache(String url) async => null;
  @override
  Future<void> writeCache(String url, dynamic body, Duration ttl) async {}
  @override
  Future<String?> readMeta(String key) async => meta[key];
  @override
  Future<void> writeMeta(String key, String value) async => meta[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _id = 'a1b2c3d4-0000-4000-8000-000000000001';
const _answers = <String, dynamic>{
  'pressure_ok': 'pass',
  'seal_intact': true,
  '_gpsLocation': {'latitude': 25.2, 'longitude': 55.3},
};

Never _http(int status, [Map<String, dynamic>? body]) =>
    throw HttpFailure(status: status, message: '${body?['message'] ?? 'x'}', body: body);

class _Rig {
  _Rig(_Handler handler) : api = _FakeApi(handler) {
    sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: conn);
    repo = InspectionRepository(sync);
    // Same wiring as inspectionRepositoryProvider.
    sync.onReplayed(InspectionRepository.entityType, repo.afterReplay);
    sync.onReplayFailed(InspectionRepository.entityType, repo.afterReplayFailed);
  }

  final _FakeApi api;
  final db = _FakeDb();
  final conn = _Conn();
  late final SyncClient sync;
  late final InspectionRepository repo;

  bool get queued => db.queue.any((m) => m.entityType == 'inspection' && m.entityId == _id);

  Future<InspectionSendStatus?> status({String serverStatus = 'pending'}) async => inspectionSendStatus(
    queued: queued,
    flushing: false,
    draft: await repo.readDraft(_id),
    serverStatus: serverStatus,
  );

  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

String? _read(String relative) {
  final f = File(relative);
  return f.existsSync() ? f.readAsStringSync() : null;
}

void main() {
  group('contract: URL, method and payload', () {
    test('the app posts {data: answers} to /api/fm/inspections/technician/:id/submit', () async {
      final rig = _Rig((m, p, d) => {'success': true});
      await rig.repo.submit(_id, Map.of(_answers));
      expect(rig.api.calls, ['POST /api/fm/inspections/technician/$_id/submit']);
      expect(rig.api.bodies.single, {'data': _answers});
    });

    test('the server serves that route (mount + router), and the web portal calls the same one', () {
      final routes = _read('../fusion-eco-server/src/routes/inspectionRoutes.ts');
      final index = _read('../fusion-eco-server/src/routes/index.ts');
      if (routes == null || index == null) {
        markTestSkipped('server repo not checked out next to the app');
        return;
      }
      expect(index, contains('router.use("/fm/inspections", inspectionRoutes)'));
      expect(routes, contains('router.post("/technician/:id/submit", submitMyInspectionResponse)'));
      expect(routes, contains('router.get("/technician/assigned", getMyAssignedInspections)'));
      expect(routes, contains('router.get("/technician/:id", getMyAssignmentById)'));
      expect(InspectionRepository.submitPath('X'), '/api/fm/inspections/technician/X/submit');

      final web = _read('../fusion-eco-client/app/technician/inspections/[id]/page.tsx');
      if (web != null) {
        expect(web, contains(r'`/api/fm/inspections/technician/${id}/submit`'));
        expect(web, contains('{ data }'));
      }
    });

    test('the server exempts the technician submit from the location gate (428)', () {
      final auth = _read('../fusion-eco-server/src/middleware/auth.ts');
      if (auth == null) {
        markTestSkipped('server repo not checked out next to the app');
        return;
      }
      expect(auth, contains(r'/\/fm\/inspections\/technician\/[^/]+\/submit$/'));
    });

    test('the submit controller reads the same body field and missingFields key the app uses', () {
      final ctl = _read('../fusion-eco-server/src/controllers/technicianInspectionController.ts');
      if (ctl == null) {
        markTestSkipped('server repo not checked out next to the app');
        return;
      }
      expect(ctl, contains('const { data } = req.body;'));
      expect(ctl, contains('missingFields,'));
    });
  });

  group('outcomes and queue behaviour', () {
    test('200: submitted, nothing queued, kept answers cleared', () async {
      final rig = _Rig((m, p, d) => {'success': true});
      final out = await rig.repo.submit(_id, Map.of(_answers));
      expect(out, isA<InspectionSubmitted>());
      expect(rig.db.queue, isEmpty);
      expect(await rig.repo.readDraft(_id), isNull);
      expect(await rig.status(), isNull);
    });

    test('428 (older server, stale check-in): queued, says check in, sends after check-in', () async {
      var gate = true;
      final rig = _Rig((m, p, d) => gate ? _http(428, {'code': 'LOCATION_REQUIRED'}) : {'success': true});
      final out = await rig.repo.submit(_id, Map.of(_answers));
      await rig.settle();

      expect(out, isA<InspectionQueued>());
      expect((out as InspectionQueued).status.state, InspectionSendState.waitingCheckIn);
      expect(rig.queued, isTrue, reason: 'a 428 must never drop the inspection');
      expect(rig.db.conflicts, isEmpty);
      expect((await rig.status())!.state, InspectionSendState.waitingCheckIn);
      expect((await rig.repo.readDraft(_id))!.answers, _answers);

      // CheckInController.checkIn() → flushQueue().
      gate = false;
      await rig.sync.flushQueue();
      expect(rig.queued, isFalse);
      expect(rig.api.bodies.last, {'data': _answers});
      expect(await rig.repo.readDraft(_id), isNull);
      expect(await rig.status(), isNull);
    });

    test('no signal: queued as waiting, answers kept, sends when back online', () async {
      final rig = _Rig((m, p, d) => {'success': true});
      rig.conn.online = false;
      final out = await rig.repo.submit(_id, Map.of(_answers));
      expect((out as InspectionQueued).status.state, InspectionSendState.waiting);
      expect((await rig.status())!.state, InspectionSendState.waiting);

      rig.conn.online = true;
      await rig.sync.flushQueue();
      expect(rig.queued, isFalse);
      expect(await rig.status(), isNull);
    });

    test('400 missing fields: refused with the field names, not queued, answers kept as Not sent', () async {
      final rig = _Rig(
        (m, p, d) => _http(400, {
          'message': 'Missing required field(s): Pressure gauge',
          'missingFields': ['Pressure gauge'],
        }),
      );
      final out = await rig.repo.submit(_id, Map.of(_answers));
      expect(out, isA<InspectionRefused>());
      final refused = out as InspectionRefused;
      expect(refused.reasonKey, 'inspection.send.refused_missing_fields');
      expect(refused.missing, ['Pressure gauge']);
      expect(rig.db.queue, isEmpty);
      expect((await rig.status())!.state, InspectionSendState.notSent);
      // Once the server shows it completed/expired there is nothing to flag.
      expect(await rig.status(serverStatus: 'completed'), isNull);
    });

    test('a queued submit refused on replay (409 expired) shows Not sent, never "submitted"', () async {
      var expired = false;
      final rig = _Rig((m, p, d) => expired ? _http(409, {'message': 'expired'}) : {'success': true});
      rig.conn.online = false;
      await rig.repo.submit(_id, Map.of(_answers));
      rig.conn.online = true;
      expired = true;
      await rig.sync.flushQueue();

      expect(rig.queued, isFalse);
      expect(rig.db.conflicts, hasLength(1));
      final s = (await rig.status())!;
      expect(s.state, InspectionSendState.notSent);
      expect(s.reasonKey, 'inspection.send.refused_expired');
      expect((await rig.repo.readDraft(_id))!.answers, _answers, reason: 'kept for Retry');
    });

    test('5xx: queued (not lost), retried by the queue', () async {
      var down = true;
      final rig = _Rig((m, p, d) => down ? _http(503) : {'success': true});
      final out = await rig.repo.submit(_id, Map.of(_answers));
      expect(out, isA<InspectionQueued>());
      expect(rig.queued, isTrue);

      await rig.sync.flushQueue();
      expect((await rig.status())!.state, InspectionSendState.retrying);

      down = false;
      await rig.sync.flushQueue();
      expect(rig.queued, isFalse);
      expect(await rig.status(), isNull);
    });
  });

  group('refusedReasonKey', () {
    test('plain-words keys per status', () {
      expect(refusedReasonKey(403), 'inspection.send.refused_access');
      expect(refusedReasonKey(404), 'inspection.send.refused_missing');
      expect(refusedReasonKey(410), 'inspection.send.refused_expired');
      expect(refusedReasonKey(413), 'inspection.send.refused_too_large');
      expect(refusedReasonKey(422), 'inspection.send.refused_hint');
    });

    test('every key used exists in en.json and ar.json', () {
      final en = File('assets/i18n/en.json').readAsStringSync();
      final ar = File('assets/i18n/ar.json').readAsStringSync();
      final src = File('lib/core/inspection/inspection_send_state.dart').readAsStringSync() +
          File('lib/data/inspection_repository.dart').readAsStringSync() +
          File('lib/features/inspection/inspection_form_screen.dart').readAsStringSync();
      final keys = RegExp(r"'(inspection\.[a-z_.]+)'").allMatches(src).map((m) => m.group(1)!).toSet();
      expect(keys, isNotEmpty);
      for (final k in keys) {
        expect(en, contains('"$k"'), reason: 'en.json missing $k');
        expect(ar, contains('"$k"'), reason: 'ar.json missing $k');
      }
    });
  });
}

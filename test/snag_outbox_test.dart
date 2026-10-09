// End-to-end (in memory) proof of the 2026-10-06 snag save fix: raise →
// outbox → flush → server → confirmed copy back on the phone, plus the
// failure paths that used to strand a snag as "saved on this phone" forever.
// Real SyncClient + SnagRepository; the server, DB and connectivity are fakes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/capture/capture_services.dart';
import 'package:technician_portal/core/network/api_client.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/offline/flush_policy.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/core/offline/queue_bus.dart';
import 'package:technician_portal/core/offline/sync_client.dart';
import 'package:technician_portal/core/snag/snag_media.dart';
import 'package:technician_portal/core/snag/snag_send_state.dart';
import 'package:technician_portal/data/snag_repository.dart';
import 'package:technician_portal/domain/snag.dart';

// ---------------------------------------------------------------- fakes

class _Online implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Handler = Object Function(String method, String path, dynamic data, Map<String, dynamic>? query);

/// The server. [handler] returns a body (2xx) or throws an [ApiFailure].
class _FakeApi implements ApiClient {
  _FakeApi(this.handler);
  _Handler handler;
  final calls = <String>[];
  final queries = <Map<String, dynamic>?>[];
  var _n = 0;

  @override
  String newMutationId() => 'm${++_n}';

  Future<Response<dynamic>> _do(String method, String path, dynamic data, [Map<String, dynamic>? query]) async {
    calls.add('$method $path');
    queries.add(query);
    final body = handler(method, path, data, query);
    return Response(requestOptions: RequestOptions(path: path), data: body, statusCode: 200);
  }

  @override
  Future<Response<dynamic>> get(String path, {Map<String, dynamic>? query, Duration? receiveTimeout}) =>
      _do('GET', path, null, query);

  @override
  Future<Response<dynamic>> post(
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    String? mutationId,
    Duration? receiveTimeout,
  }) => _do('POST', path, data, query);

  @override
  Future<Response<dynamic>> request(String method, String path, {dynamic data, String? mutationId}) =>
      _do(method.toUpperCase(), path, data);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDb implements OfflineDb {
  final queue = <PendingMutation>[];
  final conflicts = <String>[];
  final snags = <String, StoredSnagRow>{};
  final surveys = <String, Map<String, dynamic>>{};
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
      attachments: m.attachments,
      entityType: m.entityType,
      entityId: m.entityId,
    );
  }

  @override
  Future<void> updateMutationAttachments(String id, List<PendingAttachment> attachments) async {
    final i = queue.indexWhere((m) => m.clientMutationId == id);
    final m = queue[i];
    queue[i] = PendingMutation(
      clientMutationId: m.clientMutationId,
      method: m.method,
      url: m.url,
      body: m.body,
      label: m.label,
      attempts: m.attempts,
      createdAt: m.createdAt,
      attachments: attachments,
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
  Future<Set<String>> pendingEntityIds(String entityType) async =>
      {for (final m in queue) if (m.entityType == entityType && m.entityId != null) m.entityId!};

  @override
  Future<void> upsertSnag({
    required String id,
    required Map<String, dynamic> json,
    String? buildingId,
    String? surveyId,
    required String status,
    required bool localOnly,
    required DateTime updatedAt,
  }) async => snags[id] = StoredSnagRow(id: id, json: jsonDecode(jsonEncode(json)) as Map<String, dynamic>, localOnly: localOnly);

  @override
  Future<void> upsertSnags(List<SnagRowWrite> rows) async {
    for (final r in rows) {
      await upsertSnag(id: r.id, json: r.json, status: r.status, localOnly: r.localOnly, updatedAt: r.updatedAt);
    }
  }

  @override
  Future<StoredSnagRow?> getSnag(String id) async => snags[id];
  @override
  Future<List<StoredSnagRow>> listSnags({String? buildingId}) async =>
      snags.values.where((r) => buildingId == null || r.json['buildingId'] == buildingId).toList();
  @override
  Future<void> pruneSnags({required String buildingId, required Set<String> keepIds}) async => snags.removeWhere(
    (id, r) => !r.localOnly && r.json['buildingId'] == buildingId && !keepIds.contains(id),
  );
  @override
  Future<void> upsertSurvey({
    required String id,
    required Map<String, dynamic> json,
    String? buildingId,
    required bool localOnly,
    required DateTime updatedAt,
  }) async => surveys[id] = json;
  @override
  Future<Map<String, dynamic>?> getSurvey(String id) async => surveys[id];
  @override
  Future<List<Map<String, dynamic>>> listSurveys({String? buildingId}) async => surveys.values.toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------- helpers

const _building = '11111111-1111-4111-8111-111111111111';
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

Map<String, dynamic> _serverSnag(Map<String, dynamic> body, {String ref = 'SN-00001'}) => {
  'id': body['id'],
  'reference': ref,
  'number': 1,
  'context': body['context'],
  'trade': body['trade'],
  'priority': body['priority'],
  'title': body['title'],
  'status': 'open',
  'buildingId': body['buildingId'],
  'evidence': body['evidence'],
  'activity': [
    {'id': 'a1', 'type': 'raised', 'at': '2026-10-06T10:00:00Z', 'by': 'u1'},
  ],
  'createdAt': '2026-10-06T10:00:00Z',
  'updatedAt': '2026-10-06T10:00:00Z',
};

class _Rig {
  _Rig(_Handler handler, Directory root) : api = _FakeApi(handler) {
    sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: _Online());
    repo = SnagRepository(sync: sync, api: api, store: db, media: SnagMedia(rootDir: root));
    // Same wiring as snagRepositoryProvider.
    sync.onReplayed(SnagRepository.entityType, repo.afterReplay);
    sync.onReplayFailed(SnagRepository.entityType, repo.afterReplayFailed);
  }

  final _FakeApi api;
  final db = _FakeDb();
  late final SyncClient sync;
  late final SnagRepository repo;

  /// Lets the background flush started by queueRequest run to the end.
  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<Snag> raise({List<SnagRegion> regions = const []}) async {
    final r = await repo.raise(
      SnagDraft(
        id: '22222222-2222-4222-8222-222222222222',
        context: SnagContext.operations,
        trade: 'plumbing',
        priority: SnagPriority.major,
        title: 'Leak under basin',
        buildingId: _building,
        photos: [CapturedPhoto(bytes: _jpeg, fileName: 'image_picker_1.heic')],
        photoRegions: regions,
      ),
      const SnagActor(id: 'u1', name: 'Tech'),
    );
    expect(r.synced, isFalse, reason: 'outbox first: save never waits on the network');
    return r.snag;
  }

  Future<Snag> local(String id) async => (await repo.localById(id))!;
}

Object _ok(String method, String path, dynamic data, Map<String, dynamic>? query, Map<String, Map<String, dynamic>> server) {
  if (path == '/api/upload/image') {
    return {'data': {'url': 'https://files.example/snag.jpg'}};
  }
  if (method == 'POST' && path == '/api/snags') {
    final body = Map<String, dynamic>.from(data as Map);
    server[body['id'] as String] = _serverSnag(body);
    return {'success': true, 'data': server[body['id']]};
  }
  if (method == 'GET' && path.startsWith('/api/snags/')) {
    final id = path.split('/').last;
    final s = server[id];
    if (s == null) throw const HttpFailure(status: 404, message: 'Snag not found.');
    return {'success': true, 'data': s};
  }
  throw StateError('unexpected $method $path');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('snag_outbox'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('kept defect highlights travel on the first photo and survive the server round trip', () async {
    final server = <String, Map<String, dynamic>>{};
    final bodies = <Map<String, dynamic>>[];
    final rig = _Rig((m, p, d, q) {
      if (m == 'POST' && p == '/api/snags') bodies.add(Map<String, dynamic>.from(d as Map));
      return _ok(m, p, d, q, server);
    }, tmp);
    const kept = SnagRegion(x: 0.2, y: 0.3, w: 0.25, h: 0.2, label: 'damage', severity: SnagPriority.major);
    final draft = await rig.raise(regions: const [kept]);
    expect((await rig.local(draft.id)).evidence.single.regions, [kept], reason: 'on the phone at once');
    await rig.settle();
    final wire = (bodies.single['evidence'] as List).single as Map;
    expect(wire['regions'], [
      {'x': 0.2, 'y': 0.3, 'w': 0.25, 'h': 0.2, 'label': 'damage', 'severity': 'major'},
    ]);
    expect((await rig.local(draft.id)).evidence.single.regions, [kept], reason: 'the server copy keeps them');
  });

  test('every snag entity type is kept on a server failure', () {
    expect(kKeepOnServerErrorEntityTypes, containsAll([SnagRepository.entityType, SnagRepository.surveyEntityType]));
  });

  test('raise → queued at once → flush → server copy replaces "waiting to send"', () async {
    final server = <String, Map<String, dynamic>>{};
    final rig = _Rig((m, p, d, q) => _ok(m, p, d, q, server), tmp);
    final draft = await rig.raise();
    // Saved locally first, with its photo on disk (named by its real bytes).
    final before = await rig.local(draft.id);
    expect(before.localOnly, isTrue);
    expect(File(before.evidence.single.localPath!).existsSync(), isTrue);

    await rig.settle();
    expect(rig.db.queue, isEmpty);
    expect(rig.api.calls, containsAllInOrder(['POST /api/upload/image', 'POST /api/snags', 'GET /api/snags/${draft.id}']));
    final after = await rig.local(draft.id);
    expect(after.localOnly, isFalse, reason: 'afterReplay confirmed it — no hub pull needed');
    expect(after.reference, 'SN-00001');
    expect(after.evidence.single.url, 'https://files.example/snag.jpg');
    expect(after.evidence.single.localPath, before.evidence.single.localPath, reason: 'own photo stays usable offline');
    expect(snagSendStatus(after, queued: false, flushing: false).state, SnagSendState.synced);
  });

  test('503 SNAG_ENGINE_NOT_ENABLED (older server) is never dropped, reads as "keeps trying", sends once enabled', () async {
    final server = <String, Map<String, dynamic>>{};
    var enabled = false;
    final rig = _Rig((m, p, d, q) {
      if (m == 'POST' && p == '/api/snags' && !enabled) {
        throw const HttpFailure(
          status: 503,
          message: 'Snag storage is not enabled on this server yet.',
          body: {'code': 'SNAG_ENGINE_NOT_ENABLED'},
        );
      }
      return _ok(m, p, d, q, server);
    }, tmp);
    final draft = await rig.raise();
    await rig.settle();
    // Well past the old 5-attempt budget (≈100 s of polls).
    for (var i = 0; i < 8; i++) {
      await rig.sync.flushQueue();
    }
    expect(rig.db.queue, hasLength(1), reason: 'kept, not moved to the conflict log');
    expect(rig.db.conflicts, isEmpty);
    expect(rig.api.calls.where((c) => c == 'POST /api/upload/image'), hasLength(1), reason: 'photo uploaded once');
    final waiting = await rig.local(draft.id);
    expect(waiting.sendIssue?.status, 503);
    final status = snagSendStatus(waiting, queued: true, flushing: false);
    expect(status.state, SnagSendState.retrying);
    expect(status.reasonKey, 'snags.send.retrying_hint', reason: 'never "not switched on for your site"');

    enabled = true;
    await rig.sync.flushQueue();
    await rig.settle();
    final sent = await rig.local(draft.id);
    expect(sent.localOnly, isFalse);
    expect(sent.sendIssue, isNull);
  });

  test('a 4xx refusal is dropped, shown as Not sent, and Retry re-sends from the photo on disk', () async {
    final server = <String, Map<String, dynamic>>{};
    var refuse = true;
    final rig = _Rig((m, p, d, q) {
      if (m == 'POST' && p == '/api/snags' && refuse) {
        throw const HttpFailure(status: 403, message: 'OUTSIDE_BUILDING_SCOPE', body: {'code': 'OUTSIDE_BUILDING_SCOPE'});
      }
      return _ok(m, p, d, q, server);
    }, tmp);
    final draft = await rig.raise();
    await rig.settle();
    expect(rig.db.queue, isEmpty);
    expect(rig.db.conflicts, hasLength(1));
    final refused = await rig.local(draft.id);
    final status = snagSendStatus(refused, queued: false, flushing: false);
    expect(status.state, SnagSendState.notSent);
    expect(status.reasonKey, 'snags.send.refused_access');
    // resendStranded must not loop a refused snag through the conflict log.
    expect(await rig.repo.resendStranded(buildingId: _building), 0);

    refuse = false;
    await rig.repo.retrySend(refused);
    await rig.settle();
    final sent = await rig.local(draft.id);
    expect(sent.localOnly, isFalse);
    expect(sent.reference, 'SN-00001');
    expect(rig.api.calls.where((c) => c == 'POST /api/upload/image'), hasLength(2), reason: 're-read from disk');
  });

  test('an upload answered without a URL no longer aborts the whole flush', () async {
    final server = <String, Map<String, dynamic>>{};
    var broken = true;
    final rig = _Rig((m, p, d, q) {
      if (p == '/api/upload/image' && broken) return {'data': {}};
      return _ok(m, p, d, q, server);
    }, tmp);
    final draft = await rig.raise();
    await rig.settle();
    await expectLater(rig.sync.flushQueue(), completes);
    expect(rig.db.queue, hasLength(1));
    expect((await rig.local(draft.id)).sendIssue?.status, 0);
    broken = false;
    await rig.sync.flushQueue();
    await rig.settle();
    expect((await rig.local(draft.id)).localOnly, isFalse);
  });

  test('refresh: lean full pull keeps the local timeline, then pulls only changes', () async {
    final rig = _Rig((m, p, d, q) {
      if (p == '/api/snags' && m == 'GET') {
        return {
          'success': true,
          'data': {
            'items': [
              {
                'id': '33333333-3333-4333-8333-333333333333',
                'buildingId': _building,
                'title': 'Door closer missing',
                'trade': 'doors-windows',
                'priority': 'minor',
                'status': 'open',
                'updatedAt': '2026-10-06T10:00:00Z',
              },
            ],
            'total': 1,
            'view': 'list',
            'serverTime': '2026-10-06T10:05:00.000Z',
          },
        };
      }
      throw StateError('unexpected $m $p');
    }, tmp);
    await rig.db.upsertSnag(
      id: '33333333-3333-4333-8333-333333333333',
      json: {
        'id': '33333333-3333-4333-8333-333333333333',
        'buildingId': _building,
        'title': 'old',
        'activity': [
          {'id': 'a1', 'type': 'raised', 'at': '2026-10-05T10:00:00Z'},
        ],
      },
      status: 'open',
      localOnly: false,
      updatedAt: DateTime(2026),
    );
    // The list query (a full pull may follow it with repair reads of single
    // snags, 2026-10-10).
    Map<String, dynamic> listQuery() => rig.api.queries[rig.api.calls.lastIndexOf('GET /api/snags')]!;
    expect(await rig.repo.refresh(buildingId: _building), isTrue);
    expect(listQuery()['view'], 'list');
    expect(listQuery().containsKey('updatedSince'), isFalse);
    final s = await rig.local('33333333-3333-4333-8333-333333333333');
    expect(s.title, 'Door closer missing');
    expect(s.activity, hasLength(1), reason: 'lean rows carry no activity; the local timeline stays');

    await rig.repo.refresh(buildingId: _building);
    expect(listQuery()['updatedSince'], '2026-10-06T10:03:00.000Z', reason: 'server clock − 2 min overlap');
  });

  group('pure helpers', () {
    test('photo extension follows the bytes, not the picker name', () {
      expect(SnagRepository.photoExtension(_jpeg, 'heic'), 'jpg');
      expect(SnagRepository.photoExtension(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0]), 'jpg'), 'png');
      expect(SnagRepository.photoExtension(Uint8List.fromList([1, 2, 3]), 'heic'), 'heic');
    });

    test('iOS container move: a stored absolute path is re-rooted on snag_media/', () {
      const old = '/var/mobile/Containers/Data/Application/AAAA-1111/Documents/snag_media/own/s1/e1.jpg';
      const now = '/var/mobile/Containers/Data/Application/BBBB-2222/Documents/snag_media';
      expect(SnagMedia.reroot(old, now), '$now/own/s1/e1.jpg');
      expect(SnagMedia.reroot('/tmp/elsewhere/x.jpg', now), isNull);
    });

    test('ownFile finds a capture after the container moved', () async {
      final root = Directory('${tmp.path}/new/snag_media')..createSync(recursive: true);
      File('${root.path}/own/s1/e1.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_jpeg);
      final media = SnagMedia(rootDir: root);
      final f = await media.ownFile('/var/mobile/OLD-UUID/Documents/snag_media/own/s1/e1.jpg');
      expect(f, isNotNull);
      expect(f!.readAsBytesSync(), _jpeg);
    });

    test('mergeServerCopy clears the send issue and keeps own photo paths', () {
      final local = Snag(
        id: 'x',
        context: SnagContext.operations,
        issueType: 'defect',
        trade: 'civil',
        priority: SnagPriority.minor,
        title: 't',
        status: SnagStatus.open,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        evidence: [
          SnagEvidence(id: 'e1', kind: 'photo', stage: 'before', capturedAt: DateTime(2026), localPath: '/p/e1.jpg'),
        ],
        localOnly: true,
        sendIssue: SnagSendIssue(status: 503, at: DateTime(2026)),
      );
      final server = Snag.fromJson({
        'id': 'x',
        'title': 't',
        'evidence': [
          {'id': 'e1', 'kind': 'photo', 'stage': 'before', 'url': 'https://f/e1.jpg'},
        ],
      });
      final merged = SnagRepository.mergeServerCopy(server, local);
      expect(merged.localOnly, isFalse);
      expect(merged.sendIssue, isNull);
      expect(merged.evidence.single.localPath, '/p/e1.jpg');
    });
  });
}

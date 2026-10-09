// Shared in-memory rig for the snag integrity tests (2026-10-10): a real
// SyncClient + SnagRepository over a fake server, DB and connectivity —
// the same shape as snag_outbox_test.dart's private fakes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:technician_portal/core/network/api_client.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/core/offline/queue_bus.dart';
import 'package:technician_portal/core/offline/sync_client.dart';
import 'package:technician_portal/core/snag/snag_media.dart';
import 'package:technician_portal/data/snag_repository.dart';
import 'package:technician_portal/domain/snag.dart';

class RigOnline implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef RigHandler = Object Function(String method, String path, dynamic data, Map<String, dynamic>? query);

class RigApi implements ApiClient {
  RigApi(this.handler);
  RigHandler handler;
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

class RigDb implements OfflineDb {
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
  Future<void> bumpAttempts(String id, int attempts) async {}
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

const rigBuilding = '11111111-1111-4111-8111-111111111111';
const rigMe = SnagActor(id: 'me', name: 'Tech');
final rigJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

class SnagRig {
  SnagRig(RigHandler handler, this.root) : api = RigApi(handler) {
    sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: RigOnline());
    repo = SnagRepository(sync: sync, api: api, store: db, media: SnagMedia(rootDir: Directory('${root.path}/snag_media')));
    // Same wiring as snagRepositoryProvider.
    sync.onReplayed(SnagRepository.entityType, repo.afterReplay);
    sync.onReplayFailed(SnagRepository.entityType, repo.afterReplayFailed);
  }

  final Directory root;
  final RigApi api;
  final db = RigDb();
  late final SyncClient sync;
  late final SnagRepository repo;

  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> put(Snag s) => db.upsertSnag(
    id: s.id,
    json: s.toJson(),
    buildingId: s.buildingId,
    status: s.status.wire,
    localOnly: s.localOnly,
    updatedAt: s.updatedAt,
  );

  Future<Snag?> local(String id) => repo.localById(id);
}

SnagEvidence rigPhoto(String id, {String stage = 'before', String? url, String? localPath, String? by = 'someone'}) =>
    SnagEvidence(id: id, kind: 'photo', stage: stage, capturedAt: DateTime.utc(2026, 10, 9), url: url, localPath: localPath, capturedBy: by);

Snag rigSnag({
  String id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  SnagStatus status = SnagStatus.open,
  String trade = 'electrical',
  String issueType = 'defect',
  String title = 'Electrical defect',
  String? surveyId = 'walk-1',
  String? raisedBy = 'me',
  String? reference = 'SN-00007',
  String? locationLabel = 'Tower A › L1 › Room 101',
  List<SnagEvidence> evidence = const [],
  List<SnagActivity> activity = const [],
  bool localOnly = false,
  SnagSendIssue? sendIssue,
}) => Snag(
  id: id,
  reference: reference,
  number: reference == null ? null : 7,
  context: SnagContext.fmTakeover,
  issueType: issueType,
  trade: trade,
  priority: SnagPriority.minor,
  title: title,
  status: status,
  buildingId: rigBuilding,
  floorId: 'f1',
  spaceId: 'r1',
  locationLabel: locationLabel,
  surveyId: surveyId,
  raisedBy: raisedBy,
  evidence: evidence,
  activity: activity,
  createdAt: DateTime.utc(2026, 10, 9),
  updatedAt: DateTime.utc(2026, 10, 9),
  localOnly: localOnly,
  sendIssue: sendIssue,
);

/// A server list response.
Map<String, dynamic> rigList(List<Map<String, dynamic>> items, {String? serverTime, bool lean = true}) => {
  'success': true,
  'data': {
    'items': items,
    'total': items.length,
    if (lean) 'view': 'list',
    'serverTime': ?serverTime,
  },
};

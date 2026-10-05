// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../core/capture/capture_services.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../core/network/envelope.dart';
import '../core/offline/flush_policy.dart';
import '../core/offline/offline_db.dart';
import '../core/offline/sync_client.dart';
import '../core/snag/snag_media.dart';
import '../core/snag/snag_rules.dart';
import '../domain/snag.dart';
import '../domain/snag_ai.dart';

/// Who is acting. Technicians sign in with role `Technician`; the server
/// reads the real role off the JWT, this copy only drives the local rules.
class SnagActor {
  const SnagActor({required this.id, required this.name, this.role = 'Technician'});
  final String id;
  final String name;
  final String role;
}

/// Everything needed to raise one snag.
class SnagDraft {
  SnagDraft({
    required this.id,
    required this.context,
    required this.trade,
    required this.priority,
    this.issueType = 'defect',
    this.title,
    this.description,
    this.buildingId,
    this.floorId,
    this.spaceId,
    this.locationLabel,
    this.locationText,
    this.pin,
    this.assetId,
    this.assetName,
    this.assetReferenceId,
    this.surveyId,
    this.workOrderId,
    this.responsibleParty,
    this.dueDate,
    this.photos = const [],
    this.voice,
    this.lat,
    this.lng,
  });

  final String id;
  final SnagContext context;
  final String trade;
  final SnagPriority priority;
  final String issueType;
  final String? title;
  final String? description;
  final String? buildingId;
  final String? floorId;
  final String? spaceId;
  final String? locationLabel;
  final String? locationText;
  final SnagPin? pin;
  final String? assetId;
  final String? assetName;
  final String? assetReferenceId;
  final String? surveyId;
  final String? workOrderId;
  final String? responsibleParty;
  final DateTime? dueDate;
  final List<CapturedPhoto> photos;
  final VoiceRecording? voice;
  final double? lat;
  final double? lng;

  SnagDraftSignature signature({String? raisedBy}) => SnagDraftSignature(
    trade: trade,
    buildingId: buildingId,
    floorId: floorId,
    spaceId: spaceId,
    assetId: assetId,
    issueType: issueType,
    title: title,
    pin: pin,
    surveyId: surveyId,
    raisedBy: raisedBy,
  );
}

class SnagWriteResult {
  const SnagWriteResult({required this.snag, required this.synced});
  final Snag snag;

  /// false = saved on the device and queued; it syncs on its own.
  final bool synced;
}

/// A local rule refused the action before anything was written.
class SnagRuleException implements Exception {
  const SnagRuleException(this.failure);
  final SnagTransitionFailure failure;
  @override
  String toString() => failure.message;
}

/// Snag Assistant data access (docs/snag-assistant.md §6).
///
/// **Local first, outbox first.** Every write lands in [SnagStore] before any
/// network call, so the UI is instant in a basement. Raising a snag, adding
/// photos and survey writes then go straight into the offline queue
/// ([SyncClient.queueRequest]) and a flush starts in the background — save
/// never waits on an upload (2026-10-06; before, an online save held the
/// screen through upload + POST, and any non-5xx failure on that inline path
/// left the snag on the phone with nothing queued). Transitions stay
/// online-first through [SyncClient.syncRequest] (`queueOnServerError: true`)
/// because a refusal such as `409 SELF_VERIFY` must be seen at once. Snag
/// writes are never dropped for a server failure: `Snag`/`SnagSurvey` are in
/// [kKeepOnServerErrorEntityTypes], so a `503 SNAG_ENGINE_NOT_ENABLED` keeps
/// retrying instead of reaching the conflict log after five polls.
///
/// **Confirmed after replay.** [afterReplay] (registered with
/// [SyncClient.onReplayed]) reads the server's copy as soon as a queued write
/// syncs, so "waiting to send" turns into the server's `SN-` number in about
/// a second — before, the row kept `localOnly` until the hub happened to pull
/// that building again. [afterReplayFailed] records why a send failed
/// ([SnagSendIssue]) for the screens to say in plain words.
///
/// **Merge on read.** [refresh] overwrites a local snag with the server's
/// copy unless a write for it is still queued (then the device is ahead).
/// A server rejection of a queued write goes to the conflict log through the
/// flush policy, the write leaves the queue, and the next refresh restores
/// the server's truth — the local optimistic state never wins for long.
///
/// **Self-heal.** A create that exhausted its retries (the server was down
/// or not yet enabled for longer than the retry budget) leaves a snag that is
/// still `localOnly` with nothing queued. [resendStranded] finds those and
/// queues them again once `GET /api/snags/engine` says the server can take them.
class SnagRepository {
  SnagRepository({
    required SyncClient sync,
    required ApiClient api,
    required SnagStore store,
    required SnagMedia media,
    Uuid? uuid,
  }) : _sync = sync,
       _api = api,
       _store = store,
       _media = media,
       _uuid = uuid ?? const Uuid();

  final SyncClient _sync;
  final ApiClient _api;
  final SnagStore _store;
  final SnagMedia _media;
  final Uuid _uuid;

  static const entityType = 'Snag';
  static const surveyEntityType = 'SnagSurvey';

  /// Building lists and trees change rarely and a walk can run for days
  /// offline, so they outlive the 24h default cache.
  static const _locationTtl = Duration(days: 30);

  SnagMedia get media => _media;

  String newId() => _uuid.v4();

  // -------------------------------------------------------------------------
  // Locations
  // -------------------------------------------------------------------------

  /// Cache first: a cached list paints at once and is re-checked in the
  /// background; [onStale] fires only when the server's copy differs. Before
  /// (2026-10-06) `syncGet` went to the network first whenever the phone had
  /// *any* connectivity, so on one bar of signal the hub sat on a spinner for
  /// up to the 15 s connect timeout before falling back to the same cache.
  Future<List<SnagBuilding>> buildings({void Function()? onStale}) async {
    final data = await _cacheFirst('/api/snags/locations/buildings', onStale);
    return unwrapList(data).map(SnagBuilding.fromJson).where((b) => b.id.isNotEmpty).toList();
  }

  Future<SnagLocationTree?> tree(String buildingId, {void Function()? onStale}) async {
    final json = unwrapMap(await _cacheFirst('/api/snags/locations/buildings/$buildingId', onStale));
    return json.isEmpty ? null : SnagLocationTree.fromJson(json);
  }

  Future<dynamic> _cacheFirst(String url, void Function()? onStale) async {
    CachedEntity? cached;
    try {
      cached = await _sync.db.readCache(_sync.cacheKey(url, null));
    } catch (_) {
      cached = null;
    }
    if (cached == null || cached.isExpired) {
      return (await _sync.syncGet(url, ttl: _locationTtl)).data;
    }
    final before = jsonEncode(cached.body);
    unawaited(() async {
      try {
        final fresh = await _sync.syncGet(url, ttl: _locationTtl);
        if (!fresh.fromCache && jsonEncode(fresh.data) != before) onStale?.call();
      } catch (_) {
        // Offline or refused: the cached copy stays what the screen shows.
      }
    }());
    return cached.body;
  }

  // -------------------------------------------------------------------------
  // Snags — reads
  // -------------------------------------------------------------------------

  Snag _fromRow(StoredSnagRow r) => Snag.fromJson({...r.json, 'localOnly': r.localOnly});

  Future<List<Snag>> local({String? buildingId}) async =>
      (await _store.listSnags(buildingId: buildingId)).map(_fromRow).toList();

  Future<Snag?> localById(String id) async {
    final row = await _store.getSnag(id);
    return row == null ? null : _fromRow(row);
  }

  /// A full pull (which also prunes) at least this often; delta pulls in
  /// between. Server-side deletes are rare, so a 6 h prune is plenty.
  static const _fullPullEvery = Duration(hours: 6);

  /// Overlap on the delta cursor, so a row written while the last pull was
  /// in flight is never skipped.
  static const _cursorOverlap = Duration(minutes: 2);

  static String _cursorKey(String buildingId) => 'snag.cursor.$buildingId';

  /// Pulls one building's snags and merges them in. Returns false when the
  /// device is offline — the local store is then all there is, which is the
  /// normal case in the field rather than an error.
  ///
  /// Lean and incremental (2026-10-06): asks for `view=list` (no `activity`
  /// threads; the detail screen reads one snag in full) and, after the first
  /// full pull, only rows changed since the server's own clock at the last
  /// pull (`updatedSince`). A server without that support ignores both and
  /// answers the full list as before, with no `serverTime`, so every pull
  /// stays full — the old behaviour.
  Future<bool> refresh({required String buildingId, bool full = false}) async {
    final cursor = _SnagCursor.decode(await _readMeta(_cursorKey(buildingId)));
    final now = DateTime.now();
    final delta = !full && cursor != null && now.difference(cursor.fullAt) < _fullPullEvery;
    final dynamic body;
    try {
      final res = await _api.get('/api/snags', query: {
        'buildingId': buildingId,
        'limit': 2000,
        'view': 'list',
        if (delta) 'updatedSince': cursor.since.subtract(_cursorOverlap).toUtc().toIso8601String(),
      });
      body = res.data;
    } on NetworkFailure {
      return false;
    }
    final data = unwrapMap(body);
    final lean = data['view'] == 'list';
    final items = data['items'] is List
        ? (data['items'] as List).whereType<Map>().map((e) => Snag.fromJson(Map<String, dynamic>.from(e))).toList()
        : <Snag>[];
    final pending = await _store.pendingEntityIds(entityType);
    final fresh = items.where((s) => s.id.isNotEmpty && !pending.contains(s.id)).toList();
    final existing = fresh.length > 20
        ? {for (final s in await local(buildingId: buildingId)) s.id: s}
        : {for (final s in fresh) s.id: ?await localById(s.id)};
    await _store.upsertSnags([
      for (final s in fresh) _row(_mergeServer(s, existing[s.id], lean: lean)),
    ]);
    // Prune only on a complete, full list: a truncated page or a delta must
    // never delete rows.
    final total = asInt(data['total']) ?? items.length;
    final wasDelta = delta && data['serverTime'] != null;
    if (!wasDelta && total <= items.length) {
      await _store.pruneSnags(buildingId: buildingId, keepIds: {...items.map((s) => s.id), ...pending});
    }
    final serverTime = asDate(data['serverTime']);
    if (serverTime != null) {
      await _writeMeta(
        _cursorKey(buildingId),
        _SnagCursor(since: serverTime, fullAt: wasDelta ? cursor.fullAt : now).encode(),
      );
    }
    return true;
  }

  Future<String?> _readMeta(String key) async {
    try {
      return await _sync.db.readMeta(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMeta(String key, String value) async {
    try {
      await _sync.db.writeMeta(key, value);
    } catch (_) {
      // A lost cursor only costs one full pull next time.
    }
  }

  /// One snag straight from the server — a notification deep link can point
  /// at a snag this device has never listed. Null offline or when missing.
  Future<Snag?> fetchOne(String id) async {
    final pending = await _store.pendingEntityIds(entityType);
    if (pending.contains(id)) return localById(id);
    try {
      final res = await _api.get('/api/snags/$id');
      final data = unwrapMap(res.data);
      return data.isEmpty ? null : await _saveServer(Snag.fromJson(data));
    } on ApiFailure {
      return localById(id);
    }
  }

  Future<void> _saveLocal(Snag s) => _store.upsertSnag(
    id: s.id,
    json: s.toJson(),
    buildingId: s.buildingId,
    surveyId: s.surveyId,
    status: s.status.wire,
    localOnly: s.localOnly,
    updatedAt: s.updatedAt,
  );

  static SnagRowWrite _row(Snag s) => SnagRowWrite(
    id: s.id,
    json: s.toJson(),
    buildingId: s.buildingId,
    surveyId: s.surveyId,
    status: s.status.wire,
    localOnly: s.localOnly,
    updatedAt: s.updatedAt,
  );

  /// The server's copy, carrying over this device's own photo paths so the
  /// inspector keeps seeing their photos offline after sync. A [lean] list
  /// row has no `activity`, so the device's copy of the timeline is kept
  /// until the detail screen reads the snag in full. Pure, for tests.
  static Snag mergeServerCopy(Snag server, Snag? existing, {bool lean = false}) => _mergeServer(server, existing, lean: lean);

  static Snag _mergeServer(Snag server, Snag? existing, {bool lean = false}) {
    final paths = {
      for (final e in existing?.evidence ?? const <SnagEvidence>[])
        if (e.localPath != null) e.id: e.localPath,
    };
    return server.copyWith(
      localOnly: false,
      clearSendIssue: true,
      activity: lean && existing != null && server.activity.isEmpty ? existing.activity : null,
      evidence: [for (final e in server.evidence) paths.containsKey(e.id) ? e.withLocalPath(paths[e.id]) : e],
    );
  }

  /// Saves a server copy (see [mergeServerCopy]).
  Future<Snag> _saveServer(Snag server) async {
    final merged = _mergeServer(server, await localById(server.id));
    await _saveLocal(merged);
    return merged;
  }

  // -------------------------------------------------------------------------
  // Replay follow-ups (registered on the SyncClient by snagRepositoryProvider)
  // -------------------------------------------------------------------------

  /// A queued write for snag [id] just synced. Reads the server's copy so the
  /// device stops calling it unsent. Skipped while more writes for it are
  /// still queued (the device copy is ahead until the last one lands).
  /// Failures are swallowed — the next pull heals the same way.
  Future<void> afterReplay(String id) async {
    if ((await _store.pendingEntityIds(entityType)).contains(id)) return;
    try {
      final res = await _api.get('/api/snags/$id');
      final data = unwrapMap(res.data);
      if (data.isNotEmpty) await _saveServer(Snag.fromJson(data));
    } on ApiFailure {
      // Offline again, or gone: leave the row; a pull or detail open retries.
    }
  }

  /// A queued write for snag [id] failed on replay: remember why, so the
  /// screens can say it in plain words (and offer Retry once it was dropped).
  Future<void> afterReplayFailed(String id, ReplayFailure failure) async {
    final s = await localById(id);
    if (s == null) return;
    await _saveLocal(s.copyWith(
      sendIssue: SnagSendIssue(
        status: failure.status,
        code: failure.code,
        dropped: failure.outcome == FlushOutcome.drop,
        at: DateTime.now(),
      ),
    ));
  }

  /// A queued survey write synced: the server has the survey (a sweep or a
  /// completion on an unknown survey would have been refused instead).
  Future<void> afterSurveyReplay(String id) async {
    final survey = await surveyById(id);
    if (survey != null && survey.localOnly) await _saveSurvey(survey.copyWith(localOnly: false));
  }

  /// The technician's Retry. Queued → nudge the queue now. Never reached the
  /// server → queue the create again from the photos on this phone. On the
  /// server but a later change was refused → re-read the server's copy, which
  /// is the truth the device must show.
  Future<void> retrySend(Snag s) async {
    final pending = await _store.pendingEntityIds(entityType);
    if (pending.contains(s.id)) {
      _sync.kickFlush();
      return;
    }
    if (!s.localOnly) {
      await _saveLocal(s.copyWith(clearSendIssue: true));
      await fetchOne(s.id);
      return;
    }
    await _requeueCreate(s, label: 'Raise snag (retry)');
  }

  /// Queues the create of a snag that is on this phone only, re-reading its
  /// photos from disk (re-rooted if iOS moved the app container). Evidence
  /// whose file is gone is left out rather than sent as a dead placeholder.
  Future<void> _requeueCreate(Snag s, {required String label}) async {
    final uploads = <QueuedAttachment>[];
    for (final e in s.evidence.where((e) => e.stage == 'before' && e.url == null)) {
      final path = e.localPath;
      final file = path == null ? null : await _media.ownFile(path);
      if (file == null) continue;
      final Uint8List bytes = await file.readAsBytes();
      uploads.add(QueuedAttachment(
        bytes: bytes,
        fileName: 'snag-${e.id}.${e.isPhoto ? _photoExtension(bytes, 'jpg') : 'm4a'}',
        placeholder: _placeholder(e.id),
        field: e.isPhoto ? 'image' : 'file',
      ));
    }
    final body = _createBody(s);
    final sendable = uploads.map((u) => u.placeholder).toSet();
    body['evidence'] = (body['evidence'] as List)
        .where((e) => sendable.contains((e as Map)['url']) || !(e['url'] as String).startsWith('__pending'))
        .toList();
    await _saveLocal(s.copyWith(clearSendIssue: true));
    await _sync.queueRequest(
      'post',
      '/api/snags',
      data: body,
      label: label,
      attachments: uploads,
      entityType: entityType,
      entityId: s.id,
    );
  }

  // -------------------------------------------------------------------------
  // Snags — writes
  // -------------------------------------------------------------------------

  static String _placeholder(String evidenceId) => '__pending_snag_${evidenceId}__';

  Future<(List<SnagEvidence>, List<QueuedAttachment>)> _capture({
    required String snagId,
    required String stage,
    required SnagActor actor,
    List<CapturedPhoto> photos = const [],
    VoiceRecording? voice,
    double? lat,
    double? lng,
  }) async {
    final evidence = <SnagEvidence>[];
    final uploads = <QueuedAttachment>[];
    final now = DateTime.now();
    for (final photo in photos) {
      final id = newId();
      final ext = _photoExtension(photo.bytes, photo.fileName.contains('.') ? photo.fileName.split('.').last.toLowerCase() : 'jpg');
      final path = await _media.saveOwn(snagId: snagId, evidenceId: id, bytes: photo.bytes, extension: ext);
      evidence.add(SnagEvidence(
        id: id,
        kind: 'photo',
        stage: stage,
        capturedAt: now,
        localPath: path,
        capturedBy: actor.id,
        capturedByName: actor.name,
        lat: lat,
        lng: lng,
      ));
      uploads.add(QueuedAttachment(
        bytes: photo.bytes,
        fileName: 'snag-$id.$ext',
        placeholder: _placeholder(id),
        field: 'image',
      ));
    }
    if (voice != null) {
      final id = newId();
      final path = await _media.saveOwn(snagId: snagId, evidenceId: id, bytes: voice.bytes, extension: 'm4a');
      evidence.add(SnagEvidence(
        id: id,
        kind: 'audio',
        stage: stage,
        capturedAt: now,
        localPath: path,
        capturedBy: actor.id,
        capturedByName: actor.name,
      ));
      uploads.add(QueuedAttachment(
        bytes: voice.bytes,
        fileName: 'snag-$id.m4a',
        placeholder: _placeholder(id),
      ));
    }
    return (evidence, uploads);
  }

  /// The extension the upload is named with. The server's image upload
  /// accepts by multipart content type, which Dio infers from the file name
  /// alone — so bytes that are really JPEG/PNG get that extension whatever
  /// the picker called them (an iOS `.heic` name on a re-encoded JPEG would
  /// otherwise be refused with "Only image files are allowed!"). Pure.
  static String photoExtension(Uint8List bytes, String fallback) => _photoExtension(bytes, fallback);

  static String _photoExtension(Uint8List bytes, String fallback) {
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'jpg';
    if (bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return 'png';
    return fallback;
  }

  /// The wire shape of evidence: the URL is a placeholder the queue swaps
  /// for the uploaded file's URL at send time.
  static List<Map<String, dynamic>> _wireEvidence(List<SnagEvidence> evidence) => [
    for (final e in evidence)
      {
        'id': e.id,
        'kind': e.kind,
        'stage': e.stage,
        'url': e.url ?? _placeholder(e.id),
        'capturedAt': e.capturedAt.toUtc().toIso8601String(),
        if (e.lat != null && e.lng != null) 'geo': {'lat': e.lat, 'lng': e.lng},
      },
  ];

  static Map<String, dynamic> _createBody(Snag s) => {
    'id': s.id,
    'context': s.context.wire,
    'issueType': s.issueType,
    'trade': s.trade,
    'priority': s.priority.wire,
    'title': s.title,
    'description': ?s.description,
    'buildingId': ?s.buildingId,
    'floorId': ?s.floorId,
    'spaceId': ?s.spaceId,
    'locationLabel': ?s.locationLabel,
    'locationText': ?s.locationText,
    'locationPin': ?s.pin?.toJson(),
    'assetId': ?s.assetId,
    'assetName': ?s.assetName,
    'assetReferenceId': ?s.assetReferenceId,
    'surveyId': ?s.surveyId,
    'workOrderId': ?s.workOrderId,
    'responsibleParty': ?s.responsibleParty,
    'dueDate': ?s.dueDate?.toUtc().toIso8601String(),
    'clientCreatedAt': s.createdAt.toUtc().toIso8601String(),
    'evidence': _wireEvidence(s.evidence.where((e) => e.stage == 'before').toList()),
  };

  static String _defaultTitle(String trade, String issueType) {
    String cap(String w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}';
    return '${cap(trade.replaceAll('-', ' '))} ${issueType.replaceAll('-', ' ')}';
  }

  Future<SnagWriteResult> raise(SnagDraft d, SnagActor actor) async {
    final (evidence, uploads) = await _capture(
      snagId: d.id,
      stage: 'before',
      actor: actor,
      photos: d.photos,
      voice: d.voice,
      lat: d.lat,
      lng: d.lng,
    );
    final now = DateTime.now();
    final title = (d.title?.trim().isNotEmpty ?? false) ? d.title!.trim() : _defaultTitle(d.trade, d.issueType);
    final snag = Snag(
      id: d.id,
      context: d.context,
      issueType: d.issueType,
      trade: d.trade,
      priority: d.priority,
      title: title,
      description: (d.description?.trim().isEmpty ?? true) ? null : d.description!.trim(),
      status: SnagStatus.open,
      buildingId: d.buildingId,
      floorId: d.floorId,
      spaceId: d.spaceId,
      locationLabel: d.locationLabel,
      locationText: d.locationText,
      pin: d.pin,
      assetId: d.assetId,
      assetName: d.assetName,
      assetReferenceId: d.assetReferenceId,
      surveyId: d.surveyId,
      workOrderId: d.workOrderId,
      responsibleParty: d.responsibleParty,
      dueDate: d.dueDate,
      evidence: evidence,
      activity: [SnagActivity(id: newId(), at: now, type: 'raised', by: actor.id, byName: actor.name)],
      raisedBy: actor.id,
      raisedByName: actor.name,
      createdAt: now,
      updatedAt: now,
      localOnly: true,
    );
    await _saveLocal(snag);
    // Outbox first: the snag and its photos are safe on the phone the moment
    // this returns; the flush started by queueRequest sends them, and
    // [afterReplay] swaps in the server's copy (with its SN- number).
    await _sync.queueRequest(
      'post',
      '/api/snags',
      data: _createBody(snag),
      label: 'Raise snag',
      attachments: uploads,
      entityType: entityType,
      entityId: snag.id,
    );
    return SnagWriteResult(snag: snag, synced: false);
  }

  /// Sends one online-first write. On success the server's copy replaces
  /// the optimistic one. When the server refuses it — or the request failed
  /// in a way that queued nothing (an upload answered without a URL) — the
  /// optimistic change is rolled back to [rollbackTo]: the device must not
  /// show what the server does not have, with nothing left to send it.
  Future<SnagWriteResult> _send(
    Snag optimistic,
    Future<SyncedWrite> Function() call, {
    Snag? rollbackTo,
  }) async {
    try {
      final write = await call();
      if (!write.synced) return SnagWriteResult(snag: optimistic, synced: false);
      final data = unwrapMap(write.data);
      if (data.isEmpty) return SnagWriteResult(snag: optimistic, synced: true);
      final saved = await _saveServer(Snag.fromJson(data));
      return SnagWriteResult(snag: saved, synced: true);
    } on ApiFailure {
      if (rollbackTo != null) await _saveLocal(rollbackTo);
      rethrow;
    }
  }

  Future<SnagWriteResult> transition(
    Snag snag,
    SnagAction action,
    SnagActor actor, {
    String? reason,
    String? note,
    List<CapturedPhoto> photos = const [],
  }) async {
    final stage = action == SnagAction.ready ? 'after' : 'extra';
    final (added, uploads) = await _capture(snagId: snag.id, stage: stage, actor: actor, photos: photos);
    final result = SnagRules.apply(
      snag,
      action,
      actorId: actor.id,
      actorName: actor.name,
      actorRole: actor.role,
      reason: reason,
      note: note,
      added: added,
      activityId: newId(),
    );
    final next = result.snag;
    if (next == null) throw SnagRuleException(result.failure!);
    await _saveLocal(next);
    return _send(
      next,
      () => _sync.syncRequest(
        'post',
        '/api/snags/${snag.id}/transition',
        data: {
          'action': action.name,
          'reason': ?reason,
          'note': ?note,
          'evidence': _wireEvidence(added),
        },
        label: 'Snag ${snag.displayRef}: ${action.name}',
        attachments: uploads,
        entityType: entityType,
        entityId: snag.id,
        queueOnServerError: true,
      ),
      rollbackTo: snag,
    );
  }

  /// Adds photos to an existing snag. [duplicateReport] is the "+1" from the
  /// duplicate guard: the same defect seen again, which also raises
  /// "Also reported by N".
  Future<SnagWriteResult> addEvidence(
    Snag snag,
    SnagActor actor, {
    List<CapturedPhoto> photos = const [],
    bool duplicateReport = false,
    String? note,
  }) async {
    final (added, uploads) = await _capture(snagId: snag.id, stage: 'extra', actor: actor, photos: photos);
    final now = DateTime.now();
    final next = snag.copyWith(
      evidence: [...snag.evidence, ...added],
      reportCount: snag.reportCount + (duplicateReport ? 1 : 0),
      updatedAt: now,
      activity: [
        ...snag.activity,
        SnagActivity(
          id: newId(),
          at: now,
          type: duplicateReport ? 'duplicate-report' : 'evidence',
          by: actor.id,
          byName: actor.name,
          note: note,
        ),
      ],
    );
    await _saveLocal(next);
    // Outbox first, like [raise]: a photo is the slow part of any snag write.
    // A refusal on replay reaches the conflict log and [afterReplayFailed];
    // the next pull restores the server's copy (merge on read).
    await _sync.queueRequest(
      'post',
      '/api/snags/${snag.id}/evidence',
      data: {'evidence': _wireEvidence(added), 'duplicateReport': duplicateReport, 'note': ?note},
      label: duplicateReport ? 'Snag ${snag.displayRef}: also seen' : 'Snag ${snag.displayRef}: photo',
      attachments: uploads,
      entityType: entityType,
      entityId: snag.id,
    );
    return SnagWriteResult(snag: next, synced: false);
  }

  Future<SnagWriteResult> comment(Snag snag, SnagActor actor, String note) async {
    final now = DateTime.now();
    final next = snag.copyWith(
      updatedAt: now,
      activity: [
        ...snag.activity,
        SnagActivity(id: newId(), at: now, type: 'comment', by: actor.id, byName: actor.name, note: note),
      ],
    );
    await _saveLocal(next);
    return _send(
      next,
      () => _sync.syncRequest(
        'post',
        '/api/snags/${snag.id}/comments',
        data: {'note': note},
        label: 'Snag ${snag.displayRef}: comment',
        entityType: entityType,
        entityId: snag.id,
        queueOnServerError: true,
      ),
      rollbackTo: snag,
    );
  }

  /// UC-11 — online only and never queued: a suggestion that arrives an hour
  /// later is worthless. Null when offline or the assistant is unavailable;
  /// the compose card simply carries on without it.
  Future<SnagSuggestion?> assist(
    CapturedPhoto photo, {
    VoiceRecording? voice,
    String? hint,
    SnagContext context = SnagContext.operations,
  }) async {
    try {
      final res = await _api.post('/api/snags/assist', data: {
        'image': photo.dataUrl,
        'audio': ?voice?.dataUrl,
        'hint': ?hint,
        'context': context.wire,
      });
      final data = unwrapMap(res.data);
      return data.isEmpty ? null : SnagSuggestion.fromJson(data);
    } on ApiFailure {
      return null;
    }
  }

  /// The "after the snap" AI assist (`POST /api/snags/ai/assist`). Online
  /// only and never queued — a suggestion an hour late is worthless — and
  /// never in the way: offline returns [SnagAiStatus.offline], anything else
  /// that goes wrong returns [SnagAiStatus.unavailable]; both still carry the
  /// phone's own photo tips. Read-only on the server; nothing is saved from
  /// the answer unless the technician applies it.
  ///
  /// [aiJpeg] is the downscaled copy from `prepareSnagPhotoForAi` (the
  /// original photo stays the evidence); [deviceTips] are its dark/blurry
  /// findings; [brightness]/[sharpness] go along so the server applies the
  /// same thresholds.
  Future<SnagAiResult> aiAssist({
    required Uint8List aiJpeg,
    List<String> deviceTips = const [],
    double? brightness,
    double? sharpness,
    SnagContext context = SnagContext.operations,
    String? hint,
    String? buildingId,
    String? floorId,
    String? spaceId,
    String? locationLabel,
    String? locationText,
    String? assetName,
    String? currentTitle,
    String? currentTrade,
    SnagPriority? currentPriority,
    String? currentIssueType,
    int photoCount = 1,
    String? snagId,
  }) async {
    try {
      final res = await _api.post(
        '/api/snags/ai/assist',
        data: {
          'image': 'data:image/jpeg;base64,${base64Encode(aiJpeg)}',
          'context': context.wire,
          'hint': ?hint,
          'buildingId': ?buildingId,
          'floorId': ?floorId,
          'spaceId': ?spaceId,
          'locationLabel': ?locationLabel,
          'locationText': ?locationText,
          'assetName': ?assetName,
          'snagId': ?snagId,
          'current': {
            'title': ?currentTitle,
            'trade': ?currentTrade,
            'priority': ?currentPriority?.wire,
            'issueType': ?currentIssueType,
            'photoCount': photoCount,
          },
          if (brightness != null || sharpness != null)
            'quality': {'brightness': ?brightness, 'sharpness': ?sharpness},
        },
        // The server gives the model 12 s; a little more for the photo's trip.
        receiveTimeout: const Duration(seconds: 20),
      );
      final data = unwrapMap(res.data);
      if (data.isEmpty) return SnagAiResult.unavailable(captureTips: deviceTips);
      return SnagAiResult.fromJson(data, deviceTips: deviceTips);
    } on NetworkFailure {
      return SnagAiResult.offline(captureTips: deviceTips);
    } on ApiFailure {
      return SnagAiResult.unavailable(captureTips: deviceTips);
    }
  }

  // -------------------------------------------------------------------------
  // Surveys
  // -------------------------------------------------------------------------

  Future<List<SnagSurvey>> surveys({String? buildingId}) async =>
      (await _store.listSurveys(buildingId: buildingId)).map(SnagSurvey.fromJson).toList();

  Future<SnagSurvey?> surveyById(String id) async {
    final json = await _store.getSurvey(id);
    return json == null ? null : SnagSurvey.fromJson(json);
  }

  Future<void> _saveSurvey(SnagSurvey s) => _store.upsertSurvey(
    id: s.id,
    json: s.toJson(),
    buildingId: s.buildingId,
    localOnly: s.localOnly,
    updatedAt: DateTime.now(),
  );

  Future<bool> refreshSurveys({required String buildingId}) async {
    final dynamic body;
    try {
      final res = await _api.get('/api/snags/surveys', query: {'buildingId': buildingId});
      body = res.data;
    } on NetworkFailure {
      return false;
    }
    final pending = await _store.pendingEntityIds(surveyEntityType);
    for (final json in unwrapList(body)) {
      final s = SnagSurvey.fromJson(json);
      if (s.id.isEmpty || pending.contains(s.id)) continue;
      await _saveSurvey(s.copyWith(localOnly: false));
    }
    return true;
  }

  Future<SnagSurvey> startSurvey({
    required String name,
    required SnagContext context,
    required SnagBuilding building,
    required SnagActor actor,
  }) async {
    final survey = SnagSurvey(
      id: newId(),
      name: name,
      context: context,
      buildingId: building.id,
      buildingName: building.name,
      startedBy: actor.id,
      startedByName: actor.name,
      startedAt: DateTime.now(),
      localOnly: true,
    );
    await _saveSurvey(survey);
    await _postSurvey(survey);
    return survey;
  }

  /// Outbox first (2026-10-06): "Start walk" used to wait on this POST
  /// before the camera opened. [afterSurveyReplay] clears `localOnly`.
  Future<void> _postSurvey(SnagSurvey survey) async {
    await _sync.queueRequest(
      'post',
      '/api/snags/surveys',
      data: {
        'id': survey.id,
        'name': survey.name,
        'context': survey.context.wire,
        'buildingId': ?survey.buildingId,
        'buildingName': ?survey.buildingName,
        'startedAt': survey.startedAt.toUtc().toIso8601String(),
      },
      label: 'Start snag survey',
      entityType: surveyEntityType,
      entityId: survey.id,
    );
  }

  /// UC-2 room sweep. Replaces any earlier sweep of the same room.
  Future<SnagSurvey> sweep(
    SnagSurvey survey, {
    required SnagFloor floor,
    required SnagSpace space,
    required int snagCount,
    required SnagActor actor,
  }) async {
    final entry = SpaceSweep(
      spaceId: space.id,
      spaceName: space.name,
      floorId: floor.id,
      clear: snagCount == 0,
      snagCount: snagCount,
      at: DateTime.now(),
      by: actor.id,
      byName: actor.name,
    );
    final next = survey.copyWith(
      inspectedSpaces: [...survey.inspectedSpaces.where((s) => s.spaceId != space.id), entry],
    );
    await _saveSurvey(next);
    // Outbox first: "Room done" never waits on the network. A refusal on
    // replay leaves the sweep on the device; coverage still counts it locally.
    await _sync.queueRequest(
      'post',
      '/api/snags/surveys/${survey.id}/spaces',
      data: entry.toJson(),
      label: 'Room checked: ${space.name}',
      entityType: surveyEntityType,
      entityId: survey.id,
    );
    return next;
  }

  Future<SnagSurvey> completeSurvey(SnagSurvey survey) async {
    final next = survey.copyWith(completed: true, completedAt: DateTime.now());
    await _saveSurvey(next);
    await _sync.queueRequest(
      'post',
      '/api/snags/surveys/${survey.id}/complete',
      label: 'Complete snag survey',
      entityType: surveyEntityType,
      entityId: survey.id,
    );
    return next;
  }

  // -------------------------------------------------------------------------
  // Self-heal and offline prep
  // -------------------------------------------------------------------------

  /// Re-queues creates an older build gave up on (it dropped a create after
  /// five 5xx polls; this build never does). Returns how many were
  /// re-queued. Does nothing offline or while the server is not enabled for
  /// snags — re-queuing then would only burn the retry budget again — and
  /// skips snags the server *refused* (a 4xx): those wait for the
  /// technician's Retry instead of looping through the conflict log.
  Future<int> resendStranded({String? buildingId}) async {
    final pendingSurveys = await _store.pendingEntityIds(surveyEntityType);
    final pending = await _store.pendingEntityIds(entityType);
    final strandedSurveys = [
      for (final s in await surveys(buildingId: buildingId))
        if (s.localOnly && !pendingSurveys.contains(s.id)) s,
    ];
    final strandedSnags = [
      for (final s in await local(buildingId: buildingId))
        if (s.localOnly && !pending.contains(s.id) && !(s.sendIssue?.dropped ?? false)) s,
    ];
    // Cheap local check first: most pulls have nothing stranded, and then
    // there is no reason to ask the server anything.
    if (strandedSurveys.isEmpty && strandedSnags.isEmpty) return 0;
    try {
      final res = await _api.get('/api/snags/engine');
      if (asBool(unwrapMap(res.data)['enabled']) != true) return 0;
    } on ApiFailure {
      return 0;
    }
    for (final s in strandedSurveys) {
      await _postSurvey(s);
    }
    for (final s in strandedSnags) {
      await _requeueCreate(s, label: 'Raise snag (retry)');
    }
    return strandedSurveys.length + strandedSnags.length;
  }

  /// "Download for offline": other people's photos of the building's live
  /// snags, so a verifier can compare before/after with no signal.
  Future<int> prefetchMedia({required String buildingId}) async {
    final snags = await local(buildingId: buildingId);
    return _media.prefetch(snags.where((s) => s.status.isLive).expand((s) => s.evidence));
  }
}

/// Where the last pull of one building got to: the server's clock at that
/// pull ([since], the next delta's `updatedSince`) and when the last *full*
/// pull ran ([fullAt], device clock). Stored in `sync_meta` as `sinceMs|fullAtMs`.
class _SnagCursor {
  const _SnagCursor({required this.since, required this.fullAt});
  final DateTime since;
  final DateTime fullAt;

  String encode() => '${since.millisecondsSinceEpoch}|${fullAt.millisecondsSinceEpoch}';

  static _SnagCursor? decode(String? raw) {
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length != 2) return null;
    final since = int.tryParse(parts[0]);
    final fullAt = int.tryParse(parts[1]);
    if (since == null || fullAt == null) return null;
    return _SnagCursor(
      since: DateTime.fromMillisecondsSinceEpoch(since),
      fullAt: DateTime.fromMillisecondsSinceEpoch(fullAt),
    );
  }
}

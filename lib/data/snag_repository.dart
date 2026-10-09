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
import '../core/snag/snag_integrity_log.dart';
import '../core/snag/snag_integrity_scan.dart';
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
    this.photoRegions = const [],
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

  /// Highlighted defect areas the technician kept on the FIRST photo (the one
  /// AI assist looked at). Saved on that photo's evidence item.
  final List<SnagRegion> photoRegions;

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

/// Where a captured snag is being saved from (see [SnagRepository.saveShot]).
enum SnagShotMode {
  /// Walk mode: every shot is a new snag, no duplicate prompt.
  walk,

  /// The raise form: the duplicate guard may offer a "+1" on an open snag.
  single,
}

class SnagShotResult {
  const SnagShotResult({required this.snag, required this.addedToExisting});

  /// The new snag, or the existing one the photo was added to.
  final Snag snag;

  /// true only when the person picked an existing snag in the duplicate sheet.
  final bool addedToExisting;
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
    SnagIntegrityLog? integrity,
  }) : _sync = sync,
       _api = api,
       _store = store,
       _media = media,
       _uuid = uuid ?? const Uuid(),
       integrity = integrity ?? SnagIntegrityLog(() => media.diagnosticsFile('integrity.jsonl'));

  final SyncClient _sync;
  final ApiClient _api;
  final SnagStore _store;
  final SnagMedia _media;
  final Uuid _uuid;

  /// Developer-only diagnostics (never shown to users); see [SnagIntegrityLog].
  final SnagIntegrityLog integrity;

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

  /// A full pull (which also prunes and repairs) at least this often; delta
  /// pulls in between. Server-side deletes are rare, so a 6 h prune is plenty.
  static const _fullPullEvery = Duration(hours: 6);

  /// Overlap on the delta cursor, so a row written while the last pull was
  /// in flight is never skipped. The cursor itself is the SERVER's clock
  /// (`serverTime` of the last pull), never this phone's.
  static const _cursorOverlap = Duration(minutes: 2);

  /// At most this many damaged rows are re-read in full per full pull.
  static const _repairBatch = 25;

  /// `v2` (2026-10-10): the first pull after this build is a full pull, so
  /// the repair pass runs once on every device that already had a cursor.
  static String _cursorKey(String buildingId) => 'snag.cursor.v2.$buildingId';

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
  ///
  /// Integrity rules (2026-10-10, owner iPhone report "some snags not
  /// visible, status and metadata missing"):
  /// - a list row is merged **field by field** onto the device's copy
  ///   ([mergeServerRow]): a key the row does not carry keeps the device's
  ///   value, and a lean row never empties the timeline;
  /// - the device's own photos the server does not have are kept, not
  ///   dropped with the old evidence list;
  /// - a full pull never prunes a row that still holds unsent work;
  /// - a device clock that went backwards forces a full pull instead of
  ///   delta-pulling forever;
  /// - each full pull repairs damaged rows from the server and logs what it
  ///   cannot explain ([SnagIntegrityScan]) — developer log only.
  Future<bool> refresh({required String buildingId, bool full = false, String? actorId}) async {
    final cursor = _SnagCursor.decode(await _readMeta(_cursorKey(buildingId)));
    final now = DateTime.now();
    final sinceFull = cursor == null ? null : now.difference(cursor.fullAt);
    if (sinceFull != null && sinceFull.isNegative) {
      unawaited(integrity.record(SnagIntegrityLog.clockSkewFullPull, detail: {'buildingId': buildingId}));
    }
    final deltaFrom = !full && sinceFull != null && !sinceFull.isNegative && sinceFull < _fullPullEvery ? cursor : null;
    final delta = deltaFrom != null;
    final dynamic body;
    try {
      final res = await _api.get('/api/snags', query: {
        'buildingId': buildingId,
        'limit': 2000,
        'view': 'list',
        if (deltaFrom != null) 'updatedSince': deltaFrom.since.subtract(_cursorOverlap).toUtc().toIso8601String(),
      });
      body = res.data;
    } on NetworkFailure {
      return false;
    }
    final data = unwrapMap(body);
    final lean = data['view'] == 'list';
    final rows = data['items'] is List
        ? [
            for (final e in (data['items'] as List).whereType<Map>())
              if ((e['id']?.toString() ?? '').isNotEmpty) Map<String, dynamic>.from(e),
          ]
        : <Map<String, dynamic>>[];
    final wasDelta = delta && data['serverTime'] != null;
    final total = asInt(data['total']) ?? rows.length;
    final complete = !wasDelta && total <= rows.length;

    // A full pull reads every local row anyway (prune protection); a delta
    // of a few rows reads just those.
    final localAll = complete || rows.length > 20
        ? {for (final s in await local(buildingId: buildingId)) s.id: s}
        : null;
    final merged = <Snag>[];
    for (final row in rows) {
      final id = row['id'].toString();
      final existing = localAll != null ? localAll[id] : await localById(id);
      merged.add(mergeServerRow(row, existing, lean: lean));
    }
    // Read the queue as late as possible: a write queued while the list was
    // in flight (or while the rows were merged) keeps the device ahead.
    final pending = await _store.pendingEntityIds(entityType);
    final fresh = [for (final s in merged) if (!pending.contains(s.id)) s];
    await _store.upsertSnags([for (final s in fresh) _row(s)]);
    for (final s in fresh) {
      final kept = s.evidence.where((e) => e.url == null && e.localPath != null).map((e) => e.id).toList();
      if (kept.isNotEmpty) {
        unawaited(integrity.record(
          SnagIntegrityLog.deviceOnlyEvidenceKept,
          snagId: s.id,
          detail: {'evidenceIds': kept, 'ref': s.reference},
          dedupeKey: 'kept:${s.id}:${kept.join(",")}',
        ));
      }
    }

    // Prune only on a complete, full list: a truncated page or a delta must
    // never delete rows. And never a row that still holds unsent work: the
    // store already spares `local_only` rows; this spares queued snags and
    // server-known snags carrying photos or a refused write the server does
    // not have.
    if (complete) {
      final serverIds = {for (final r in rows) r['id'].toString()};
      final protected = <String>{
        for (final s in localAll?.values ?? const <Snag>[])
          if (!serverIds.contains(s.id) && _holdsUnsentWork(s)) s.id,
      };
      for (final id in protected) {
        unawaited(integrity.record(SnagIntegrityLog.pruneKept, snagId: id, dedupeKey: 'prune:$id'));
      }
      await _store.pruneSnags(buildingId: buildingId, keepIds: {...serverIds, ...pending, ...protected});
    }
    final serverTime = asDate(data['serverTime']);
    if (serverTime != null) {
      await _writeMeta(
        _cursorKey(buildingId),
        _SnagCursor(since: serverTime, fullAt: wasDelta ? deltaFrom.fullAt : now).encode(),
      );
    }
    if (!wasDelta) await _repairAfterFullPull(buildingId, actorId: actorId);
    return true;
  }

  /// Work on this phone that the server does not have: photos never
  /// uploaded, or a write the server refused.
  static bool _holdsUnsentWork(Snag s) =>
      s.localOnly || s.sendIssue != null || s.evidence.any((e) => e.url == null && e.localPath != null);

  /// Re-reads, in full, rows the lean list left without their timeline or
  /// SN- number (bounded), then logs photos this device cannot explain.
  /// Never throws; a network failure just ends the pass.
  Future<void> _repairAfterFullPull(String buildingId, {String? actorId}) async {
    try {
      final pending = await _store.pendingEntityIds(entityType);
      final snags = await local(buildingId: buildingId);
      final damaged = [
        for (final s in snags)
          if (!s.localOnly && !pending.contains(s.id) && (s.reference == null || s.activity.isEmpty)) s,
      ]..sort((a, b) {
          // Unnumbered first (the card shows "#abc123" instead of SN-), then newest.
          final byRef = (a.reference == null ? 0 : 1).compareTo(b.reference == null ? 0 : 1);
          return byRef != 0 ? byRef : b.updatedAt.compareTo(a.updatedAt);
        });
      for (final s in damaged.take(_repairBatch)) {
        final Map<String, dynamic> data;
        try {
          data = unwrapMap((await _api.get('/api/snags/${s.id}')).data);
        } on NetworkFailure {
          break;
        } on ApiFailure {
          continue;
        }
        if (data.isEmpty || (await _store.pendingEntityIds(entityType)).contains(s.id)) continue;
        await _saveServerRow(data);
        unawaited(integrity.record(
          SnagIntegrityLog.repairedFromServer,
          snagId: s.id,
          detail: {'missingRef': s.reference == null, 'missingActivity': s.activity.isEmpty},
        ));
      }
      for (final f in SnagIntegrityScan.find(await local(buildingId: buildingId), actorId: actorId)) {
        await integrity.record(
          f.kind,
          snagId: f.snagId,
          detail: {'ref': f.ref, 'evidenceIds': f.evidenceIds},
          dedupeKey: f.key,
        );
      }
    } catch (_) {
      // Diagnostics and repair are best effort; the pull itself succeeded.
    }
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
      return data.isEmpty ? null : await _saveServerRow(data);
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

  /// A server row exactly as received, merged **field by field** onto the
  /// device's copy (2026-10-10): a key the row does not carry keeps the
  /// device's value (an explicit `null` still clears it — that is the
  /// server's answer), so a slimmer list view can never blank out metadata
  /// the device already has. [existing] must be the same snag; anything
  /// else is ignored. Pure, for tests.
  static Snag mergeServerRow(
    Map<String, dynamic> row,
    Snag? existing, {
    bool lean = false,
    bool keepSendIssue = false,
  }) {
    final id = row['id']?.toString();
    final same = existing != null && existing.id == id ? existing : null;
    final merged = <String, dynamic>{
      for (final e in (same?.toJson() ?? const <String, dynamic>{}).entries)
        if (e.key != 'localOnly' && e.key != 'sendIssue') e.key: e.value,
      ...row,
    };
    // A lean row from a server that still sends `activity: []` is "not
    // included", not "no events".
    final leanRow = lean || !row.containsKey('activity');
    return _mergeServer(Snag.fromJson(merged), same, lean: leanRow, keepSendIssue: keepSendIssue);
  }

  static Snag _mergeServer(Snag server, Snag? existing, {bool lean = false, bool keepSendIssue = false}) {
    return server.copyWith(
      localOnly: false,
      clearSendIssue: !keepSendIssue,
      sendIssue: keepSendIssue ? existing?.sendIssue : null,
      activity: lean && existing != null && server.activity.isEmpty ? existing.activity : null,
      evidence: mergeEvidence(server.id, server.evidence, existing?.evidence ?? const []),
    );
  }

  /// The server's evidence list, plus this device's own captures **for this
  /// snag** that the server does not have (2026-10-10). Server evidence is
  /// append-only, so a missing item was never delivered (an upload refused,
  /// a placeholder never swapped for a URL, a write refused): dropping it
  /// with the old list made the photo vanish from the phone, with nothing
  /// left to resend it. Only captures whose file lives under
  /// `own/<snagId>/` are kept, so a photo can never move between snags. Pure.
  static List<SnagEvidence> mergeEvidence(String snagId, List<SnagEvidence> server, List<SnagEvidence> local) {
    final paths = {for (final e in local) if (e.localPath != null) e.id: e.localPath};
    final serverIds = {for (final e in server) e.id};
    return [
      for (final e in server) paths.containsKey(e.id) ? e.withLocalPath(paths[e.id]) : e,
      for (final e in local)
        if (!serverIds.contains(e.id) && e.url == null && e.localPath != null && SnagMedia.isOwnCaptureFor(e.localPath!, snagId)) e,
    ];
  }

  /// Saves a server copy from its raw JSON (see [mergeServerRow]).
  Future<Snag> _saveServerRow(Map<String, dynamic> row, {bool keepSendIssue = false}) async {
    final merged = mergeServerRow(row, await localById(row['id']?.toString() ?? ''), keepSendIssue: keepSendIssue);
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
      if (data.isNotEmpty) await _saveServerRow(data);
    } on ApiFailure {
      // Offline again, or gone: leave the row; a pull or detail open retries.
    }
  }

  /// A queued write for snag [id] failed on replay: remember why, so the
  /// screens can say it in plain words (and offer Retry once it was dropped).
  ///
  /// A *dropped* write on a snag the server knows (a refused transition, a
  /// refused photo) also re-reads the server's copy right away (2026-10-10):
  /// the optimistic change never happened on the server, so its row was not
  /// touched and no delta pull would ever bring the truth back — the phone
  /// kept showing, say, "ready" for up to 6 h while the server said "in
  /// progress". The refusal stays on the row (Not sent + Retry), and the
  /// device's own photos stay (see [mergeEvidence]).
  Future<void> afterReplayFailed(String id, ReplayFailure failure) async {
    final s = await localById(id);
    if (s == null) return;
    final dropped = failure.outcome == FlushOutcome.drop;
    await _saveLocal(s.copyWith(
      sendIssue: SnagSendIssue(
        status: failure.status,
        code: failure.code,
        dropped: dropped,
        at: DateTime.now(),
      ),
    ));
    if (!dropped || s.localOnly) return;
    if ((await _store.pendingEntityIds(entityType)).contains(id)) return;
    try {
      final data = unwrapMap((await _api.get('/api/snags/$id')).data);
      if (data.isEmpty) return;
      final before = s.status;
      final after = await _saveServerRow(data, keepSendIssue: true);
      unawaited(integrity.record(
        SnagIntegrityLog.refusedWriteResynced,
        snagId: id,
        detail: {'status': failure.status, 'code': failure.code, 'deviceStatus': before.wire, 'serverStatus': after.status.wire},
      ));
    } on ApiFailure {
      // Offline: the next full pull restores it.
    }
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
    List<SnagRegion> firstPhotoRegions = const [],
  }) async {
    final evidence = <SnagEvidence>[];
    final uploads = <QueuedAttachment>[];
    final now = DateTime.now();
    for (final photo in photos) {
      final first = evidence.isEmpty;
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
        regions: first ? firstPhotoRegions : const [],
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
        // Optional (2026-10-06): an older server ignores it.
        if (e.isPhoto && e.regions.isNotEmpty) 'regions': [for (final r in e.regions) r.toJson()],
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

  /// Raises a NEW snag. A draft id that already names a snag on this phone
  /// is refused (2026-10-10): saving it would silently replace that other
  /// snag's row — its photos, status and history — with this one. Every
  /// caller mints the id with [newId] per shot, so this only fires on a bug,
  /// and then it fails loudly instead of mixing two snags.
  Future<SnagWriteResult> raise(SnagDraft d, SnagActor actor) async {
    if (await _store.getSnag(d.id) != null) {
      await integrity.record(SnagIntegrityLog.idReused, snagId: d.id, detail: {'surveyId': d.surveyId});
      throw StateError('Snag id ${d.id} is already in use on this device.');
    }
    final (evidence, uploads) = await _capture(
      snagId: d.id,
      stage: 'before',
      actor: actor,
      photos: d.photos,
      voice: d.voice,
      lat: d.lat,
      lng: d.lng,
      firstPhotoRegions: d.photoRegions,
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

  /// Saves one captured snag (walk shot or the raise form) — the single
  /// place that decides "new snag" vs "photo on an existing snag".
  ///
  /// **Walk mode always raises a new snag** (2026-10-10, owner iPhone
  /// report: "I started one snag in walk mode and captured one photo … it
  /// got added to an existing snag's after-photos"). The walk used to run
  /// the duplicate guard on Save & next: same room + same trade + the
  /// default issue type `defect` already scores 0.65 (bar 0.6), so almost
  /// every shot in a room with another live same-trade snag — from an
  /// earlier walk, or another person's — opened the "Already raised?" sheet,
  /// whose filled primary button ("Same issue — add my photo") put the shot
  /// on THAT snag (including snags already marked ready, beside their
  /// after-photos) and raised nothing. One walk shot = one new snag; merging
  /// duplicates is a deliberate act on the snag itself, never a side effect
  /// of saving.
  ///
  /// [SnagShotMode.single] (the raise form) still asks [confirmDuplicate]
  /// with open / in-progress candidates; the photo goes to an existing snag
  /// only when the person picked that snag, and only if it is still one of
  /// the candidates on this phone when the answer comes back.
  Future<SnagShotResult> saveShot(
    SnagDraft draft,
    SnagActor actor, {
    required SnagShotMode mode,
    Future<DuplicateDecision> Function(List<DuplicateCandidate> candidates)? confirmDuplicate,
  }) async {
    if (mode == SnagShotMode.single && confirmDuplicate != null) {
      final pool = await local(buildingId: draft.buildingId);
      final candidates = SnagDuplicateFinder.find(draft.signature(raisedBy: actor.id), pool);
      if (candidates.isNotEmpty) {
        final decision = await confirmDuplicate(candidates);
        final chosen = decision.snag;
        if (decision.choice == DuplicateChoice.sameIssue &&
            chosen != null &&
            !chosen.localOnly &&
            candidates.any((c) => c.snag.id == chosen.id)) {
          final r = await addEvidence(
            chosen,
            actor,
            photos: draft.photos,
            duplicateReport: true,
            firstPhotoRegions: draft.photoRegions,
          );
          return SnagShotResult(snag: r.snag, addedToExisting: true);
        }
      }
    }
    final r = await raise(draft, actor);
    return SnagShotResult(snag: r.snag, addedToExisting: false);
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
      final saved = await _saveServerRow(data);
      return SnagWriteResult(snag: saved, synced: true);
    } on ApiFailure {
      if (rollbackTo != null) await _saveLocal(rollbackTo);
      rethrow;
    }
  }

  /// The newest copy of [snag] on this phone (2026-10-10). Screens hand
  /// writes the [Snag] they built with, which can be minutes old (the detail
  /// screen's Mark ready waits on the camera; a pull or a replay follow-up
  /// may have saved a newer copy since). Writing on top of the old object
  /// put the old status, photos and timeline back — metadata "went missing".
  Future<Snag> _fresh(Snag snag) async {
    final current = await localById(snag.id);
    if (current == null) return snag;
    if (jsonEncode(current.toJson()) != jsonEncode(snag.toJson())) {
      unawaited(integrity.record(SnagIntegrityLog.staleWriteAvoided, snagId: snag.id));
    }
    return current;
  }

  Future<SnagWriteResult> transition(
    Snag stale,
    SnagAction action,
    SnagActor actor, {
    String? reason,
    String? note,
    List<CapturedPhoto> photos = const [],
  }) async {
    final snag = await _fresh(stale);
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
  /// "Also reported by N". Photos added here are always `extra` — only the
  /// "ready" [transition] makes after-photos (the server enforces the same).
  /// Only for a snag the person explicitly chose; walk mode never calls it
  /// (see [saveShot]).
  Future<SnagWriteResult> addEvidence(
    Snag stale,
    SnagActor actor, {
    List<CapturedPhoto> photos = const [],
    bool duplicateReport = false,
    String? note,
    List<SnagRegion> firstPhotoRegions = const [],
  }) async {
    final snag = await _fresh(stale);
    final (added, uploads) = await _capture(
      snagId: snag.id,
      stage: 'extra',
      actor: actor,
      photos: photos,
      firstPhotoRegions: firstPhotoRegions,
    );
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

  Future<SnagWriteResult> comment(Snag stale, SnagActor actor, String note) async {
    final snag = await _fresh(stale);
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
        // The server gives the model 15 s (it also draws the defect boxes
        // since 2026-10-06); a little more for the photo's trip.
        receiveTimeout: const Duration(seconds: 24),
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

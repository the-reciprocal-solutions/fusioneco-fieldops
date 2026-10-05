// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../../app/env.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import 'flush_policy.dart';
import 'offline_db.dart';
import 'queue_bus.dart';
import 'replay_hooks.dart';
import 'replay_notices.dart';

/// The one line shown anywhere a write lands in the offline queue instead of
/// the server — a note, a photo, a voice recording, a session, a close, an
/// invite response. Every call site used to word this slightly differently
/// ("Note saved offline...", "Photo saved offline...", "Session started
/// offline..."); a technician skimming past several of these back to back
/// read them as different things happening, when it is always the same one:
/// the write is queued and will replay automatically once the connection is
/// back.
const kOfflineQueuedMessage =
    "Saved offline. It'll sync automatically once you're back online.";

/// How far the current [SyncClient.flushQueue] run has gotten — the Home
/// screen's progress bar and the Sync Center screen both read this the same
/// way [SyncedWrite] is read: as plain synchronous state on [SyncClient],
/// refreshed through the same [QueueBus] tick every other queue-driven
/// provider already uses.
class SyncProgress {
  const SyncProgress({required this.completed, required this.total});
  final int completed;
  final int total;
}

class SyncedRead<T> {
  const SyncedRead({required this.data, required this.fromCache});
  final T data;
  final bool fromCache;
}

class SyncedWrite {
  const SyncedWrite({required this.synced, this.data});

  /// false means the mutation is parked in the queue and will replay on reconnect.
  final bool synced;
  final dynamic data;
}

class QueuedAttachment {
  const QueuedAttachment({
    required this.bytes,
    required this.fileName,
    required this.placeholder,
    this.field = 'file',
  });

  final Uint8List bytes;
  final String fileName;

  /// Token embedded in the mutation body, replaced by the uploaded URL on flush.
  final String placeholder;

  /// `file` → POST /api/upload/file, `image` → POST /api/upload/image.
  final String field;
}

/// Offline-aware transport. Reads fall back to cache on a network failure; writes
/// park in the queue on a network failure and replay in order. A 4xx/5xx always
/// propagates — replaying it could not succeed.
class SyncClient {
  SyncClient({
    required ApiClient api,
    required OfflineDb db,
    required QueueBus bus,
    Connectivity? connectivity,
    void Function()? onEnqueued,
  }) : _api = api,
       _db = db,
       _bus = bus,
       _connectivity = connectivity ?? Connectivity(),
       _onEnqueued = onEnqueued,
       _leaseOwner = api.newMutationId();

  final ApiClient _api;
  final OfflineDb _db;
  final QueueBus _bus;
  final Connectivity _connectivity;

  /// FR-4.4 — told whenever a write lands in the queue, so the OS can be
  /// asked to drain it as soon as there's signal, even if the app is killed
  /// before then (see `background_sync.dart`).
  final void Function()? _onEnqueued;

  /// This client's identity for the cross-engine flush lease ([SyncLease]).
  final String _leaseOwner;

  /// Follow-ups a repository asked for after its queued writes sync
  /// (P-008 (2): AR progress re-reads the floor). See [onReplayed].
  final _replayHooks = ReplayHooks();

  /// See [onReplayFailed]. One hook per entity type.
  final _failureHooks = <String, ReplayFailureHook>{};

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _pollTimer;
  bool _flushing = false;

  /// Set by [queueRequest] when a flush is already running: that run read
  /// its batch before the new write landed, so it runs once more at the end
  /// instead of leaving the write for the next 20 s poll.
  bool _flushAgain = false;

  OfflineDb get db => _db;

  /// Runs [hook] with the entity id of every replayed queued write of
  /// [entityType], once per id, after a flush. One hook per type.
  void onReplayed(String entityType, ReplayHook hook) =>
      _replayHooks.register(entityType, hook);

  /// Runs [hook] with the entity id whenever a queued write of [entityType]
  /// fails on replay (kept for a retry, dropped, or stopping the run), so the
  /// owning screen can say why it has not gone yet. A failing hook is
  /// swallowed — a flush must never throw. One hook per type; registering
  /// again replaces it.
  void onReplayFailed(String entityType, ReplayFailureHook hook) =>
      _failureHooks[entityType] = hook;
  QueueBus get bus => _bus;

  Future<bool> get isOffline async {
    final results = await _connectivity.checkConnectivity();
    return results.every((r) => r == ConnectivityResult.none);
  }

  /// Flush on start, whenever connectivity comes back, and on a 20s poll.
  ///
  /// The connectivity stream alone isn't reliable enough on its own —
  /// confirmed live on device: `onConnectivityChanged` can fail to emit a
  /// clean offline→online transition when a low-capability network (e.g. an
  /// IMS-only mobile radio with no general internet) lingers through the
  /// "offline" window, so the event that's supposed to wake the queue back
  /// up never fires. `flushQueue` is cheap to no-op (an early `isOffline` /
  /// empty-queue return), so polling it is safe to run continuously as a
  /// backstop rather than trusting the stream to be the only trigger.
  void startAutoFlush() {
    _connectivitySub ??= _connectivity.onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) unawaited(flushQueue());
    });
    _pollTimer ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(flushQueue()),
    );
    unawaited(flushQueue());
  }

  Future<void> dispose() async {
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  String cacheKey(String url, Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) return url;
    final keys = query.keys.toList()..sort();
    final qs = keys.map((k) => '$k=${query[k]}').join('&');
    return '$url?$qs';
  }

  Future<SyncedRead<dynamic>> syncGet(
    String url, {
    Map<String, dynamic>? query,
    Duration ttl = Env.cacheTtl,
  }) async {
    final key = cacheKey(url, query);

    if (await isOffline) {
      final cached = await _db.readCache(key);
      if (cached != null && !cached.isExpired) {
        return SyncedRead(data: cached.body, fromCache: true);
      }
    }

    try {
      final response = await _api.get(url, query: query);
      await _db.writeCache(key, response.data, ttl);
      return SyncedRead(data: response.data, fromCache: false);
    } on NetworkFailure {
      final cached = await _db.readCache(key);
      if (cached != null && !cached.isExpired) {
        return SyncedRead(data: cached.body, fromCache: true);
      }
      rethrow;
    }
  }

  /// [queueOnServerError] also parks the write when the server answers 5xx
  /// right now, instead of throwing. Opt-in, for writes whose evidence must
  /// not be lost to a server-side outage: the Snag Assistant uses it because
  /// the server answers `503 SNAG_ENGINE_NOT_ENABLED` until its one manual
  /// migration has run (docs/snag-assistant.md §7.3), and a surveyor's walk
  /// has to survive that. A queued 5xx replays under the normal flush policy
  /// (retry, then the conflict log after [Env.maxMutationAttempts]).
  Future<SyncedWrite> syncRequest(
    String method,
    String url, {
    dynamic data,
    required String label,
    QueuedAttachment? attachment,
    List<QueuedAttachment> attachments = const [],
    String? entityType,
    String? entityId,
    bool queueOnServerError = false,
  }) async {
    final mutationId = _api.newMutationId();
    final allAttachments = [...attachments, ?attachment];

    if (await isOffline) {
      await _enqueue(
        mutationId,
        method,
        url,
        data,
        label,
        allAttachments,
        entityType,
        entityId,
      );
      return const SyncedWrite(synced: false);
    }

    try {
      var body = data;
      for (final a in allAttachments) {
        final uploadedUrl = await uploadBytes(
          bytes: a.bytes,
          fileName: a.fileName,
          field: a.field,
        );
        body = _substitute(body, a.placeholder, uploadedUrl);
      }
      final response = await _api.request(
        method,
        url,
        data: body,
        mutationId: mutationId,
      );
      // Online, the caller gets the body and shows any refusals itself, so
      // only the informational capture conflict is logged here.
      await _recordReplayNotices(
        response.data,
        label: label,
        url: url,
        includeRefusals: false,
      );
      return SyncedWrite(synced: true, data: response.data);
    } on HttpFailure catch (e) {
      if (!queueOnServerError || e.status < 500) rethrow;
      await _enqueue(
        mutationId,
        method,
        url,
        data,
        label,
        allAttachments,
        entityType,
        entityId,
      );
      return const SyncedWrite(synced: false);
    } on NetworkFailure {
      await _enqueue(
        mutationId,
        method,
        url,
        data,
        label,
        allAttachments,
        entityType,
        entityId,
      );
      return const SyncedWrite(synced: false);
    }
  }

  /// Outbox-first write: parks the request in the queue straight away and
  /// starts a flush in the background, instead of holding the caller while
  /// photos upload over a weak link (the Snag Assistant's save, 2026-10-06:
  /// an online save used to wait on upload + POST, up to 15 s connect + 120 s
  /// upload, and any non-5xx failure on that inline path left the record on
  /// the phone with nothing queued). Replay is the same code path, ordering
  /// and idempotency (`X-Client-Mutation-Id`) as any offline write. Returns
  /// the mutation id. Purely additive: [syncRequest] is unchanged.
  Future<String> queueRequest(
    String method,
    String url, {
    dynamic data,
    required String label,
    List<QueuedAttachment> attachments = const [],
    String? entityType,
    String? entityId,
  }) async {
    final mutationId = _api.newMutationId();
    await _enqueue(
      mutationId,
      method,
      url,
      data,
      label,
      attachments,
      entityType,
      entityId,
    );
    kickFlush();
    return mutationId;
  }

  /// Starts a flush now, or — if one is already running — makes it run once
  /// more when it ends, so a write queued mid-drain is not left for the poll.
  void kickFlush() {
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    unawaited(flushQueue());
  }

  Future<void> _enqueue(
    String mutationId,
    String method,
    String url,
    dynamic data,
    String label,
    List<QueuedAttachment> attachments,
    String? entityType,
    String? entityId,
  ) async {
    await _db.enqueue(
      PendingMutation(
        clientMutationId: mutationId,
        method: method,
        url: url,
        body: data,
        label: label,
        attempts: 0,
        createdAt: DateTime.now(),
        attachments: [
          for (final a in attachments)
            PendingAttachment(
              bytes: a.bytes,
              fileName: a.fileName,
              field: a.field,
              placeholder: a.placeholder,
            ),
        ],
        entityType: entityType,
        entityId: entityId,
      ),
    );
    _bus.notify();
    _onEnqueued?.call();
  }

  /// Live only while a flush is running, null the rest of the time. [total]
  /// is fixed to the batch this run started with, so an item queued by the
  /// technician mid-flush does not make an in-progress bar's denominator
  /// jump around.
  SyncProgress? _progress;
  SyncProgress? get progress => _progress;

  bool get isSyncing => _progress != null;

  /// Replays oldest-first and stops at the first network failure so ordering
  /// holds. A 4xx (or the attempt cap) drops the mutation into the conflict
  /// log; a 5xx keeps its remaining attempts.
  ///
  /// [stopAfterId] runs only as far as that one mutation — still oldest
  /// first, since anything queued ahead of it has to go first for ordering
  /// to hold — rather than draining the whole queue. That is the entire
  /// difference between a "Sync now" tap on one item and "Sync all": both
  /// call this, one just stops earlier.
  Future<void> flushQueue({String? stopAfterId}) async {
    if (_flushing) return;
    // Claimed before the first await (2026-10-06): two triggers landing
    // together (poll + resume + a [kickFlush]) both used to pass the
    // `isOffline` await with `_flushing` still false, and the lease does not
    // separate them — same owner — so the same photos uploaded twice.
    _flushing = true;
    try {
      // FR-4.4 — the app and a background run are separate engines sharing
      // one queue. Whoever doesn't hold the lease steps aside; the holder
      // drains everything anyway.
      if (await isOffline || !await _db.tryAcquireFlushLease(_leaseOwner)) {
        _flushing = false;
        return;
      }
    } catch (_) {
      _flushing = false;
      rethrow;
    }
    var changed = false;
    var stopped = false;

    try {
      final pending = await _db.listMutations();
      if (pending.isEmpty) return;
      final replayed = <ReplayedWrite>[];

      final stopIndex = stopAfterId == null
          ? -1
          : pending.indexWhere((m) => m.clientMutationId == stopAfterId);
      final total = stopIndex >= 0 ? stopIndex + 1 : pending.length;
      _progress = SyncProgress(completed: 0, total: total);
      _bus.notify();

      for (var i = 0; i < pending.length; i++) {
        final mutation = pending[i];
        try {
          var body = mutation.body;
          if (mutation.hasAttachments) {
            // FR-4.7 — each attachment uploads and resolves independently;
            // one already carrying `uploadedUrl` (a prior partial attempt on
            // this same mutation) is skipped rather than re-sent.
            var current = mutation.attachments;
            for (var j = 0; j < current.length; j++) {
              var a = current[j];
              if (a.uploadedUrl == null) {
                final uploadedUrl = await uploadBytes(
                  bytes: a.bytes,
                  fileName: a.fileName,
                  field: a.field,
                );
                a = a.withUploadedUrl(uploadedUrl);
                current = [
                  for (var k = 0; k < current.length; k++)
                    k == j ? a : current[k],
                ];
                await _db.updateMutationAttachments(
                  mutation.clientMutationId,
                  current,
                );
              }
              body = _substitute(body, a.placeholder, a.uploadedUrl!);
            }
          }
          final response = await _api.request(
            mutation.method,
            mutation.url,
            data: body,
            mutationId: mutation.clientMutationId,
          );
          // Replayed from the queue, nobody is waiting on this body: a
          // per-item refusal inside the 200 (P-008 (2), four-eyes) is logged
          // here or the technician never hears of it.
          await _recordReplayNotices(
            response.data,
            label: mutation.label,
            url: mutation.url,
            includeRefusals: true,
          );
          await _db.deleteMutation(mutation.clientMutationId);
          replayed.add((entityType: mutation.entityType, entityId: mutation.entityId));
          changed = true;
        } on NetworkFailure {
          break;
        } on ApiFailure catch (e) {
          // An HttpFailure: the 428 location-gate trap: `middleware/auth.ts`
          // refuses every mutating request once the technician's last GPS
          // fix is stale. Every mutation behind this one would fail the exact
          // same way until a fresh fix is captured, so this stops the run —
          // same as a NetworkFailure — rather than dropping a whole shift's
          // queued checks as unrecoverable 4xxs. `ApiClient`'s interceptor
          // already fired `onLocationRequired`, which `LocationCheckInGate`
          // turns into a blocking check-in prompt; `CheckInController.checkIn()`
          // resumes this queue once a fix lands. A 401 (expired session)
          // stops the run for the same reason — see [classifyFlushFailure].
          //
          // Any other ApiFailure is neither a network failure nor an HTTP
          // answer: `uploadBytes` got a 2xx without a URL (UnknownFailure). This used to escape the loop
          // and abort the whole flush on every run, so one such item stuck
          // the entire queue behind it. Now it is a server-side failure like
          // a 5xx: retried, then dropped (or kept, for the entity types in
          // [kKeepOnServerErrorEntityTypes]).
          final status = e is HttpFailure ? e.status : 0;
          final outcome = classifyFlushFailure(
            status: status,
            attemptsSoFar: mutation.attempts,
            maxAttempts: Env.maxMutationAttempts,
            keepOnServerError: kKeepOnServerErrorEntityTypes.contains(mutation.entityType),
          );
          await _reportFailure(
            mutation,
            ReplayFailure(status: status, outcome: outcome, code: _codeOf(e)),
          );
          switch (outcome) {
            case FlushOutcome.stopRun:
              stopped = true;
            case FlushOutcome.drop:
              await _db.addConflict(
                label: mutation.label,
                url: mutation.url,
                reason: e.message,
              );
              await _db.deleteMutation(mutation.clientMutationId);
              changed = true;
            case FlushOutcome.retryLater:
              await _db.bumpAttempts(
                mutation.clientMutationId,
                mutation.attempts + 1,
              );
              changed = true;
          }
          if (stopped) break;
        }

        // Renew the lease after every item, so a long drain over a slow
        // link (8 photos per check) never lets it lapse mid-run.
        await _db.tryAcquireFlushLease(_leaseOwner);
        _progress = SyncProgress(completed: i + 1, total: total);
        _bus.notify();
        if (mutation.clientMutationId == stopAfterId) break;
      }
      // After the loop, so a slow re-read never holds up the drain.
      await _replayHooks.runFor(replayed);
    } finally {
      _flushing = false;
      await _db.releaseFlushLease(_leaseOwner);
      if (_progress != null) {
        _progress = null;
        _bus.notify();
      } else if (changed) {
        _bus.notify();
      }
      if (_flushAgain && !stopped) {
        _flushAgain = false;
        unawaited(flushQueue());
      }
      _flushAgain = false;
    }
  }

  static String? _codeOf(ApiFailure e) {
    if (e is! HttpFailure) return null;
    final body = e.body;
    final code = body is Map ? body['code'] : null;
    return code is String && code.isNotEmpty ? code : null;
  }

  Future<void> _reportFailure(PendingMutation m, ReplayFailure failure) async {
    final type = m.entityType;
    final id = m.entityId;
    if (type == null || id == null) return;
    final hook = _failureHooks[type];
    if (hook == null) return;
    try {
      await hook(id, failure);
    } catch (_) {
      // Display-only bookkeeping; never let it break the drain.
    }
  }

  Future<String> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String field = 'file',
    String? entityType,
    String? entityId,
  }) async {
    final path = field == 'image' ? '/api/upload/image' : '/api/upload/file';
    final form = FormData.fromMap({
      field: MultipartFile.fromBytes(bytes, filename: fileName),
      'entityType': ?entityType,
      'entityId': ?entityId,
    });
    final response = await _api.post(
      path,
      data: form,
      receiveTimeout: Env.uploadTimeout,
    );
    final body = response.data;
    final url = body is Map
        ? (body['data'] is Map ? body['data']['url'] : body['url'])
        : null;
    if (url is! String || url.isEmpty) {
      throw const UnknownFailure(
        "The upload didn't complete. Please try again.",
      );
    }
    return url;
  }

  /// What a successful response still has to tell the technician, logged in
  /// the local conflict log the Sync Center shows (`replay_notices.dart`):
  /// FR-4.8 `captureConflict` (the register moved while the write was queued;
  /// informational, `dropped: false`) and, with [includeRefusals], per-item
  /// refusals in `rejected[]` (P-008 (2); `dropped: true`).
  Future<void> _recordReplayNotices(
    dynamic responseData, {
    required String label,
    required String url,
    required bool includeRefusals,
  }) async {
    final notices = [
      for (final n in replayNoticesFrom(responseData))
        if (includeRefusals || !n.dropped) n,
    ];
    if (notices.isEmpty) return;
    for (final n in notices) {
      await _db.addConflict(
        label: label,
        url: url,
        reason: n.reason,
        dropped: n.dropped,
      );
    }
    _bus.notify();
  }

  dynamic _substitute(dynamic body, String? placeholder, String url) {
    if (placeholder == null || body == null) return body;
    final encoded = jsonEncode(body).replaceAll(placeholder, url);
    return jsonDecode(encoded);
  }
}

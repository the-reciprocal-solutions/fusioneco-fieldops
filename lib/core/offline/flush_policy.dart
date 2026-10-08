/// What [SyncClient.flushQueue] does with one queued mutation the server
/// answered with an error. Pulled out as pure functions so the rules that
/// decide whether a technician's evidence is kept or dropped are unit-tested
/// on their own, without a database or a network.
enum FlushOutcome {
  /// Stop the whole run and keep everything queued. Every mutation behind
  /// this one would fail the same way until something outside the queue
  /// changes (a fresh GPS fix, a new sign-in), so dropping them would lose
  /// work that is perfectly valid.
  stopRun,

  /// The server rejected this one for good (a 4xx, or out of retries). Move
  /// it to the conflict log and carry on with the next.
  drop,

  /// A server-side hiccup (5xx) with attempts left. Keep it and move on.
  retryLater,
}

/// Entity types whose queued writes are never given up on for a server-side
/// failure (5xx, or an upload that came back without a URL). Snag creates
/// carry the only copy of a defect's photos: the default "5 attempts, then
/// the conflict log" burns through in about 100 s on the 20 s poll, so a
/// short server outage — or a server still answering
/// `503 SNAG_ENGINE_NOT_ENABLED` — used to strand every snag of a walk as
/// "on this phone" for good (2026-10-06, iPhone report). A 4xx is still a
/// real refusal and still drops. A constant rather than a registration so
/// the Android background engine, which builds its own [SyncClient], applies
/// the same rule. Must match `SnagRepository.entityType`/`surveyEntityType`
/// (test/snag_outbox_test.dart checks).
const kKeepOnServerErrorEntityTypes = <String>{'Snag', 'SnagSurvey'};

FlushOutcome classifyFlushFailure({
  required int status,
  required int attemptsSoFar,
  required int maxAttempts,
  bool keepOnServerError = false,
}) {
  // 428 — the location gate (see `middleware/auth.ts`): fixed by a check-in.
  // 401 — the session expired: fixed by signing in again. FR-4.4 makes this
  // one matter: a background run can start hours after the 24h session
  // lapsed, with nobody there to sign in, and treating it as an ordinary
  // 4xx would silently move a whole shift's checks into "could not be saved".
  if (status == 428 || status == 401) return FlushOutcome.stopRun;

  if (status >= 400 && status < 500) return FlushOutcome.drop;
  // 5xx, or 0 = no HTTP status at all (an upload answered without a URL).
  if (keepOnServerError) return FlushOutcome.retryLater;
  final attempts = attemptsSoFar + 1;
  if (attempts >= maxAttempts) return FlushOutcome.drop;
  return FlushOutcome.retryLater;
}

/// What a queued write's failed replay looked like, handed to the
/// repository that owns it (see `SyncClient.onReplayFailed`) so it can show
/// the technician *why* something has not gone yet — in plain words, never
/// the server's raw message.
class ReplayFailure {
  const ReplayFailure({required this.status, required this.outcome, this.code});

  /// HTTP status; 0 when the server never gave one (an upload without a URL).
  final int status;

  /// The server's machine code (`{code: "SNAG_ENGINE_NOT_ENABLED"}`), if any.
  final String? code;
  final FlushOutcome outcome;
}

typedef ReplayFailureHook = Future<void> Function(String entityId, ReplayFailure failure);

/// FR-4.4 — a short-lived "I'm uploading" marker in `sync_meta`, so the app
/// and a background WorkManager run (a separate Flutter engine on Android)
/// never replay the queue at the same time. Replaying a check twice is safe,
/// since the server's idempotency guard dedupes on the mutation id. Uploading
/// its photos twice is not: each upload mints a new file. So the queue has one
/// drainer at a time.
///
/// It's a lease rather than a plain flag, so a run that dies mid-flush (the
/// OS kills the background engine) can't lock the queue forever. The holder
/// renews it after every item, and on a [heartbeat] while an item is in
/// flight.
///
/// 2026-10-08 (device test): [ttl] was 3 minutes, sized to outlast one slow
/// item (8 photos over a weak link) since renewal only happened between
/// items. Android then cancelled a background run right after its POST
/// landed — before it deleted the row or released the lease — and the app
/// showed "1 waiting" for the full 3 minutes although the server had it.
/// Now the holder renews every [heartbeat] while running, so [ttl] only has
/// to cover a few missed beats: a dead holder frees the queue in ≤ [ttl],
/// while a slow but alive one keeps it.
class SyncLease {
  const SyncLease({required this.owner, required this.expiresAt});

  final String owner;
  final DateTime expiresAt;

  static const ttl = Duration(seconds: 45);

  /// How often a live holder renews. Three beats fit in one [ttl], so one
  /// slow database write cannot cost a working holder its lease.
  static const heartbeat = Duration(seconds: 15);

  /// `owner|expiresAtMs` — stored as one `sync_meta` value.
  String encode() => '$owner|${expiresAt.millisecondsSinceEpoch}';

  static SyncLease? decode(String? raw) {
    if (raw == null) return null;
    final bar = raw.lastIndexOf('|');
    if (bar <= 0) return null;
    final ms = int.tryParse(raw.substring(bar + 1));
    if (ms == null) return null;
    return SyncLease(
      owner: raw.substring(0, bar),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  /// [owner] may take (or renew) the lease if nobody holds it, it has
  /// expired, or [owner] already holds it.
  static bool canTake(SyncLease? current, String owner, DateTime now) =>
      current == null ||
      current.owner == owner ||
      !current.expiresAt.isAfter(now);
}

/// Why queued writes have not gone yet, in words a technician can act on —
/// the "Waiting to send" sheet behind the shell's sync banner (2026-10-06).
///
/// Pure: [SyncClient] records a [ReplayStatus] per mutation as it flushes,
/// and [explainQueue] turns the queue plus those statuses into one
/// [WaitingReason] per item. Tested in test/waiting_reasons_test.dart.
library;

/// What the last replay of one queued write ran into.
enum WaitKind {
  /// No connection at all when it was tried.
  network,

  /// There was a connection but no answer for this item (a timeout, a
  /// stalled upload). Stops the run, like [network].
  noAnswer,

  /// The server answered 5xx; retried automatically.
  serverBusy,

  /// The server answered 5xx with a machine code (e.g. `503
  /// SNAG_ENGINE_NOT_ENABLED`): a feature not switched on for the site yet.
  serverNotReady,

  /// 428: the location check-in gate. Stops the run.
  location,

  /// 401 the session renewal could not fix. Stops the run.
  signIn,

  /// Could not be prepared on this phone (not a server answer).
  appError,
}

class ReplayStatus {
  const ReplayStatus(this.kind, {required this.at, this.status, this.code});

  final WaitKind kind;
  final DateTime at;
  final int? status;
  final String? code;
}

/// The one line the sheet shows under each item.
enum WaitingReason {
  /// The phone is offline; everything goes when signal is back.
  offline,

  /// Being sent right now.
  sending,

  /// Not tried yet (or tried while offline and not again since).
  notSentYet,

  /// Signal, but this item got no answer; it will be tried again.
  noAnswer,

  /// The server was busy; it retries automatically.
  serverBusy,

  /// The feature is not switched on for this site yet; kept on the phone.
  serverNotReady,

  /// Waiting for the location check-in.
  needsCheckIn,

  /// Waiting for the technician to sign in again.
  needsSignIn,

  /// Could not be prepared on this phone; Retry or Discard.
  cannotPrepare,

  /// Queued behind an item above that is waiting (order is kept).
  behindOther,
}

/// The fields of a queued write the explanation needs.
class QueueEntry {
  const QueueEntry({
    required this.id,
    required this.label,
    required this.createdAt,
    this.attempts = 0,
  });

  final String id;
  final String label;
  final DateTime createdAt;
  final int attempts;
}

class WaitingItem {
  const WaitingItem({required this.entry, required this.reason});

  final QueueEntry entry;
  final WaitingReason reason;

  /// A reason the technician might want to act on (Retry / Discard / check
  /// in), rather than one that simply resolves itself in a few seconds.
  bool get needsAttention => switch (reason) {
        WaitingReason.offline ||
        WaitingReason.sending ||
        WaitingReason.notSentYet ||
        WaitingReason.behindOther =>
          false,
        _ => true,
      };
}

/// One reason per queued item, oldest first ([queue] must already be in
/// replay order). A run stops at a [WaitKind.noAnswer], [WaitKind.location]
/// or [WaitKind.signIn] item, so everything after it reads
/// [WaitingReason.behindOther] — that is the honest answer for those.
List<WaitingItem> explainQueue({
  required List<QueueEntry> queue,
  required Map<String, ReplayStatus> statuses,
  required bool offline,
  bool syncing = false,
}) {
  final out = <WaitingItem>[];
  var blocked = false;
  for (final e in queue) {
    WaitingReason reason;
    final s = statuses[e.id];
    if (offline) {
      reason = WaitingReason.offline;
    } else if (blocked) {
      reason = WaitingReason.behindOther;
    } else {
      switch (s?.kind) {
        case null:
        case WaitKind.network:
          reason = syncing ? WaitingReason.sending : WaitingReason.notSentYet;
        case WaitKind.noAnswer:
          reason = WaitingReason.noAnswer;
          blocked = true;
        case WaitKind.serverBusy:
          reason = WaitingReason.serverBusy;
        case WaitKind.serverNotReady:
          reason = WaitingReason.serverNotReady;
        case WaitKind.location:
          reason = WaitingReason.needsCheckIn;
          blocked = true;
        case WaitKind.signIn:
          reason = WaitingReason.needsSignIn;
          blocked = true;
        case WaitKind.appError:
          reason = WaitingReason.cannotPrepare;
      }
    }
    out.add(WaitingItem(entry: e, reason: reason));
  }
  return out;
}

/// Whether the shell's banner should show while ONLINE. A write queued a
/// moment ago is normally sent within seconds (outbox-first saves enqueue and
/// flush at once), and a bar that flashes up for that read as "something
/// random at the top of the app" (owner, 2026-10-06). So: only when an item
/// needs attention, or something has waited longer than [grace].
bool shouldShowWaitingBanner(
  List<WaitingItem> items, {
  required DateTime now,
  Duration grace = const Duration(seconds: 30),
}) {
  if (items.isEmpty) return false;
  for (final i in items) {
    if (i.needsAttention) return true;
    if (now.difference(i.entry.createdAt) > grace) return true;
  }
  return false;
}

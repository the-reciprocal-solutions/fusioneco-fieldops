import '../../domain/snag.dart';

/// Where one snag is on its way to the server, in the terms a technician
/// cares about (2026-10-06). Replaces the single "On device" flag, which
/// read the same for "uploading right now", "no signal", "the server is
/// refusing it" and "this will never send by itself" — the iPhone report
/// "shows as saved locally but does not persist" was the last one hiding
/// behind the first.
enum SnagSendState {
  /// The server has it and nothing is waiting.
  synced,

  /// Queued, and the queue is draining right now.
  sending,

  /// Queued, nothing has gone wrong yet — usually no signal.
  waiting,

  /// Queued behind the location check-in gate (428).
  waitingCheckIn,

  /// Queued; the session expired (401). Sends after the next sign-in.
  waitingSignIn,

  /// Queued; the server failed (5xx) or is not taking snags yet. Retries
  /// on its own — snag writes are never dropped for a server failure.
  retrying,

  /// Not queued and not on the server: the server refused it (4xx), or an
  /// older build gave up on it. Only a Retry tap sends it again.
  notSent;

  bool get isSynced => this == SnagSendState.synced;

  /// A Retry button makes sense (a manual nudge never hurts while queued).
  bool get canRetry => this != SnagSendState.synced && this != SnagSendState.sending;
}

class SnagSendStatus {
  const SnagSendStatus(this.state, {this.reasonKey});
  final SnagSendState state;

  /// i18n key of the plain-words reason, null when there is nothing to say.
  final String? reasonKey;

  /// Short label for a list flag.
  String get labelKey => switch (state) {
    SnagSendState.synced => 'snags.send.synced',
    SnagSendState.sending => 'snags.send.sending',
    SnagSendState.notSent => 'snags.send.not_sent',
    _ => 'snags.send.waiting',
  };
}

/// [queued]: a write for this snag is in the offline queue.
/// [flushing]: the queue is draining right now.
SnagSendStatus snagSendStatus(Snag s, {required bool queued, required bool flushing}) {
  final issue = s.sendIssue;
  if (queued) {
    if (issue == null || issue.dropped) {
      return SnagSendStatus(
        flushing ? SnagSendState.sending : SnagSendState.waiting,
        reasonKey: flushing ? null : 'snags.send.waiting_hint',
      );
    }
    if (issue.status == 428) {
      return const SnagSendStatus(SnagSendState.waitingCheckIn, reasonKey: 'snags.send.checkin_hint');
    }
    if (issue.status == 401) {
      return const SnagSendStatus(SnagSendState.waitingSignIn, reasonKey: 'snags.send.signin_hint');
    }
    if (flushing) return const SnagSendStatus(SnagSendState.sending);
    return SnagSendStatus(
      SnagSendState.retrying,
      reasonKey: issue.code == 'SNAG_ENGINE_NOT_ENABLED' ? 'snags.send.not_enabled_hint' : 'snags.send.retrying_hint',
    );
  }
  if (issue != null && issue.dropped) {
    return SnagSendStatus(SnagSendState.notSent, reasonKey: refusedReasonKey(issue));
  }
  if (s.localOnly) {
    // Not queued, never confirmed, no recorded refusal: a create an older
    // build gave up on, or one whose confirmation has not been read back yet.
    return const SnagSendStatus(SnagSendState.notSent, reasonKey: 'snags.send.stranded_hint');
  }
  return const SnagSendStatus(SnagSendState.synced);
}

/// Plain words for a 4xx refusal. The server's own message is deliberately
/// not shown: it is written for developers ("trade must be one of: …").
String refusedReasonKey(SnagSendIssue issue) {
  if (issue.status == 403) return 'snags.send.refused_access';
  if (issue.status == 404) return 'snags.send.refused_missing';
  if (issue.status == 409) return 'snags.send.refused_conflict';
  if (issue.status == 413) return 'snags.send.refused_too_large';
  return 'snags.send.refused_hint';
}

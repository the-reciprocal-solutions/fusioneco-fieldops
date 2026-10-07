import '../../domain/conversation.dart';

/// Pure rules for showing an agent's work in a thread
/// (docs/conversations-and-schedules.md "Agent activity"). Nothing here
/// invents progress: every step comes from the server — a session's `stage`,
/// a specialist's stage, or an agent `typing` event — and is only remembered
/// in the order this phone saw it.

/// A session the server still calls queued/working but that started longer
/// ago than this is treated as stuck, not live. The server's own "busy"
/// window is 20 min (`LIVE_SESSION_WINDOW_MS`) and "active work" 30 min; a
/// run whose job was lost (e.g. a technician's run before the 2026-10-06
/// server fix) otherwise kept a pulsing Working card on the thread for 24 h.
const kStaleSessionAfter = Duration(minutes: 30);

/// Queued (not yet working) for longer than this → say it plainly
/// ("Still waiting to start…") instead of a silent spinner.
const kWaitingLongAfter = Duration(minutes: 2);

/// How long after asking an agent the thread polls fast even when the POST
/// started no session (a schedule capture, a clarifying question, a note):
/// the server posts those lines itself, and a lost socket must not hide them.
const kAgentFollowUpWindow = Duration(seconds: 45);

/// Most steps kept per session (the newest win).
const kMaxTrailSteps = 8;

bool isStaleSession(ConvSession s, DateTime now) => s.isLive && now.difference(s.countFrom) > kStaleSessionAfter;

bool isWaitingLong(ConvSession s, DateTime now) =>
    s.status == SessionStatus.queued && now.difference(s.countFrom) > kWaitingLongAfter;

/// The sessions to show as working right now: live and not stuck.
List<ConvSession> visibleLiveSessions(Iterable<ConvSession> sessions, DateTime now) =>
    [for (final s in sessions) if (s.isLive && !isStaleSession(s, now)) s];

/// Appends [stage] to a session's step list when it differs from the last
/// step (a poll repeats the same stage; that is not a new step).
List<String> appendStep(List<String> trail, String? stage) {
  final st = stage?.trim() ?? '';
  if (st.isEmpty) return trail;
  if (trail.isNotEmpty && trail.last == st) return trail;
  final next = [...trail.where((s) => s != st), st];
  return next.length > kMaxTrailSteps ? next.sublist(next.length - kMaxTrailSteps) : next;
}

/// Records every real stage carried by [s] (its own stage, then each
/// specialist's as "Name · stage") into [trails] keyed by session id.
Map<String, List<String>> recordSession(Map<String, List<String>> trails, ConvSession s) {
  if (s.id.isEmpty) return trails;
  final before = trails[s.id] ?? const <String>[];
  var t = appendStep(before, s.stage);
  for (final sp in s.specialists) {
    if (sp.stage != null && sp.stage!.trim().isNotEmpty) t = appendStep(t, '${sp.name} · ${sp.stage}');
  }
  // appendStep hands back the same list when nothing new was seen.
  return identical(t, before) ? trails : {...trails, s.id: t};
}

/// The live session an agent `typing` event belongs to: the one whose agent
/// typed, else the only live one (a specialist typing for the Flow Agent).
ConvSession? sessionForTyping(Iterable<ConvSession> sessions, String agentId) {
  final live = sessions.where((s) => s.isLive).toList();
  for (final s in live) {
    if (s.agentId == agentId) return s;
  }
  return live.length == 1 ? live.first : null;
}

/// Sessions that just ended badly (live before, failed/offline/stopped now)
/// with no agent reply to their message in [messages] — the thread then says
/// so in plain words instead of the Working card just vanishing.
List<ConvSession> endedWithoutReply(
  List<ConvSession> before,
  List<ConvSession> after,
  List<ConvMessage> messages,
) {
  final wasLive = {for (final s in before) if (s.isLive) s.id};
  return [
    for (final s in after)
      if (wasLive.contains(s.id) &&
          (s.status == SessionStatus.failed || s.status == SessionStatus.stopped || s.status == SessionStatus.offline) &&
          !messages.any((m) => m.isAgent && (m.id == s.replyId || (s.messageId.isNotEmpty && m.replyTo == s.messageId && m.kind != ConvMessageKind.system))))
        s,
  ];
}

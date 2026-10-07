import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/offline/flush_policy.dart';
import 'package:technician_portal/core/snag/snag_send_state.dart';
import 'package:technician_portal/domain/snag.dart';

Snag _snag({bool localOnly = false, SnagSendIssue? issue}) => Snag(
  id: 'abc123456',
  context: SnagContext.operations,
  issueType: 'defect',
  trade: 'civil',
  priority: SnagPriority.minor,
  title: 't',
  status: SnagStatus.open,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  localOnly: localOnly,
  sendIssue: issue,
);

SnagSendIssue _issue(int status, {String? code, bool dropped = false}) =>
    SnagSendIssue(status: status, code: code, dropped: dropped, at: DateTime(2026));

void main() {
  SnagSendStatus st(Snag s, {bool queued = false, bool flushing = false}) =>
      snagSendStatus(s, queued: queued, flushing: flushing);

  test('server copy, nothing queued → synced (no badge)', () {
    expect(st(_snag()).state, SnagSendState.synced);
  });

  test('queued, draining → sending; idle → waiting for signal', () {
    expect(st(_snag(localOnly: true), queued: true, flushing: true).state, SnagSendState.sending);
    final w = st(_snag(localOnly: true), queued: true);
    expect(w.state, SnagSendState.waiting);
    expect(w.reasonKey, 'snags.send.waiting_hint');
  });

  test('queued behind the location gate or an expired session says so', () {
    expect(st(_snag(localOnly: true, issue: _issue(428)), queued: true).state, SnagSendState.waitingCheckIn);
    expect(st(_snag(localOnly: true, issue: _issue(401)), queued: true).state, SnagSendState.waitingSignIn);
  });

  test('queued after a 5xx → retrying; an older server\'s engine-not-enabled reads the same, never "not switched on"', () {
    final r = st(_snag(localOnly: true, issue: _issue(500)), queued: true);
    expect(r.state, SnagSendState.retrying);
    expect(r.reasonKey, 'snags.send.retrying_hint');
    // Snags are on for every site (owner iPhone test, 2026-10-06): no
    // separate "not switched on for your site" state any more.
    final legacy = st(_snag(localOnly: true, issue: _issue(503, code: 'SNAG_ENGINE_NOT_ENABLED')), queued: true);
    expect(legacy.state, SnagSendState.retrying);
    expect(legacy.reasonKey, 'snags.send.retrying_hint');
  });

  test('refused (dropped 4xx) and not queued → Not sent with a plain reason and Retry', () {
    final r = st(_snag(localOnly: true, issue: _issue(403, dropped: true)));
    expect(r.state, SnagSendState.notSent);
    expect(r.reasonKey, 'snags.send.refused_access');
    expect(r.state.canRetry, isTrue);
    expect(st(_snag(localOnly: true, issue: _issue(400, dropped: true))).reasonKey, 'snags.send.refused_hint');
  });

  test('a retry after a refusal reads as waiting again, not refused', () {
    expect(st(_snag(localOnly: true, issue: _issue(400, dropped: true)), queued: true).state, SnagSendState.waiting);
  });

  test('stranded by an older build (localOnly, nothing queued, no issue) → Not sent', () {
    final r = st(_snag(localOnly: true));
    expect(r.state, SnagSendState.notSent);
    expect(r.reasonKey, 'snags.send.stranded_hint');
  });

  test('sendIssue round-trips through the local row and is never in copyWith-cleared state by accident', () {
    final s = _snag(localOnly: true, issue: _issue(503, code: 'X'));
    final back = Snag.fromJson(s.toJson());
    expect(back.sendIssue?.status, 503);
    expect(back.sendIssue?.code, 'X');
    expect(back.copyWith(title: 'n').sendIssue, isNotNull);
    expect(back.copyWith(clearSendIssue: true).sendIssue, isNull);
  });

  group('classifyFlushFailure keepOnServerError', () {
    test('a 5xx is retried forever for kept types, still dropped for others', () {
      expect(
        classifyFlushFailure(status: 503, attemptsSoFar: 40, maxAttempts: 5, keepOnServerError: true),
        FlushOutcome.retryLater,
      );
      expect(classifyFlushFailure(status: 503, attemptsSoFar: 4, maxAttempts: 5), FlushOutcome.drop);
    });

    test('status 0 (upload without URL) behaves like a 5xx', () {
      expect(classifyFlushFailure(status: 0, attemptsSoFar: 0, maxAttempts: 5), FlushOutcome.retryLater);
      expect(classifyFlushFailure(status: 0, attemptsSoFar: 9, maxAttempts: 5, keepOnServerError: true), FlushOutcome.retryLater);
    });

    test('a 4xx still drops and 428/401 still stop, kept or not', () {
      expect(classifyFlushFailure(status: 400, attemptsSoFar: 0, maxAttempts: 5, keepOnServerError: true), FlushOutcome.drop);
      expect(classifyFlushFailure(status: 428, attemptsSoFar: 0, maxAttempts: 5, keepOnServerError: true), FlushOutcome.stopRun);
      expect(classifyFlushFailure(status: 401, attemptsSoFar: 0, maxAttempts: 5, keepOnServerError: true), FlushOutcome.stopRun);
    });
  });
}

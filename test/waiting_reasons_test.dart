import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/offline/waiting_reasons.dart';

final _t0 = DateTime(2026, 10, 6, 9);

QueueEntry _e(String id, {int ageSec = 0}) =>
    QueueEntry(id: id, label: 'Change $id', createdAt: _t0.subtract(Duration(seconds: ageSec)));

ReplayStatus _s(WaitKind k, {String? code}) => ReplayStatus(k, at: _t0, code: code);

List<WaitingReason> _reasons(List<WaitingItem> items) => [for (final i in items) i.reason];

void main() {
  group('explainQueue', () {
    test('offline: every item waits for signal', () {
      final out = explainQueue(
        queue: [_e('a'), _e('b')],
        statuses: {'a': _s(WaitKind.serverBusy)},
        offline: true,
      );
      expect(_reasons(out), [WaitingReason.offline, WaitingReason.offline]);
    });

    test('never tried: not sent yet, or sending while a run is going', () {
      expect(_reasons(explainQueue(queue: [_e('a')], statuses: {}, offline: false)), [WaitingReason.notSentYet]);
      expect(
        _reasons(explainQueue(queue: [_e('a')], statuses: {}, offline: false, syncing: true)),
        [WaitingReason.sending],
      );
    });

    test('tried while offline, now online: just not sent yet', () {
      final out = explainQueue(queue: [_e('a')], statuses: {'a': _s(WaitKind.network)}, offline: false);
      expect(_reasons(out), [WaitingReason.notSentYet]);
    });

    test('a 428 stops the run: that item needs a check-in, the rest wait behind it', () {
      final out = explainQueue(
        queue: [_e('a'), _e('b'), _e('c')],
        statuses: {'b': _s(WaitKind.location)},
        offline: false,
      );
      expect(_reasons(out), [WaitingReason.notSentYet, WaitingReason.needsCheckIn, WaitingReason.behindOther]);
    });

    test('a refused sign-in stops the run', () {
      final out = explainQueue(queue: [_e('a'), _e('b')], statuses: {'a': _s(WaitKind.signIn)}, offline: false);
      expect(_reasons(out), [WaitingReason.needsSignIn, WaitingReason.behindOther]);
    });

    test('no answer for one item (timeout / stalled upload) holds the queue behind it', () {
      final out = explainQueue(queue: [_e('a'), _e('b')], statuses: {'a': _s(WaitKind.noAnswer)}, offline: false);
      expect(_reasons(out), [WaitingReason.noAnswer, WaitingReason.behindOther]);
    });

    test('a 5xx does not block the rest (retryLater carries on)', () {
      final out = explainQueue(
        queue: [_e('a'), _e('b')],
        statuses: {'a': _s(WaitKind.serverBusy)},
        offline: false,
      );
      expect(_reasons(out), [WaitingReason.serverBusy, WaitingReason.notSentYet]);
    });

    test('snag engine not switched on: kept, plain "not switched on for your site"', () {
      final out = explainQueue(
        queue: [_e('a')],
        statuses: {'a': _s(WaitKind.serverNotReady, code: 'SNAG_ENGINE_NOT_ENABLED')},
        offline: false,
      );
      expect(_reasons(out), [WaitingReason.serverNotReady]);
      expect(out.single.needsAttention, isTrue);
    });

    test('a poisoned item is explained, and does not block the items after it', () {
      final out = explainQueue(queue: [_e('a'), _e('b')], statuses: {'a': _s(WaitKind.appError)}, offline: false);
      expect(_reasons(out), [WaitingReason.cannotPrepare, WaitingReason.notSentYet]);
    });
  });

  group('shouldShowWaitingBanner (online)', () {
    test('empty queue: never', () {
      expect(shouldShowWaitingBanner(const [], now: _t0), isFalse);
    });

    test('a write queued seconds ago and about to go: no bar flashing up', () {
      final items = explainQueue(queue: [_e('a', ageSec: 3)], statuses: {}, offline: false, syncing: true);
      expect(shouldShowWaitingBanner(items, now: _t0), isFalse);
    });

    test('something waiting longer than 30 s: shown', () {
      final items = explainQueue(queue: [_e('a', ageSec: 45)], statuses: {}, offline: false);
      expect(shouldShowWaitingBanner(items, now: _t0), isTrue);
    });

    test('something that needs attention: shown at once', () {
      final items = explainQueue(queue: [_e('a', ageSec: 1)], statuses: {'a': _s(WaitKind.location)}, offline: false);
      expect(shouldShowWaitingBanner(items, now: _t0), isTrue);
    });
  });
}

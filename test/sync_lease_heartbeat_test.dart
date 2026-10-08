// FR-4.4 lease heartbeat (2026-10-08). On device, Android cancelled a
// background run right after its POST landed; its 3-minute lease then kept
// the app from finishing the item, so "1 waiting" showed for 3 minutes
// although the server had it. The lease is now short and renewed on a
// heartbeat while a run is alive. These tests drive a real SyncClient on a
// fake clock (fake_async), with a server that can be held mid-send.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/network/api_client.dart';
import 'package:technician_portal/core/offline/flush_policy.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/core/offline/queue_bus.dart';
import 'package:technician_portal/core/offline/sync_client.dart';

class _Online implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.wifi];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds every request on [gate] until the test releases it.
class _Api implements ApiClient {
  Completer<void> gate = Completer<void>();
  final sent = <String>[];

  @override
  String newMutationId() => 'app-engine';

  @override
  Future<Response<dynamic>> request(String method, String path, {dynamic data, String? mutationId}) async {
    await gate.future;
    sent.add(path);
    return Response(requestOptions: RequestOptions(path: path), data: const {}, statusCode: 200);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The lease as the real DB stores it, so [SyncLease.canTake] decides.
class _Db implements OfflineDb {
  _Db(this.now);

  final DateTime Function() now;
  final queue = <PendingMutation>[];
  SyncLease? lease;
  var renewals = 0;

  @override
  Future<bool> tryAcquireFlushLease(String owner) async {
    if (!SyncLease.canTake(lease, owner, now())) return false;
    if (lease?.owner == owner) renewals++;
    lease = SyncLease(owner: owner, expiresAt: now().add(SyncLease.ttl));
    return true;
  }

  @override
  Future<void> releaseFlushLease(String owner) async {
    if (lease?.owner == owner) lease = null;
  }

  @override
  Future<List<PendingMutation>> listMutations() async => List.of(queue);
  @override
  Future<void> deleteMutation(String id) async => queue.removeWhere((m) => m.clientMutationId == id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PendingMutation _m(String id) => PendingMutation(
  clientMutationId: id,
  method: 'post',
  url: '/api/$id',
  body: const {},
  label: 'Submit asset verification',
  attempts: 0,
  createdAt: DateTime(2026, 10, 8),
);

void main() {
  test('the lease is short, but spans several heartbeats', () {
    expect(SyncLease.ttl, lessThanOrEqualTo(const Duration(minutes: 1)));
    expect(SyncLease.ttl.inSeconds, greaterThanOrEqualTo(SyncLease.heartbeat.inSeconds * 3));
  });

  test('a slow item keeps the lease alive through the heartbeat', () {
    fakeAsync((clock) {
      final api = _Api();
      final db = _Db(() => clock.getClock(DateTime(2026, 10, 8, 12)).now())..queue.add(_m('a'));
      final sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: _Online());

      var done = false;
      sync.flushQueue().then((_) => done = true);

      // Two minutes on one item: far past the 45 s lease without a heartbeat.
      clock.elapse(const Duration(minutes: 2));
      expect(done, isFalse);
      expect(db.lease?.owner, 'app-engine', reason: 'a live holder never lets it lapse');
      expect(db.renewals, greaterThanOrEqualTo(7));

      api.gate.complete();
      clock.flushMicrotasks();
      expect(done, isTrue);
      expect(api.sent, ['/api/a']);
      expect(db.lease, isNull, reason: 'released at the end of the run');

      // No stray timer keeps renewing after the run.
      final after = db.renewals;
      clock.elapse(const Duration(minutes: 1));
      expect(db.renewals, after);
    });
  });

  test('a holder that dies mid-send frees the queue within the lease, not 3 minutes', () {
    fakeAsync((clock) {
      final api = _Api()..gate.complete(); // the server answers at once
      final now = clock.getClock(DateTime(2026, 10, 8, 12));
      final db = _Db(now.now)..queue.add(_m('a'));
      final sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: _Online());

      // What the cancelled background run left behind: its lease, and no
      // heartbeat left to renew it.
      db.lease = SyncLease(owner: 'background', expiresAt: now.now().add(SyncLease.ttl));

      sync.flushQueue();
      clock.flushMicrotasks();
      expect(api.sent, isEmpty, reason: 'the app steps aside while the lease looks live');

      // A fixed 46 s, not `SyncLease.ttl`: the promise is "under a minute",
      // so putting the lease back to 3 minutes must fail this test.
      clock.elapse(const Duration(seconds: 46));
      sync.flushQueue(); // the app's next poll
      clock.flushMicrotasks();

      expect(api.sent, ['/api/a'], reason: 'taken over within the 45 s lease');
      expect(db.queue, isEmpty);
      expect(db.lease, isNull);
    });
  });

  test('a run that finds its lease taken over stops before the next item', () {
    fakeAsync((clock) {
      final api = _Api();
      final now = clock.getClock(DateTime(2026, 10, 8, 12));
      final db = _Db(now.now)..queue.addAll([_m('a'), _m('b')]);
      final sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: _Online());

      sync.flushQueue();
      clock.flushMicrotasks();
      // This run is frozen past its lease and another engine takes over.
      db.lease = SyncLease(owner: 'background', expiresAt: now.now().add(const Duration(minutes: 5)));
      clock.elapse(SyncLease.heartbeat + const Duration(seconds: 1));

      api.gate.complete(); // the in-flight item still finishes...
      clock.elapse(const Duration(seconds: 1));

      expect(api.sent, ['/api/a'], reason: '...but b is left to the engine holding the lease');
      expect(db.queue.map((m) => m.clientMutationId), ['b']);
      expect(db.lease?.owner, 'background', reason: "never releases someone else's lease");
    });
  });
}

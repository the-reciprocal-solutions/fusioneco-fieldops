// FR-4.6 — the Sync Center's per-row "sending" / "sent" states come from
// SyncClient.sendingId and SyncClient.recentlySent; this pins both down
// against a real SyncClient with a fake server that can be held mid-send.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/network/api_client.dart';
import 'package:technician_portal/core/network/api_exception.dart';
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

/// Each request waits on [gate] (when set) so a test can look at the client
/// while a write is in flight; [fail] makes the next request a network drop.
class _Api implements ApiClient {
  Completer<void>? gate;
  final started = StreamController<String>.broadcast();
  bool fail = false;

  @override
  Future<Response<dynamic>> request(String method, String path, {dynamic data, String? mutationId}) async {
    started.add(path);
    if (gate != null) await gate!.future;
    if (fail) throw const NetworkFailure('offline');
    return Response(requestOptions: RequestOptions(path: path), data: {'ok': true}, statusCode: 200);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Db implements OfflineDb {
  final queue = <PendingMutation>[];

  @override
  Future<List<PendingMutation>> listMutations() async => List.of(queue);
  @override
  Future<void> deleteMutation(String id) async => queue.removeWhere((m) => m.clientMutationId == id);
  @override
  Future<bool> tryAcquireFlushLease(String owner) async => true;
  @override
  Future<void> releaseFlushLease(String owner) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PendingMutation _m(String id, String label) => PendingMutation(
  clientMutationId: id,
  method: 'post',
  url: '/api/$id',
  body: const {},
  label: label,
  attempts: 0,
  createdAt: DateTime(2026, 10, 8),
);

class _NewIdApi extends _Api {
  @override
  String newMutationId() => 'lease';
}

void main() {
  late _Api api;
  late _Db db;
  late SyncClient sync;

  setUp(() {
    api = _NewIdApi();
    db = _Db()..queue.addAll([_m('a', 'Submit asset verification'), _m('b', 'Report tag issue')]);
    sync = SyncClient(api: api, db: db, bus: QueueBus(), connectivity: _Online());
  });

  test('marks the item in flight as sending, whatever started the run', () async {
    api.gate = Completer<void>();
    final firstStarted = api.started.stream.first;
    final run = sync.flushQueue(); // an automatic run: no row was tapped
    await firstStarted;

    expect(sync.sendingId, 'a');

    api.gate!.complete();
    await run;
    expect(sync.sendingId, isNull);
  });

  test('a sent write is listed as sent, newest first, instead of vanishing', () async {
    await sync.flushQueue();

    expect(db.queue, isEmpty);
    expect(sync.recentlySent.map((w) => w.label), ['Report tag issue', 'Submit asset verification']);
  });

  test('a run that stops on a network drop clears sending and lists nothing as sent', () async {
    api.fail = true;
    await sync.flushQueue();

    expect(sync.sendingId, isNull);
    expect(sync.recentlySent, isEmpty);
    expect(db.queue, hasLength(2));
  });
}

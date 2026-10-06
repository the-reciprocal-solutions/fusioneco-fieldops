import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/sync_client.dart';
import '../core/offline/waiting_reasons.dart';
import 'providers.dart';

/// State behind the shell's sync banner and its "Waiting to send" sheet
/// (2026-10-06). Kept out of providers.dart (the DI graph) on purpose.

/// Whether the phone is offline, as the banner shows it.
///
/// Starts online: at a cold start connectivity_plus can answer "none" before
/// Android has registered its network callback, and a one-shot check then
/// pinned the bar on screen with nothing re-checking it (device report
/// 2026-09-27: "offline bar at the top by default"). Online is believed at
/// once; offline only when a second check ~2 s later agrees. While offline it
/// re-checks every 10 s: the stream can miss the offline→online edge (see
/// SyncClient.startAutoFlush). Moved here from the banner widget so the sheet
/// reads the same answer.
class DeviceOfflineController extends Notifier<bool> {
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _confirm;
  Timer? _poll;

  @override
  bool build() {
    ref.onDispose(() {
      _sub?.cancel();
      _confirm?.cancel();
      _poll?.cancel();
    });
    try {
      _sub = Connectivity().onConnectivityChanged.listen((_) => _check(), onError: (Object _) {});
    } catch (_) {
      // No platform channel (a widget test): stay "online".
    }
    Future<void>.microtask(_check);
    return false;
  }

  Future<bool> _isOffline() async {
    try {
      return await ref.read(syncClientProvider).isOffline;
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    final offline = await _isOffline();
    if (!offline) {
      _confirm?.cancel();
      _poll?.cancel();
      _poll = null;
      if (state) state = false;
      return;
    }
    if (state) return;
    _confirm?.cancel();
    _confirm = Timer(const Duration(seconds: 2), () async {
      if (!await _isOffline()) return;
      state = true;
      _poll ??= Timer.periodic(const Duration(seconds: 10), (_) => _check());
    });
  }
}

final deviceOfflineProvider = NotifierProvider<DeviceOfflineController, bool>(DeviceOfflineController.new);

/// The queue, light (no bodies, no photo bytes), oldest first.
final queueEntriesProvider = FutureProvider<List<QueueEntry>>((ref) async {
  ref.watch(queueChangedProvider);
  final rows = await ref.watch(offlineDbProvider).listQueueEntries();
  return [
    for (final r in rows) QueueEntry(id: r.id, label: r.label, createdAt: r.createdAt, attempts: r.attempts),
  ];
});

/// One plain reason per queued write ([explainQueue]).
final waitingItemsProvider = Provider<List<WaitingItem>>((ref) {
  ref.watch(queueChangedProvider);
  final entries = ref.watch(queueEntriesProvider).valueOrNull ?? const <QueueEntry>[];
  final sync = ref.watch(syncClientProvider);
  return explainQueue(
    queue: entries,
    statuses: sync.lastReplayStatus,
    offline: ref.watch(deviceOfflineProvider),
    syncing: sync.isSyncing,
  );
});

/// What the sheet's buttons do — a seam so widget tests need no database.
abstract interface class WaitingActions {
  Future<void> retry(String mutationId);
  Future<void> discard(String mutationId);
  Future<void> sendAll();
}

class _SyncWaitingActions implements WaitingActions {
  const _SyncWaitingActions(this._sync);
  final SyncClient _sync;

  @override
  Future<void> retry(String mutationId) => _sync.retryMutation(mutationId);

  @override
  Future<void> discard(String mutationId) => _sync.discardMutation(mutationId);

  @override
  Future<void> sendAll() => _sync.flushQueue();
}

final waitingActionsProvider = Provider<WaitingActions>(
  (ref) => _SyncWaitingActions(ref.watch(syncClientProvider)),
);

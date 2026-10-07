import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/snag/snag_media.dart';
import '../data/snag_repository.dart';
import '../domain/snag.dart';
import 'auth_controller.dart';
import 'providers.dart';

/// Snag Assistant state (docs/snag-assistant.md). Hand-written providers,
/// same style as the rest of `state/`: screens read the *local* store, which
/// is always current; [SnagSyncController] pulls the server into it.

final snagMediaProvider = Provider<SnagMedia>((ref) => SnagMedia());

final snagRepositoryProvider = Provider<SnagRepository>((ref) {
  final sync = ref.watch(syncClientProvider);
  final repo = SnagRepository(
    sync: sync,
    api: ref.watch(apiClientProvider),
    store: ref.watch(offlineDbProvider),
    media: ref.watch(snagMediaProvider),
  );
  // 2026-10-06 — a queued snag write that syncs is confirmed at once (the
  // server's copy replaces "waiting to send"), and a failed replay records
  // why, for the plain-words reason on the card and detail. Registered here
  // because this provider is built by the dashboard's snag card at startup,
  // before the first flush can replay anything. Before this hook, a replayed
  // create kept `localOnly` until the hub happened to pull that building.
  void bump() => ref.read(snagTickProvider.notifier).state++;
  sync.onReplayed(SnagRepository.entityType, (id) async {
    await repo.afterReplay(id);
    bump();
  });
  sync.onReplayFailed(SnagRepository.entityType, (id, failure) async {
    await repo.afterReplayFailed(id, failure);
    bump();
  });
  sync.onReplayed(SnagRepository.surveyEntityType, (id) async {
    await repo.afterSurveyReplay(id);
    bump();
  });
  return repo;
});

/// Bumped after every local snag/survey write so every list re-reads the
/// store. The store is not part of the offline queue, so [queueChangedProvider]
/// alone would miss a write that synced straight through.
final snagTickProvider = StateProvider<int>((ref) => 0);

void bumpSnags(WidgetRef ref) => ref.read(snagTickProvider.notifier).state++;

final snagActorProvider = Provider<SnagActor?>((ref) {
  final session = ref.watch(authControllerProvider).session;
  if (session == null || session.userId.isEmpty) return null;
  return SnagActor(id: session.userId, name: session.name);
});

/// The building the hub is showing. Persisted in `sync_meta`, so a surveyor
/// working one site all week never picks it twice.
class SnagBuildingIdController extends Notifier<String?> {
  static const _metaKey = 'snag.buildingId';

  @override
  String? build() {
    unawaited(_restore());
    return null;
  }

  Future<void> _restore() async {
    final saved = await ref.read(offlineDbProvider).readMeta(_metaKey);
    if (state == null && saved != null && saved.isNotEmpty) state = saved;
  }

  Future<void> select(String id) async {
    state = id;
    await ref.read(offlineDbProvider).writeMeta(_metaKey, id);
  }
}

final snagBuildingIdProvider = NotifierProvider<SnagBuildingIdController, String?>(
  SnagBuildingIdController.new,
);

/// Cache first (see [SnagRepository.buildings]): paints the cached list at
/// once, re-reads itself only if the background check found a change.
final snagBuildingsProvider = FutureProvider<List<SnagBuilding>>(
  (ref) => ref.watch(snagRepositoryProvider).buildings(onStale: ref.invalidateSelf),
);

final snagTreeProvider = FutureProvider.family<SnagLocationTree?, String>(
  (ref, buildingId) => ref.watch(snagRepositoryProvider).tree(buildingId, onStale: ref.invalidateSelf),
);

/// Local snags, one building or all ([buildingId] null).
final snagsProvider = FutureProvider.family<List<Snag>, String?>((ref, buildingId) async {
  ref.watch(snagTickProvider);
  return ref.watch(snagRepositoryProvider).local(buildingId: buildingId);
});

final snagByIdProvider = FutureProvider.family<Snag?, String>((ref, id) async {
  ref.watch(snagTickProvider);
  final repo = ref.watch(snagRepositoryProvider);
  return await repo.localById(id) ?? await repo.fetchOne(id);
});

final snagSurveysProvider = FutureProvider.family<List<SnagSurvey>, String?>((ref, buildingId) async {
  ref.watch(snagTickProvider);
  return ref.watch(snagRepositoryProvider).surveys(buildingId: buildingId);
});

final snagSurveyProvider = FutureProvider.family<SnagSurvey?, String>((ref, id) async {
  ref.watch(snagTickProvider);
  return ref.watch(snagRepositoryProvider).surveyById(id);
});

/// Snag ids with a write still in the offline queue.
final pendingSnagIdsProvider = FutureProvider<Set<String>>((ref) async {
  ref.watch(queueChangedProvider);
  ref.watch(snagTickProvider);
  return ref.watch(offlineDbProvider).pendingEntityIds(SnagRepository.entityType);
});

/// True while the offline queue is draining — "Sending…" rather than
/// "Waiting to send" on a queued snag.
final snagQueueFlushingProvider = Provider<bool>((ref) => ref.watch(syncProgressProvider) != null);

class SnagSyncState {
  const SnagSyncState({this.syncing = false, this.online, this.lastSyncedAt, this.resent = 0});
  final bool syncing;

  /// null = never tried this session.
  final bool? online;
  final DateTime? lastSyncedAt;
  final int resent;
}

/// Pulls a building's snags and surveys from the server into the local
/// store, then re-queues anything stranded (see [SnagRepository.resendStranded]).
/// Also re-runs itself when the offline queue drains, so a snag that just
/// synced loses its "On device" badge without a manual pull.
class SnagSyncController extends Notifier<SnagSyncState> {
  Timer? _debounce;
  int? _lastQueueCount;

  @override
  SnagSyncState build() {
    ref.onDispose(() => _debounce?.cancel());
    ref.listen(pendingSnagIdsProvider, (previous, next) {
      final count = next.valueOrNull?.length;
      final before = _lastQueueCount;
      _lastQueueCount = count;
      if (before != null && count != null && count < before) {
        final building = ref.read(snagBuildingIdProvider);
        if (building != null) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(seconds: 2), () => refresh(building));
        }
      }
    });
    return const SnagSyncState();
  }

  Future<void> refresh(String buildingId) async {
    if (state.syncing) return;
    state = SnagSyncState(syncing: true, online: state.online, lastSyncedAt: state.lastSyncedAt);
    final repo = ref.read(snagRepositoryProvider);
    var online = false;
    var resent = 0;
    try {
      online = await repo.refresh(buildingId: buildingId);
      if (online) {
        await repo.refreshSurveys(buildingId: buildingId);
        resent = await repo.resendStranded(buildingId: buildingId);
      }
    } catch (_) {
      // A failed pull leaves the local store as it was — which is exactly
      // what the screen was already showing. Nothing to surface.
    } finally {
      ref.read(snagTickProvider.notifier).state++;
      state = SnagSyncState(
        online: online,
        lastSyncedAt: online ? DateTime.now() : state.lastSyncedAt,
        resent: resent,
      );
    }
  }
}

final snagSyncProvider = NotifierProvider<SnagSyncController, SnagSyncState>(SnagSyncController.new);

/// Follow-up work a repository wants after one of its queued writes syncs
/// (PENDING P-008 (2)).
///
/// AR progress is local-first: a queued verify shows as "verified" at once.
/// If the server then refuses it on replay (four-eyes), the local row kept
/// the refused status until something happened to re-read the floor. With a
/// hook registered for `ArProgress`, the flush re-reads each replayed floor
/// right away, so the server's copy wins as soon as the queue drains.
///
/// Hooks run after the flush loop, once per distinct (type, id). A failing
/// hook is swallowed: the write itself already synced, and a flush must
/// never throw.
library;

import 'package:flutter/foundation.dart';

typedef ReplayHook = Future<void> Function(String entityId);

typedef ReplayedWrite = ({String? entityType, String? entityId});

class ReplayHooks {
  final _hooks = <String, ReplayHook>{};

  /// One hook per entity type; registering again replaces it, so a rebuilt
  /// provider never makes the flush re-read twice.
  void register(String entityType, ReplayHook hook) => _hooks[entityType] = hook;

  Future<void> runFor(Iterable<ReplayedWrite> replayed) async {
    final seen = <String>{};
    for (final w in replayed) {
      final type = w.entityType;
      final id = w.entityId;
      if (type == null || id == null) continue;
      final hook = _hooks[type];
      if (hook == null || !seen.add('$type\u0000$id')) continue;
      try {
        await hook(id);
      } catch (e) {
        debugPrint('Replay hook for $type/$id failed: $e');
      }
    }
  }
}

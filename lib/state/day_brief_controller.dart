import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/day/day_planner.dart';
import '../core/network/api_exception.dart';
import '../core/network/envelope.dart';
import '../core/offline/sync_client.dart';
import '../domain/day_brief.dart';
import '../domain/maintenance_record.dart';
import 'auth_controller.dart';
import 'dashboard_controller.dart';
import 'locale_controller.dart';
import 'providers.dart';

/// Reads the server brief. Through [SyncClient.syncGet], so the last answer
/// is kept on the phone (24 h) and comes back when there is no signal.
abstract interface class DayBriefSource {
  Future<({DayBrief brief, bool fromCache})> fetch({required int tzOffsetMinutes, required String lang});
}

class DayBriefRepository implements DayBriefSource {
  DayBriefRepository(this._sync);

  final SyncClient _sync;

  static const path = '/api/fm/technicians/me/day-brief';

  @override
  Future<({DayBrief brief, bool fromCache})> fetch({required int tzOffsetMinutes, required String lang}) async {
    final read = await _sync.syncGet(path, query: {'tz': tzOffsetMinutes, 'lang': lang});
    return (brief: DayBrief.fromJson(unwrapMap(read.data)), fromCache: read.fromCache);
  }
}

final dayBriefSourceProvider = Provider<DayBriefSource>((ref) => DayBriefRepository(ref.watch(syncClientProvider)));

/// What the card is showing.
/// - [loading]: first fetch in flight — the phone's own plan shows meanwhile.
/// - [ready]: a fresh server brief.
/// - [offline]: no signal — a saved brief from today ("Saved earlier") and/or
///   the phone's own plan from cached jobs.
/// - [error]: the server answered but couldn't build it — the phone's plan.
enum DayBriefPhase { loading, ready, offline, error }

class DayBriefState {
  const DayBriefState({
    this.phase = DayBriefPhase.loading,
    this.brief,
    this.steps = const [],
    this.savedAt,
  });

  final DayBriefPhase phase;

  /// The server brief behind the card (fresh, or the saved copy offline).
  final DayBrief? brief;

  /// The steps to show, in order. Ticks come from real job status only.
  final List<DayStep> steps;

  /// When a saved brief was made (offline only).
  final DateTime? savedAt;

  DayCounts get counts => DayCounts.of(steps);

  /// The first step still to do (a job, not an invite).
  DayStep? get next => steps.where((s) => !s.done && s.isJob).firstOrNull;

  bool get showAiSummary => brief != null && brief!.aiSummary && phase != DayBriefPhase.error;
}

class DayBriefController extends Notifier<DayBriefState> {
  int _requestId = 0;

  @override
  DayBriefState build() {
    // Jobs on the phone changed (dashboard refresh, queue drained): recompute
    // the phone's plan / ticks without another request.
    ref.listen(dashboardControllerProvider.select((s) => s.records), (_, records) => _onRecords(records));
    ref.listen(localeControllerProvider, (_, _) => refresh());
    Future.microtask(refresh);
    return DayBriefState(steps: DayPlanner.plan(_records(), DateTime.now()));
  }

  List<MaintenanceRecord> _records() => ref.read(dashboardControllerProvider).records;

  void _onRecords(List<MaintenanceRecord> records) {
    final now = DateTime.now();
    switch (state.phase) {
      case DayBriefPhase.ready:
        state = DayBriefState(phase: state.phase, brief: state.brief, steps: DayPlanner.overlayDone(state.brief!.steps, records));
      case DayBriefPhase.offline:
        state = DayBriefState(
          phase: state.phase,
          brief: state.brief,
          savedAt: state.savedAt,
          steps: DayPlanner.mergeCached(DayPlanner.plan(records, now, blockedIds: _blocked(state.brief)), state.brief),
        );
      case DayBriefPhase.loading:
      case DayBriefPhase.error:
        state = DayBriefState(phase: state.phase, brief: state.brief, steps: DayPlanner.plan(records, now));
    }
  }

  static Set<String> _blocked(DayBrief? b) => {for (final s in b?.steps ?? const <DayStep>[]) if (s.permitBlocked) s.id};

  static bool _sameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  Future<void> refresh() async {
    final session = ref.read(authControllerProvider).session;
    if (session == null || session.userId.isEmpty) return;
    final requestId = ++_requestId;
    final now = DateTime.now();
    if (state.phase != DayBriefPhase.ready) {
      state = DayBriefState(phase: DayBriefPhase.loading, brief: state.brief, steps: DayPlanner.plan(_records(), now));
    }
    try {
      final r = await ref.read(dayBriefSourceProvider).fetch(
            tzOffsetMinutes: now.timeZoneOffset.inMinutes,
            lang: ref.read(localeControllerProvider),
          );
      if (requestId != _requestId) return;
      if (!r.fromCache) {
        state = DayBriefState(phase: DayBriefPhase.ready, brief: r.brief, steps: DayPlanner.overlayDone(r.brief.steps, _records()));
        return;
      }
      // A saved copy: only today's counts as "today's plan".
      final saved = _sameDay(r.brief.generatedAt, now) ? r.brief : null;
      state = DayBriefState(
        phase: DayBriefPhase.offline,
        brief: saved,
        savedAt: saved?.generatedAt,
        steps: DayPlanner.mergeCached(DayPlanner.plan(_records(), now, blockedIds: _blocked(saved)), saved),
      );
    } on NetworkFailure {
      if (requestId != _requestId) return;
      state = DayBriefState(phase: DayBriefPhase.offline, steps: DayPlanner.plan(_records(), now));
    } on ApiFailure {
      if (requestId != _requestId) return;
      state = DayBriefState(phase: DayBriefPhase.error, steps: DayPlanner.plan(_records(), now));
    } catch (_) {
      if (requestId != _requestId) return;
      state = DayBriefState(phase: DayBriefPhase.error, steps: DayPlanner.plan(_records(), now));
    }
  }
}

final dayBriefControllerProvider = NotifierProvider<DayBriefController, DayBriefState>(DayBriefController.new);

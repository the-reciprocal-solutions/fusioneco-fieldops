import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../data/schedule_repository.dart';
import '../domain/user_schedule.dart';
import 'providers.dart';

/// My schedules (orchestrator spec O3 "Management"). Online only — see
/// [ScheduleRepository].
final scheduleRepositoryProvider = Provider<ScheduleRepository>(
  (ref) => ScheduleRepository(ref.watch(apiClientProvider)),
);

class SchedulesController extends AutoDisposeAsyncNotifier<List<UserSchedule>> {
  @override
  Future<List<UserSchedule>> build() => _load();

  Future<List<UserSchedule>> _load() async {
    final rows = await ref.read(scheduleRepositoryProvider).mine();
    // Active first (soonest next run first), then paused, then finished.
    int rank(UserSchedule s) => s.isFinished ? 2 : (s.isPaused ? 1 : 0);
    rows.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final an = a.nextRunAt, bn = b.nextRunAt;
      if (an == null && bn == null) return a.title.compareTo(b.title);
      if (an == null) return 1;
      if (bn == null) return -1;
      return an.compareTo(bn);
    });
    return rows;
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(_load);
    state = next;
  }

  /// Returns the failure (a [NetworkFailure] means offline), or null.
  Future<ApiFailure?> setPaused(UserSchedule s, bool paused) async {
    try {
      await ref.read(scheduleRepositoryProvider).setPaused(s.id, paused);
      await refresh();
      return null;
    } on ApiFailure catch (e) {
      return e;
    }
  }

  /// "Run now" / "Try again".
  Future<ApiFailure?> runNow(UserSchedule s) async {
    try {
      await ref.read(scheduleRepositoryProvider).runNow(s.id);
      await refresh();
      return null;
    } on ApiFailure catch (e) {
      return e;
    }
  }

  Future<ApiFailure?> delete(UserSchedule s) async {
    final before = state.valueOrNull;
    if (before != null) state = AsyncData(before.where((x) => x.id != s.id).toList());
    try {
      await ref.read(scheduleRepositoryProvider).delete(s.id);
      return null;
    } on ApiFailure catch (e) {
      if (before != null) state = AsyncData(before);
      return e;
    }
  }
}

final schedulesControllerProvider =
    AsyncNotifierProvider.autoDispose<SchedulesController, List<UserSchedule>>(SchedulesController.new);

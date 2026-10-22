import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/attendance/day_rules.dart';
import '../data/day_attendance_repository.dart';
import '../domain/day_attendance.dart';
import '../core/push/day_reminders.dart';
import '../core/capture/capture_media.dart';
import 'auth_controller.dart';
import 'providers.dart';

/// Where the start / end of day pictures are kept on disk.
final captureMediaProvider = Provider<CaptureMedia>((ref) => CaptureMedia());

/// Whose attendance to read and write. Null when signed out.
final sessionUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.session?.userId)),
);

/// Bumped whenever the day changes on this phone (a start / end tapped, a replay
/// confirmed, a fresh description of today arrived), so the card and the banner
/// refresh.
final dayTickProvider = StateProvider<int>((ref) => 0);

final dayAttendanceRepositoryProvider = Provider<DayAttendanceRepository>((ref) {
  final sync = ref.watch(syncClientProvider);
  final repo = DayAttendanceRepository(
    sync: sync,
    api: ref.watch(apiClientProvider),
    store: ref.watch(offlineDbProvider),
    media: ref.watch(captureMediaProvider),
    deviceId: () => ref.read(secureStoreProvider).getOrCreateDeviceId(),
    pendingIds: ref.watch(offlineDbProvider).pendingEntityIds,
  );
  // A queued end that reaches the server is confirmed at once, and a final
  // refusal records why. Registered here, before the first flush can replay
  // anything, because the shell builds this provider at startup.
  void bump() => ref.read(dayTickProvider.notifier).state++;
  sync.onReplayed(DayAttendanceRepository.inEntityType, (id) async {
    await repo.afterReplay(id, isStart: true);
    bump();
  });
  sync.onReplayed(DayAttendanceRepository.outEntityType, (id) async {
    await repo.afterReplay(id, isStart: false);
    bump();
  });
  sync.onReplayFailed(DayAttendanceRepository.inEntityType, (id, failure) async {
    await repo.afterReplayFailed(id, failure, isStart: true);
    bump();
  });
  sync.onReplayFailed(DayAttendanceRepository.outEntityType, (id, failure) async {
    await repo.afterReplayFailed(id, failure, isStart: false);
    bump();
  });
  return repo;
});

/// Today's shift and the phone's own start / end of the day. Read from the
/// phone only (instant, works offline); the shell refreshes it from the server
/// on start and on resume.
class DayView {
  const DayView({this.today, this.local});

  final DayToday? today;
  final DayLocal? local;

  /// The card state at [now].
  DayCardState card(DateTime now) => dayCardState(today: today, local: local, now: now);

  bool get hasShift => today?.hasShift == true;
}

final dayViewProvider = FutureProvider<DayView>((ref) async {
  ref.watch(dayTickProvider);
  ref.watch(queueChangedProvider);
  final userId = ref.watch(sessionUserIdProvider);
  if (userId == null) return const DayView();
  final repo = ref.watch(dayAttendanceRepositoryProvider);
  final today = await repo.cachedToday(userId);
  if (today == null || !today.hasShift || today.date == null) return DayView(today: today);
  final local = await repo.localFor(userId, today.date!);
  // The phone's own reminders follow what it knows: no signal needed.
  unawaited(DayReminders.sync(today: today, local: local));
  return DayView(today: today, local: local);
});

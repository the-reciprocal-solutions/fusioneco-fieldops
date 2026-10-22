import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/capture/capture_photo.dart';
import '../core/capture/capture_rules.dart';
import '../core/capture/fix_source.dart';
import '../domain/capture.dart';
import '../domain/day_attendance.dart';
import 'day_attendance_controller.dart';

/// Where a position comes from. Overridden in tests.
final captureFixSourceProvider = Provider<FixSource>((ref) => LadderFixSource());

/// Opens the camera for the start / end of day picture. Overridden in tests.
final capturePhotoTakerProvider = Provider<Future<CapturePhoto?> Function()>(
  (ref) => () => takeCapturePhoto(),
);

/// Burns the stamp into the picture. Overridden in tests.
final capturePhotoStamperProvider = Provider<Future<CapturePhoto> Function(CapturePhoto, List<String>)>(
  (ref) => stampPhoto,
);

/// Which end of the day the sheet is for: today's shift, and (to END the day)
/// the phone's own record of the start.
class DayCaptureArgs {
  const DayCaptureArgs.start({required DayToday this.today}) : local = null;

  const DayCaptureArgs.end({required DayToday this.today, required DayLocal this.local});

  final DayToday? today;
  final DayLocal? local;

  bool get isStart => local == null;
  String get label => today?.shift?.name ?? 'My day';

  @override
  bool operator ==(Object other) =>
      other is DayCaptureArgs && other.today?.date == today?.date && other.local?.inAt == local?.inAt;

  @override
  int get hashCode => Object.hash(today?.date, local?.inAt);
}

class DayCaptureState {
  const DayCaptureState({
    this.finding = true,
    this.fix,
    this.photo,
    this.photoSkipped = false,
    this.takingPhoto = false,
    this.reason,
    this.saving = false,
    this.error,
    this.done = false,
  });

  /// Looking for a position right now.
  final bool finding;
  final CaptureFix? fix;

  /// The stamped picture, once taken.
  final CapturePhoto? photo;

  /// The technician chose to go on without a picture (camera broken or
  /// refused). Allowed, never blocks; the server flags it.
  final bool photoSkipped;
  final bool takingPhoto;

  /// Why there is no position, when there isn't one.
  final String? reason;

  final bool saving;
  final String? error;

  /// The start / end was saved on the phone and queued.
  final bool done;

  bool get hasPhoto => photo != null;

  /// A picture (or an explicit skip) is in, a position attempt has finished,
  /// and a reason was given if there is no position. Pure.
  bool get canSubmit {
    if (saving || finding || done) return false;
    if (!hasPhoto && !photoSkipped) return false;
    final f = fix;
    if (f == null) return false;
    if (reasonRequired(f) && (reason == null || reason!.trim().isEmpty)) return false;
    return true;
  }

  DayCaptureState copyWith({
    bool? finding,
    CaptureFix? fix,
    CapturePhoto? photo,
    bool? photoSkipped,
    bool? takingPhoto,
    String? reason,
    bool clearReason = false,
    bool? saving,
    String? error,
    bool clearError = false,
    bool? done,
  }) => DayCaptureState(
    finding: finding ?? this.finding,
    fix: fix ?? this.fix,
    photo: photo ?? this.photo,
    photoSkipped: photoSkipped ?? this.photoSkipped,
    takingPhoto: takingPhoto ?? this.takingPhoto,
    reason: clearReason ? null : (reason ?? this.reason),
    saving: saving ?? this.saving,
    error: clearError ? null : (error ?? this.error),
    done: done ?? this.done,
  );
}

/// The start / end of day sheet's logic: find the position, take the picture,
/// save. Everything it saves goes through the day repository, which writes to
/// the phone first and queues the request, so [submit] never waits on a network.
class DayCaptureController extends AutoDisposeFamilyNotifier<DayCaptureState, DayCaptureArgs> {
  Future<CaptureFix>? _fixFuture;
  bool _disposed = false;

  @override
  DayCaptureState build(DayCaptureArgs arg) {
    ref.onDispose(() => _disposed = true);
    unawaited(Future.microtask(findPosition));
    return const DayCaptureState();
  }

  /// (Re)tries for a position. Never throws: no position is a valid answer.
  Future<void> findPosition() async {
    state = state.copyWith(finding: true, clearError: true);
    final future = _fixFuture = ref.read(captureFixSourceProvider).acquire();
    final fix = await future;
    if (_disposed) return;
    state = state.copyWith(finding: false, fix: fix);
  }

  /// Opens the camera, then burns the stamp once the position is known.
  Future<void> takePhoto() async {
    if (state.takingPhoto) return;
    state = state.copyWith(takingPhoto: true, clearError: true);
    try {
      final raw = await ref.read(capturePhotoTakerProvider)();
      if (raw == null) {
        state = state.copyWith(takingPhoto: false);
        return;
      }
      // The position was searched for while the camera was open. If it is
      // still arriving, wait for it so the stamp carries it.
      final CaptureFix fix;
      final known = state.fix;
      if (known != null) {
        fix = known;
      } else {
        final pending = _fixFuture;
        fix = pending == null ? const CaptureFix.none() : await pending;
      }
      final lines = stampLines(isStart: arg.isStart, at: DateTime.now(), label: arg.label, fix: fix);
      final stamped = await ref.read(capturePhotoStamperProvider)(raw, lines);
      state = state.copyWith(takingPhoto: false, photo: stamped, photoSkipped: false);
    } catch (_) {
      state = state.copyWith(
        takingPhoto: false,
        error: 'Could not open the camera. You can continue without a photo.',
      );
    }
  }

  void skipPhoto() => state = state.copyWith(photoSkipped: true, clearError: true);

  void setReason(String value) =>
      state = value.trim().isEmpty ? state.copyWith(clearReason: true) : state.copyWith(reason: value);

  /// Saves the start / end on the phone and queues it. True when saved; false
  /// when it could not be saved at all (a real local failure, never "no network").
  Future<bool> submit() async {
    if (!state.canSubmit) return false;
    final userId = ref.read(sessionUserIdProvider);
    if (userId == null) return false;
    state = state.copyWith(saving: true, clearError: true);
    try {
      final repo = ref.read(dayAttendanceRepositoryProvider);
      final fix = state.fix ?? const CaptureFix.none();
      final today = arg.today!;
      final local = arg.local;
      if (local == null) {
        await repo.startDay(userId: userId, today: today, fix: fix, photo: state.photo, reason: state.reason);
      } else {
        await repo.endDay(userId: userId, local: local, fix: fix, photo: state.photo, reason: state.reason);
      }
      ref.read(dayTickProvider.notifier).state++;
      state = state.copyWith(saving: false, done: true);
      return true;
    } catch (_) {
      state = state.copyWith(
        saving: false,
        error: 'Could not save this on the phone. Check the free storage and try again.',
      );
      return false;
    }
  }
}

final dayCaptureProvider =
    NotifierProvider.autoDispose.family<DayCaptureController, DayCaptureState, DayCaptureArgs>(
  DayCaptureController.new,
);

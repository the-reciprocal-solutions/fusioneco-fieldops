import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../core/offline/prefetch.dart';
import '../domain/maintenance_record.dart';
import 'auth_controller.dart';
import 'orders_controller.dart';
import 'providers.dart';

class DashboardState {
  const DashboardState({
    this.totalCount = 0,
    this.completedCount = 0,
    this.overdueCount = 0,
    this.dueTodayCount = 0,
    this.activeTasks = const [],
    this.records = const [],
    this.loading = true,
    this.loaded = false,
    this.error,
  });

  final int totalCount;
  final int completedCount;
  final int overdueCount;
  final int dueTodayCount;
  final List<MaintenanceRecord> activeTasks;

  /// Every assigned work order from the last fetch (network or the offline
  /// cache). The Your day card plans from these when the server brief can't
  /// be reached (docs/day-brief.md), so it costs no second request.
  final List<MaintenanceRecord> records;
  final bool loading;

  /// True once counts have come back at least once. Before that the zeros in
  /// this object are placeholders, and a technician must not be shown them as
  /// though they were the day's real figures.
  final bool loaded;
  final String? error;
}

/// A record no longer needing work. `Expired` counts as done: an expired AMC
/// contract is closed business, not an outstanding task.
bool _isFinished(MaintenanceRecord r) {
  final status = r.status;
  return status == 'Completed' || status == 'completed' || status == 'Expired';
}

bool _isActive(MaintenanceRecord r) => !_isFinished(r) && r.status != 'Cancelled';

class DashboardController extends Notifier<DashboardState> {
  /// A pull-to-refresh and a queue-change refetch can overlap; only the most
  /// recent one may write its answer.
  int _requestId = 0;

  @override
  DashboardState build() {
    ref.listen(queueChangedProvider, (_, _) => refresh());
    Future.microtask(refresh);
    return const DashboardState();
  }

  Future<void> refresh() async {
    final session = ref.read(authControllerProvider).session;
    if (session == null || session.userId.isEmpty) return;

    final requestId = ++_requestId;
    state = DashboardState(
      totalCount: state.totalCount,
      completedCount: state.completedCount,
      overdueCount: state.overdueCount,
      dueTodayCount: state.dueTodayCount,
      activeTasks: state.activeTasks,
      records: state.records,
      loading: true,
      loaded: state.loaded,
    );

    try {
      final page =
          await ref.read(ordersRepositoryProvider).listAll(session.userId);
      if (requestId != _requestId) return;
      state = _derive(page.records);
    } on ApiFailure catch (e) {
      if (requestId != _requestId) return;
      state = DashboardState(
        records: state.records,
        loading: false,
        loaded: state.loaded,
        error: e.message,
      );
    }

    // Warm the offline cache with today's work while a connection still
    // exists, so a job never opened is still readable in the field.
    unawaited(
      prefetchOfflineBundle(ref.read(syncClientProvider), session.userId),
    );
  }

  DashboardState _derive(List<MaintenanceRecord> records) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final active = records.where(_isActive).toList();

    // Overdue compares against the instant, not midnight — a job due at 09:00
    // is overdue by 09:01. "Due today" is the whole calendar day, so a record
    // can be counted in both.
    final overdue = active
        .where((r) => r.effectiveDate != null && r.effectiveDate!.isBefore(now))
        .toList();

    final dueToday = active.where((r) {
      final due = r.effectiveDate;
      return due != null && !due.isBefore(today) && due.isBefore(tomorrow);
    }).toList();

    final inProgress = active
        .where((r) => (r.status ?? '').toLowerCase().contains('progress'))
        .toList();

    // Due-today first, then in-progress, so a record that is both keeps the
    // in-progress position. Deduped by id, capped at five.
    final combined = <String, MaintenanceRecord>{};
    for (final r in dueToday) {
      combined[r.id] = r;
    }
    for (final r in inProgress) {
      combined[r.id] = r;
    }

    return DashboardState(
      totalCount: records.length,
      completedCount: records.where(_isFinished).length,
      overdueCount: overdue.length,
      dueTodayCount: dueToday.length,
      activeTasks: combined.values.take(5).toList(),
      records: records,
      loading: false,
      loaded: true,
    );
  }
}

final dashboardControllerProvider =
    NotifierProvider<DashboardController, DashboardState>(
  DashboardController.new,
);

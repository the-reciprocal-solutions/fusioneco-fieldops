import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/c2o/c2o_asset_resolver.dart';
import '../core/scanner/scan_history.dart';
import 'auth_controller.dart';
import 'providers.dart';

/// The scanner's history (lib/core/scanner/scan_history.dart) over the
/// local DB. Overridden in tests with an in-memory store.
final scanHistoryProvider = Provider<ScanHistory>((ref) => ScanHistory(ref.watch(offlineDbProvider)));

/// Whose history to read and write. Its own provider so tests don't need
/// the whole auth controller. Null when signed out: nothing is recorded.
final scanUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.session?.userId)),
);

/// Resolves a waiting C2O tag again (the Scans page's retry). A seam so the
/// page is testable without the network.
final scanRetryResolverProvider = Provider<Future<C2oResolution?> Function(String raw)>(
  (ref) => (raw) => ref.read(c2oAssetResolverProvider).resolve(raw),
);

class ScansState {
  const ScansState({
    this.loading = true,
    this.records = const [],
    this.query = '',
    this.filter = ScanFilter.all,
    this.retrying = false,
  });

  final bool loading;

  /// Everything kept for this user, newest first.
  final List<ScanRecord> records;
  final String query;
  final ScanFilter filter;
  final bool retrying;

  List<ScanRecord> get visible => [
        for (final r in records)
          if (filter.accepts(r) && r.matches(query)) r,
      ];

  int get waiting => records.where((r) => r.status == ScanStatus.waiting).length;

  ScansState copyWith({bool? loading, List<ScanRecord>? records, String? query, ScanFilter? filter, bool? retrying}) =>
      ScansState(
        loading: loading ?? this.loading,
        records: records ?? this.records,
        query: query ?? this.query,
        filter: filter ?? this.filter,
        retrying: retrying ?? this.retrying,
      );
}

/// The Scans page: load, search, filter, retry what waited for signal,
/// clear. Everything is local; only the retry touches the network, through
/// the same offline-first resolver the scanner uses.
class ScansController extends AutoDisposeNotifier<ScansState> {
  @override
  ScansState build() => const ScansState();

  ScanHistory get _history => ref.read(scanHistoryProvider);
  String? get _user => ref.read(scanUserIdProvider);

  Future<void> load() async {
    final user = _user;
    if (user == null) {
      state = state.copyWith(loading: false, records: const []);
      return;
    }
    try {
      final records = await _history.list(user);
      state = state.copyWith(loading: false, records: records);
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  void setQuery(String q) => state = state.copyWith(query: q);
  void setFilter(ScanFilter f) => state = state.copyWith(filter: f);

  /// Re-resolves every waiting C2O tag. Returns how many resolved now
  /// (found or a definite problem); the rest still need signal.
  Future<int> retryWaiting() async {
    if (state.retrying) return 0;
    final waiting = [for (final r in state.records) if (r.status == ScanStatus.waiting && r.kind == ScanKind.c2oAsset) r];
    if (waiting.isEmpty) return 0;
    state = state.copyWith(retrying: true);
    final resolve = ref.read(scanRetryResolverProvider);
    var settled = 0;
    final updated = {for (final r in state.records) r.id: r};
    for (final r in waiting) {
      C2oResolution? outcome;
      try {
        outcome = await resolve(r.raw);
      } catch (_) {
        outcome = null;
      }
      if (outcome == null || outcome is C2oNeedsSignal) continue;
      final next = rescanned(r, outcome);
      updated[r.id] = next;
      await _history.update(next);
      settled++;
    }
    state = state.copyWith(
      retrying: false,
      records: [for (final r in state.records) updated[r.id] ?? r],
    );
    return settled;
  }

  /// Retries one waiting tag; the updated row, or null when it still waits.
  Future<ScanRecord?> retryOne(ScanRecord r) async {
    C2oResolution? outcome;
    try {
      outcome = await ref.read(scanRetryResolverProvider)(r.raw);
    } catch (_) {
      return null;
    }
    if (outcome == null || outcome is C2oNeedsSignal) return null;
    final next = rescanned(r, outcome);
    await _history.update(next);
    state = state.copyWith(records: [for (final x in state.records) x.id == r.id ? next : x]);
    return next;
  }

  Future<void> clear() async {
    final user = _user;
    if (user == null) return;
    try {
      await _history.clear(user);
    } catch (_) {}
    state = state.copyWith(records: const []);
  }
}

final scansProvider = NotifierProvider.autoDispose<ScansController, ScansState>(ScansController.new);

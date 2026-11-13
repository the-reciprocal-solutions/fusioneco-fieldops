import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/alerts_repository.dart';
import '../domain/alert.dart';
import 'providers.dart';

final alertsRepositoryProvider = Provider<AlertsRepository>(
  (ref) => AlertsRepository(ref.watch(apiClientProvider)),
);

/// The list's filters (severity / status / mine). Open alerts by default.
final alertFiltersProvider = StateProvider<AlertFilters>((ref) => const AlertFilters());

/// Bumped by the socket's `alerts:changed` (and after the phone's own
/// actions): the list and any open detail refetch. The web Alert Center
/// polls every 60 s; the phone is told instead (FE-mobile.md Phase 2).
final alertsTickProvider = StateProvider<int>((ref) => 0);

/// The alert as the server returned it from one of the phone's own actions,
/// and when. Shown at once in place of the list row / detail, instead of
/// waiting for the refetch (owner, 2026-10-30: the card took ~10 s to change).
class AlertPatch {
  const AlertPatch(this.item, this.at);
  final AlertItem item;
  final DateTime at;
}

final alertPatchesProvider = StateProvider<Map<String, AlertPatch>>((ref) => const {});

/// After an action: show [item] now, and refetch.
void applyAlertPatch(WidgetRef ref, AlertItem item) {
  final n = ref.read(alertPatchesProvider.notifier);
  n.state = {...n.state, item.key: AlertPatch(item, DateTime.now())};
  ref.read(alertsTickProvider.notifier).state++;
}

/// A fetch that started after a patch already has that change: drop it.
void _dropPatchesBefore(Ref ref, DateTime started) {
  final n = ref.read(alertPatchesProvider.notifier);
  if (n.state.values.any((p) => p.at.isBefore(started))) {
    n.state = {for (final e in n.state.entries) if (!e.value.at.isBefore(started)) e.key: e.value};
  }
}

/// Pages of 50 shown ("Load more"); back to 1 when the filters change.
final alertPageCountProvider = StateProvider.autoDispose<int>((ref) {
  ref.watch(alertFiltersProvider);
  return 1;
});

/// Pages 1..count, joined. A refetch (socket, own action) reloads all of
/// them, so the list doesn't shrink back to 50 under the user.
final alertListProvider = FutureProvider.autoDispose<AlertPage>((ref) async {
  ref.watch(alertsTickProvider);
  final filters = ref.watch(alertFiltersProvider);
  final count = ref.watch(alertPageCountProvider);
  final repo = ref.watch(alertsRepositoryProvider);
  final started = DateTime.now();
  final pages = await Future.wait([for (var p = 1; p <= count; p++) repo.list(filters, page: p)]);
  _dropPatchesBefore(ref, started);
  if (pages.length == 1) return pages.single;
  // The feed can shift between pages (a new alert on top): skip repeats.
  final seen = <String>{};
  return AlertPage(
    rows: [for (final pg in pages) for (final a in pg.rows) if (seen.add(a.key)) a],
    total: pages.first.total,
    summary: pages.first.summary,
  );
});

final alertDetailProvider = FutureProvider.autoDispose.family<AlertDetail, String>((ref, key) async {
  ref.watch(alertsTickProvider);
  final started = DateTime.now();
  final detail = await ref.watch(alertsRepositoryProvider).detail(key);
  _dropPatchesBefore(ref, started);
  return detail;
});

/// [a] with the phone's own newer change, if any.
AlertItem patchedAlert(Map<String, AlertPatch> patches, AlertItem a) => patches[a.key]?.item ?? a;

/// Who the alert may be handed to (the Assign sheet).
final alertAssigneesProvider = FutureProvider.autoDispose.family<List<Assignee>, String>(
  (ref, key) => ref.watch(alertsRepositoryProvider).assignees(key),
);

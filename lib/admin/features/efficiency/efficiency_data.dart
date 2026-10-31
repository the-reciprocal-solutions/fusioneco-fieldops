import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../modules/module_spec.dart';

/// Building Efficiency data (FE-mobile.md Phase 2). One summary call
/// (`GET /api/fm/hvac-efficiency/summary`, ~50 KB live) feeds almost every
/// page, exactly as the web's `useHvacData` does. Sites come from the BMS
/// connections (`/sites`), not the org/site picker.

class HvacSite {
  const HvacSite({required this.connectionId, required this.site, required this.label, this.connectionName, this.devices = 0});

  final String connectionId;
  final String site;
  final String label;
  final String? connectionName;
  final int devices;

  /// What the phone stores (SessionStore `hvac-eff:last-site`).
  String get key => '$connectionId|$site';

  Map<String, dynamic> get query => {'connectionId': connectionId, 'site': site};

  factory HvacSite.fromJson(Json j) => HvacSite(
        connectionId: '${j['connectionId']}',
        site: '${j['site'] ?? ''}',
        label: s(j['label']) ?? s(j['site']) ?? '–',
        connectionName: s(j['connectionName']),
        devices: (n(j['devices']) ?? 0).toInt(),
      );

  @override
  bool operator ==(Object other) => other is HvacSite && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

final hvacSitesProvider = FutureProvider<List<HvacSite>>((ref) async {
  final body = await ref.watch(apiClientProvider).get('/api/fm/hvac-efficiency/sites');
  return rowsOf(body).map(HvacSite.fromJson).toList();
});

/// The site being looked at: the user's last pick if it still exists, else the first.
class EffSiteController extends Notifier<HvacSite?> {
  @override
  HvacSite? build() {
    final sites = ref.watch(hvacSitesProvider).valueOrNull;
    if (sites == null || sites.isEmpty) return null;
    final saved = ref.read(sessionStoreProvider).readEffSite();
    return sites.firstWhere((x) => x.key == saved, orElse: () => sites.first);
  }

  void pick(HvacSite site) {
    state = site;
    ref.read(sessionStoreProvider).writeEffSite(site.key);
  }
}

final effSiteProvider = NotifierProvider<EffSiteController, HvacSite?>(EffSiteController.new);

/// Look-back window in days (the web offers 1 / 7 / 30).
final effDaysProvider = StateProvider<int>((ref) => 1);

/// The shared summary for the picked site and window.
final effSummaryProvider = FutureProvider.autoDispose<Json?>((ref) async {
  final site = ref.watch(effSiteProvider);
  // No site yet: stay loading (the provider re-runs when one is picked)
  // rather than settle on "no data" — a page once stuck blank on that.
  if (site == null) return Completer<Json?>().future;
  final body = await ref.watch(apiClientProvider).get(
    '/api/fm/hvac-efficiency/summary',
    query: {...site.query, 'days': '${ref.watch(effDaysProvider)}'},
  );
  return dataOf(body);
});

/// Findings in one pillar (comfort / energy / equipment / power / safety / data),
/// most urgent first.
List<Json> findingsOf(Json summary, {String? pillar}) {
  final all = rowsOf({'data': summary['findings']});
  final picked = pillar == null ? all : all.where((f) => f['pillar'] == pillar).toList();
  picked.sort((a, b) => severityRank(a['severity']).compareTo(severityRank(b['severity'])));
  return picked;
}

/// risk (worst) → warn → info.
int severityRank(Object? sev) => switch ('$sev') {
      'risk' => 0,
      'warn' => 1,
      'info' => 2,
      _ => 3,
    };

/// One pillar card (`pillars[]`), or null when the site has no such area.
Json? pillarOf(Json summary, String key) {
  for (final p in rowsOf({'data': summary['pillars']})) {
    if (p['key'] == key) return p;
  }
  return null;
}

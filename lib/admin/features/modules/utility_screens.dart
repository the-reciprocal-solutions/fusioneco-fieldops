import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../catalog/module_icons.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'cctv_legacy.dart';
import 'module_spec.dart';
import 'module_summary_screen.dart';
import 'utility_trends.dart';

/// Facility Utilities + HVAC on the phone (FE-mobile.md Phase 3b). Every
/// utility page on the web defaults to the building system ("msc" variant,
/// hooks/useFuPageVariant.ts); this reads the same two calls the web's
/// Facility Utilities dashboard uses (hooks/useUtilityOverview.ts):
///   GET /api/proxy/bacnet/api/devices?utility_tag=…               devices, online/offline
///   GET /api/proxy/bacnet/api/history/devices/latest?utility_tag=…  latest value of every point
/// Both take the tag repeated for several utilities at once. Live sizes
/// (2026-10-30): under 10 KB per utility. Polled every 45 s while open, like the web.

/// Catalog module id → the web's MSC master code (`useMscData("…")`).
const utilityTags = <String, String>{
  'energy': 'ENERGY',
  'dg': 'DG',
  'ups': 'UPS',
  'solar_panel': 'SOLAR',
  'water_meter': 'WATER-METER',
  'tank_level': 'TANK-LEVEL',
  'pump': 'PUMP',
  'feel_temperature': 'TEMP',
  'co2': 'CO2',
  'fire': 'FIRE',
  'intrusion': 'INTRUSION',
  'cctv': 'CCTV',
  'lift': 'LIFT',
  'it_rack': 'RACK',
  'hvac_ac': 'AC',
  'hvac_ahu': 'AHU',
  'hvac_ductable_ac': 'DUCTABLE-AC',
};

const _pollEvery = Duration(seconds: 45);

class MscDevice {
  const MscDevice({required this.id, required this.name, required this.tag, this.description, this.online = true, this.points = const [], this.raw = const {}, this.assetId, this.labels = const {}});

  final String id;
  final String name;
  final String tag;
  final String? description;
  final bool online;

  /// (readable name, formatted value) in the order the building system sends them.
  final List<(String, String)> points;

  /// The latest values as sent (`Device/Point` → value), for rules that read
  /// named points (floor_plan_screen.dart `deviceHealth`).
  final Map<String, Object?> raw;

  /// The FM asset this device is mapped to (Device Mapping, `fe_asset_uuid`).
  final String? assetId;

  /// Device Mapping's name for a point (`Device/Point` → "Supply Air Temperature").
  final Map<String, String> labels;

  /// What to call a point: its mapped name, else the readable raw name.
  String labelOf(String key) => labels[key] ?? humanizePoint(key);
}

/// Port of the web's `humanizePoint` (fusion-eco-client lib/api/msc.ts) so both
/// apps name points the same way. CHANGE BOTH.
/// `ReturnAirTemp` → `Return air temp`; `VID-AC-01/Comp1Hp1Fault` →
/// `Compressor 1 high-pressure 1 fault`.
String humanizePoint(String name) {
  var n = name.substring(name.lastIndexOf('/') + 1);
  n = n
      .replaceAllMapped(RegExp(r'Comp(\d)'), (m) => 'Compressor ${m[1]} ')
      .replaceAllMapped(RegExp(r'Hp(\d)?'), (m) => ' high-pressure${m[1] != null ? ' ${m[1]}' : ''} ')
      .replaceAllMapped(RegExp(r'Lp(\d)?'), (m) => ' low-pressure${m[1] != null ? ' ${m[1]}' : ''} ')
      .replaceAll('Chw', 'Chilled water ')
      .replaceAll('UPS', ' UPS ')
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\bups\b'), 'UPS')
      .replaceAll(RegExp(r'\bco2\b'), 'CO₂');
  return n.isEmpty ? name : '${n[0].toUpperCase()}${n.substring(1)}';
}

String formatPoint(Object? v) {
  if (v is bool) return v ? 'On' : 'Off';
  if (v is num) return fmtNum(v, decimals: v.abs() < 10 ? 2 : 1);
  return s(v) ?? '–';
}

/// Device Mapping names for one utility's devices, as the web reads them
/// (lib/api/utilityDisplay.ts getUtilityDisplayCached):
///   `GET /api/fm/utility-display/<TAG>?deviceIds=1,2` → `{devices: {<id>: [{pointKey, displayName}]}}`
/// Kept 60 s (the screens poll every 45 s). A failure means "no names", never an error.
final _namesCache = <String, (DateTime, Map<String, List<Json>>)>{};

Future<Map<String, List<Json>>> _mappedNames(ApiClient api, String tag, List<String> ids) async {
  if (ids.isEmpty) return const {};
  final key = '$tag|${(List.of(ids)..sort()).join(',')}';
  final hit = _namesCache[key];
  if (hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 60)) return hit.$2;
  Map<String, List<Json>> out = const {};
  try {
    final body = await api.get('/api/fm/utility-display/${Uri.encodeComponent(tag)}', query: {'deviceIds': ids.join(',')});
    final devices = dataOf(body)['devices'];
    if (devices is Map) {
      out = {for (final e in devices.entries) '${e.key}': rowsOf({'data': e.value})};
    }
  } catch (_) {
    // No names: the readable raw names stay.
  }
  _namesCache[key] = (DateTime.now(), out);
  return out;
}

/// Raw point key → mapped name: the exact key, else the same short name
/// (after the last `/`), as the web's latestWithMappedAliases matches.
Map<String, String> mappedLabels(Iterable<String> keys, List<Json> mapped) {
  String short(String k) => k.substring(k.lastIndexOf('/') + 1);
  final out = <String, String>{};
  for (final m in mapped) {
    final pk = s(m['pointKey']);
    final name = s(m['displayName']);
    if (pk == null || name == null) continue;
    final hit = keys.contains(pk) ? pk : keys.where((k) => short(k) == short(pk)).firstOrNull;
    if (hit != null) out.putIfAbsent(hit, () => name);
  }
  return out;
}

/// The building system's whole device list (about 95 devices, 33 KB), kept
/// 5 minutes per signed-in client. The building system answers the same call
/// in 0.3 s one moment and 10–36 s the next (timed 2026-11-02), with or
/// without a `utility_tag` filter, so the phone asks once and filters here:
/// every utility screen after the first opens at once, and the 45 s refresh
/// only re-reads the latest values. Devices change rarely; pull to refresh
/// re-reads after the 5 minutes.
final _deviceLists = Expando<(DateTime, Future<List<Json>>)>('mscDevices');
const _deviceListTtl = Duration(minutes: 5);

Future<List<Json>> _allDevices(ApiClient api) {
  final hit = _deviceLists[api];
  if (hit != null && DateTime.now().difference(hit.$1) < _deviceListTtl) return hit.$2;
  final f = api.get('/api/proxy/bacnet/api/devices').then(rowsOf);
  _deviceLists[api] = (DateTime.now(), f);
  // A failed read isn't kept: the next screen asks again.
  f.catchError((Object _) {
    if (identical(_deviceLists[api]?.$2, f)) _deviceLists[api] = null;
    return const <Json>[];
  });
  return f;
}

/// Devices + their latest readings for [tags], joined by device id; points
/// named as Device Mapping names them.
Future<List<MscDevice>> loadMscDevices(ApiClient api, List<String> tags) async {
  if (tags.isEmpty) return const [];
  final results = await Future.wait([
    _allDevices(api),
    api.get('/api/proxy/bacnet/api/history/devices/latest', query: {'utility_tag': tags}),
  ]);
  final latest = <String, Map>{};
  for (final d in rowsOf(results[1])) {
    if (d['points'] is Map) latest['${d['device_id']}'] = d['points'] as Map;
  }
  final rows = [for (final d in results[0] as List<Json>) if (tags.contains(s(d['utility_tag']))) d];
  final names = <String, List<Json>>{};
  for (final tag in tags) {
    final ids = [
      for (final d in rows)
        if (s(d['utility_tag']) == tag || tags.length == 1) '${d['device_id']}',
    ];
    names.addAll(await _mappedNames(api, tag, ids));
  }
  return [for (final d in rows) _device(d, latest['${d['device_id']}'] ?? const {}, names['${d['device_id']}'] ?? const [])];
}

/// Devices + readings from a VENDOR provider (Vidyutt / SustainSphere family),
/// the one the user has in Settings — the server works out which:
///   `GET /api/fm/utilities/live?tags=DG,UPS` (server services/utilityLive.ts)
///   → `{provider:{slug,displayName,family}, devices:[{id, tag, name, subsiteName,
///      online, readings:[{key,name,value,unit,time}]}], failedTags}`
/// Same [MscDevice] the building-system path builds, so every screen shows
/// either. The first read of a provider walks its sites (5–8 s, live
/// 2026-11-02); later ones come from the server's caches.
Future<List<MscDevice>> loadVendorDevices(ApiClient api, List<String> tags) async {
  if (tags.isEmpty) return const [];
  final body = await api.get('/api/fm/utilities/live', query: {'tags': tags.join(',')}, timeout: const Duration(seconds: 90));
  return [for (final d in rowsOf({'data': dataOf(body)['devices']})) vendorDevice(d)];
}

/// One vendor device. Empty values are left out (SustainSphere answers its
/// whole field list with nulls); the provider's own "Online / Offline" field is
/// the card's chip, not a reading.
MscDevice vendorDevice(Json d) {
  final readings = rowsOf({'data': d['readings']});
  bool polling(Json r) => '${r['key']}'.toUpperCase().contains('POLLING');
  String nameOf(Json r) => s(r['name']) ?? humanizePoint('${r['key']}');
  return MscDevice(
    id: '${d['id']}',
    name: s(d['name']) ?? '–',
    tag: s(d['tag']) ?? '',
    description: s(d['subsiteName']),
    online: d['online'] == true,
    raw: {for (final r in readings) '${r['key']}': r['value']},
    labels: {for (final r in readings) '${r['key']}': nameOf(r)},
    points: [
      for (final r in readings)
        if (!polling(r) && r['value'] != null && '${r['value']}'.isNotEmpty) (nameOf(r), vendorValue(r['value'], s(r['unit']))),
    ],
  );
}

/// A reading with its unit ("25 °C"), as the vendor pages show it.
String vendorValue(Object? v, String? unit) {
  final t = formatPoint(v);
  return unit == null || unit.isEmpty || t == '–' ? t : '$t $unit';
}

/// The user's provider decides (bootstrap `prefs.utilityProvider`).
Future<List<MscDevice>> loadUtilityDevices(ApiClient api, List<String> tags, {required bool bacnet}) =>
    bacnet ? loadMscDevices(api, tags) : loadVendorDevices(api, tags);

MscDevice _device(Json d, Map latest, List<Json> mapped) {
  final keys = [for (final k in latest.keys) '$k'];
  final labels = mappedLabels(keys, mapped);
  String label(String k) => labels[k] ?? humanizePoint(k);
  return MscDevice(
    id: '${d['device_id']}',
    name: s(d['name']) ?? '–',
    tag: s(d['utility_tag']) ?? '',
    description: s(d['description']),
    online: s(d['status']) != 'offline',
    assetId: s(d['fe_asset_uuid'])?.trim(),
    raw: {for (final e in latest.entries) '${e.key}': e.value},
    labels: labels,
    points: [for (final e in latest.entries) (label('${e.key}'), formatPoint(e.value))],
  );
}

/// Shared loading / polling for the three utility screens.
mixin _MscPolling<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  List<MscDevice>? devices;
  Object? error;
  DateTime? updatedAt;
  Timer? _timer;

  List<String> get tags;

  /// BacNet MSC chosen for the user in Settings (or an older server): read the
  /// building system directly; else their vendor provider via the server.
  bool get onBacnet => ref.read(loadedCatalogProvider)?.utilitiesOnBacnet ?? true;

  @override
  void initState() {
    super.initState();
    load();
    _timer = Timer.periodic(_pollEvery, (_) => load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final list = await loadUtilityDevices(ref.read(apiClientProvider), tags, bacnet: onBacnet);
      if (mounted) setState(() => (devices = list, error = null, updatedAt = DateTime.now()));
    } catch (e) {
      // A failed poll keeps the last good values (as the web does).
      if (mounted) setState(() => error = e);
    }
  }

  List<Widget> loadingOrError(BuildContext context) {
    if (devices == null && error == null) return const [Padding(padding: EdgeInsets.all(32), child: TechSpinner())];
    if (devices == null) {
      return [TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: error is ApiFailure ? (error as ApiFailure).message : null)];
    }
    return const [];
  }

  List<Kpi> deviceKpis(List<MscDevice> d) => [
    Kpi('util.devices', fmtNum(d.length)),
    Kpi('util.online', fmtNum(d.where((x) => x.online).length), tone: Tone.good),
    Kpi('util.offline', fmtNum(d.where((x) => !x.online).length), tone: d.any((x) => !x.online) ? Tone.bad : Tone.neutral),
  ];
}

Widget _kpiWrap(List<Kpi> kpis) => LayoutBuilder(
  builder: (context, c) {
    final w = (c.maxWidth - 20) / 3;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final k in kpis) SizedBox(width: w, child: KpiTile(k))],
    );
  },
);

Widget _updated(BuildContext context, DateTime? at, Object? error) => Padding(
  padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
  child: AppText.caption(
    at == null ? '' : context.formatString((error == null ? 'util.updated' : 'util.stale').getString(context), ['${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}']),
    color: error == null ? FeColors.ink2 : FeColors.warning,
  ),
);

// ── one utility ─────────────────────────────────────────────────────────────

/// One utility (DG, UPS, …) or HVAC unit type: device counts, then each
/// device with its live readings (the web's **Dashboard** tab, shown only
/// while `is<Utility>_Dashboard` is on — it arrives in the catalog `tabs`),
/// or its **Trends** (`is<Utility>_Trends`, utility_trends.dart). HVAC types
/// have no tab switches: both always.
class UtilityScreen extends ConsumerStatefulWidget {
  const UtilityScreen({super.key, required this.module, required this.tag, this.dashboardTab, this.trendsTab, this.alwaysTrends = false});

  final MobileModule module;
  final String tag;

  /// e.g. `isDg_Dashboard`; null = always shown.
  final String? dashboardTab;

  /// e.g. `isDg_Trends`; null = no Trends on the web page (unless [alwaysTrends]).
  final String? trendsTab;
  final bool alwaysTrends;

  @override
  ConsumerState<UtilityScreen> createState() => _UtilityScreenState();
}

class _UtilityScreenState extends ConsumerState<UtilityScreen> with _MscPolling {
  @override
  List<String> get tags => [widget.tag];

  bool _trends = false;

  @override
  Widget build(BuildContext context) {
    final showReadings = widget.dashboardTab == null || widget.module.tabs.contains(widget.dashboardTab);
    final trendsOnWeb = widget.alwaysTrends || (widget.trendsTab != null && widget.module.tabs.contains(widget.trendsTab));
    // Trends read the building system's history: Vidyutt / SustainSphere users
    // get no Trends option at all (owner, 2026-11-02).
    final showTrends = trendsOnWeb && onBacnet;
    // Trends only (Dashboard switched off) opens on Trends.
    final onTrends = showTrends && (_trends || !showReadings);
    final d = devices;
    return Scaffold(
      appBar: FeHeader(title: widget.module.label),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            ...loadingOrError(context),
            if (d != null) ...[
              _kpiWrap(deviceKpis(d)),
              _updated(context, updatedAt, error),
              if (d.isNotEmpty && showTrends && showReadings) ...[
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: AppText('util.tab_readings'.getString(context))),
                    ButtonSegment(value: true, label: AppText('util.tab_trends'.getString(context))),
                  ],
                  selected: {onTrends},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _trends = s.first),
                ),
                const SizedBox(height: 12),
              ],
              // No cameras in the building system: the web shows its legacy
              // CCTV page (SustainSphere) instead, and so does the phone.
              if (d.isEmpty && widget.tag == 'CCTV' && showReadings)
                const CctvLegacyView()
              else if (d.isEmpty)
                TechEmptyState(icon: moduleIcon(widget.module.icon), title: 'util.no_devices'.getString(context), subtitle: 'util.no_devices_hint'.getString(context))
              else if (onTrends)
                UtilityTrendsView(devices: d)
              else if (!showReadings)
                TechEmptyState(icon: LucideIcons.eyeOff, title: 'util.dashboard_off'.getString(context))
              else
                for (final dev in d)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DeviceCard(device: dev),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A device with its first readings; tap for all of them.
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.device, this.maxPoints = 6});
  final MscDevice device;
  final int maxPoints;

  @override
  Widget build(BuildContext context) {
    final dev = device;
    final shown = dev.points.take(maxPoints).toList();
    return TechCard(
      onTap: dev.points.length > maxPoints ? () => _showAll(context, dev) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TechChip(label: (dev.online ? 'util.online' : 'util.offline').getString(context), style: context.chips.status(dev.online ? 'completed' : 'cancelled')),
              const Spacer(),
              AppText.caption(dev.tag),
            ],
          ),
          const SizedBox(height: 8),
          AppText.titleSmall(dev.name),
          if (dev.description != null) AppText.bodySmall(dev.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (shown.isEmpty) ...[
            const SizedBox(height: 8),
            AppText.bodySmall('util.no_readings'.getString(context)),
          ] else ...[
            const SizedBox(height: 10),
            _PointGrid(points: shown),
            if (dev.points.length > maxPoints) ...[
              const SizedBox(height: 6),
              AppText.caption(context.formatString('util.more_points'.getString(context), [dev.points.length - maxPoints]), color: FeColors.primary),
            ],
          ],
        ],
      ),
    );
  }

  static void _showAll(BuildContext context, MscDevice dev) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          AppText.title(dev.name),
          if (dev.description != null) AppText.bodySmall(dev.description!),
          const SizedBox(height: 16),
          _PointGrid(points: dev.points),
        ],
      ),
    ),
  );
}

class _PointGrid extends StatelessWidget {
  const _PointGrid({required this.points});
  final List<(String, String)> points;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = (c.maxWidth - 12) / 2;
      return Wrap(
        spacing: 12,
        runSpacing: 10,
        children: [
          for (final (name, value) in points)
            SizedBox(
              width: w,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.caption(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  AppText.body(value, weight: FontWeight.w700, maxLines: 1),
                ],
              ),
            ),
        ],
      );
    },
  );
}

// ── Facility Utilities overview ─────────────────────────────────────────────

/// The utilities this user may open, with device counts (one call each for
/// devices and readings, all tags at once). Tap → that utility's screen.
class UtilitiesOverviewScreen extends ConsumerStatefulWidget {
  const UtilitiesOverviewScreen({super.key, required this.module});
  final MobileModule module;

  @override
  ConsumerState<UtilitiesOverviewScreen> createState() => _UtilitiesOverviewScreenState();
}

class _UtilitiesOverviewScreenState extends ConsumerState<UtilitiesOverviewScreen> with _MscPolling {
  List<MobileModule> get _utilities {
    final boot = ref.read(loadedCatalogProvider);
    return [
      for (final m in boot?.modules ?? const <MobileModule>[])
        if (utilityTags.containsKey(m.id) && !m.id.startsWith('hvac_')) m,
    ];
  }

  @override
  List<String> get tags => [for (final m in _utilities) utilityTags[m.id]!];

  @override
  Widget build(BuildContext context) {
    ref.watch(loadedCatalogProvider);
    final d = devices;
    return Scaffold(
      appBar: FeHeader(title: widget.module.label),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            ...loadingOrError(context),
            if (d != null) ...[
              _kpiWrap(deviceKpis(d)),
              _updated(context, updatedAt, error),
              for (final m in _utilities)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _UtilityRow(module: m, devices: d.where((x) => x.tag == utilityTags[m.id]).toList()),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UtilityRow extends StatelessWidget {
  const _UtilityRow({required this.module, required this.devices});
  final MobileModule module;
  final List<MscDevice> devices;

  @override
  Widget build(BuildContext context) {
    final offline = devices.where((d) => !d.online).length;
    return TechCard(
      onTap: () => context.push(modulePath(module.id)),
      child: Row(
        children: [
          IconBadge(icon: moduleIcon(module.icon), style: context.accents.blue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.titleSmall(module.label),
                AppText.bodySmall(
                  devices.isEmpty ? 'util.no_devices'.getString(context) : context.formatString('util.devices_line'.getString(context), [devices.length, offline]),
                  color: offline > 0 ? FeColors.danger : FeColors.ink2,
                ),
              ],
            ),
          ),
          const Icon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
        ],
      ),
    );
  }
}

// ── Utility Explorer ────────────────────────────────────────────────────────

/// Every device of every utility this user has, searchable by name / tag.
class UtilityExplorerScreen extends ConsumerStatefulWidget {
  const UtilityExplorerScreen({super.key, required this.module});
  final MobileModule module;

  @override
  ConsumerState<UtilityExplorerScreen> createState() => _UtilityExplorerScreenState();
}

class _UtilityExplorerScreenState extends ConsumerState<UtilityExplorerScreen> with _MscPolling {
  String _q = '';

  @override
  List<String> get tags {
    final boot = ref.read(loadedCatalogProvider);
    return [
      for (final m in boot?.modules ?? const <MobileModule>[])
        if (utilityTags.containsKey(m.id)) utilityTags[m.id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final d = devices?.where((x) => q.isEmpty || x.name.toLowerCase().contains(q) || x.tag.toLowerCase().contains(q) || (x.description ?? '').toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: FeHeader(title: widget.module.label),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: InputDecoration(hintText: 'common.search'.getString(context), prefixIcon: const Icon(LucideIcons.search, size: 18)),
            ),
            const SizedBox(height: 8),
            ...loadingOrError(context),
            if (d != null) ...[
              _updated(context, updatedAt, error),
              if (d.isEmpty) TechEmptyState(icon: LucideIcons.compass, title: 'module.empty'.getString(context)),
              for (final dev in d)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DeviceCard(device: dev, maxPoints: 4),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

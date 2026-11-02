import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/env.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';
import 'module_spec.dart';
import 'utility_screens.dart';

/// Floor Plan on the phone — the web's Floor Map (client
/// app/facility-utilities/floor-map/page.tsx): room temperature sensors and
/// AC / ductable AC / AHU units on the floor's plan, coloured by health.
///
///   devices  the building system, tags TEMP / AC / DUCTABLE-AC / AHU, polled
///   floor    the device's mapped asset (`fe_asset_uuid` → asset.floorID)
///   plan     `GET /api/floors/floors?all=true` → imageUrl
///   spot     asset.customAttributes.x / .y, percent of the plan image
///
/// Read-only: placing or moving a device stays on the web (it writes the
/// asset). A PDF plan opens on the web (the phone doesn't draw PDFs).
const floorMapTags = ['TEMP', 'AC', 'DUCTABLE-AC', 'AHU'];

const _pollEvery = Duration(seconds: 45);

enum MapHealth { ok, warn, alarm, offline, unknown }

/// One device's headline on the map. Port of the web's `deviceReading`
/// (lib/msc/deviceReading.ts) for the four map tags, with the comfort rule
/// (lib/msc/comfort.ts). CHANGE BOTH.
class MapReading {
  const MapReading({required this.health, this.temp, this.note});
  final MapHealth health;
  final double? temp;

  /// "Too warm" / "On · set 24°" / "Not reporting" / an active alarm.
  final String? note;
}

const _standardBand = (lo: 20.0, hi: 26.0);

double? _num(Map<String, Object?> p, List<String> names) {
  for (final n in names) {
    final v = p[n];
    final x = v is num
        ? v.toDouble()
        : v is String && v.trim().isNotEmpty
        ? double.tryParse(v)
        : null;
    if (x != null && x.isFinite) return x;
  }
  return null;
}

bool? _bool(Map<String, Object?> p, List<String> names) {
  for (final n in names) {
    final v = p[n];
    if (v is bool) return v;
    if (v is num && (v == 0 || v == 1)) return v == 1;
    if (v is String && RegExp(r'^(true|false|on|off|active|inactive|1|0)$', caseSensitive: false).hasMatch(v.trim())) {
      return RegExp(r'^(true|on|active|1)$', caseSensitive: false).hasMatch(v.trim());
    }
  }
  return null;
}

bool _real(double? v, double lo, double hi) => v != null && v >= lo && v <= hi;

String _f1(double v) => v.toStringAsFixed(1);

MapReading deviceHealth(String tag, Map<String, Object?> points, {bool online = true}) {
  final p = {for (final e in points.entries) e.key.substring(e.key.lastIndexOf('/') + 1): e.value};
  final offline = points.isEmpty || !online || _bool(p, ['PollingOnline', 'CommOnline']) == false;

  final alarms = <String>[];
  for (final e in p.entries) {
    final n = e.key;
    if (!RegExp('(Alarm|Fault|Trip|Failure|Leak|Missing|BatteryLow|OutOfService|FireStatus)').hasMatch(n)) continue;
    if (RegExp(r'Healthy|Count$').hasMatch(n) && !RegExp(r'^Total(Alarm|Fault)Count$').hasMatch(n)) continue;
    if (n.endsWith('Count')) {
      if ((_num(p, [n]) ?? 0) > 0) alarms.add(humanizePoint(n.replaceAll(RegExp('Total|Count'), '')));
    } else if (_bool(p, [n]) == true) {
      alarms.add(humanizePoint(n.replaceAll(RegExp(r'Status$'), '')));
    }
  }

  var health = MapHealth.ok;
  double? temp;
  String? note;
  if (tag == 'TEMP') {
    final t = _num(p, ['Temperature', 'SpaceTemp', 'RoomTemp', 'OutdoorTemp']);
    temp = _real(t, -40, 80) ? t : null; // -50 / 150 are the sensor's "no value"
    final lo = _num(p, ['MinThreshold', 'HeatingSetpoint']);
    final hi = _num(p, ['MaxThreshold', 'CoolingSetpoint']);
    final band = _real(lo, 5, 45) && _real(hi, 5, 45) && hi! > lo! ? (lo: lo, hi: hi) : _standardBand;
    if (temp != null) {
      if (temp > band.hi) {
        health = MapHealth.warn;
        note = 'floor.too_warm';
      } else if (temp < band.lo) {
        health = MapHealth.warn;
        note = 'floor.too_cold';
      } else {
        note = 'floor.comfortable';
      }
    }
  } else {
    temp = _num(p, ['RoomTemp', 'ReturnAirTemp', 'SupplyAirTemp', 'ReturnTemp']);
    final set = _num(p, ['RoomTempSetpoint', 'SetTemp', 'SupplyAirTempSetpoint']);
    final state = _num(p, ['State']);
    final on = state != null ? state == 1 : _bool(p, ['FanStatus', 'FanEnable', 'SupplyFanEnable']);
    if (set != null && temp != null && on == true && temp - set > 3) health = MapHealth.warn;
    note = on == null
        ? null
        : on
        ? (set != null ? 'On · set ${_f1(set)}°' : 'On')
        : 'Off';
  }
  if (alarms.isNotEmpty) {
    health = RegExp('Fire|Trip|Leak').hasMatch(alarms.join(' ')) ? MapHealth.alarm : MapHealth.warn;
    note = alarms.take(2).join(' · ');
  }
  if (offline) return MapReading(health: MapHealth.offline, temp: temp, note: 'floor.not_reporting');
  if (temp == null && health == MapHealth.ok && alarms.isEmpty && tag == 'TEMP') return const MapReading(health: MapHealth.unknown);
  return MapReading(health: health, temp: temp, note: note);
}

Color healthColor(MapHealth h) => switch (h) {
  MapHealth.ok => FeColors.success,
  MapHealth.warn => FeColors.warning,
  MapHealth.alarm => FeColors.danger,
  _ => FeColors.ink2,
};

class FloorRow {
  const FloorRow({required this.id, required this.name, this.number, this.imageUrl, this.building});
  final String id;
  final String name;
  final String? number;
  final String? imageUrl;
  final String? building;
}

/// A plan image the phone can load: absolute URLs as they are, web paths
/// (`/images/floors/…`) on the web app's host. Null for none.
String? planUrl(String? raw, {String webBase = Env.webBaseUrl}) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  if (v.startsWith('http://') || v.startsWith('https://') || v.startsWith('data:')) return v;
  final base = webBase.endsWith('/') ? webBase.substring(0, webBase.length - 1) : webBase;
  return v.startsWith('/') ? '$base$v' : '$base/$v';
}

bool isPdf(String url) => RegExp(r'\.pdf($|\?)', caseSensitive: false).hasMatch(url) || url.startsWith('data:application/pdf');

/// The spot saved by Floor Management ▸ Asset Mapping, as fractions (0–1).
Offset? spotOf(Json? asset) {
  final ca = asset?['customAttributes'];
  if (ca is! Map) return null;
  final x = n(ca['x']);
  final y = n(ca['y']);
  if (x == null || y == null) return null;
  return Offset((x / 100).clamp(0, 1).toDouble(), (y / 100).clamp(0, 1).toDouble());
}

/// Everything the map needs, loaded once (floors, assets) or polled (devices).
class FloorMapData {
  const FloorMapData({required this.devices, required this.floors, required this.assets});
  final List<MscDevice> devices;
  final Map<String, FloorRow> floors;

  /// asset id → asset JSON (null: not found / no access).
  final Map<String, Json?> assets;

  String? floorOf(MscDevice d) => d.assetId == null ? null : s(assets[d.assetId]?['floorID']);

  /// Floors with at least one device, lowest number first.
  List<FloorRow> get floorsInUse {
    final ids = {for (final d in devices) ?floorOf(d)};
    final list = [for (final id in ids) ?floors[id]];
    list.sort((a, b) => (n(a.number) ?? 99).compareTo(n(b.number) ?? 99) == 0 ? a.name.compareTo(b.name) : (n(a.number) ?? 99).compareTo(n(b.number) ?? 99));
    return list;
  }

  List<MscDevice> on(String floorId) => [
    for (final d in devices)
      if (floorOf(d) == floorId) d,
  ];
}

Future<Map<String, FloorRow>> loadFloors(ApiClient api) async {
  final body = await api.get('/api/floors/floors', query: {'all': 'true'});
  return {
    for (final f in rowsOf(body))
      '${f['id']}': FloorRow(
        id: '${f['id']}',
        name: s(f['floorName']) ?? 'Floor',
        number: s(f['floorNumber']),
        imageUrl: s(f['imageUrl']),
        building: s(at(f, 'building.name')),
      ),
  };
}

class FloorPlanScreen extends ConsumerStatefulWidget {
  const FloorPlanScreen({super.key, required this.module});
  final MobileModule module;

  @override
  ConsumerState<FloorPlanScreen> createState() => _FloorPlanScreenState();
}

class _FloorPlanScreenState extends ConsumerState<FloorPlanScreen> {
  List<MscDevice>? _devices;
  Map<String, FloorRow> _floors = const {};
  final Map<String, Json?> _assets = {};
  Object? _error;
  DateTime? _updatedAt;
  String? _picked;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load(first: true);
    _timer = Timer.periodic(_pollEvery, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool first = false}) async {
    final api = ref.read(apiClientProvider);
    try {
      final results = await Future.wait([
        loadMscDevices(api, floorMapTags),
        if (first || _floors.isEmpty) loadFloors(api).catchError((Object _) => <String, FloorRow>{}),
      ]);
      final devices = results[0] as List<MscDevice>;
      // Each linked asset once (its floor and spot rarely change).
      final missing = {
        for (final d in devices)
          if (d.assetId != null && !_assets.containsKey(d.assetId)) d.assetId!,
      };
      final fetched = await Future.wait([
        for (final id in missing)
          api
              .get('/api/fm/assets/${Uri.encodeComponent(id)}')
              .then<Json?>((b) => b is Map && b['data'] is Map ? (b['data'] as Map).cast<String, dynamic>() : null)
              .catchError((Object _) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _devices = devices;
        if (results.length > 1) _floors = results[1] as Map<String, FloorRow>;
        for (final (i, id) in missing.indexed) {
          _assets[id] = fetched[i];
        }
        _error = null;
        _updatedAt = DateTime.now();
      });
    } catch (e) {
      // A failed poll keeps the last good values (as the web does).
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final data = devices == null ? null : FloorMapData(devices: devices, floors: _floors, assets: _assets);
    final floors = data?.floorsInUse ?? const <FloorRow>[];
    final floor =
        floors.where((f) => f.id == _picked).firstOrNull ??
        floors.where((f) => data!.on(f.id).any((d) => spotOf(_assets[d.assetId]) != null)).firstOrNull ??
        floors.firstOrNull;
    final onFloor = floor == null ? const <MscDevice>[] : data!.on(floor.id);
    final unlinked = devices == null ? 0 : devices.where((d) => data!.floorOf(d) == null).length;
    final manyBuildings = {for (final f in floors) f.building}.length > 1;

    return Scaffold(
      appBar: FeHeader(
        title: widget.module.label,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          // RowGroup brings its own 16px side inset; everything else gets it here.
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            for (final w in [
              if (devices == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
              if (devices == null && _error != null)
                TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: 'module.load_error'.getString(context),
                  subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null,
                ),
              if (devices != null && floors.isEmpty)
                TechEmptyState(icon: LucideIcons.map, title: 'floor.none_title'.getString(context), subtitle: 'floor.none_hint'.getString(context)),
              if (floor != null) ...[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final f in floors)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: ChoiceChip(
                            label: AppText.caption(manyBuildings && f.building != null ? '${f.name} · ${f.building}' : f.name),
                            selected: f.id == floor.id,
                            onSelected: (_) => setState(() => _picked = f.id),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Legend(devices: onFloor),
                const SizedBox(height: 12),
                _Plan(floor: floor, devices: onFloor, assets: _assets, webPath: widget.module.webPath),
                if (_updatedAt != null) ...[
                  const SizedBox(height: 6),
                  AppText.caption(
                    context.formatString((_error == null ? 'util.updated' : 'util.stale').getString(context), [
                      '${_updatedAt!.hour.toString().padLeft(2, '0')}:${_updatedAt!.minute.toString().padLeft(2, '0')}',
                    ]),
                    color: _error == null ? FeColors.ink2 : FeColors.warning,
                  ),
                ],
              ],
              if (unlinked > 0 && floor == null) ...[
                const SizedBox(height: 12),
                AppText.caption(context.formatString('floor.unlinked'.getString(context), [unlinked])),
              ],
            ])
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: w),
            if (floor != null) ...[
              const SizedBox(height: 16),
              RowGroup(
                label: 'floor.devices'.getString(context),
                dividerIndent: 16,
                rows: [for (final d in onFloor) _DeviceRow(device: d, placed: spotOf(_assets[d.assetId]) != null)],
              ),
              if (unlinked > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: AppText.caption(context.formatString('floor.unlinked'.getString(context), [unlinked])),
                ),
            ],
            // Pins are building-system (BacNet) devices on the web too: a
            // Vidyutt / SustainSphere user sees the building system's here.
            if (!(ref.read(loadedCatalogProvider)?.utilitiesOnBacnet ?? true))
              const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 0), child: DesktopNote(textKey: 'floor.bacnet_only')),
            const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 0), child: DesktopNote(textKey: 'desktop.floor')),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.devices});
  final List<MscDevice> devices;

  @override
  Widget build(BuildContext context) {
    final counts = <MapHealth, int>{};
    for (final d in devices) {
      final h = deviceHealth(d.tag, d.raw, online: d.online).health;
      counts[h] = (counts[h] ?? 0) + 1;
    }
    Widget item(MapHealth h, String key) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: healthColor(h), shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        AppText.caption('${'floor.$key'.getString(context)} ${counts[h] ?? 0}'),
      ],
    );
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        item(MapHealth.ok, 'normal'),
        item(MapHealth.warn, 'slightly_off'),
        item(MapHealth.alarm, 'attention'),
        if ((counts[MapHealth.offline] ?? 0) + (counts[MapHealth.unknown] ?? 0) > 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(color: FeColors.ink2, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              AppText.caption('${'floor.no_reading'.getString(context)} ${(counts[MapHealth.offline] ?? 0) + (counts[MapHealth.unknown] ?? 0)}'),
            ],
          ),
      ],
    );
  }
}

/// The plan with a pin per placed device; pinch to zoom. The pins sit on the
/// image's own size, so the image's aspect ratio is read first.
class _Plan extends StatefulWidget {
  const _Plan({required this.floor, required this.devices, required this.assets, required this.webPath});
  final FloorRow floor;
  final List<MscDevice> devices;
  final Map<String, Json?> assets;
  final String webPath;

  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;
  bool _failed = false;
  String? _url;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_Plan old) {
    super.didUpdateWidget(old);
    if (old.floor.imageUrl != widget.floor.imageUrl) _resolve();
  }

  void _resolve() {
    final url = planUrl(widget.floor.imageUrl);
    if (url == _url) return;
    _stop();
    _url = url;
    _aspect = null;
    _failed = false;
    if (url == null || isPdf(url)) return;
    _stream = NetworkImage(url).resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) {
        if (mounted) setState(() => _aspect = info.image.width / info.image.height);
      },
      onError: (_, _) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _stream!.addListener(_listener!);
  }

  void _stop() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Widget _box(Widget child) => Container(
    constraints: const BoxConstraints(minHeight: 180),
    width: double.infinity,
    decoration: BoxDecoration(
      color: FeColors.panel,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: FeColors.line),
    ),
    padding: const EdgeInsets.all(16),
    alignment: Alignment.center,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null) {
      return _box(TechEmptyState(icon: LucideIcons.imageOff, title: 'floor.no_plan'.getString(context), subtitle: 'floor.no_plan_hint'.getString(context)));
    }
    if (isPdf(url)) {
      return _box(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppText.bodySmall('floor.pdf_plan'.getString(context), align: TextAlign.center),
            const SizedBox(height: 8),
            const DesktopNote(textKey: 'desktop.floor_pdf'),
          ],
        ),
      );
    }
    if (_failed) return _box(TechEmptyState(icon: LucideIcons.imageOff, title: 'floor.plan_missing'.getString(context)));
    if (_aspect == null) return _box(const TechSpinner());

    final pins = [
      for (final d in widget.devices)
        if (spotOf(widget.assets[d.assetId]) case final spot?) (d, spot),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: InteractiveViewer(
        maxScale: 5,
        child: AspectRatio(
          aspectRatio: _aspect!,
          child: LayoutBuilder(
            builder: (context, c) => Stack(
              children: [
                Positioned.fill(child: Image.network(url, fit: BoxFit.fill)),
                for (final (d, spot) in pins)
                  Positioned(
                    left: spot.dx * c.maxWidth - 16,
                    top: spot.dy * c.maxHeight - 16,
                    child: _Pin(device: d),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.device});
  final MscDevice device;

  @override
  Widget build(BuildContext context) {
    final r = deviceHealth(device.tag, device.raw, online: device.online);
    final hue = healthColor(r.health);
    return Semantics(
      button: true,
      label: device.name,
      child: GestureDetector(
        onTap: () => showDeviceSheet(context, device),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: hue, width: 3),
          ),
          alignment: Alignment.center,
          child: Icon(device.tag == 'TEMP' ? LucideIcons.thermometer : LucideIcons.fan, size: 16, color: hue),
        ),
      ),
    );
  }
}

/// The device's readings, as on the utility screens.
void showDeviceSheet(BuildContext context, MscDevice device) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: DeviceCard(device: device, maxPoints: 40),
    ),
  ),
);

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.placed});
  final MscDevice device;
  final bool placed;

  @override
  Widget build(BuildContext context) {
    final r = deviceHealth(device.tag, device.raw, online: device.online);
    String word(String? v) => v == null
        ? ''
        : v.startsWith('floor.')
        ? v.getString(context)
        : v;
    return ListTile(
      dense: true,
      onTap: () => showDeviceSheet(context, device),
      leading: Icon(device.tag == 'TEMP' ? LucideIcons.thermometer : LucideIcons.fan, color: healthColor(r.health), size: 20),
      title: AppText.body(device.name),
      subtitle: AppText.caption([word(r.note), if (!placed) 'floor.not_placed'.getString(context)].where((t) => t.isNotEmpty).join(' · ')),
      trailing: AppText.titleSmall(r.temp == null ? '–' : '${_f1(r.temp!)} °C', color: healthColor(r.health)),
    );
  }
}

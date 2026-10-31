import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/module_icons.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';
import '../module/module_screen.dart';
import '../modules/module_spec.dart';
import '../modules/module_summary_screen.dart';

/// Plant Room on the phone (FE-mobile.md Phase 2): the saved Plant Studio
/// rooms, then one room as a 2D card grid of its machines with live values.
/// The 3D studio, the builder and AI generation stay on the web.
///   GET /api/fm/plant-layouts?scope=all          rooms (mine + shared to my org)
///   GET /api/fm/plant-layouts/:id                one room: instances + connections
///   GET /api/fm/plant-layouts/live?assetIds=…    mapped live points per FM asset
/// Live sizes (2026-10-30): /live is 11 KB for 60 assets (the server cap), so
/// it needs no `?view=mobile`. It is slow, though (about 20 s even for a few
/// assets, PENDING P-017), hence the long timeout and one poll at a time.

const _pollEvery = Duration(seconds: 30);
const _liveTimeout = Duration(seconds: 60);
const _base = '/api/fm/plant-layouts';

/// The web studio's room URL (app/facility-utilities/plant-room/[layoutId]).
String plantRoomWebPath(String id) => '/facility-utilities/plant-room/$id';

// ── pure helpers (unit-tested) ─────────────────────────────────────────────

/// Port of the web's `toAlarmState` (fusion-eco-client
/// components/hvac/ahu-visualizer/model/ahuParameters.ts). CHANGE BOTH.
String toAlarmState(Object? v) {
  if (v == null || v == '') return 'unknown';
  if (v is bool) return v ? 'alarm' : 'normal';
  final s = '$v'.trim().toUpperCase();
  if (RegExp(r'\bTRIP(PED)?\b').hasMatch(s)) return 'trip';
  if (RegExp(r'\bNO\s+(ALARM|FAULT|FIRE)\b').hasMatch(s)) return 'normal';
  if (RegExp(r'\bUNHEALTHY\b|\bABNORMAL\b|\bNOT\s+NORMAL\b|\bALARM\b|\bFAULT(Y|ED)?\b|\bFIRE\b|\bSMOKE\b').hasMatch(s)) return 'alarm';
  if (RegExp(r'\bNORMAL\b|\bOK\b|\bHEALTHY\b|\bOFF\b|\bFALSE\b|^0$').hasMatch(s)) return 'normal';
  if (RegExp(r'\bON\b|\bTRUE\b|^1$').hasMatch(s)) return 'alarm';
  return 'unknown';
}

/// Standard parameters that report an alarm. Only these are read with
/// [toAlarmState]: on a "Running status" point, `ON` means running, not alarm.
final _alarmParam = RegExp(r'alarm|fault|trip|fire|smoke|leak', caseSensitive: false);

/// One live point of a placed machine.
class PlantPoint {
  const PlantPoint({required this.name, required this.value, this.unit, this.time});
  final String name;
  final Object? value;
  final String? unit;
  final String? time;

  bool get isAlarm => _alarmParam.hasMatch(name) && const {'alarm', 'trip'}.contains(toAlarmState(value));

  String get display {
    final v = value is num ? fmtNum(value as num, decimals: (value as num).abs() < 10 ? 2 : 1) : (value is bool ? ((value as bool) ? 'On' : 'Off') : '$value');
    return unit == null || unit!.isEmpty ? v : '$v $unit';
  }
}

/// Where a machine's numbers come from on the phone.
/// `live | no-data | unmapped | unbound | not-found` come from the server.
/// `device`: bound straight to a BMS device, read by the web studio only.
/// `none`: placed without an asset or device (the web animates a demo).
enum PlantFeed { live, noData, unmapped, unbound, notFound, device, none, waiting }

PlantFeed _feedOf(String? s) => switch (s) {
      'live' => PlantFeed.live,
      'no-data' => PlantFeed.noData,
      'unmapped' => PlantFeed.unmapped,
      'unbound' => PlantFeed.unbound,
      'not-found' => PlantFeed.notFound,
      _ => PlantFeed.noData,
    };

/// One machine placed in a room.
class PlantMachine {
  const PlantMachine({required this.id, required this.type, required this.label, this.assetId, this.assetName, this.deviceName, this.feed = PlantFeed.waiting, this.points = const []});

  final String id;
  final String type;
  final String label;
  final String? assetId;
  final String? assetName;
  final String? deviceName;
  final PlantFeed feed;
  final List<PlantPoint> points;

  bool get alarm => points.any((p) => p.isAlarm);

  /// critical (an alarm point) · ok (live) · nodata (anything else), the
  /// web's attention levels minus `warn`: that one comes from each machine
  /// type's own thresholds, which the phone does not copy.
  String get level => alarm ? 'critical' : (feed == PlantFeed.live ? 'ok' : 'nodata');

  /// Joins the machine with its asset's live feed from `/live`.
  PlantMachine withLive(Map? live) {
    if (assetId == null) return this;
    final a = live?[assetId];
    if (a is! Map) return this;
    final pts = a['points'] is Map ? (a['points'] as Map) : const {};
    return PlantMachine(
      id: id,
      type: type,
      label: label,
      assetId: assetId,
      assetName: assetName,
      deviceName: deviceName,
      feed: _feedOf(s(a['status'])),
      points: [
        for (final e in pts.entries)
          if (e.value is Map) PlantPoint(name: s((e.value as Map)['name']) ?? '${e.key}', value: (e.value as Map)['value'], unit: s((e.value as Map)['unit']), time: s((e.value as Map)['time'])),
      ],
    );
  }

  static PlantMachine fromJson(Map j) {
    final binding = j['binding'] is Map ? j['binding'] as Map : null;
    final asset = s(j['assetId']);
    return PlantMachine(
      id: '${j['id']}',
      type: s(j['type']) ?? '',
      label: s(j['label']) ?? '–',
      assetId: asset,
      assetName: s(j['assetName']),
      deviceName: s(binding?['deviceName']),
      feed: asset != null ? PlantFeed.waiting : (binding != null ? PlantFeed.device : PlantFeed.none),
    );
  }
}

/// Machines of a room, alarms first, then live, then the rest (stable).
List<PlantMachine> sortMachines(List<PlantMachine> m) {
  const rank = {'critical': 0, 'ok': 1, 'nodata': 2};
  final indexed = [for (var i = 0; i < m.length; i++) (i, m[i])];
  indexed.sort((a, b) {
    final r = rank[a.$2.level]!.compareTo(rank[b.$2.level]!);
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final (_, x) in indexed) x];
}

/// The distinct FM asset ids to ask `/live` for (server cap: 60).
List<String> assetIdsOf(List<PlantMachine> m) => {for (final x in m) if (x.assetId != null) x.assetId!}.take(60).toList();

String _typeLabel(BuildContext context, String type) {
  final key = 'plant.t_${type.toLowerCase()}';
  final v = key.getString(context);
  return v == key ? chipLabel(type) : v;
}

/// The Plant Room module is still in the catalog (screens pushed with
/// Navigator don't pass the router's guard).
bool _stillVisible(WidgetRef ref) {
  final boot = ref.watch(loadedCatalogProvider);
  return boot == null || boot.module('plant_room') != null;
}

// ── room list ───────────────────────────────────────────────────────────────

class PlantRoomListScreen extends ConsumerStatefulWidget {
  const PlantRoomListScreen({super.key, required this.module});
  final MobileModule module;

  @override
  ConsumerState<PlantRoomListScreen> createState() => _PlantRoomListScreenState();
}

class _PlantRoomListScreenState extends ConsumerState<PlantRoomListScreen> {
  List<Json>? _rooms;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(apiClientProvider).get(_base, query: {'scope': 'all'});
      if (mounted) setState(() => (_rooms = rowsOf(res), _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _rooms;
    return Scaffold(
      appBar: FeHeader(title: widget.module.label, actions: [OpenOnWebButton(path: widget.module.webPath)]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (rooms == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
            if (rooms == null && _error != null)
              TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null),
            if (rooms != null && rooms.isEmpty)
              TechEmptyState(icon: moduleIcon(widget.module.icon), title: 'plant.no_rooms'.getString(context), subtitle: 'plant.no_rooms_hint'.getString(context)),
            if (rooms != null)
              for (final r in rooms)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TechCard(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlantRoomScreen(layoutId: '${r['id']}', name: s(r['name']) ?? '–'))),
                    child: Row(
                      children: [
                        Icon(moduleIcon(widget.module.icon), color: FeColors.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText.titleSmall(s(r['name']) ?? '–'),
                              AppText.caption(context.formatString('plant.updated_on'.getString(context), [fmtDate(r['updatedAt']) ?? '–'])),
                            ],
                          ),
                        ),
                        if (r['shared'] == true) AppText.caption('plant.shared'.getString(context), color: FeColors.primary),
                        const Icon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

// ── one room ────────────────────────────────────────────────────────────────

class PlantRoomScreen extends ConsumerStatefulWidget {
  const PlantRoomScreen({super.key, required this.layoutId, required this.name});
  final String layoutId;
  final String name;

  @override
  ConsumerState<PlantRoomScreen> createState() => _PlantRoomScreenState();
}

class _PlantRoomScreenState extends ConsumerState<PlantRoomScreen> {
  List<PlantMachine>? _machines;
  Map? _live;
  Object? _error;
  DateTime? _liveAt;
  bool _polling = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Only while this screen is open; dispose stops it.
    _timer = Timer.periodic(_pollEvery, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(apiClientProvider).get('$_base/${widget.layoutId}');
      final inst = dataOf(res)['instances'];
      final list = [for (final i in (inst is List ? inst : const [])) if (i is Map) PlantMachine.fromJson(i)];
      if (!mounted) return;
      setState(() => (_machines = list, _error = null));
      await _poll();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// One `/live` call at a time: it can take longer than the poll interval.
  Future<void> _poll() async {
    final ids = assetIdsOf(_machines ?? const []);
    if (_polling || ids.isEmpty) return;
    _polling = true;
    try {
      final res = await ref.read(apiClientProvider).get('$_base/live', query: {'assetIds': ids.join(',')}, timeout: _liveTimeout);
      final assets = dataOf(res)['assets'];
      if (mounted) setState(() => (_live = assets is Map ? assets : const {}, _liveAt = DateTime.now(), _error = null));
    } catch (e) {
      // A failed poll keeps the last good values (as the web does).
      if (mounted) setState(() => _error = e);
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_stillVisible(ref)) return const UnavailableScreen();
    final raw = _machines;
    final machines = raw == null ? null : sortMachines([for (final m in raw) m.withLive(_live)]);
    return Scaffold(
      appBar: FeHeader(title: widget.name, actions: [OpenOnWebButton(path: plantRoomWebPath(widget.layoutId))]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (machines == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
            if (machines == null && _error != null)
              TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null),
            if (machines != null && machines.isEmpty) TechEmptyState(icon: LucideIcons.factory, title: 'plant.no_machines'.getString(context)),
            if (machines != null && machines.isNotEmpty) ...[
              _Kpis(machines: machines),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
                child: AppText.caption(_status(context, machines), color: _error == null ? FeColors.ink2 : FeColors.warning),
              ),
              _Grid(machines: machines),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => openOnWeb(context, plantRoomWebPath(widget.layoutId)),
                icon: const Icon(LucideIcons.box, size: 16),
                label: AppText('plant.open_3d'.getString(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _status(BuildContext context, List<PlantMachine> m) {
    if (assetIdsOf(m).isEmpty) return 'plant.no_assets'.getString(context);
    final at = _liveAt;
    if (at == null) return (_error == null ? 'plant.loading_live' : 'plant.live_failed').getString(context);
    final hhmm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return context.formatString((_error == null ? 'util.updated' : 'util.stale').getString(context), [hhmm]);
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.machines});
  final List<PlantMachine> machines;

  @override
  Widget build(BuildContext context) {
    final alarms = machines.where((m) => m.level == 'critical').length;
    final kpis = [
      Kpi('plant.machines', fmtNum(machines.length)),
      Kpi('plant.alarms', fmtNum(alarms), tone: alarms > 0 ? Tone.bad : Tone.good),
      Kpi('plant.live', fmtNum(machines.where((m) => m.feed == PlantFeed.live).length), tone: Tone.info),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 20) / 3;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final k in kpis) SizedBox(width: w, child: KpiTile(k))]);
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.machines});
  final List<PlantMachine> machines;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final w = (c.maxWidth - 10) / 2;
          return Wrap(spacing: 10, runSpacing: 10, children: [for (final m in machines) SizedBox(width: w, child: _MachineCard(m))]);
        },
      );
}

class _MachineCard extends StatelessWidget {
  const _MachineCard(this.m);
  final PlantMachine m;

  static const _maxPoints = 3;

  @override
  Widget build(BuildContext context) {
    final color = switch (m.level) { 'critical' => FeColors.danger, 'ok' => FeColors.success, _ => FeColors.ink2 };
    final points = [...m.points.where((p) => p.isAlarm), ...m.points.where((p) => !p.isAlarm)];
    return TechCard(
      padding: const EdgeInsets.all(12),
      onTap: () => _showMachine(context, m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Expanded(child: AppText.caption(_typeLabel(context, m.type), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 6),
          AppText.titleSmall(m.label, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          if (points.isEmpty)
            AppText.caption(_feedText(context, m.feed), color: color, maxLines: 2)
          else
            for (final p in points.take(_maxPoints))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Expanded(child: AppText.caption(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 6),
                    Flexible(child: AppText.bodySmall(p.display, weight: FontWeight.w700, color: p.isAlarm ? FeColors.danger : null, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

String _feedText(BuildContext context, PlantFeed f) => switch (f) {
      PlantFeed.live => 'plant.feed_live',
      PlantFeed.noData => 'plant.feed_no_data',
      PlantFeed.unmapped => 'plant.feed_unmapped',
      PlantFeed.unbound => 'plant.feed_unbound',
      PlantFeed.notFound => 'plant.feed_not_found',
      PlantFeed.device => 'plant.feed_device',
      PlantFeed.none => 'plant.feed_none',
      PlantFeed.waiting => 'plant.loading_live',
    }
        .getString(context);

void _showMachine(BuildContext context, PlantMachine m) => showModalBottomSheet<void>(
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
            AppText.caption(_typeLabel(context, m.type)),
            AppText.title(m.label),
            if (m.assetName != null || m.deviceName != null) AppText.bodySmall(m.assetName ?? m.deviceName!),
            const SizedBox(height: 4),
            AppText.caption(_feedText(context, m.feed), color: m.alarm ? FeColors.danger : FeColors.ink2),
            const SizedBox(height: 16),
            for (final p in m.points)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText.body(p.name),
                          if (p.time != null) AppText.caption(p.time!),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    AppText.body(p.display, weight: FontWeight.w700, color: p.isAlarm ? FeColors.danger : null),
                  ],
                ),
              ),
          ],
        ),
      ),
    );

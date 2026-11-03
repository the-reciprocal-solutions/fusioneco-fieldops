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

/// Plant Room on the phone: a summary only (owner, 2026-11-03 — "recommend
/// the web for the plant room; simple summary data is enough"). The saved
/// Plant Studio rooms, then one room's machines counted and grouped by type,
/// with the "use a desktop" note. Live values, alarm colours, the 3D studio,
/// the builder and AI generation are on the web.
///   GET /api/fm/plant-layouts?scope=all   rooms (mine + shared to my org)
///   GET /api/fm/plant-layouts/:id         one room: its placed machines
const _base = '/api/fm/plant-layouts';

/// One machine placed in a room (only what the summary counts).
class PlantMachine {
  const PlantMachine({required this.id, required this.type, required this.label, this.assetId, this.deviceName});
  final String id;
  final String type;
  final String label;
  final String? assetId;
  final String? deviceName;

  static PlantMachine fromJson(Map j) {
    final binding = j['binding'] is Map ? j['binding'] as Map : null;
    return PlantMachine(id: '${j['id']}', type: s(j['type']) ?? '', label: s(j['label']) ?? '–', assetId: s(j['assetId']), deviceName: s(binding?['deviceName']));
  }
}

/// Machine counts per type, biggest first (then by type, stable).
List<(String, int)> countByType(List<PlantMachine> m) {
  final c = <String, int>{};
  for (final x in m) {
    c[x.type] = (c[x.type] ?? 0) + 1;
  }
  final out = [for (final e in c.entries) (e.key, e.value)];
  out.sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
  return out;
}

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
      appBar: FeHeader(title: widget.module.label),
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

// ── one room (summary) ──────────────────────────────────────────────────────

class PlantRoomScreen extends ConsumerStatefulWidget {
  const PlantRoomScreen({super.key, required this.layoutId, required this.name});
  final String layoutId;
  final String name;

  @override
  ConsumerState<PlantRoomScreen> createState() => _PlantRoomScreenState();
}

class _PlantRoomScreenState extends ConsumerState<PlantRoomScreen> {
  List<PlantMachine>? _machines;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(apiClientProvider).get('$_base/${widget.layoutId}');
      final inst = dataOf(res)['instances'];
      final list = [for (final i in (inst is List ? inst : const [])) if (i is Map) PlantMachine.fromJson(i)];
      if (mounted) setState(() => (_machines = list, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_stillVisible(ref)) return const UnavailableScreen();
    final m = _machines;
    return Scaffold(
      appBar: FeHeader(title: widget.name),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (m == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
            if (m == null && _error != null)
              TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null),
            if (m != null && m.isEmpty) TechEmptyState(icon: LucideIcons.factory, title: 'plant.no_machines'.getString(context)),
            if (m != null && m.isNotEmpty) ...[
              _Kpis(machines: m),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 20, bottom: 10),
                child: AppText.caption('plant.by_type'.getString(context).toUpperCase(), weight: FontWeight.w700),
              ),
              TechCard(
                child: Column(
                  children: [
                    for (final (type, n) in countByType(m))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Expanded(child: AppText.body(_typeLabel(context, type))),
                            AppText.body(fmtNum(n), weight: FontWeight.w700),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (m != null) const DesktopNote(textKey: 'desktop.plant_3d'),
          ],
        ),
      ),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.machines});
  final List<PlantMachine> machines;

  @override
  Widget build(BuildContext context) {
    final asset = machines.where((x) => x.assetId != null).length;
    final device = machines.where((x) => x.assetId == null && x.deviceName != null).length;
    final kpis = [
      Kpi('plant.machines', fmtNum(machines.length)),
      Kpi('plant.types', fmtNum(countByType(machines).length), tone: Tone.info),
      Kpi('plant.linked', fmtNum(asset + device), tone: Tone.good),
      Kpi('plant.not_linked', fmtNum(machines.length - asset - device), tone: machines.length - asset - device > 0 ? Tone.warn : Tone.good),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final k in kpis) SizedBox(width: w, child: KpiTile(k))]);
      },
    );
  }
}

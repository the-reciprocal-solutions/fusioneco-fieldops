import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/env.dart';
import '../../core/media/photo_picker.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';
import '../module/module_screen.dart';
import '../modules/fm_specs.dart' show snagsSpec;
import '../modules/module_spec.dart';
import '../modules/module_summary_screen.dart';
import '../modules/record_detail_screen.dart';

/// Photo Twin on the phone (FE-mobile.md Phase 2). The Gaussian-splat viewer
/// stays on the web (phones vary too much for it in v1). The phone has:
///   - snag counts + the open snags, each with its moves (snag_actions.dart)
///   - the photo scans of each building (the 3D viewer is on the desktop)
///   - Report issue → a reactive ticket, as the web's Report sheet does
/// Calls (live sizes 2026-10-30):
///   GET /api/snags/summary · GET /api/snags?view=list (13 KB / 10 snags)
///   GET /api/fm/bs/3d-models (38 KB, every model; the photo scans are `metadata.kind == 'splat'`)
///   GET /api/snags/locations/buildings (the buildings this user may see)

/// The web viewer on one scan (components/digital-twin/realistic/viewState.ts: `b`, `m`).
String photoTwinWebPath(String buildingId, String modelId) => '/digital-twin/realistic?b=${Uri.encodeQueryComponent(buildingId)}&m=${Uri.encodeQueryComponent(modelId)}';

/// One photo scan (a splat model row).
class TwinScan {
  const TwinScan({required this.buildingId, required this.modelId, required this.name, this.level, this.thumbUrl});
  final String buildingId;
  final String modelId;
  final String name;
  final String? level;
  final String? thumbUrl;
}

/// The current photo scans, only for buildings the user may see, by building id.
Map<String, List<TwinScan>> scansByBuilding(List<Json> models, Set<String> buildingIds) {
  final out = <String, List<TwinScan>>{};
  for (final m in models) {
    final meta = m['metadata'] is Map ? m['metadata'] as Map : const {};
    final b = s(m['buildingId']);
    if (meta['kind'] != 'splat' || m['isCurrent'] == false || b == null || !buildingIds.contains(b)) continue;
    final thumb = s(meta['thumbUrl']);
    out.putIfAbsent(b, () => []).add(TwinScan(
          buildingId: b,
          modelId: s(m['modelId']) ?? '${m['id']}',
          name: s(m['name']) ?? '–',
          level: s(at(meta, 'placement.level')),
          // Relative thumbs are files of the web app (public/twin-assets).
          thumbUrl: thumb == null ? null : (thumb.startsWith('/') ? '${Env.webBaseUrl}$thumb' : thumb),
        ));
  }
  return out;
}

bool _photoTwinVisible(WidgetRef ref) {
  final boot = ref.watch(loadedCatalogProvider);
  return boot == null || boot.module('photo_twin') != null;
}

class PhotoTwinScreen extends ConsumerStatefulWidget {
  const PhotoTwinScreen({super.key, required this.module});
  final MobileModule module;

  @override
  ConsumerState<PhotoTwinScreen> createState() => _PhotoTwinScreenState();
}

class _PhotoTwinScreenState extends ConsumerState<PhotoTwinScreen> {
  Json? _summary;
  List<Json>? _snags;

  /// The last few closed / waived snags, so a closed one can be opened and
  /// reopened (the open list never shows them; found 2026-11-03).
  List<Json> _closed = const [];
  List<Json> _buildings = const [];
  Map<String, List<TwinScan>> _scans = const {};
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    try {
      final r = await Future.wait([
        api.get('/api/snags/summary'),
        api.get('/api/snags', query: {'view': 'list', 'status': 'open,in-progress,ready', 'limit': '50'}),
        api.get('/api/snags/locations/buildings'),
        api.get('/api/fm/bs/3d-models'),
        api.get('/api/snags', query: {'view': 'list', 'status': 'closed,waived', 'limit': '5'}),
      ]);
      final buildings = rowsOf(r[2]);
      if (!mounted) return;
      setState(() {
        _summary = dataOf(r[0]);
        _snags = rowsOf(r[1]);
        _closed = rowsOf(r[4]);
        _buildings = buildings;
        _scans = scansByBuilding(rowsOf(r[3]), {for (final b in buildings) '${b['id']}'});
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _openSnag(Json snag) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _Guarded(child: RecordDetailScreen(spec: snagsSpec, recordId: '${snag['id']}', initial: snag))));
    if (changed == true) _load();
  }

  Future<void> _report() async {
    final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _Guarded(child: ReportIssueScreen(buildings: _buildings))));
    if (sent == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final snags = _snags;
    final sum = _summary;
    return Scaffold(
      appBar: FeHeader(title: widget.module.label),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: FeColors.primary,
        foregroundColor: Colors.white,
        onPressed: _report,
        icon: const Icon(LucideIcons.triangleAlert),
        label: AppText('twin.report'.getString(context), color: Colors.white),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            if (snags == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: TechSpinner()),
            if (snags == null && _error != null)
              TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null),
            if (sum != null) _kpis(sum),
            if (snags != null) ...[
              _heading(context, 'twin.open_snags'),
              if (snags.isEmpty) AppText.bodySmall('twin.no_open_snags'.getString(context)),
              for (final r in snags)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: RecordCard(row: snagsSpec.list!.row(r), onTap: () => _openSnag(r))),
              if (_closed.isNotEmpty) ...[
                _heading(context, 'twin.recently_closed'),
                for (final r in _closed)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: RecordCard(row: snagsSpec.list!.row(r), onTap: () => _openSnag(r))),
              ],
              _heading(context, 'twin.scans'),
              if (_scans.isEmpty) AppText.bodySmall('twin.no_scans'.getString(context)),
              if (_scans.isNotEmpty) const Padding(padding: EdgeInsets.only(bottom: 10), child: DesktopNote(textKey: 'desktop.twin_scans')),
              for (final b in _buildings)
                if (_scans[b['id']] case final scans?) ...[
                  Padding(padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8), child: AppText.titleSmall(s(b['name']) ?? '–')),
                  for (final scan in scans) Padding(padding: const EdgeInsets.only(bottom: 10), child: _ScanCard(scan)),
                ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _kpis(Json j) {
    final kpis = [
      Kpi('kpi.open', fmtNum(at(j, 'byStatus.open'))),
      Kpi('kpi.in_progress', fmtNum(at(j, 'byStatus.in-progress')), tone: Tone.info),
      Kpi('twin.ready', fmtNum(at(j, 'byStatus.ready')), tone: Tone.warn),
      Kpi('kpi.overdue', fmtNum(j['overdue']), tone: Tone.bad),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final k in kpis) SizedBox(width: w, child: KpiTile(k))]);
      },
    );
  }

  Widget _heading(BuildContext context, String key) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, top: 20, bottom: 10),
        child: AppText.caption(key.getString(context).toUpperCase(), weight: FontWeight.w700),
      );
}

/// Screens pushed from Photo Twin go away if the module is switched off.
class _Guarded extends ConsumerWidget {
  const _Guarded({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _photoTwinVisible(ref) ? child : const UnavailableScreen();
}

class _ScanCard extends StatelessWidget {
  const _ScanCard(this.scan);
  final TwinScan scan;

  @override
  Widget build(BuildContext context) => TechCard(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: scan.thumbUrl == null
                  ? _noThumb()
                  : Image.network(scan.thumbUrl!, width: 72, height: 54, fit: BoxFit.cover, errorBuilder: (_, _, _) => _noThumb()),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.titleSmall(scan.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (scan.level != null) AppText.caption(context.formatString('twin.level'.getString(context), [scan.level!])),
                ],
              ),
            ),
          ],
        ),
      );

  static Widget _noThumb() => Container(width: 72, height: 54, color: FeColors.line, child: const Icon(LucideIcons.aperture, color: FeColors.ink2));
}

// ── Report issue ────────────────────────────────────────────────────────────

/// The web Report sheet's "fault" route (ReportIssueSheet.tsx +
/// reportPayload.ts `buildReactivePayload`), without the 3D spot: a reactive
/// ticket. Snags are raised by technicians in FieldOps (walk, AI assist).
const issueTypes = ['fault', 'safety', 'cleaning', 'other'];
const _defaultTrade = {'fault': 'Mechanical', 'safety': 'Fire Safety', 'cleaning': 'General', 'other': 'General'};
const _typeLabel = {'fault': 'Fault', 'safety': 'Safety', 'cleaning': 'Cleaning', 'other': 'Other'};
const reportPriorities = ['low', 'medium', 'high', 'critical'];

String _clip(String v, int max) => v.length > max ? '${v.substring(0, max - 1)}…' : v;

/// Body for `POST /api/fm/reactive-maintenance`. CHANGE BOTH with the web's
/// `buildReactivePayload` (type = trade, subRequest = `Type: title`).
Json reactivePayload({
  required String type,
  required String title,
  required String note,
  required String priority,
  required String buildingName,
  String? buildingId,
  String? where,
  required String requestedBy,
  List<String> attachments = const [],
  bool duplicateAck = false,
}) =>
    {
      'type': _defaultTrade[type] ?? 'General',
      'subRequest': _clip('${_typeLabel[type] ?? 'Other'}${title.trim().isEmpty ? '' : ': ${title.trim()}'}', 255),
      'description': '${note.trim()}\n\n— Reported from the Fusion Eco Admin app',
      'priority': priority,
      'location': _clip([buildingName, if (where != null && where.trim().isNotEmpty) where.trim()].join(' · '), 255),
      'department': 'Facility Management',
      'requestedBy': requestedBy,
      'assetId': null,
      'attachments': attachments,
      'buildingId': ?buildingId,
      if (duplicateAck) 'duplicateAck': true,
    };

class ReportIssueScreen extends ConsumerStatefulWidget {
  const ReportIssueScreen({super.key, required this.buildings});
  final List<Json> buildings;

  @override
  ConsumerState<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends ConsumerState<ReportIssueScreen> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _where = TextEditingController();
  String _type = 'fault';
  String _priority = 'medium';
  String? _buildingId;
  PickedPhoto? _photo;
  String? _photoUrl; // uploaded once; a retry doesn't upload again
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.buildings.length == 1) _buildingId = '${widget.buildings.first['id']}';
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _where.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty && _buildingId != null;

  Future<void> _submit({bool duplicateAck = false}) async {
    if (!_valid || _busy) return;
    setState(() => (_busy = true, _error = null));
    final api = ref.read(apiClientProvider);
    final user = ref.read(authControllerProvider).user;
    final building = widget.buildings.firstWhere((b) => '${b['id']}' == _buildingId);
    final duplicateTitle = 'twin.duplicate'.getString(context);
    final sendAnyway = 'twin.send_anyway'.getString(context);
    final cancel = 'common.cancel'.getString(context);
    try {
      if (_photo != null && _photoUrl == null) _photoUrl = await api.uploadFile(_photo!.bytes, _photo!.name);
      final res = await api.post('/api/fm/reactive-maintenance', body: reactivePayload(
        type: _type,
        title: _title.text,
        note: _note.text,
        priority: _priority,
        buildingName: s(building['name']) ?? '',
        buildingId: _buildingId,
        where: _where.text,
        requestedBy: user?.name ?? user?.email ?? 'Fusion Eco Admin app',
        attachments: [?_photoUrl],
        duplicateAck: duplicateAck,
      ));
      if (!mounted) return;
      final ticket = s(dataOf(res)['ticketId']) ?? '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: AppText(context.formatString('twin.reported'.getString(context), [ticket]))));
      Navigator.of(context).pop(true);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // 409 = the server's duplicate check (a similar open ticket); the web asks, then resends with duplicateAck.
      if (e is HttpFailure && e.status == 409 && !duplicateAck) {
        final again = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: AppText(duplicateTitle),
            content: AppText(e.message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: AppText(cancel)),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: AppText(sendAnyway)),
            ],
          ),
        );
        if (again == true) await _submit(duplicateAck: true);
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FeHeader(title: 'twin.report'.getString(context)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            _label(context, 'twin.issue_type'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in issueTypes)
                  ChoiceChip(label: AppText('twin.type_$t'.getString(context)), selected: _type == t, onSelected: _busy ? null : (_) => setState(() => _type = t)),
              ],
            ),
            _label(context, 'twin.building'),
            DropdownButtonFormField<String>(
              initialValue: _buildingId,
              isExpanded: true,
              hint: AppText.body('twin.pick_building'.getString(context), color: FeColors.ink2),
              items: [for (final b in widget.buildings) DropdownMenuItem(value: '${b['id']}', child: AppText(s(b['name']) ?? '–', maxLines: 1, overflow: TextOverflow.ellipsis))],
              onChanged: _busy ? null : (v) => setState(() => _buildingId = v),
            ),
            _label(context, 'twin.title'),
            TextField(controller: _title, enabled: !_busy, maxLength: 200, onChanged: (_) => setState(() {})),
            _label(context, 'twin.where'),
            TextField(controller: _where, enabled: !_busy, decoration: InputDecoration(hintText: 'twin.where_hint'.getString(context))),
            _label(context, 'twin.note'),
            TextField(controller: _note, enabled: !_busy, minLines: 3, maxLines: 6),
            _label(context, 'twin.priority'),
            SegmentedButton<String>(
              segments: [for (final p in reportPriorities) ButtonSegment(value: p, label: FittedBox(fit: BoxFit.scaleDown, child: AppText('twin.prio_$p'.getString(context), maxLines: 1)))],
              selected: {_priority},
              showSelectedIcon: false,
              onSelectionChanged: _busy ? null : (v) => setState(() => _priority = v.first),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final p = await ref.read(photoPickerProvider)(context);
                      if (p != null && mounted) setState(() => (_photo = p, _photoUrl = null));
                    },
              icon: Icon(_photo == null ? LucideIcons.camera : LucideIcons.check, size: 16),
              label: AppText((_photo == null ? 'twin.add_photo' : 'twin.photo_added').getString(context)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              AppText.bodySmall(_error!, color: FeColors.danger),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _valid && !_busy ? _submit : null,
              child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : AppText('twin.send'.getString(context)),
            ),
            const SizedBox(height: 8),
            AppText.caption('twin.report_hint'.getString(context)),
          ],
        ),
      );

  Widget _label(BuildContext context, String key) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: AppText.caption(key.getString(context), weight: FontWeight.w700, color: FeColors.ink),
      );
}

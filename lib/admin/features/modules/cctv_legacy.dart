import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import 'module_spec.dart';

/// CCTV when the building system has no cameras: the web's legacy page
/// (client app/facility-utilities/cctv/CCTVLegacyPage.tsx inside
/// SustainSphereFallback — env "test" → `/api/proxy/v1`):
///
///   GET  energy-dashboard/all_org_tree              orgs (children of the top one)
///   GET  energy-dashboard/all_sites_by_o_id?o_id=   sites
///   GET  energy_dashboard/list_devices_by_subsite?m_device_tag_code=CCTV&o_subsite_id=0&site_id=
///   POST energy_dashboard/list_utilites_info_by_subsite_id
///        {m_device_tag_code: CCTV, device_ids, camera_ids, site_id}
///        → [{camera_id, camera_name, last_communication_time, encode_str}]
///
/// `encode_str` is a JPEG snapshot (~400 KB) and the call is slow (live
/// 2026-11-01: 20 s for two), so snapshots are asked a few cameras at a time
/// and fill in as they come. No picture = "No picture", as on the web.
const _proxy = '/api/proxy/v1';
const _batch = 3;

typedef CctvSite = ({int id, String name, int cameras});
typedef CctvCamera = ({int id, String name});

class CctvSnapshot {
  const CctvSnapshot({this.jpeg, this.polledAt});
  final Uint8List? jpeg;
  final String? polledAt;
}

List<Map> _data(Object? body) => body is Map && body['data'] is List ? (body['data'] as List).whereType<Map>().toList() : const [];

/// Every site the provider lists, with its camera count (sites without
/// cameras kept, so the picker matches the web's).
Future<List<CctvSite>> loadCctvSites(ApiClient api) async {
  final tree = _data(await api.get('$_proxy/energy-dashboard/all_org_tree'));
  if (tree.isEmpty) return const [];
  final top = tree.first;
  final orgs = top['children'] is List && (top['children'] as List).isNotEmpty ? (top['children'] as List).whereType<Map>().toList() : [top];
  final sites = <(int, String)>[];
  for (final org in orgs) {
    for (final s0 in _data(await api.get('$_proxy/energy-dashboard/all_sites_by_o_id', query: {'o_id': '${org['o_id']}'}))) {
      final id = n(s0['site_id'])?.toInt();
      if (id != null && !sites.any((x) => x.$1 == id)) sites.add((id, s(s0['site_name']) ?? 'Site $id'));
    }
  }
  final counts = await Future.wait([for (final (id, _) in sites) loadCctvCameras(api, id).then((c) => c.length).catchError((Object _) => 0)]);
  return [for (final (i, (id, name)) in sites.indexed) (id: id, name: name, cameras: counts[i])];
}

Future<List<CctvCamera>> loadCctvCameras(ApiClient api, int siteId) async => [
      for (final c in _data(await api.get('$_proxy/energy_dashboard/list_devices_by_subsite', query: {
        'm_device_tag_code': 'CCTV',
        'o_subsite_id': '0',
        'site_id': '$siteId',
      })))
        if (n(c['camera_id']) != null) (id: n(c['camera_id'])!.toInt(), name: s(c['camera_name']) ?? 'Camera ${c['camera_id']}'),
    ];

Future<Map<int, CctvSnapshot>> loadCctvSnapshots(ApiClient api, int siteId, List<int> ids) async {
  final body = await api.post('$_proxy/energy_dashboard/list_utilites_info_by_subsite_id', body: {
    'm_device_tag_code': 'CCTV',
    'device_ids': ids,
    'camera_ids': ids,
    'site_id': siteId,
  });
  final out = <int, CctvSnapshot>{};
  for (final d in _data(body)) {
    final id = n(d['camera_id'])?.toInt();
    if (id == null) continue;
    final raw = s(d['encode_str']);
    Uint8List? jpeg;
    if (raw != null) {
      try {
        jpeg = base64Decode(raw);
      } catch (_) {}
    }
    out[id] = CctvSnapshot(jpeg: jpeg, polledAt: s(d['last_communication_time']));
  }
  // Asked but not answered: no picture.
  for (final id in ids) {
    out.putIfAbsent(id, () => const CctvSnapshot());
  }
  return out;
}

class CctvLegacyView extends ConsumerStatefulWidget {
  const CctvLegacyView({super.key});

  @override
  ConsumerState<CctvLegacyView> createState() => _CctvLegacyViewState();
}

class _CctvLegacyViewState extends ConsumerState<CctvLegacyView> {
  List<CctvSite>? _sites;
  int? _siteId;
  List<CctvCamera>? _cameras;
  final Map<int, CctvSnapshot> _shots = {};
  Object? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _loadSites();
  }

  Future<void> _loadSites() async {
    try {
      final sites = await loadCctvSites(ref.read(apiClientProvider));
      if (!mounted) return;
      setState(() => _sites = sites);
      // First site with cameras (the web opens the first site, which here has none).
      final first = sites.where((x) => x.cameras > 0).firstOrNull ?? sites.firstOrNull;
      if (first != null) await _openSite(first.id);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _openSite(int id) async {
    final gen = ++_gen;
    setState(() {
      _siteId = id;
      _cameras = null;
      _shots.clear();
      _error = null;
    });
    final api = ref.read(apiClientProvider);
    try {
      final cams = await loadCctvCameras(api, id);
      if (!mounted || gen != _gen) return;
      setState(() => _cameras = cams);
      for (var i = 0; i < cams.length; i += _batch) {
        final ids = [for (final c in cams.skip(i).take(_batch)) c.id];
        final got = await loadCctvSnapshots(api, id, ids).catchError((Object _) => {for (final x in ids) x: const CctvSnapshot()});
        if (!mounted || gen != _gen) return;
        setState(() => _shots.addAll(got));
      }
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sites = _sites;
    if (sites == null && _error == null) return const Padding(padding: EdgeInsets.all(32), child: TechSpinner());
    if (_error != null && _cameras == null) {
      return TechEmptyState(
        icon: LucideIcons.circleAlert,
        title: 'cctv.load_error'.getString(context),
        subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null,
      );
    }
    final cams = _cameras;
    final online = _shots.values.where((x) => x.jpeg != null).length;
    final noPic = _shots.values.where((x) => x.jpeg == null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText.caption('cctv.legacy_note'.getString(context)),
        const SizedBox(height: 10),
        if ((sites ?? const []).length > 1)
          DropdownButtonFormField<int>(
            initialValue: _siteId,
            isExpanded: true,
            decoration: InputDecoration(labelText: 'cctv.site'.getString(context)),
            items: [
              for (final x in sites!)
                DropdownMenuItem(value: x.id, child: AppText(context.formatString('cctv.site_line'.getString(context), [x.name, x.cameras]), maxLines: 1)),
            ],
            onChanged: (v) => v == null ? null : _openSite(v),
          ),
        const SizedBox(height: 12),
        if (cams == null)
          const Padding(padding: EdgeInsets.all(32), child: TechSpinner())
        else if (cams.isEmpty)
          TechEmptyState(icon: LucideIcons.cctv, title: 'cctv.none'.getString(context))
        else ...[
          AppText.bodySmall(context.formatString('cctv.summary'.getString(context), [cams.length, online, noPic, cams.length - _shots.length])),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) {
              final w = (box.maxWidth - 10) / 2;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final c in cams) SizedBox(width: w, child: _CameraTile(camera: c, shot: _shots[c.id]))],
              );
            },
          ),
        ],
      ],
    );
  }
}

class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.camera, required this.shot});
  final CctvCamera camera;
  final CctvSnapshot? shot;

  @override
  Widget build(BuildContext context) {
    final jpeg = shot?.jpeg;
    final (label, hue) = shot == null
        ? ('cctv.checking', FeColors.ink2)
        : jpeg != null
            ? ('cctv.online', FeColors.success)
            : ('cctv.no_picture', FeColors.danger);
    return TechCard(
      padding: const EdgeInsets.all(8),
      onTap: jpeg == null
          ? null
          : () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  insetPadding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(padding: const EdgeInsets.all(12), child: AppText.titleSmall(camera.name)),
                      InteractiveViewer(maxScale: 5, child: Image.memory(jpeg)),
                      if (shot?.polledAt != null) Padding(padding: const EdgeInsets.all(10), child: AppText.caption(shot!.polledAt!)),
                    ],
                  ),
                ),
              ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: FeColors.line,
                width: double.infinity,
                child: jpeg != null
                    ? Image.memory(jpeg, fit: BoxFit.cover, gaplessPlayback: true)
                    : Center(child: shot == null ? const TechSpinner(size: 20) : const Icon(LucideIcons.videoOff, color: FeColors.ink2)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          AppText.bodySmall(camera.name, maxLines: 1, overflow: TextOverflow.ellipsis, weight: FontWeight.w600),
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: hue, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              AppText.caption(label.getString(context)),
            ],
          ),
        ],
      ),
    );
  }
}

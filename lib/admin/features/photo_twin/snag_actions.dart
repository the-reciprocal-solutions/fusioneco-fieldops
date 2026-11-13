import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../modules/chat_screen.dart' show newSessionId;
import '../modules/module_spec.dart';

/// Snag actions and detail sections, shared by the Snags module and Photo
/// Twin. The rules are the server's (services/snag/snagRules.ts; FieldOps
/// port lib/core/snag/snag_rules.dart): the phone only offers the moves the
/// status allows, and the server still has the last word (an after photo for
/// `ready`, someone else to `verify`, Admin to `waive`; its message is shown).
///
///   start   open → in-progress
///   ready   open | in-progress → ready     needs an after photo
///   verify  ready → closed                 not by whoever marked it ready (hidden for them)
///   reject  ready → open                   reason
///   reopen  closed → open                  reason
///   waive   anything not closed/waived     reason, Admin only (hidden for others)

Future<void> _transition(dynamic api, Json r, String action, {String? reason, String? afterPhoto}) => api.post('/api/snags/${r['id']}/transition', body: {
      'action': action,
      'reason': ?reason,
      if (afterPhoto != null)
        'evidence': [
          {'kind': 'photo', 'stage': 'after', 'url': afterPhoto, 'capturedAt': DateTime.now().toUtc().toIso8601String()},
        ],
    });

RecordAction _move(String label, String action, IconData icon, {bool primary = false, bool danger = false, TextAsk ask = TextAsk.none}) => RecordAction(
      label: label,
      icon: icon,
      primary: primary,
      danger: danger,
      ask: ask,
      run: (api, r, text) => _transition(api, r, action, reason: text),
    );

/// One request id per snag for "Raise work order", so a retry after a lost
/// answer links the same work order instead of creating a second one.
final _woRequestIds = <String, String>{};

List<RecordAction> snagActions(Json r) {
  final st = s(r['status']) ?? '';
  final active = st != 'closed' && st != 'waived';
  // Who asks (`_me`, from the detail screen). Unknown → offer it and let the
  // server answer, as before.
  final meId = s(at(r, '_me.id'));
  final meRole = s(at(r, '_me.role'));
  final markedReadyByMe = meId != null && s(r['readyBy']) == meId;
  final mayWaive = meRole == null || meRole == 'Admin';
  return [
    if (st == 'open') _move('act.start', 'start', LucideIcons.play, primary: true),
    if (st == 'open' || st == 'in-progress')
      RecordAction(
        label: 'act.snag_ready',
        icon: LucideIcons.camera,
        primary: st == 'in-progress',
        photoRun: (api, r, text, url) => _transition(api, r, 'ready', afterPhoto: url),
      ),
    if (st == 'ready' && !markedReadyByMe) _move('act.verify', 'verify', LucideIcons.badgeCheck, primary: true),
    if (st == 'ready') _move('act.reject', 'reject', LucideIcons.x, danger: true, ask: TextAsk.required),
    if (st == 'closed') _move('act.reopen', 'reopen', LucideIcons.rotateCcw, ask: TextAsk.required),
    RecordAction(label: 'act.comment', icon: LucideIcons.messageSquare, ask: TextAsk.required, run: (api, r, text) => api.post('/api/snags/${r['id']}/comments', body: {'note': text})),
    if (active)
      RecordAction(
        label: 'act.add_photo',
        icon: LucideIcons.imagePlus,
        photoRun: (api, r, text, url) => api.post('/api/snags/${r['id']}/evidence', body: {
          'evidence': [
            {'kind': 'photo', 'stage': 'extra', 'url': url, 'capturedAt': DateTime.now().toUtc().toIso8601String()},
          ],
        }),
      ),
    if (active && s(r['workOrderId']) == null)
      RecordAction(
        label: 'act.snag_wo',
        icon: LucideIcons.wrench,
        run: (api, r, text) => api.post('/api/snags/${r['id']}/work-order', body: {'requestId': _woRequestIds.putIfAbsent('${r['id']}', newSessionId)}),
      ),
    if (active && mayWaive) _move('act.waive', 'waive', LucideIcons.ban, danger: true, ask: TextAsk.required),
  ];
}

/// Photos (before / after / extra) and the thread, newest first.
List<Widget> snagSections(BuildContext context, Json r) {
  final photos = [for (final e in (r['evidence'] is List ? r['evidence'] as List : const [])) if (e is Map && e['kind'] != 'audio' && s(e['url']) != null) e];
  final thread = [for (final a in (r['activity'] is List ? r['activity'] as List : const [])) if (a is Map) a]
    ..sort((a, b) => '${b['at']}'.compareTo('${a['at']}'));
  return [
    if (photos.isNotEmpty) ...[
      const SizedBox(height: 16),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: AppText.caption('snag.photos'.getString(context).toUpperCase())),
      const SizedBox(height: 8),
      SizedBox(
        height: 120,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: photos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, i) => _Photo(url: s(photos[i]['url'])!, stage: s(photos[i]['stage']) ?? 'before'),
        ),
      ),
    ],
    if (thread.isNotEmpty) ...[
      const SizedBox(height: 16),
      RowGroup(
        label: 'snag.thread'.getString(context),
        dividerIndent: 16,
        rows: [
          for (final a in thread)
            ListTile(
              dense: true,
              title: AppText.body(_eventLabel(context, s(a['type']) ?? '')),
              subtitle: AppText.caption([s(a['byName']), fmtDate(a['at']), s(a['reason']), s(a['note'])].whereType<String>().join(' · ')),
            ),
        ],
      ),
    ],
  ];
}

String _eventLabel(BuildContext context, String type) {
  final key = 'snag.ev_${type.replaceAll('-', '_')}';
  final v = key.getString(context);
  // A missing key comes back as "<key> not found" (flutter_localization), not the key.
  return v == key || v.startsWith('$key ') ? chipLabel(type) : v;
}

class _Photo extends StatelessWidget {
  const _Photo({required this.url, required this.stage});
  final String url;
  final String stage;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Image.network(
              url,
              width: 120,
              height: 120,
              fit: BoxFit.cover,
              // Storage the phone can't reach (a LAN-only file server) → a tile, not a crash.
              errorBuilder: (_, _, _) => Container(width: 120, height: 120, color: FeColors.line, child: const Icon(LucideIcons.imageOff, color: FeColors.ink2)),
            ),
            PositionedDirectional(
              start: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                child: AppText.caption('snag.stage_$stage'.getString(context), color: Colors.white),
              ),
            ),
          ],
        ),
      );
}

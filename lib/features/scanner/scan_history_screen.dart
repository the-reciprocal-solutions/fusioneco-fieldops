import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router.dart';
import '../../core/scanner/scan_history.dart';
import '../../state/scan_history_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// Every scan, in full, with the past ones kept on the phone (owner,
/// 2026-10-06). Opened by tapping the scanner's session strip (which only
/// had room for about two entries) or the scanner's history button.
///
/// Offline-first: the list is the local DB, so it opens with no signal.
/// The one network action is retrying tags that waited for signal.
class ScanHistoryScreen extends ConsumerStatefulWidget {
  const ScanHistoryScreen({super.key, this.sessionSince});

  /// When opened from a scanner session: scans at or after this moment are
  /// listed first under "This session".
  final DateTime? sessionSince;

  @override
  ConsumerState<ScanHistoryScreen> createState() => _ScanHistoryScreenState();
}

class _ScanHistoryScreenState extends ConsumerState<ScanHistoryScreen> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() async {
      if (!mounted) return;
      final c = ref.read(scansProvider.notifier);
      await c.load();
      // Anything that waited for signal gets one quiet try on open.
      if (mounted && ref.read(scansProvider).waiting > 0) unawaited(c.retryWaiting());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: AppText(text)));
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: AppText('scans.clear_title'.getString(dialogContext)),
        content: AppText('scans.clear_body'.getString(dialogContext)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: AppText('common.cancel'.getString(dialogContext)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: AppText('scans.clear_confirm'.getString(dialogContext), color: FeColors.danger),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(scansProvider.notifier).clear();
  }

  Future<void> _retryAll() async {
    final settled = await ref.read(scansProvider.notifier).retryWaiting();
    if (!mounted) return;
    if (settled == 0) _toast('scans.still_no_signal'.getString(context));
  }

  /// A tap goes where the scan pointed: the asset, the board, the permit,
  /// the work order, the web page. A tag still waiting for signal is tried
  /// again first. Plain text is copied.
  Future<void> _open(ScanRecord r) async {
    var rec = r;
    if (rec.status == ScanStatus.waiting) {
      final next = await ref.read(scansProvider.notifier).retryOne(rec);
      if (!mounted) return;
      if (next == null) {
        _toast('scans.still_no_signal'.getString(context));
        return;
      }
      rec = next;
    }
    if (!mounted) return;
    final assetId = rec.assetId;
    if (rec.kind == ScanKind.c2oAsset) {
      if (assetId != null && rec.status != ScanStatus.failed) context.push(Routes.assetDetail(assetId));
      return;
    }
    if (rec.kind == ScanKind.text) {
      await Clipboard.setData(ClipboardData(text: rec.raw));
      if (mounted) _toast('scans.copied'.getString(context));
      return;
    }
    final target = rec.target;
    if (target == null || target.isEmpty) return;
    if (rec.kind == ScanKind.link) {
      final uri = Uri.tryParse(target);
      if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (target.startsWith('http')) {
      context.push(Routes.webPage(target, title: rec.title ?? rec.code));
      return;
    }
    context.push(target);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(scansProvider);
    final c = ref.read(scansProvider.notifier);
    final visible = s.visible;
    final since = widget.sessionSince;

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: 'scans.title'.getString(context),
        actions: [
          IconButton(
            tooltip: 'scans.clear'.getString(context),
            icon: const Icon(LucideIcons.trash2, size: 20),
            onPressed: s.records.isEmpty ? null : _confirmClear,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await c.load();
          await c.retryWaiting();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            TextField(
              controller: _search,
              onChanged: c.setQuery,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(LucideIcons.search, size: 18),
                hintText: 'scans.search_hint'.getString(context),
                isDense: true,
                suffixIcon: s.query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'common.clear'.getString(context),
                        icon: const Icon(LucideIcons.x, size: 16),
                        onPressed: () {
                          _search.clear();
                          c.setQuery('');
                        },
                      ),
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in ScanFilter.values) ...[
                    ChoiceChip(
                      label: AppText.label('scans.filter_${f.name}'.getString(context)),
                      selected: s.filter == f,
                      onSelected: (_) => c.setFilter(f),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            _Summary(state: s, onRetry: _retryAll),
            const SizedBox(height: 8),
            if (s.loading)
              const Padding(padding: EdgeInsets.all(32), child: TechSpinner())
            else if (s.records.isEmpty)
              TechEmptyState(
                icon: LucideIcons.scanLine,
                title: 'scans.empty_title'.getString(context),
                subtitle: 'scans.empty_body'.getString(context),
              )
            else if (visible.isEmpty)
              TechEmptyState(icon: LucideIcons.searchX, title: 'scans.no_match'.getString(context))
            else
              ..._grouped(context, visible, since),
            if (s.records.isNotEmpty) ...[
              const SizedBox(height: 16),
              AppText.caption(
                context.formatString('scans.kept_note'.getString(context), [
                  '${ScanHistoryPolicy.maxAge.inDays}',
                  '${ScanHistoryPolicy.maxEntries}',
                ]),
                align: TextAlign.center,
                color: FeColors.ink2,
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _grouped(BuildContext context, List<ScanRecord> rows, DateTime? since) {
    final out = <Widget>[];
    String? current;
    final now = DateTime.now();
    for (final r in rows) {
      final group = since != null && !r.at.isBefore(since) ? 'scans.this_session'.getString(context) : _dayLabel(context, r.at, now);
      if (group != current) {
        current = group;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: AppText.label(group.toUpperCase(), color: FeColors.ink2, weight: FontWeight.w700),
        ));
      }
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ScanRow(record: r, onTap: () => _open(r)),
      ));
    }
    return out;
  }

  static String _dayLabel(BuildContext context, DateTime at, DateTime now) {
    final d = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'scans.today'.getString(context);
    if (diff == 1) return 'scans.yesterday'.getString(context);
    return DateFormat('d MMM yyyy').format(at);
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.state, required this.onRetry});

  final ScansState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.loading || state.records.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: AppText.caption(
            [
              context.formatString('scans.count'.getString(context), ['${state.records.length}']),
              if (state.waiting > 0) context.formatString('scans.waiting_count'.getString(context), ['${state.waiting}']),
            ].join(' · '),
            color: FeColors.ink2,
          ),
        ),
        if (state.waiting > 0)
          state.retrying
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(LucideIcons.refreshCw, size: 14),
                  label: AppText.label('scans.retry_waiting'.getString(context), color: FeColors.primary),
                ),
      ],
    );
  }
}

/// One scan: what it was, its name when known, where, when, and where it
/// stands — with the plain reason when it went wrong.
class ScanRow extends StatelessWidget {
  const ScanRow({super.key, required this.record, required this.onTap});

  final ScanRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final (icon, kindKey) = switch (r.kind) {
      ScanKind.c2oAsset || ScanKind.asset => (LucideIcons.tag, 'scans.kind_asset'),
      ScanKind.workOrder => (LucideIcons.clipboardList, 'scans.kind_work_order'),
      ScanKind.material => (LucideIcons.package, 'scans.kind_material'),
      ScanKind.record => (LucideIcons.fileText, 'scans.kind_record'),
      ScanKind.marker => (LucideIcons.scanQrCode, 'scans.kind_marker'),
      ScanKind.permit => (LucideIcons.fileCheck, 'scans.kind_permit'),
      ScanKind.link => (LucideIcons.link, 'scans.kind_link'),
      ScanKind.text => (LucideIcons.type, 'scans.kind_text'),
    };
    final (color, statusKey) = switch (r.status) {
      ScanStatus.found => (FeColors.success, 'scans.status_found'),
      ScanStatus.foundOffline => (FeColors.primary, 'scans.status_found_offline'),
      ScanStatus.waiting => (FeColors.warning, 'scans.status_waiting'),
      ScanStatus.failed => (FeColors.danger, 'scans.status_failed'),
      ScanStatus.opened => (FeColors.ink2, 'scans.status_opened'),
    };
    final title = r.title ?? r.code;
    final sub = [
      kindKey.getString(context),
      if (r.title != null) r.code,
      ?r.place,
    ].join(' · ');

    return TechCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium(title, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                AppText.caption(sub, color: FeColors.ink2, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (r.reasonKey != null && r.status != ScanStatus.found && r.status != ScanStatus.foundOffline) ...[
                  const SizedBox(height: 4),
                  AppText.caption(r.reasonKey!.getString(context), color: color, maxLines: 3),
                ],
                if (r.offRoute) ...[
                  const SizedBox(height: 4),
                  AppText.caption('scans.off_route'.getString(context), color: FeColors.warning),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AppText.caption(DateFormat('HH:mm').format(r.at), color: FeColors.ink2),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: AppText.caption(statusKey.getString(context), color: color, weight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

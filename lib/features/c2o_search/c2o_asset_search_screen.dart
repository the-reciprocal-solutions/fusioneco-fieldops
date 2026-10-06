import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/c2o/assigned_assets.dart';
import '../../core/c2o/c2o_asset_search.dart';
import '../../core/network/api_exception.dart';
import '../../core/offline/offline_db.dart';
import '../../state/auth_controller.dart';
import '../../state/orders_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/fe_header.dart';

/// FR-1.6 — the fallback when there is no tag to scan at all: search by
/// Asset ID, serial, or room over the assets assigned to this technician
/// today, unioned with whatever FR-1.1 has already resolved into the scan
/// cache (that copy wins on overlap — it's the verified one). The assignment
/// half goes through `OrdersRepository`, which is itself offline-first
/// (serves its own cache when there's no signal), so this still works with
/// the radio off exactly like the scan cache lookup — it just also covers
/// assets nobody has pointed a camera at yet.
///
/// Also the FR-1.7 entry point: since a manually found asset is by
/// definition one whose tag couldn't be scanned, this is where "tag
/// missing/unreadable" gets reported as a structured outcome instead of a
/// notes field nobody can count.
class C2oAssetSearchScreen extends ConsumerStatefulWidget {
  const C2oAssetSearchScreen({super.key});

  @override
  ConsumerState<C2oAssetSearchScreen> createState() => _C2oAssetSearchScreenState();
}

class _C2oAssetSearchScreenState extends ConsumerState<C2oAssetSearchScreen> {
  final _query = TextEditingController();
  List<CachedC2oAsset>? _route;
  var _queryText = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scanned = await ref.read(offlineDbProvider).listC2oAssets();

    var assigned = const <CachedC2oAsset>[];
    final session = ref.read(authControllerProvider).session;
    if (session != null && session.userId.isNotEmpty) {
      try {
        final page = await ref.read(ordersRepositoryProvider).listAll(session.userId);
        assigned = assignedAssetsFrom(page.records);
      } catch (_) {
        // Best-effort enrichment — the scan cache alone still works offline;
        // this only ever adds to it, never replaces it.
      }
    }

    // Scanned/verified data wins over the thinner assignment view when the
    // same asset shows up in both.
    final byId = <String, CachedC2oAsset>{
      for (final a in assigned) a.assetId: a,
      for (final a in scanned) a.assetId: a,
    };
    if (mounted) setState(() => _route = byId.values.toList());
  }

  Future<void> _showDetail(CachedC2oAsset cached) async {
    final outcome = await showModalBottomSheet<_TagReportOutcome>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AssetDetailSheet(cached: cached),
    );
    if (outcome == null || !mounted) return;
    final key = switch (outcome) {
      _TagReportOutcome.sent => 'search.tag_issue_reported',
      _TagReportOutcome.queued => 'search.tag_issue_queued',
      _TagReportOutcome.rejected => 'search.tag_issue_rejected',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: AppText(key.getString(context))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = _route;
    final results = route == null ? null : searchCachedAssets(route, _queryText);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(showBack: true, title: 'search.title'.getString(context)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _query,
                autofocus: true,
                onChanged: (value) => setState(() => _queryText = value),
                decoration: InputDecoration(
                  hintText: 'search.hint'.getString(context),
                  prefixIcon: const Icon(LucideIcons.search, size: 18),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: route == null
                  ? const Center(child: CircularProgressIndicator())
                  : route.isEmpty
                      ? _EmptyState(message: 'search.no_route'.getString(context))
                      : (results?.isEmpty ?? false)
                          ? _EmptyState(
                              message: context.formatString(
                                'search.no_matches'.getString(context),
                                [_queryText],
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: results!.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final cached = results[index];
                                final asset = cached.claims['asset'];
                                final name = asset is Map ? asset['assetName']?.toString() : null;
                                final space = asset is Map ? asset['space']?.toString() : null;
                                return ListTile(
                                  title: AppText(name ?? cached.assetReferenceId ?? cached.assetId),
                                  subtitle: AppText.caption(
                                    [cached.assetReferenceId, space].where((v) => v != null && v.isNotEmpty).join(' · '),
                                    color: FeColors.ink2,
                                  ),
                                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                                  onTap: () => _showDetail(cached),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What happened to a submitted tag report — the toast must say which.
/// "Reported" while offline (caught on device) reads as delivered when it
/// is only parked in the queue.
enum _TagReportOutcome {
  /// The server has it.
  sent,

  /// No signal — saved and queued; replays on reconnect.
  queued,

  /// The server refused it (e.g. unknown asset). Saved on the phone only.
  rejected,
}

/// The sheet content for one search result: identity block plus the FR-1.7
/// tag-issue report form. Its own [ConsumerStatefulWidget] because the
/// reason chips and note field need state that outlives individual
/// `setState` calls on the parent screen.
class _AssetDetailSheet extends ConsumerStatefulWidget {
  const _AssetDetailSheet({required this.cached});

  final CachedC2oAsset cached;

  @override
  ConsumerState<_AssetDetailSheet> createState() => _AssetDetailSheetState();
}

class _AssetDetailSheetState extends ConsumerState<_AssetDetailSheet> {
  final _note = TextEditingController();
  TagIssueReason? _reason;
  var _reportingOpen = false;
  var _submitting = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null) return;

    setState(() => _submitting = true);
    final cached = widget.cached;
    final asset = cached.claims['asset'];
    final name = asset is Map ? asset['assetName']?.toString() : null;

    final note = _note.text.trim().isEmpty ? null : _note.text.trim();

    await ref.read(offlineDbProvider).reportTagIssue(
      TagIssueReport(
        assetId: cached.assetId,
        assetReferenceId: cached.assetReferenceId,
        assetName: name,
        reason: reason,
        note: note,
        reportedAt: DateTime.now(),
      ),
    );
    // The local report above is already saved regardless. SyncClient queues
    // this offline like any other write (synced: false); a 4xx it does not
    // queue, because a retry would be refused the same way.
    _TagReportOutcome outcome;
    try {
      final write = await ref
          .read(assetTagIssueRepositoryProvider)
          .report(cached.assetId, reason: reason, note: note);
      outcome = write.synced ? _TagReportOutcome.sent : _TagReportOutcome.queued;
    } on NetworkFailure {
      outcome = _TagReportOutcome.queued;
    } on ApiFailure {
      outcome = _TagReportOutcome.rejected;
    }

    if (mounted) Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final cached = widget.cached;
    final asset = cached.claims['asset'];
    final name = asset is Map ? asset['assetName']?.toString() : null;
    final manufacturer = asset is Map ? asset['manufacturer']?.toString() : null;
    final model = asset is Map ? asset['model']?.toString() : null;
    final serial = asset is Map ? asset['serialNumber']?.toString() : null;
    final space = asset is Map ? asset['space']?.toString() : null;
    final building = asset is Map ? asset['building']?.toString() : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText.titleSmall(name ?? cached.assetReferenceId ?? cached.assetId, weight: FontWeight.w700),
            const SizedBox(height: 4),
            AppText.caption(cached.assetReferenceId ?? cached.assetId, color: FeColors.ink2),
            const SizedBox(height: 16),
            if (manufacturer != null || model != null)
              _Row(
                label: 'search.manufacturer_model'.getString(context),
                value: [manufacturer, model].where((v) => v != null && v.isNotEmpty).join(' · '),
              ),
            if (serial != null && serial.isNotEmpty)
              _Row(label: 'search.serial'.getString(context), value: serial),
            if (building != null || space != null)
              _Row(
                label: 'search.location'.getString(context),
                value: [building, space].where((v) => v != null && v.isNotEmpty).join(' — '),
              ),
            const SizedBox(height: 4),
            // FR-2 — the full identity/location/nameplate/warranty/findings
            // screen, built off the same cached scan payload this sheet
            // already has a slice of. Deliberately NOT written into the
            // offline cache here — `cached` may be a thin entry built from
            // an assigned work order (FR-1.6 scoping) rather than a real
            // scan, and the cache's merge rule prefers whatever is already
            // in it over a fresh assigned-order read, so writing a thin
            // entry there would permanently shadow better data on every
            // later search. AssetDetailScreen falls back to the same
            // assigned-orders lookup itself instead.
            TextButton.icon(
              onPressed: () => context.push(Routes.assetDetail(cached.assetId)),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              icon: const Icon(LucideIcons.fileText, size: 14),
              label: AppText('search.view_full_details'.getString(context)),
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            if (!_reportingOpen)
              OutlinedButton.icon(
                onPressed: () => setState(() => _reportingOpen = true),
                style: OutlinedButton.styleFrom(foregroundColor: FeColors.danger, side: const BorderSide(color: FeColors.danger)),
                icon: const Icon(LucideIcons.tag, size: 16),
                label: AppText('search.report_tag_issue'.getString(context)),
              )
            else ...[
              AppText.caption('search.tag_issue_prompt'.getString(context), color: FeColors.ink2),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: AppText('search.tag_missing'.getString(context)),
                    selected: _reason == TagIssueReason.missing,
                    onSelected: (_) => setState(() => _reason = TagIssueReason.missing),
                  ),
                  ChoiceChip(
                    label: AppText('search.tag_unreadable'.getString(context)),
                    selected: _reason == TagIssueReason.unreadable,
                    onSelected: (_) => setState(() => _reason = TagIssueReason.unreadable),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                  labelText: 'search.tag_issue_note'.getString(context),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _reason == null || _submitting ? null : _submit,
                  style: FilledButton.styleFrom(backgroundColor: FeColors.danger),
                  child: _submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : AppText('search.submit_report'.getString(context)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.caption(label, color: FeColors.ink2),
          AppText(value),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: AppText(message, align: TextAlign.center, style: TextStyle(color: FeColors.ink2)),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/offline/left_on_device.dart';
import '../../core/offline/mutation_labels.dart';
import '../../core/offline/sync_client.dart' show SentWrite;
import '../../core/offline/offline_db.dart';
import '../../core/utils/dates.dart';
import '../../domain/maintenance_record.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/sync_conflict_panel.dart';

/// Everything sitting in the offline queue, grouped by the order it belongs
/// to, with a "Sync all" and a per-item "Sync now". The Home screen's
/// progress card is the entry point — this is where it redirects to.
class SyncCenterScreen extends ConsumerStatefulWidget {
  const SyncCenterScreen({super.key});

  @override
  ConsumerState<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends ConsumerState<SyncCenterScreen> {
  bool _syncingAll = false;

  /// The one mutation a "Sync now" tap targeted, so only its own button
  /// shows a spinner — the other rows just go disabled like "Sync all" does.
  String? _target;

  Future<void> _syncAll() async {
    setState(() => _syncingAll = true);
    await ref.read(syncClientProvider).flushQueue();
    if (mounted) setState(() => _syncingAll = false);
  }

  Future<void> _syncOne(String mutationId) async {
    setState(() => _target = mutationId);
    await ref.read(syncClientProvider).flushQueue(stopAfterId: mutationId);
    if (mounted) setState(() => _target = null);
  }

  @override
  Widget build(BuildContext context) {
    final mutationsAsync = ref.watch(pendingMutationsProvider);
    final progress = ref.watch(syncProgressProvider);
    // Null while loading or on error: then the screen claims nothing either
    // way rather than briefly saying "nothing left" before the count lands.
    final leftOnDevice = ref.watch(leftOnDeviceProvider).valueOrNull;
    final sendingId = ref.watch(sendingMutationIdProvider);
    final recentlySent = ref.watch(recentlySentProvider);
    final busy = _syncingAll || _target != null;

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'sync.pending_sync_title'.getString(context)),
      body: RefreshIndicator(
        onRefresh: () {
          ref.invalidate(leftOnDeviceProvider);
          return ref.refresh(pendingMutationsProvider.future);
        },
        child: mutationsAsync.when(
          loading: () => const Center(child: TechSpinner()),
          error: (error, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TechEmptyState(
                icon: LucideIcons.circleAlert,
                title: 'sync.load_error_title'.getString(context),
                subtitle: 'common.pull_to_retry'.getString(context),
              ),
            ],
          ),
          data: (mutations) {
            final groups = _groupByOrder(mutations);

            return ListView(
              padding: const EdgeInsets.only(top: 16, bottom: 24),
              children: [
                const SyncConflictPanel(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppText.bodyMedium(
                          progress != null
                              ? context.formatString(
                                  'sync.syncing_progress'.getString(context),
                                  [progress.completed, progress.total],
                                )
                              : mutations.isEmpty
                              ? 'sync.nothing_waiting'.getString(context)
                              : context.formatString(
                                  (mutations.length == 1
                                          ? 'sync.items_waiting_one'
                                          : 'sync.items_waiting_other')
                                      .getString(context),
                                  [mutations.length],
                                ),
                          weight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: busy || mutations.isEmpty ? null : _syncAll,
                        child: _syncingAll
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : AppText('sync.sync_all'.getString(context)),
                      ),
                    ],
                  ),
                ),
                if (progress != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress.total == 0
                            ? null
                            : progress.completed / progress.total,
                        minHeight: 8,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                // FR-4.10 — the queue being empty is not the same as nothing
                // being left: drafts and local-only rows are unsent work too.
                if (leftOnDevice != null && leftOnDevice.isEmpty && mutations.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TechEmptyState(
                      icon: LucideIcons.cloudCheck,
                      title: 'sync.nothing_left_title'.getString(context),
                      subtitle: 'sync.nothing_left_subtitle'.getString(context),
                    ),
                  ),
                if (leftOnDevice != null && leftOnDevice.drafts.isNotEmpty)
                  _DraftsSection(drafts: leftOnDevice.drafts),
                if (leftOnDevice != null && leftOnDevice.unsentLocal > 0)
                  _LocalOnlyNote(count: leftOnDevice.unsentLocal),
                if (mutations.isNotEmpty)
                  for (final group in groups)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _GroupHeader(group: group),
                            for (final mutation in group.items)
                              _MutationRow(
                                mutation: mutation,
                                busy: busy,
                                syncing: _target == mutation.clientMutationId,
                                sending: sendingId == mutation.clientMutationId,
                                onSyncNow: () =>
                                    _syncOne(mutation.clientMutationId),
                              ),
                          ],
                        ),
                      ),
                    ),
                if (recentlySent.isNotEmpty) _SentSection(sent: recentlySent),
              ],
            );
          },
        ),
      ),
    );
  }

  List<_Group> _groupByOrder(List<PendingMutation> mutations) {
    final byKey = <String, _Group>{};
    for (final mutation in mutations) {
      byKey
          .putIfAbsent(
            mutation.groupKey,
            () => _Group(
              reference: mutation.orderReference,
              orderType: mutation.orderType,
              entityId: mutation.entityId,
            ),
          )
          .items
          .add(mutation);
    }
    return byKey.values.toList();
  }
}

class _Group {
  _Group({required this.reference, required this.orderType, this.entityId});

  final String? reference;
  final OrderType? orderType;
  final String? entityId;
  final items = <PendingMutation>[];
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});

  final _Group group;

  @override
  Widget build(BuildContext context) {
    final type = group.orderType;
    final id = group.entityId;
    final canOpen = type != null && id != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: canOpen
            ? () => context.push(Routes.orderDetail(type.slug, id))
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Icon(
                LucideIcons.clipboardList,
                size: 14,
                color: FeColors.ink2,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AppText.labelMedium(
                  group.reference ?? 'sync.other_changes'.getString(context),
                  color: FeColors.ink2,
                ),
              ),
              if (canOpen)
                const Icon(
                  LucideIcons.chevronRight,
                  size: 14,
                  color: FeColors.ink2,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MutationRow extends StatelessWidget {
  const _MutationRow({
    required this.mutation,
    required this.busy,
    required this.syncing,
    required this.sending,
    required this.onSyncNow,
  });

  final PendingMutation mutation;

  /// Any sync is running — every button but the one that started it disables.
  final bool busy;

  /// This row's own "Sync now" is the one running.
  final bool syncing;

  /// FR-4.6 — this row is the one being sent right now, whatever started
  /// the run.
  final bool sending;
  final VoidCallback onSyncNow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TechCard(
      padding: const EdgeInsets.all(12),
      radius: context.radii.card,
      borderColor: FeColors.line,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium(mutation.label, weight: FontWeight.w600),
                const SizedBox(height: 2),
                AppText.bodySmall(
                  sending
                      ? 'sync.sending_now'.getString(context)
                      : mutation.attempts > 0
                      ? context.formatString(
                          'sync.queued_retried'.getString(context),
                          [
                            formatDateTimeShort(mutation.createdAt),
                            mutation.attempts,
                          ],
                        )
                      : context.formatString(
                          'sync.queued'.getString(context),
                          [formatDateTimeShort(mutation.createdAt)],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 32,
            child: OutlinedButton(
              onPressed: busy ? null : onSyncNow,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              child: syncing || sending
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : AppText('sync.sync_now'.getString(context)),
            ),
          ),
        ],
      ),
    ),
  );
}

/// FR-4.10 — unfinished capture forms still on this phone. Tapping one
/// reopens the form, which restores the draft itself.
///
/// Discard (2026-10-08 review): the form cannot un-pick a result once
/// tapped, so a check started by mistake used to stay a draft forever and
/// "Nothing is left on this device" could never be reached without
/// submitting a check nobody meant to make.
class _DraftsSection extends ConsumerWidget {
  const _DraftsSection({required this.drafts});

  final List<DraftSummary> drafts;

  Future<void> _confirmDiscard(BuildContext context, WidgetRef ref, DraftSummary d) async {
    final name = d.assetName ?? 'sync.draft_unnamed'.getString(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: FeColors.panel,
        title: AppText('sync.draft_discard_title'.getString(context)),
        content: AppText(
          context.formatString('sync.draft_discard_body'.getString(context), [d.photoCount, name]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: AppText('common.cancel'.getString(context)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: FeColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: AppText('sync.draft_discard'.getString(context)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(offlineDbProvider).deleteDraft(d.assetId);
    // Drafts are not queue rows: tick the bus so the list and the
    // dashboard card re-read.
    ref.read(queueBusProvider).notify();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              const Icon(LucideIcons.filePen, size: 14, color: FeColors.ink2),
              const SizedBox(width: 6),
              Expanded(
                child: AppText.labelMedium(
                  'sync.drafts_title'.getString(context),
                  color: FeColors.ink2,
                ),
              ),
            ],
          ),
        ),
        for (final d in drafts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(context.radii.card),
              onTap: () => context.push(
                Routes.verifyAsset(
                  d.assetId,
                  assetName: d.assetName,
                  claimedSerial: d.claimedSerial,
                  claimedTag: d.claimedTag,
                  floorId: d.floorId,
                ),
              ),
              child: TechCard(
                padding: const EdgeInsets.all(12),
                radius: context.radii.card,
                borderColor: FeColors.line,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText.bodyMedium(
                            d.assetName ?? 'sync.draft_unnamed'.getString(context),
                            weight: FontWeight.w600,
                          ),
                          const SizedBox(height: 2),
                          AppText.bodySmall(
                            context.formatString(
                              'sync.draft_meta'.getString(context),
                              [formatDateTimeShort(d.updatedAt), d.photoCount],
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'sync.draft_discard'.getString(context),
                      icon: const Icon(LucideIcons.trash2, size: 18, color: FeColors.danger),
                      onPressed: () => _confirmDiscard(context, ref, d),
                    ),
                    const Icon(LucideIcons.chevronRight, size: 16, color: FeColors.ink2),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Snags / AR marks the server does not have yet. Informational: they are
/// opened from their own screens, and their sends are in the queue above.
class _LocalOnlyNote extends StatelessWidget {
  const _LocalOnlyNote({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    child: TechCard(
      padding: const EdgeInsets.all(12),
      radius: context.radii.card,
      borderColor: FeColors.line,
      child: Row(
        children: [
          const Icon(LucideIcons.smartphone, size: 16, color: FeColors.ink2),
          const SizedBox(width: 8),
          Expanded(
            child: AppText.bodySmall(
              context.formatString('sync.local_only_note'.getString(context), [count]),
            ),
          ),
        ],
      ),
    ),
  );
}

/// FR-4.6 — what reached the server this session, so a row that leaves the
/// queue reads as "sent" rather than just disappearing.
class _SentSection extends StatelessWidget {
  const _SentSection({required this.sent});

  final List<SentWrite> sent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: AppText.labelMedium('sync.sent_title'.getString(context), color: FeColors.ink2),
        ),
        for (final w in sent)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Icon(LucideIcons.circleCheckBig, size: 16, color: FeColors.success),
                const SizedBox(width: 8),
                Expanded(child: AppText.bodySmall(w.label, color: FeColors.ink)),
                AppText.caption(
                  context.formatString('sync.sent_at'.getString(context), [formatDateTimeShort(w.at)]),
                  color: FeColors.ink2,
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

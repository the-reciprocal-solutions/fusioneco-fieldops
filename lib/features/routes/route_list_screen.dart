import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/c2o/assigned_route.dart';
import '../../core/c2o/route_download_service.dart';
import '../../core/c2o/route_pack.dart';
import '../../core/network/api_exception.dart';
import '../../core/offline/offline_db.dart';
import '../../data/route_assignment_repository.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// FR-5.1 + FR-5.5 — Route mode's entry point. Top: routes an admin assigned
/// to this technician ("what's waiting for me"), each one tap from a size
/// check and download. Below: what's already on the device. The FAB stays
/// for an ad-hoc route someone names in person.
class RouteListScreen extends ConsumerWidget {
  const RouteListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routesAsync = ref.watch(downloadedRoutePacksProvider);
    final assignedAsync = ref.watch(assignedRoutesProvider);
    final downloaded = routesAsync.valueOrNull ?? const <DownloadedRoutePack>[];
    // A downloaded route that was assigned shows its readable name, not a uuid.
    final labels = {
      for (final a
          in assignedAsync.valueOrNull?.routes ?? const <AssignedRoute>[])
        (a.scope, a.scopeId): a.label,
    };

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'routes.title'.getString(context)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openDownloadSheet(context, ref),
        icon: const Icon(LucideIcons.download),
        label: AppText(
          'routes.download_new'.getString(context),
          color: Colors.white,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () {
          ref.invalidate(assignedRoutesProvider);
          return ref.refresh(downloadedRoutePacksProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _SectionHeader('routes.assigned_section'.getString(context)),
            ..._assignedSection(context, ref, assignedAsync, downloaded),
            const SizedBox(height: 20),
            _SectionHeader('routes.downloaded_section'.getString(context)),
            ...routesAsync.when(
              loading: () => [const Center(child: TechSpinner())],
              error: (error, _) => [
                TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: 'routes.load_error_title'.getString(context),
                  subtitle: 'common.pull_to_retry'.getString(context),
                ),
              ],
              data: (routes) => routes.isEmpty
                  ? [
                      TechEmptyState(
                        icon: LucideIcons.mapPin,
                        title: 'routes.empty_title'.getString(context),
                        subtitle: 'routes.empty_subtitle'.getString(context),
                      ),
                    ]
                  : [
                      for (final route in routes)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _RouteCard(
                            route: route,
                            label: labels[(route.scope, route.id)],
                            onDelete: () async {
                              await ref
                                  .read(routeDownloadServiceProvider)
                                  .delete(route.scope, route.id);
                              ref.read(routePacksTickProvider.notifier).state++;
                            },
                          ),
                        ),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _assignedSection(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<AssignedRoutesRead> assignedAsync,
    List<DownloadedRoutePack> downloaded,
  ) => assignedAsync.when(
    loading: () => [const Center(child: TechSpinner())],
    error: (error, _) => [
      _SectionNote(
        icon: LucideIcons.wifiOff,
        text: 'routes.assigned_load_error'.getString(context),
      ),
    ],
    data: (read) => [
      if (read.fromCache)
        _SectionNote(
          icon: LucideIcons.wifiOff,
          text: 'routes.assigned_offline_hint'.getString(context),
        ),
      if (read.routes.isEmpty)
        _SectionNote(
          icon: LucideIcons.inbox,
          text: 'routes.assigned_empty'.getString(context),
        )
      else
        for (final assigned in read.routes)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AssignedRouteCard(
              route: assigned,
              downloaded: assigned.isDownloadedIn(downloaded),
            ),
          ),
    ],
  );

  Future<void> _openDownloadSheet(BuildContext context, WidgetRef ref) async {
    final downloaded = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _DownloadRouteSheet(),
    );
    if (downloaded == true) {
      ref.read(routePacksTickProvider.notifier).state++;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: AppText.labelMedium(
      text,
      color: FeColors.ink2,
      weight: FontWeight.w700,
    ),
  );
}

class _SectionNote extends StatelessWidget {
  const _SectionNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TechCard(
      child: Row(
        children: [
          Icon(icon, size: 18, color: FeColors.ink2),
          const SizedBox(width: 10),
          Expanded(child: AppText.bodySmall(text, color: FeColors.ink2)),
        ],
      ),
    ),
  );
}

/// FR-5.5 — one route an admin assigned. Download goes size-check first
/// (FR-5.1's "size estimate before commit"), then the same download path as
/// the manual sheet. Once on the device it opens like any downloaded route.
class _AssignedRouteCard extends ConsumerStatefulWidget {
  const _AssignedRouteCard({required this.route, required this.downloaded});

  final AssignedRoute route;
  final bool downloaded;

  @override
  ConsumerState<_AssignedRouteCard> createState() => _AssignedRouteCardState();
}

class _AssignedRouteCardState extends ConsumerState<_AssignedRouteCard> {
  var _busy = false;

  Future<void> _download() async {
    final route = widget.route;
    final service = ref.read(routeDownloadServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final estimate = await service.estimate(
        scope: route.scope,
        id: route.scopeId,
        packageId: route.packageId,
        projectId: route.projectId,
      );
      if (!mounted) return;

      // NFR-4 — an assigned route has no scope picker to narrow, so a pack
      // over the device budget can't be fixed by the technician at all;
      // the only honest option here is to block and point back at the
      // admin who assigned it, not offer a "download anyway".
      if (estimate.exceedsCap) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: AppText.title(
              'routes.assigned_too_large_title'.getString(dialogContext),
            ),
            content: AppText.bodyMedium(
              dialogContext.formatString(
                'routes.assigned_too_large_message'.getString(dialogContext),
                [
                  estimate.assetCount,
                  estimate.formattedSize,
                  RoutePackEstimate.capBytes ~/ (1024 * 1024),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: AppText.label(
                  'common.ok'.getString(dialogContext),
                  color: Colors.white,
                ),
              ),
            ],
          ),
        );
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: AppText.title(
            'routes.assigned_download_title'.getString(dialogContext),
          ),
          content: AppText.bodyMedium(
            dialogContext.formatString(
              'routes.assigned_download_message'.getString(dialogContext),
              [estimate.assetCount, estimate.formattedSize],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: AppText.label('common.cancel'.getString(dialogContext)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: AppText.label(
                'routes.download'.getString(dialogContext),
                color: Colors.white,
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      await service.download(
        scope: route.scope,
        id: route.scopeId,
        packageId: route.packageId,
        projectId: route.projectId,
      );
      ref.read(routePacksTickProvider.notifier).state++;
      // The card's "N of M checked" was read when the screen opened; the
      // pack just downloaded can disagree with it (caught on device: card
      // "0 of 0" beside a freshly downloaded 2-asset pack). We're online —
      // re-read it.
      ref.invalidate(assignedRoutesProvider);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: AppText(
              'routes.assigned_downloaded_toast'.getString(context),
            ),
          ),
        );
      }
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// FR-5.8 — "I can't finish this". The technician doesn't choose who takes
  /// over; the admin does. Before asking, count this route's checks still
  /// queued on the phone — the server can't see those, so this dialog is the
  /// only place anyone gets told they exist.
  Future<void> _release() async {
    final route = widget.route;
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(offlineDbProvider);
    final pack = (await db.listRoutePacks())
        .where((p) => p.scope == route.scope && p.id == route.scopeId)
        .firstOrNull;
    final queued = queuedChecksForRoute(pack, await db.listMutations());
    if (!mounted) return;

    // null = cancelled; '' = release with no reason given.
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ReleaseRouteDialog(queuedChecks: queued),
    );
    if (note == null || !mounted) return;
    final releasedText = 'routes.released_toast'.getString(context);
    final offlineText = 'routes.release_offline'.getString(context);

    setState(() => _busy = true);
    try {
      // Best effort: push queued checks up first, so the admin's progress
      // numbers are as true as they can be when they pick the next person.
      // Returns quietly when offline; anything left keeps retrying afterwards.
      await ref.read(syncClientProvider).flushQueue();
      await ref
          .read(routeAssignmentRepositoryProvider)
          .release(route.id, note: note);
      ref.invalidate(assignedRoutesProvider);
      messenger.showSnackBar(SnackBar(content: AppText(releasedText)));
    } on NetworkFailure {
      messenger.showSnackBar(SnackBar(content: AppText(offlineText)));
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final hours = DateTime.now().difference(route.assignedAt).inHours;
    final ago = hours < 1
        ? 'routes.age_just_now'.getString(context)
        : context.formatString('routes.age_hours'.getString(context), [hours]);

    return TechCard(
      accentTop: widget.downloaded ? FeColors.success : FeColors.primary,
      onTap: widget.downloaded
          ? () => context.push(Routes.routeDetail(route.scope, route.scopeId))
          : null,
      // Title row carries the actions; the detail lines below get the full
      // card width, so a hand-off name is never squeezed to "Handed over fro…"
      // by the Download button.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText.bodyMedium(route.label, weight: FontWeight.w700),
              ),
              const SizedBox(width: 12),
              ..._actions(context),
            ],
          ),
          if (route.isHandOver) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(
                  LucideIcons.handshake,
                  size: 14,
                  color: FeColors.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: AppText.bodySmall(
                    context.formatString(
                      'routes.handed_over_from'.getString(context),
                      [route.handedOverFromName!],
                    ),
                    color: FeColors.primary,
                    weight: FontWeight.w600,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          if (route.assetCount != null && route.checkedCount != null)
            AppText.bodySmall(
              context.formatString('routes.checked_of'.getString(context), [
                route.checkedCount!,
                route.assetCount!,
              ]),
              color: FeColors.ink2,
            )
          else if (route.assetCount != null)
            AppText.bodySmall(
              context.formatString('routes.asset_count'.getString(context), [
                route.assetCount!,
              ]),
              color: FeColors.ink2,
            ),
          const SizedBox(height: 2),
          AppText.bodySmall(
            context.formatString('routes.assigned_ago'.getString(context), [
              ago,
            ]),
            color: FeColors.ink2,
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) => [
    if (widget.downloaded)
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            LucideIcons.checkCircle2,
            size: 16,
            color: FeColors.success,
          ),
          const SizedBox(width: 4),
          AppText.bodySmall(
            'routes.assigned_downloaded'.getString(context),
            color: FeColors.success,
            weight: FontWeight.w700,
          ),
        ],
      )
    else
      ElevatedButton.icon(
        onPressed: _busy ? null : _download,
        icon: _busy
            ? const SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(LucideIcons.download, size: 16),
        label: AppText(
          'routes.download'.getString(context),
          color: Colors.white,
        ),
      ),
    // A plain icon button straight into a confirm dialog. The dialog is the
    // guard against a stray gloved tap. NOT a PopupMenuButton: on the OPPO
    // test phone (Android 16) opening a popup menu makes the system inject a
    // KEYCODE_BACK, which popped the whole Routes screen instead of showing
    // the menu. Dialogs don't trigger it.
    IconButton(
      tooltip: 'routes.release'.getString(context),
      onPressed: _busy ? null : _release,
      icon: const Icon(LucideIcons.logOut, size: 20, color: FeColors.ink2),
    ),
  ];
}

/// FR-5.8 — confirm a release, with an optional reason for the admin. Pops
/// the (possibly empty) note on confirm, null on cancel.
class _ReleaseRouteDialog extends StatefulWidget {
  const _ReleaseRouteDialog({required this.queuedChecks});

  final int queuedChecks;

  @override
  State<_ReleaseRouteDialog> createState() => _ReleaseRouteDialogState();
}

class _ReleaseRouteDialogState extends State<_ReleaseRouteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: AppText.title('routes.release_title'.getString(context)),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.bodyMedium('routes.release_message'.getString(context)),
          if (widget.queuedChecks > 0) ...[
            const SizedBox(height: 12),
            TechCard(
              tint: FeColors.warning.withValues(alpha: 0.10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    LucideIcons.cloudUpload,
                    size: 18,
                    color: FeColors.warning,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppText.bodySmall(
                      widget.queuedChecks == 1
                          ? 'routes.release_queued_warning_one'.getString(
                              context,
                            )
                          : context.formatString(
                              'routes.release_queued_warning'.getString(
                                context,
                              ),
                              [widget.queuedChecks],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLength: 500,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'routes.release_note_hint'.getString(context),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: AppText.label('common.cancel'.getString(context)),
      ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: FeColors.danger),
        onPressed: () => Navigator.of(context).pop(_note.text),
        child: AppText.label(
          'routes.release_confirm'.getString(context),
          color: Colors.white,
        ),
      ),
    ],
  );
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.route, required this.onDelete, this.label});

  final DownloadedRoutePack route;
  final VoidCallback onDelete;

  /// The assignment's readable name, when this route was assigned.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final stale = RouteDownloadService.isStale(route);
    final ageHours = route.age.inHours;
    final ageLabel = ageHours < 1
        ? 'routes.age_just_now'.getString(context)
        : context.formatString('routes.age_hours'.getString(context), [
            ageHours,
          ]);

    return TechCard(
      accentTop: stale ? FeColors.warning : FeColors.primary,
      onTap: () => context.push(Routes.routeDetail(route.scope, route.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText.bodyMedium(
                  label ?? '${_scopeLabel(context, route.scope)} · ${route.id}',
                  weight: FontWeight.w700,
                ),
              ),
              IconButton(
                tooltip: 'common.remove'.getString(context),
                icon: const Icon(
                  LucideIcons.trash2,
                  size: 18,
                  color: FeColors.ink2,
                ),
                onPressed: () => _confirmDelete(context, onDelete),
              ),
            ],
          ),
          const SizedBox(height: 4),
          AppText.bodySmall(
            context.formatString('routes.asset_count'.getString(context), [
              route.assetCount,
            ]),
            color: FeColors.ink2,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                stale ? LucideIcons.triangleAlert : LucideIcons.checkCircle2,
                size: 14,
                color: stale ? FeColors.warning : FeColors.success,
              ),
              const SizedBox(width: 6),
              AppText.bodySmall(
                stale
                    ? 'routes.stale_badge'.getString(context)
                    : context.formatString(
                        'routes.downloaded_ago'.getString(context),
                        [ageLabel],
                      ),
                color: stale ? FeColors.warning : FeColors.ink2,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    VoidCallback onDelete,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: AppText('routes.remove_title'.getString(context)),
        content: AppText('common.cannot_be_undone'.getString(context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: AppText('common.cancel'.getString(context)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: AppText(
              'common.delete'.getString(context),
              color: FeColors.danger,
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) onDelete();
  }
}

String _scopeLabel(BuildContext context, RouteScope scope) => switch (scope) {
  RouteScope.package => 'routes.scope_package'.getString(context),
  RouteScope.building => 'routes.scope_building'.getString(context),
  RouteScope.level => 'routes.scope_level'.getString(context),
  RouteScope.system => 'routes.scope_system'.getString(context),
};

/// FR-5.1 — pick a scope, check the size, then commit to the download.
class _DownloadRouteSheet extends ConsumerStatefulWidget {
  const _DownloadRouteSheet();

  @override
  ConsumerState<_DownloadRouteSheet> createState() =>
      _DownloadRouteSheetState();
}

class _DownloadRouteSheetState extends ConsumerState<_DownloadRouteSheet> {
  var _scope = RouteScope.package;
  final _id = TextEditingController();
  final _packageId = TextEditingController();
  final _projectId = TextEditingController();

  RoutePackEstimate? _estimate;
  var _checking = false;
  var _downloading = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _packageId.dispose();
    _projectId.dispose();
    super.dispose();
  }

  bool get _needsAnchor => _scope != RouteScope.package;

  Future<void> _checkSize() async {
    setState(() {
      _checking = true;
      _error = null;
      _estimate = null;
    });
    try {
      final estimate = await ref
          .read(routeDownloadServiceProvider)
          .estimate(
            scope: _scope,
            id: _id.text.trim(),
            packageId: _packageId.text.trim().isEmpty
                ? null
                : _packageId.text.trim(),
            projectId: _projectId.text.trim().isEmpty
                ? null
                : _projectId.text.trim(),
          );
      if (mounted) setState(() => _estimate = estimate);
    } on ApiFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    final service = ref.read(routeDownloadServiceProvider);
    final packageId = _packageId.text.trim().isEmpty ? null : _packageId.text.trim();
    final projectId = _projectId.text.trim().isEmpty ? null : _projectId.text.trim();
    try {
      // NFR-4 — re-check size right before committing, not just whenever
      // "Check size" was last tapped. Catches skipping straight to Download
      // and catches the estimate going stale after editing scope/id/anchor.
      final estimate = await service.estimate(
        scope: _scope,
        id: _id.text.trim(),
        packageId: packageId,
        projectId: projectId,
      );
      if (mounted) setState(() => _estimate = estimate);
      if (estimate.exceedsCap) return;

      await service.download(
        scope: _scope,
        id: _id.text.trim(),
        packageId: packageId,
        projectId: projectId,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _checking || _downloading;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.title(
            'routes.download_new'.getString(context),
            weight: FontWeight.w800,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<RouteScope>(
            initialValue: _scope,
            decoration: InputDecoration(
              labelText: 'routes.scope_label'.getString(context),
            ),
            items: [
              for (final scope in RouteScope.values)
                DropdownMenuItem(
                  value: scope,
                  child: Text(_scopeLabel(context, scope)),
                ),
            ],
            onChanged: busy
                ? null
                : (value) => setState(() {
                    _scope = value ?? RouteScope.package;
                    _estimate = null;
                  }),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _id,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: 'routes.id_label'.getString(context),
            ),
          ),
          if (_needsAnchor) ...[
            const SizedBox(height: 12),
            AppText.bodySmall(
              'routes.anchor_hint'.getString(context),
              color: FeColors.ink2,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _packageId,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: 'routes.package_anchor_label'.getString(context),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _projectId,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: 'routes.project_anchor_label'.getString(context),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_error != null) ...[
            AppText.bodySmall(_error!, color: FeColors.danger),
            const SizedBox(height: 12),
          ],
          if (_estimate != null) ...[
            TechCard(
              tint: _estimate!.exceedsCap
                  ? FeColors.danger.withValues(alpha: 0.08)
                  : FeColors.primary.withValues(alpha: 0.06),
              child: AppText.bodyMedium(
                _estimate!.exceedsCap
                    ? context.formatString(
                        'routes.estimate_too_large'.getString(context),
                        [
                          _estimate!.assetCount,
                          _estimate!.formattedSize,
                          RoutePackEstimate.capBytes ~/ (1024 * 1024),
                        ],
                      )
                    : context.formatString(
                        'routes.estimate_result'.getString(context),
                        [_estimate!.assetCount, _estimate!.formattedSize],
                      ),
                weight: FontWeight.w600,
                color: _estimate!.exceedsCap ? FeColors.danger : null,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy || _id.text.trim().isEmpty
                      ? null
                      : _checkSize,
                  child: _checking
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : AppText('routes.check_size'.getString(context)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: busy || _id.text.trim().isEmpty || (_estimate?.exceedsCap ?? false)
                      ? null
                      : _download,
                  child: _downloading
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : AppText(
                          'routes.download'.getString(context),
                          color: Colors.white,
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

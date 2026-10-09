import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/c2o/route_download_service.dart';
import '../../core/c2o/route_pack.dart';
import '../../core/c2o/route_progress.dart';
import '../../core/c2o/route_walk_context.dart';
import '../../core/offline/offline_db.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// FR-5.2 (room-grouped list) + FR-5.3 (verified/outstanding/flagged
/// progress) for one downloaded route. Reads everything from local storage —
/// re-opening this screen after a force-quit (FR-5.6) shows exactly what was
/// there before, because nothing about it depends on in-memory session state.
/// The actual grouping/progress math lives in `route_progress.dart`, pure
/// and unit-tested; this file is just the read + render.
class RouteDetailScreen extends ConsumerWidget {
  const RouteDetailScreen({super.key, required this.scope, required this.id});

  final RouteScope scope;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routesAsync = ref.watch(downloadedRoutePacksProvider);
    final assetsAsync = ref.watch(_routeAssetsProvider((scope, id)));
    // Pulled out once so both the FAB and the asset-row taps below share the
    // same staleness check, instead of each re-deriving it from routesAsync.
    final route = routesAsync.valueOrNull?.where((r) => r.scope == scope && r.id == id).firstOrNull;
    final stale = route != null && RouteDownloadService.isStale(route);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: '${_scopeLabel(context, scope)} · $id'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: route == null
            ? null
            : () => stale
                ? _showStaleBlock(context, ref, route)
                : context.push(Routes.scanForRoute(scope, id)),
        icon: const Icon(LucideIcons.scanLine),
        label: AppText('routes.scan_for_route'.getString(context), color: Colors.white),
      ),
      body: routesAsync.when(
        loading: () => const Center(child: TechSpinner()),
        error: (error, _) => Center(
          child: TechEmptyState(
            icon: LucideIcons.circleAlert,
            title: 'routes.load_error_title'.getString(context),
          ),
        ),
        data: (_) {
          if (route == null) {
            return Center(
              child: TechEmptyState(
                icon: LucideIcons.mapPinOff,
                title: 'routes.not_found'.getString(context),
              ),
            );
          }

          return assetsAsync.when(
            loading: () => const Center(child: TechSpinner()),
            error: (error, _) => Center(
              child: TechEmptyState(
                icon: LucideIcons.circleAlert,
                title: 'routes.load_error_title'.getString(context),
              ),
            ),
            data: (assets) => _RouteBody(
              route: route,
              assets: assets,
              onOpenAsset: (assetId) => stale
                  ? _showStaleBlock(context, ref, route)
                  : context.push(
                      Routes.assetDetail(
                        assetId,
                        route: RouteWalkContext(scope: scope, id: id, offRoute: false),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}

/// FR-5.7 — the hardened half of staleness: `routes.stale_badge` already
/// warns, this actually stops a new check starting against a pack the plan's
/// agreed window (24h, [RouteDownloadService.isStale]'s default) has passed.
/// One tap re-downloads the same scope/id in place — `saveRoutePack` replaces
/// the existing row (same primary key), so this is a refresh, not a duplicate.
Future<void> _showStaleBlock(
  BuildContext context,
  WidgetRef ref,
  DownloadedRoutePack route,
) async {
  final refresh = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: AppText.title(
        'routes.stale_block_title'.getString(dialogContext),
      ),
      content: AppText.bodyMedium(
        'routes.stale_block_message'.getString(dialogContext),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: AppText.label('common.cancel'.getString(dialogContext)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: AppText.label(
            'routes.refresh_route'.getString(dialogContext),
            color: Colors.white,
          ),
        ),
      ],
    ),
  );
  if (refresh != true || !context.mounted) return;

  try {
    await ref.read(routeDownloadServiceProvider).download(
          scope: route.scope,
          id: route.id,
          packageId: route.packageId,
          projectId: route.projectId,
        );
    ref.read(routePacksTickProvider.notifier).state++;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText('routes.refreshed'.getString(context))),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText('routes.refresh_failed'.getString(context))),
      );
    }
  }
}

final _routeAssetsProvider =
    FutureProvider.family<List<RouteAssetRow>, (RouteScope, String)>((ref, key) async {
      final (scope, id) = key;
      ref.watch(routePacksTickProvider);
      // A submitted or synced check ticks the queue; re-read so the count
      // and the "waiting to upload" marks follow it (FR-5.3).
      ref.watch(queueChangedProvider);
      final db = ref.watch(offlineDbProvider);
      final routes = await db.listRoutePacks();
      final route = routes.where((r) => r.scope == scope && r.id == id).firstOrNull;
      if (route == null) return const [];

      final wanted = route.assetIds.toSet();
      final cached = await db.listC2oAssets();

      final rows = cached
          .where((c) => wanted.contains(c.assetId))
          .map(
            (c) => routeAssetRowFromClaims(
              assetId: c.assetId,
              assetReferenceId: c.assetReferenceId,
              claims: c.claims,
            ),
          )
          .toList();
      return applyQueuedChecks(rows, await db.listMutations());
    });

String _scopeLabel(BuildContext context, RouteScope scope) => switch (scope) {
  RouteScope.package => 'routes.scope_package'.getString(context),
  RouteScope.building => 'routes.scope_building'.getString(context),
  RouteScope.level => 'routes.scope_level'.getString(context),
  RouteScope.system => 'routes.scope_system'.getString(context),
};

class _RouteBody extends StatelessWidget {
  const _RouteBody({required this.route, required this.assets, required this.onOpenAsset});

  final DownloadedRoutePack route;
  final List<RouteAssetRow> assets;
  final void Function(String assetId) onOpenAsset;

  @override
  Widget build(BuildContext context) {
    final progress = RouteProgress.from(assets);
    final stale = RouteDownloadService.isStale(route);

    final unassignedLabel = 'routes.unassigned_room'.getString(context);
    final stops = groupRouteForWalk(assets);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if (stale)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TechCard(
              tint: FeColors.warningSoft,
              child: Row(
                children: [
                  const Icon(LucideIcons.triangleAlert, size: 18, color: FeColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppText.bodySmall(
                      'routes.stale_badge'.getString(context),
                      color: FeColors.warning,
                    ),
                  ),
                ],
              ),
            ),
          ),
        _ProgressRow(progress: progress),
        const SizedBox(height: 16),
        if (assets.isEmpty)
          TechEmptyState(
            icon: LucideIcons.mapPin,
            title: 'routes.no_assets_title'.getString(context),
          )
        else
          for (final stop in stops) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 8),
              child: AppText.bodyMedium(
                [?stop.level, stop.room ?? unassignedLabel].join(' · '),
                weight: FontWeight.w700,
                color: FeColors.ink2,
              ),
            ),
            for (final asset in stop.rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AssetRow(asset: asset, onTap: () => onOpenAsset(asset.id)),
              ),
          ],
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.progress});

  final RouteProgress progress;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _ProgressStat(
          label: 'routes.progress_verified'.getString(context),
          value: progress.verified,
          color: FeColors.success,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _ProgressStat(
          label: 'routes.progress_outstanding'.getString(context),
          value: progress.outstanding,
          color: FeColors.ink2,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _ProgressStat(
          label: 'routes.progress_flagged'.getString(context),
          value: progress.flagged,
          color: FeColors.danger,
        ),
      ),
    ],
  );
}

class _ProgressStat extends StatelessWidget {
  const _ProgressStat({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => TechCard(
    child: Column(
      children: [
        AppText.titleMedium('$value', weight: FontWeight.w800, color: color),
        const SizedBox(height: 2),
        AppText.bodySmall(
          label,
          color: FeColors.ink2,
          align: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.asset, required this.onTap});

  final RouteAssetRow asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (asset) {
      RouteAssetRow(isVerified: true) => (LucideIcons.checkCircle2, FeColors.success),
      RouteAssetRow(isFlagged: true) => (LucideIcons.circleAlert, FeColors.danger),
      _ => (LucideIcons.circle, FeColors.ink2),
    };

    return TechCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: AppText.bodyMedium(asset.name ?? asset.id, weight: FontWeight.w600),
          ),
          if (asset.queued) ...[
            const Icon(LucideIcons.cloudUpload, size: 16, color: FeColors.warning),
            const SizedBox(width: 4),
            AppText.caption('routes.queued_upload'.getString(context), color: FeColors.warning),
            const SizedBox(width: 8),
          ],
          const Icon(LucideIcons.chevronRight, size: 16, color: FeColors.ink2),
        ],
      ),
    );
  }
}

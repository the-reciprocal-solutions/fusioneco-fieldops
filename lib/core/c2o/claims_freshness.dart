import '../../data/c2o_field_verification_repository.dart';
import '../offline/offline_db.dart';
import 'route_download_service.dart';

/// FR-5.7 — "a week-old cache cannot be verified against", enforced where a
/// check actually starts (the capture screen) rather than only on the route
/// screen. The route screen's block was the only one; the dashboard's
/// Scan QR, search, the BIM viewer and AR all reached the same cached
/// claims with no age check (found in the 2026-10-08 FR-5 review).
///
/// The age is the cached claim's own `cachedAt`: a route download stamps
/// every asset it brings, and a single scan stamps the one it resolves, so
/// one rule covers both. Same window as [RouteDownloadService.isStale].
bool claimsAreStale(CachedC2oAsset cached, {DateTime? now}) =>
    (now ?? DateTime.now()).difference(cached.cachedAt) >
    RouteDownloadService.maxAge;

enum ClaimsRefreshOutcome {
  /// Fresh claims are on the phone now.
  refreshed,

  /// No signal (or the server failed) — still stale, try again later.
  failed,

  /// Neither a downloaded route nor a tag token to ask the server with (an
  /// asset cached from the tokenless general label). Only a route download
  /// can bring it back.
  noWayToRefresh,
}

/// Brings one asset's claims up to date: through the downloaded route that
/// carries it when there is one (so the route's own age resets too, and the
/// route screen stops blocking), else through the same public lookup a tag
/// scan uses.
class ClaimsRefresher {
  ClaimsRefresher({
    required C2oAssetCache cache,
    required RoutePackStore routes,
    required RouteDownloadService downloader,
    required C2oScanFetcher fetcher,
  }) : _cache = cache,
       _routes = routes,
       _downloader = downloader,
       _fetcher = fetcher;

  final C2oAssetCache _cache;
  final RoutePackStore _routes;
  final RouteDownloadService _downloader;
  final C2oScanFetcher _fetcher;

  Future<ClaimsRefreshOutcome> refresh(CachedC2oAsset cached) async {
    try {
      final packs = await _routes.listRoutePacks();
      final route = packs
          .where((p) => p.assetIds.contains(cached.assetId))
          .firstOrNull;
      if (route != null) {
        await _downloader.download(
          scope: route.scope,
          id: route.id,
          packageId: route.packageId,
          projectId: route.projectId,
        );
        // Dropped from the route server-side: the download did not touch it.
        final now = await _cache.getC2oAsset(cached.assetId);
        if (now != null && !claimsAreStale(now)) {
          return ClaimsRefreshOutcome.refreshed;
        }
      }

      final token = cached.scanToken;
      if (token == null) {
        return route == null
            ? ClaimsRefreshOutcome.noWayToRefresh
            : ClaimsRefreshOutcome.failed;
      }
      final claims = await _fetcher.fetchScanTarget(cached.assetId, token);
      await _cache.upsertC2oAsset(
        CachedC2oAsset(
          assetId: cached.assetId,
          assetReferenceId: cached.assetReferenceId,
          scanToken: token,
          claims: claims,
          cachedAt: DateTime.now(),
          packStamp: cached.packStamp,
        ),
      );
      return ClaimsRefreshOutcome.refreshed;
    } catch (_) {
      return ClaimsRefreshOutcome.failed;
    }
  }
}

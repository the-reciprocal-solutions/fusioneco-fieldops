import '../../data/route_pack_repository.dart';
import '../offline/offline_db.dart';
import 'asset_detail.dart';
import 'route_pack.dart';

/// FR-5.1 — downloads a route pack and writes it into local storage:
/// [DownloadedRoutePack] for the route's own identity/freshness, and each
/// asset upserted into the SAME cache FR-1.1's single-scan resolve already
/// writes to ([C2oAssetCache]) — so a scan during the walk answers offline
/// exactly the way it already does today, whether the asset got there one
/// at a time or in bulk.
///
/// Takes [RouteFetcher]/[C2oAssetCache]/[RoutePackStore] as interfaces
/// (same split as `C2oAssetResolver`) so this is fully testable without
/// sqflite or Dio.
class RouteDownloadService {
  RouteDownloadService({
    required RouteFetcher fetcher,
    required C2oAssetCache assetCache,
    required RoutePackStore routeStore,
    FloorPlanPrefetcher? floorPlans,
    PhotoPrefetch? photos,
  }) : _fetcher = fetcher,
       _assetCache = assetCache,
       _routeStore = routeStore,
       _floorPlans = floorPlans,
       _photos = photos;

  final RouteFetcher _fetcher;
  final C2oAssetCache _assetCache;
  final RoutePackStore _routeStore;
  final FloorPlanPrefetcher? _floorPlans;
  final PhotoPrefetch? _photos;

  /// FR-5.1's pre-download size check.
  Future<RoutePackEstimate> estimate({
    required RouteScope scope,
    required String id,
    String? packageId,
    String? projectId,
  }) async {
    final json = await _fetcher.fetchRouteEstimate(
      scope.apiValue,
      id,
      packageId: packageId,
      projectId: projectId,
    );
    return RoutePackEstimate.fromJson(json);
  }

  /// Downloads the pack and persists it — every asset upserted into the
  /// shared c2o cache (stamped with the pack's `versionTag` so it's
  /// identifiable as part of this route later), then the route's own
  /// metadata row. Returns the parsed pack for the screen to show
  /// immediately, without a re-read from disk.
  Future<RoutePack> download({
    required RouteScope scope,
    required String id,
    String? packageId,
    String? projectId,
  }) async {
    final json = await _fetcher.fetchRoutePack(
      scope.apiValue,
      id,
      packageId: packageId,
      projectId: projectId,
    );
    final pack = RoutePack.fromJson(json);

    for (final asset in pack.assets) {
      // Pass the server's last check and findings through whole — the
      // detail screen needs who/when (FR-2.6) and the list (FR-2.7), and
      // keeping only the result lost both offline (caught on device).
      final lastVerification = asset.raw['lastVerification'];
      final openFindings = asset.raw['openFindings'];
      await _assetCache.upsertC2oAsset(
        CachedC2oAsset(
          assetId: asset.id,
          assetReferenceId: asset.assetReferenceId,
          scanToken: asset.scanToken,
          // Same wrapper shape `resolveScan()` returns — `AssetDetail.fromClaims`
          // reads `claims['asset']` and doesn't care how it got there.
          claims: {
            'asset': asset.raw,
            'history': lastVerification is Map ? [lastVerification] : const [],
            'openFindings': openFindings is List ? openFindings : const [],
          },
          cachedAt: DateTime.now(),
          packStamp: pack.versionTag,
        ),
      );
    }

    await _routeStore.saveRoutePack(
      DownloadedRoutePack(
        scope: scope,
        id: id,
        asOf: pack.asOf,
        versionTag: pack.versionTag,
        assetIds: pack.assets.map((a) => a.id).toList(),
        downloadedAt: DateTime.now(),
        packageId: packageId,
        projectId: projectId,
      ),
    );

    await _prefetchFloorPlans(pack);
    await _prefetchPhotos(pack);
    return pack;
  }

  /// FR-2.1 — each asset's reference photo, for the same reason as the
  /// floor plans: the walk is offline. Best effort, one at a time; a photo
  /// that fails only shows as "not downloaded yet" on its asset.
  Future<void> _prefetchPhotos(RoutePack pack) async {
    final photos = _photos;
    if (photos == null) return;

    final urls = <String>{
      for (final asset in pack.assets)
        if (referencePhotoUrl(asset.raw['imageUrl']) case final String url) url,
    };
    for (final url in urls) {
      try {
        await photos(url);
      } catch (_) {}
    }
  }

  /// FR-2.8 — downloading a route is the technician deliberately preparing
  /// to lose signal, so the plans for the floors it touches come down now,
  /// not on first open (caught on device: a route walked offline never had
  /// a plan). Best effort: the route is already saved, and a floor that
  /// fails here only means its plan screen says "not downloaded yet".
  Future<void> _prefetchFloorPlans(RoutePack pack) async {
    final floorPlans = _floorPlans;
    if (floorPlans == null) return;

    final floorIds = <String>{
      for (final asset in pack.assets)
        if (asset.raw['floorID'] case final String id when id.isNotEmpty) id,
    };
    for (final floorId in floorIds) {
      try {
        await floorPlans.prefetch(floorId);
      } catch (_) {}
    }
  }

  Future<List<DownloadedRoutePack>> listDownloaded() => _routeStore.listRoutePacks();

  Future<void> delete(RouteScope scope, String id) =>
      _routeStore.deleteRoutePack(scope, id);

  /// FR-5.7 — a pack older than [maxAge] should be refreshed before it's
  /// relied on to verify against. No server-side enforcement of this
  /// threshold (SR-2 only gives the freshness stamp); it's a client policy,
  /// kept here rather than scattered across widgets.
  static bool isStale(DownloadedRoutePack pack, {Duration maxAge = RouteDownloadService.maxAge}) =>
      pack.age > maxAge;

  /// The agreed window: older than this, a pack (or one cached asset's
  /// claims, see `claims_freshness.dart`) must be refreshed before a check.
  static const maxAge = Duration(hours: 24);
}

/// Downloads one image to the device (FR-2.1's reference photos).
typedef PhotoPrefetch = Future<void> Function(String imageUrl);

/// Brings one floor's plan (metadata and image) onto the device so FR-2.8
/// works offline. An interface so [RouteDownloadService] stays testable
/// without the sync cache or the network.
abstract interface class FloorPlanPrefetcher {
  Future<void> prefetch(String floorId);
}

/// Narrow view of [RouteFetcher] this service needs — named separately so
/// the import doesn't force every caller through `data/route_pack_repository.dart`.
abstract interface class RouteFetcherLike {
  Future<Map<String, dynamic>> fetchRouteEstimate(
    String scope,
    String id, {
    String? packageId,
    String? projectId,
  });

  Future<Map<String, dynamic>> fetchRoutePack(
    String scope,
    String id, {
    String? packageId,
    String? projectId,
  });
}

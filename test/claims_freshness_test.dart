// FR-5.7 — found in the 2026-10-08 FR-5 review: only the route screen
// refused a pack past 24 h. The dashboard's Scan QR, search, BIM and AR all
// reached the same cached claims and could verify against a week-old copy.
// The age check now sits in the capture screen; these cover its rule and
// the refresh it offers.
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/c2o/claims_freshness.dart';
import 'package:technician_portal/core/c2o/route_download_service.dart';
import 'package:technician_portal/core/c2o/route_pack.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/data/c2o_field_verification_repository.dart';
import 'package:technician_portal/data/route_pack_repository.dart';

class _Cache implements C2oAssetCache {
  final rows = <String, CachedC2oAsset>{};

  @override
  Future<CachedC2oAsset?> getC2oAsset(String idOrReference) async => rows[idOrReference];

  @override
  Future<void> upsertC2oAsset(CachedC2oAsset asset) async => rows[asset.assetId] = asset;

  @override
  Future<List<CachedC2oAsset>> listC2oAssets() async => rows.values.toList();
}

class _Routes implements RoutePackStore {
  final saved = <DownloadedRoutePack>[];

  @override
  Future<void> saveRoutePack(DownloadedRoutePack pack) async {
    saved
      ..removeWhere((p) => p.scope == pack.scope && p.id == pack.id)
      ..add(pack);
  }

  @override
  Future<List<DownloadedRoutePack>> listRoutePacks() async => List.of(saved);

  @override
  Future<void> deleteRoutePack(RouteScope scope, String id) async {}
}

class _PackServer implements RouteFetcher {
  Map<String, dynamic>? pack;
  var calls = 0;

  @override
  Future<Map<String, dynamic>> fetchRoutePack(String scope, String id, {String? packageId, String? projectId}) async {
    calls++;
    return pack ?? (throw const NetworkFailure('offline'));
  }

  @override
  Future<Map<String, dynamic>> fetchRouteEstimate(String scope, String id, {String? packageId, String? projectId}) =>
      throw UnimplementedError();
}

class _ScanServer implements C2oScanFetcher {
  Map<String, dynamic>? claims;
  String? askedToken;

  @override
  Future<Map<String, dynamic>> fetchScanTarget(String assetId, String? token) async {
    askedToken = token;
    return claims ?? (throw const NetworkFailure('offline'));
  }
}

final _old = DateTime.now().subtract(const Duration(days: 7));

CachedC2oAsset _cached(String id, {String? token = 'tok', DateTime? at}) => CachedC2oAsset(
  assetId: id,
  scanToken: token,
  claims: {
    'asset': {'id': id, 'serialNumber': 'OLD'},
  },
  cachedAt: at ?? _old,
);

void main() {
  late _Cache cache;
  late _Routes routes;
  late _PackServer packServer;
  late _ScanServer scanServer;
  late ClaimsRefresher refresher;

  setUp(() {
    cache = _Cache();
    routes = _Routes();
    packServer = _PackServer();
    scanServer = _ScanServer();
    refresher = ClaimsRefresher(
      cache: cache,
      routes: routes,
      downloader: RouteDownloadService(fetcher: packServer, assetCache: cache, routeStore: routes),
      fetcher: scanServer,
    );
  });

  test('stale is past the same 24 h window as a route', () {
    final now = DateTime(2026, 10, 8, 12);
    expect(claimsAreStale(_cached('a', at: now.subtract(const Duration(hours: 23))), now: now), isFalse);
    expect(claimsAreStale(_cached('a', at: now.subtract(const Duration(hours: 25))), now: now), isTrue);
    expect(RouteDownloadService.maxAge, const Duration(hours: 24));
  });

  test('an asset on a downloaded route refreshes the whole route', () async {
    cache.rows['a'] = _cached('a');
    routes.saved.add(
      DownloadedRoutePack(
        scope: RouteScope.package,
        id: 'pkg',
        asOf: _old,
        versionTag: 'v1',
        assetIds: const ['a'],
        downloadedAt: _old,
      ),
    );
    packServer.pack = {
      'scope': 'package',
      'id': 'pkg',
      'asOf': DateTime.now().toIso8601String(),
      'versionTag': 'v2',
      'assets': [
        {'id': 'a', 'serialNumber': 'NEW'},
      ],
    };

    expect(await refresher.refresh(cache.rows['a']!), ClaimsRefreshOutcome.refreshed);
    expect(cache.rows['a']!.claims['asset']['serialNumber'], 'NEW');
    expect(claimsAreStale(cache.rows['a']!), isFalse);
    expect(RouteDownloadService.isStale(routes.saved.single), isFalse, reason: 'the route screen unblocks too');
    expect(scanServer.askedToken, isNull, reason: 'one download, not a second lookup');
  });

  test('an asset from a single scan refreshes through its tag token', () async {
    cache.rows['a'] = _cached('a', token: 'tok-a');
    scanServer.claims = {
      'asset': {'id': 'a', 'serialNumber': 'NEW'},
    };

    expect(await refresher.refresh(cache.rows['a']!), ClaimsRefreshOutcome.refreshed);
    expect(scanServer.askedToken, 'tok-a');
    expect(cache.rows['a']!.claims['asset']['serialNumber'], 'NEW');
    expect(cache.rows['a']!.scanToken, 'tok-a');
    expect(claimsAreStale(cache.rows['a']!), isFalse);
  });

  test('no signal leaves it stale and says so', () async {
    cache.rows['a'] = _cached('a');
    expect(await refresher.refresh(cache.rows['a']!), ClaimsRefreshOutcome.failed);
    expect(claimsAreStale(cache.rows['a']!), isTrue);
  });

  test('no route and no token has no way to refresh', () async {
    cache.rows['a'] = _cached('a', token: null);
    expect(await refresher.refresh(cache.rows['a']!), ClaimsRefreshOutcome.noWayToRefresh);
    expect(packServer.calls, 0);
  });

  test('an asset dropped from its route falls back to its token', () async {
    cache.rows['a'] = _cached('a', token: 'tok-a');
    routes.saved.add(
      DownloadedRoutePack(
        scope: RouteScope.package,
        id: 'pkg',
        asOf: _old,
        versionTag: 'v1',
        assetIds: const ['a'],
        downloadedAt: _old,
      ),
    );
    packServer.pack = {
      'scope': 'package',
      'id': 'pkg',
      'asOf': DateTime.now().toIso8601String(),
      'versionTag': 'v2',
      'assets': const [],
    };
    scanServer.claims = {
      'asset': {'id': 'a', 'serialNumber': 'NEW'},
    };

    expect(await refresher.refresh(cache.rows['a']!), ClaimsRefreshOutcome.refreshed);
    expect(scanServer.askedToken, 'tok-a');
  });
}

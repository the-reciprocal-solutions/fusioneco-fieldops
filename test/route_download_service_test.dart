import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/c2o/asset_detail.dart';
import 'package:technician_portal/core/c2o/route_download_service.dart';
import 'package:technician_portal/core/c2o/route_pack.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/data/route_pack_repository.dart';

/// In-memory stand-in for [OfflineDb]'s c2o table — same fake shape
/// `c2o_asset_resolver_test.dart` uses, no sqflite involved.
class _FakeAssetCache implements C2oAssetCache {
  final rows = <String, CachedC2oAsset>{};

  @override
  Future<CachedC2oAsset?> getC2oAsset(String idOrReference) async => rows[idOrReference];

  @override
  Future<void> upsertC2oAsset(CachedC2oAsset asset) async {
    rows[asset.assetId] = asset;
  }

  @override
  Future<List<CachedC2oAsset>> listC2oAssets() async => rows.values.toList();
}

class _FakeRouteStore implements RoutePackStore {
  final saved = <String, DownloadedRoutePack>{};
  var deleteCalls = 0;

  @override
  Future<void> saveRoutePack(DownloadedRoutePack pack) async {
    saved['${pack.scope.name}:${pack.id}'] = pack;
  }

  @override
  Future<List<DownloadedRoutePack>> listRoutePacks() async => saved.values.toList();

  @override
  Future<void> deleteRoutePack(RouteScope scope, String id) async {
    deleteCalls++;
    saved.remove('${scope.name}:$id');
  }
}

class _FakeFetcher implements RouteFetcher {
  _FakeFetcher({this.estimateAnswer, this.packAnswer});

  Map<String, dynamic>? estimateAnswer;
  Map<String, dynamic>? packAnswer;
  String? lastScope;
  String? lastId;
  String? lastPackageId;
  String? lastProjectId;

  @override
  Future<Map<String, dynamic>> fetchRouteEstimate(
    String scope,
    String id, {
    String? packageId,
    String? projectId,
  }) async {
    lastScope = scope;
    lastId = id;
    lastPackageId = packageId;
    lastProjectId = projectId;
    return estimateAnswer ?? (throw StateError('no estimate scripted'));
  }

  @override
  Future<Map<String, dynamic>> fetchRoutePack(
    String scope,
    String id, {
    String? packageId,
    String? projectId,
  }) async {
    lastScope = scope;
    lastId = id;
    lastPackageId = packageId;
    lastProjectId = projectId;
    return packAnswer ?? (throw StateError('no pack scripted'));
  }
}

class _FakeFloorPlans implements FloorPlanPrefetcher {
  _FakeFloorPlans({this.failFor = const {}});

  final Set<String> failFor;
  final requested = <String>[];

  @override
  Future<void> prefetch(String floorId) async {
    requested.add(floorId);
    if (failFor.contains(floorId)) throw StateError('no signal for $floorId');
  }
}

Map<String, dynamic> _packJson({
  String scope = 'package',
  String id = 'pkg-1',
  String versionTag = 'tag-1',
  List<Map<String, dynamic>> assets = const [],
}) => {
  'scope': scope,
  'id': id,
  'asOf': '2026-09-25T05:39:33.603Z',
  'versionTag': versionTag,
  'assetCount': assets.length,
  'assets': assets,
};

void main() {
  group('RouteDownloadService.estimate (FR-5.1)', () {
    test('passes scope/id/anchors straight through and parses the result', () async {
      final fetcher = _FakeFetcher(
        estimateAnswer: {'assetCount': 60, 'estimatedBytes': 92160},
      );
      final service = RouteDownloadService(
        fetcher: fetcher,
        assetCache: _FakeAssetCache(),
        routeStore: _FakeRouteStore(),
      );

      final estimate = await service.estimate(
        scope: RouteScope.building,
        id: 'bldg-1',
        packageId: 'pkg-1',
      );

      expect(estimate.assetCount, 60);
      expect(fetcher.lastScope, 'building');
      expect(fetcher.lastId, 'bldg-1');
      expect(fetcher.lastPackageId, 'pkg-1');
    });
  });

  group('RouteDownloadService.download (FR-5.1)', () {
    test('writes every asset into the shared c2o cache, wrapped like resolveScan()', () async {
      final assetCache = _FakeAssetCache();
      final fetcher = _FakeFetcher(
        packAnswer: _packJson(
          assets: [
            {
              'id': 'asset-1',
              'assetReferenceId': 'AST228',
              'assetName': 'Chiller',
              'scanToken': 'tok-1',
              'lastVerification': {'result': 'verified'},
            },
          ],
        ),
      );
      final service = RouteDownloadService(
        fetcher: fetcher,
        assetCache: assetCache,
        routeStore: _FakeRouteStore(),
      );

      await service.download(scope: RouteScope.package, id: 'pkg-1');

      final cached = assetCache.rows['asset-1']!;
      expect(cached.assetReferenceId, 'AST228');
      expect(cached.scanToken, 'tok-1');
      expect(cached.packStamp, 'tag-1');
      // Same wrapper shape `AssetDetail.fromClaims` expects.
      expect(cached.claims['asset'], isA<Map>());
      expect((cached.claims['asset'] as Map)['assetName'], 'Chiller');
      expect(cached.claims['history'], [
        {'result': 'verified'},
      ]);
    });

    test('keeps who and when of the last check, and the open findings, for FR-2.6/2.7 offline', () async {
      // Caught on device: the detail screen showed "Mismatch" with no name
      // or date, and never any findings, for an asset read from a pack.
      final assetCache = _FakeAssetCache();
      final fetcher = _FakeFetcher(
        packAnswer: _packJson(
          assets: [
            {
              'id': 'asset-1',
              'assetName': 'Chiller',
              'lastVerification': {
                'result': 'mismatch',
                'verifiedAt': '2026-09-25T05:40:41.326Z',
                'verifiedByName': 'Daniel Okafor',
                'discrepancies': ['serialNumber'],
              },
              'openFindingCount': 1,
              'openFindings': [
                {
                  'id': 'f-1',
                  'severity': 'error',
                  'message': 'Serial does not match the register',
                  'fixHint': 'Re-check the nameplate',
                  'ruleName': 'Field verification',
                  'createdAt': '2026-09-25T05:40:41.326Z',
                },
              ],
            },
          ],
        ),
      );
      final service = RouteDownloadService(
        fetcher: fetcher,
        assetCache: assetCache,
        routeStore: _FakeRouteStore(),
      );

      await service.download(scope: RouteScope.package, id: 'pkg-1');

      final detail = AssetDetail.fromClaims(assetCache.rows['asset-1']!.claims)!;
      expect(detail.lastCheck!.result, 'mismatch');
      expect(detail.lastCheck!.verifiedByName, 'Daniel Okafor');
      expect(detail.lastCheck!.verifiedAt, DateTime.parse('2026-09-25T05:40:41.326Z'));
      expect(detail.openFindings, hasLength(1));
      expect(detail.openFindings.single.message, 'Serial does not match the register');
    });

    test('an asset with no prior verification gets an empty history, not a null crash', () async {
      final assetCache = _FakeAssetCache();
      final fetcher = _FakeFetcher(
        packAnswer: _packJson(assets: [{'id': 'asset-1'}]),
      );
      final service = RouteDownloadService(
        fetcher: fetcher,
        assetCache: assetCache,
        routeStore: _FakeRouteStore(),
      );

      await service.download(scope: RouteScope.package, id: 'pkg-1');

      expect(assetCache.rows['asset-1']!.claims['history'], isEmpty);
    });

    test('saves the route metadata with every downloaded asset id, for later resume/progress', () async {
      final routeStore = _FakeRouteStore();
      final fetcher = _FakeFetcher(
        packAnswer: _packJson(
          scope: 'level',
          id: 'floor-3',
          versionTag: 'v-42',
          assets: [
            {'id': 'asset-1'},
            {'id': 'asset-2'},
          ],
        ),
      );
      final service = RouteDownloadService(
        fetcher: fetcher,
        assetCache: _FakeAssetCache(),
        routeStore: routeStore,
      );

      await service.download(
        scope: RouteScope.level,
        id: 'floor-3',
        packageId: 'pkg-9',
      );

      final saved = routeStore.saved['level:floor-3']!;
      expect(saved.assetIds, ['asset-1', 'asset-2']);
      expect(saved.versionTag, 'v-42');
      expect(saved.packageId, 'pkg-9');
    });

    test('a scope requiring an anchor still reaches the fetcher with it attached', () async {
      final fetcher = _FakeFetcher(packAnswer: _packJson(scope: 'system', id: 'HVAC'));
      final service = RouteDownloadService(
        fetcher: fetcher,
        assetCache: _FakeAssetCache(),
        routeStore: _FakeRouteStore(),
      );

      await service.download(
        scope: RouteScope.system,
        id: 'HVAC',
        projectId: 'proj-1',
      );

      expect(fetcher.lastScope, 'system');
      expect(fetcher.lastProjectId, 'proj-1');
    });
  });

  group('RouteDownloadService.download — floor plans (FR-2.8)', () {
    // Caught on device: a route walked offline never had a floor plan,
    // because plans were only ever fetched when opened online.
    test('prefetches each floor the route touches, once', () async {
      final floorPlans = _FakeFloorPlans();
      final service = RouteDownloadService(
        fetcher: _FakeFetcher(
          packAnswer: _packJson(
            assets: [
              {'id': 'a1', 'floorID': 'floor-1'},
              {'id': 'a2', 'floorID': 'floor-1'},
              {'id': 'a3', 'floorID': 'floor-2'},
              {'id': 'a4'},
              {'id': 'a5', 'floorID': ''},
            ],
          ),
        ),
        assetCache: _FakeAssetCache(),
        routeStore: _FakeRouteStore(),
        floorPlans: floorPlans,
      );

      await service.download(scope: RouteScope.package, id: 'pkg-1');

      expect(floorPlans.requested, unorderedEquals(['floor-1', 'floor-2']));
    });

    test('a floor that fails to prefetch does not fail the route download', () async {
      final routeStore = _FakeRouteStore();
      final floorPlans = _FakeFloorPlans(failFor: {'floor-1'});
      final service = RouteDownloadService(
        fetcher: _FakeFetcher(
          packAnswer: _packJson(
            assets: [
              {'id': 'a1', 'floorID': 'floor-1'},
              {'id': 'a2', 'floorID': 'floor-2'},
            ],
          ),
        ),
        assetCache: _FakeAssetCache(),
        routeStore: routeStore,
        floorPlans: floorPlans,
      );

      await service.download(scope: RouteScope.package, id: 'pkg-1');

      expect(routeStore.saved, hasLength(1));
      expect(floorPlans.requested, unorderedEquals(['floor-1', 'floor-2']));
    });
  });

  // FR-2.1 — the reference photo was only ever there online; a route is
  // walked offline, so its photos come down with it.
  group('RouteDownloadService.download — reference photos (FR-2.1)', () {
    test('fetches each real photo link once, skipping junk, and survives a failure', () async {
      final fetched = <String>[];
      final routeStore = _FakeRouteStore();
      final service = RouteDownloadService(
        fetcher: _FakeFetcher(
          packAnswer: _packJson(
            assets: [
              {'id': 'a1', 'imageUrl': 'https://files/a.jpg'},
              {'id': 'a2', 'imageUrl': 'https://files/a.jpg'},
              {'id': 'a3', 'imageUrl': 'https://files/broken.jpg'},
              {'id': 'a4', 'imageUrl': '/images/assets/seed.jpg'},
              {'id': 'a5', 'imageUrl': ''},
              {'id': 'a6'},
            ],
          ),
        ),
        assetCache: _FakeAssetCache(),
        routeStore: routeStore,
        photos: (url) async {
          fetched.add(url);
          if (url.contains('broken')) throw StateError('404');
        },
      );

      await service.download(scope: RouteScope.package, id: 'pkg-1');

      expect(fetched, unorderedEquals(['https://files/a.jpg', 'https://files/broken.jpg']));
      expect(routeStore.saved, hasLength(1), reason: 'a failed photo never fails the route');
    });

    test('referencePhotoUrl keeps only real http(s) links', () {
      expect(referencePhotoUrl(' https://files/x.jpg '), 'https://files/x.jpg');
      expect(referencePhotoUrl('http://192.168.0.1:9002/b/x.jpg'), 'http://192.168.0.1:9002/b/x.jpg');
      expect(referencePhotoUrl('/images/x.jpg'), isNull);
      expect(referencePhotoUrl('file:///etc/passwd'), isNull);
      expect(referencePhotoUrl(''), isNull);
      expect(referencePhotoUrl(42), isNull);
      expect(
        AssetDetail.fromClaims({
          'asset': {'id': 'a', 'imageUrl': '/seed/x.jpg'},
        })!.imageUrl,
        isNull,
      );
    });
  });

  group('RouteDownloadService.delete / listDownloaded', () {
    test('delete removes the route from the store', () async {
      final routeStore = _FakeRouteStore();
      final service = RouteDownloadService(
        fetcher: _FakeFetcher(),
        assetCache: _FakeAssetCache(),
        routeStore: routeStore,
      );
      await routeStore.saveRoutePack(
        DownloadedRoutePack(
          scope: RouteScope.package,
          id: 'pkg-1',
          asOf: DateTime.now(),
          versionTag: 'v1',
          assetIds: const ['asset-1'],
          downloadedAt: DateTime.now(),
        ),
      );

      await service.delete(RouteScope.package, 'pkg-1');

      expect(routeStore.deleteCalls, 1);
      expect(await service.listDownloaded(), isEmpty);
    });
  });

  group('RouteDownloadService.isStale (FR-5.7)', () {
    test('a pack under the threshold is not stale', () {
      final pack = DownloadedRoutePack(
        scope: RouteScope.package,
        id: 'pkg-1',
        asOf: DateTime.now().subtract(const Duration(hours: 2)),
        versionTag: 'v1',
        assetIds: const [],
        downloadedAt: DateTime.now(),
      );
      expect(RouteDownloadService.isStale(pack), isFalse);
    });

    test('a pack past the default 24h threshold is stale', () {
      final pack = DownloadedRoutePack(
        scope: RouteScope.package,
        id: 'pkg-1',
        asOf: DateTime.now().subtract(const Duration(hours: 25)),
        versionTag: 'v1',
        assetIds: const [],
        downloadedAt: DateTime.now(),
      );
      expect(RouteDownloadService.isStale(pack), isTrue);
    });

    test('a custom threshold overrides the default', () {
      final pack = DownloadedRoutePack(
        scope: RouteScope.package,
        id: 'pkg-1',
        asOf: DateTime.now().subtract(const Duration(hours: 2)),
        versionTag: 'v1',
        assetIds: const [],
        downloadedAt: DateTime.now(),
      );
      expect(
        RouteDownloadService.isStale(pack, maxAge: const Duration(hours: 1)),
        isTrue,
      );
    });
  });
}

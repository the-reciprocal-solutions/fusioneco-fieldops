import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/sha256.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/offline/offline_db.dart';
import 'package:technician_portal/core/offline/sync_client.dart';
import 'package:technician_portal/data/ar_repository.dart';
import 'package:technician_portal/domain/ar_models.dart';

// ------------------------------------------------------------------- fakes

typedef _Call = ({String path, Map<String, dynamic>? query, String? ifNoneMatch});

/// Scripted network: each path answers from a queue (the last answer
/// repeats). An answer is an [ArHttpResponse] or an [ApiFailure] to throw.
class _FakeTransport implements ArTransport {
  final _json = <String, List<Object>>{};
  final bytes = <String, Object>{};
  final calls = <_Call>[];
  final byteCalls = <String>[];

  void answer(String path, Object response) => _json.putIfAbsent(path, () => []).add(response);

  @override
  Future<ArHttpResponse> getJson(
    String path, {
    Map<String, dynamic>? query,
    String? ifNoneMatch,
  }) async {
    calls.add((path: path, query: query, ifNoneMatch: ifNoneMatch));
    final queue = _json[path];
    if (queue == null || queue.isEmpty) throw StateError('nothing scripted for $path');
    final r = queue.length > 1 ? queue.removeAt(0) : queue.first;
    if (r is ApiFailure) throw r;
    return r as ArHttpResponse;
  }

  @override
  Future<Uint8List> getBytes(
    String path, {
    void Function(int received, int total)? onProgress,
  }) async {
    byteCalls.add(path);
    final r = bytes[path];
    if (r is ApiFailure) throw r;
    if (r is! Uint8List) throw StateError('no bytes scripted for $path');
    onProgress?.call(r.length ~/ 2, r.length);
    return r;
  }
}

typedef _Request = ({
  String method,
  String url,
  dynamic data,
  String label,
  List<QueuedAttachment> attachments,
  String? entityType,
  String? entityId,
});

class _FakeSync implements ArSync {
  final gets = <String, Object>{};
  final requests = <_Request>[];
  Object writeAnswer = const SyncedWrite(synced: false);
  Set<String> pending = {};

  @override
  Future<SyncedRead<dynamic>> syncGet(String url, {Map<String, dynamic>? query}) async {
    final r = gets[url];
    if (r is ApiFailure) throw r;
    if (r == null) throw const NetworkFailure();
    return r as SyncedRead<dynamic>;
  }

  @override
  Future<SyncedWrite> syncRequest(
    String method,
    String url, {
    dynamic data,
    required String label,
    List<QueuedAttachment> attachments = const [],
    String? entityType,
    String? entityId,
  }) async {
    requests.add((
      method: method,
      url: url,
      data: data,
      label: label,
      attachments: attachments,
      entityType: entityType,
      entityId: entityId,
    ));
    final answer = writeAnswer;
    if (answer is ApiFailure) throw answer;
    return answer as SyncedWrite;
  }

  @override
  Future<Set<String>> pendingEntityIds(String entityType) async => pending;
}

class _MemoryPackStore implements ArPackStore {
  final manifests = <String, StoredArManifest>{};
  final tiles = <String, StoredArTile>{};
  final features = <String, Map<int, Map<String, dynamic>>>{};
  final markers = <String, (Map<String, dynamic>, bool)>{};
  final corners = <String, List<Map<String, dynamic>>>{};
  final grid = <String, List<Map<String, dynamic>>>{};
  final progress = <String, Map<String, (Map<String, dynamic>, bool)>>{};
  final prefs = <String, String>{};
  var manifestSaves = 0;

  @override
  Future<void> saveArManifest(
    StoredArManifest manifest, {
    List<Map<String, dynamic>> markers = const [],
    List<Map<String, dynamic>> corners = const [],
    List<Map<String, dynamic>> gridLines = const [],
  }) async {
    manifestSaves++;
    final floorId = manifest.scopeId;
    manifests[_key(manifest.scope, floorId)] = manifest;
    if (manifest.scope != 'floor') return; // like OfflineDb: only a floor pack owns the side tables
    this.corners[floorId] = corners;
    grid[floorId] = gridLines;
    this.markers.removeWhere((_, v) => v.$1['floorId'] == floorId && !v.$2);
    for (final m in markers) {
      this.markers[m['code'] as String] = (
        {...m, 'floorId': m['floorId'] ?? floorId, 'buildingId': m['buildingId'] ?? manifest.buildingId},
        false,
      );
    }
  }

  /// Floor packs keep the bare floor id as their key (what the older tests
  /// read); other scopes are `scope:id`.
  static String _key(String scope, String id) => scope == 'floor' ? id : '$scope:$id';

  @override
  Future<StoredArManifest?> getArManifest(String scopeId, {String scope = 'floor'}) async =>
      manifests[_key(scope, scopeId)];

  @override
  Future<List<StoredArManifest>> listArManifests() async => manifests.values.toList();

  @override
  Future<void> deleteArManifest(String scopeId, {String scope = 'floor'}) async {
    manifests.remove(_key(scope, scopeId));
    if (scope != 'floor') return;
    corners.remove(scopeId);
    grid.remove(scopeId);
    markers.removeWhere((_, v) => v.$1['floorId'] == scopeId && !v.$2);
  }

  @override
  Future<StoredArTile?> getArTile(String hash) async => tiles[hash];

  @override
  Future<List<StoredArTile>> listArTiles() async =>
      tiles.values.toList()..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));

  @override
  Future<void> upsertArTile(StoredArTile tile) async {
    tiles[tile.hash] = tile;
  }

  @override
  Future<void> touchArTiles(List<String> hashes, DateTime at) async {
    for (final h in hashes) {
      final t = tiles[h];
      if (t != null) tiles[h] = StoredArTile(hash: t.hash, path: t.path, bytes: t.bytes, lastUsedAt: at);
    }
  }

  @override
  Future<void> deleteArTiles(List<String> hashes) async {
    hashes.forEach(tiles.remove);
  }

  @override
  Future<void> upsertArFeatures(String buildId, List<Map<String, dynamic>> rows) async {
    final byId = features.putIfAbsent(buildId, () => {});
    for (final f in rows) {
      byId[f['featureId'] as int] = {...f, 'buildId': buildId};
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listArFeatures(String buildId) async =>
      (features[buildId] ?? const {}).values.toList();

  @override
  Future<List<Map<String, dynamic>>> findArFeatures({String? globalId, String? assetId}) async => [
        for (final build in features.values)
          for (final f in build.values)
            if ((globalId != null && f['globalId'] == globalId) || (assetId != null && f['assetId'] == assetId)) f,
      ];

  @override
  Future<void> upsertArMarker(Map<String, dynamic> marker, {bool localOnly = false}) async {
    markers[marker['code'] as String] = (marker, localOnly);
  }

  @override
  Future<Map<String, dynamic>?> getArMarker(String code) async => markers[code]?.$1;

  @override
  Future<List<Map<String, dynamic>>> listArMarkers({String? floorId, String? buildingId}) async => [
        for (final (m, _) in markers.values)
          if ((floorId == null || m['floorId'] == floorId) && (buildingId == null || m['buildingId'] == buildingId)) m,
      ];

  @override
  Future<void> deleteArMarker(String code) async {
    markers.remove(code);
  }

  @override
  Future<List<Map<String, dynamic>>> listArCorners(String floorId) async => corners[floorId] ?? const [];

  @override
  Future<List<Map<String, dynamic>>> listArGridLines(String floorId) async => grid[floorId] ?? const [];

  @override
  Future<void> upsertArProgress(String floorId, List<Map<String, dynamic>> rows, {required bool pending}) async {
    final floor = progress.putIfAbsent(floorId, () => {});
    for (final r in rows) {
      floor[r['globalId'] as String] = ({...r, 'pending': pending}, pending);
    }
  }

  @override
  Future<void> replaceArProgress(String floorId, List<Map<String, dynamic>> rows, {bool keepPending = true}) async {
    final floor = progress.putIfAbsent(floorId, () => {});
    floor.removeWhere((_, v) => !keepPending || !v.$2);
    for (final r in rows) {
      floor.putIfAbsent(r['globalId'] as String, () => ({...r, 'pending': false}, false));
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listArProgress(String floorId) async =>
      [for (final (r, _) in (progress[floorId] ?? const {}).values) r];

  @override
  Future<String?> getArPref(String key) async => prefs[key];

  @override
  Future<void> setArPref(String key, String? value) async {
    if (value == null) {
      prefs.remove(key);
    } else {
      prefs[key] = value;
    }
  }
}

class _MemoryTileFiles implements ArTileFiles {
  final files = <String, Uint8List>{};
  final writes = <String>[];

  @override
  Future<String> pathFor(String hash) async => '/support/ar/tiles/$hash.glb';

  @override
  Future<bool> exists(String hash) async => files.containsKey(hash);

  @override
  Future<Uint8List?> read(String hash) async => files[hash];

  @override
  Future<void> write(String hash, Uint8List bytes) async {
    writes.add(hash);
    files[hash] = bytes;
  }

  @override
  Future<void> delete(String hash) async {
    files.remove(hash);
  }

  @override
  Future<String> hashOf(Uint8List bytes) async => Sha256.hex(bytes);
}

// ------------------------------------------------------------------ data

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

final _tileNear = _bytes('tile near the board');
final _tileFar = _bytes('tile across the floor');
final _tileHave = _bytes('tile already on the phone');
final _hashNear = Sha256.hex(_tileNear);
final _hashFar = Sha256.hex(_tileFar);
final _hashHave = Sha256.hex(_tileHave);

final _tileSolid = _bytes('solid walls for the model viewer');
final _hashSolid = Sha256.hex(_tileSolid);

Map<String, dynamic> _solidTile(String hash) => {..._tile(hash, 0, 400), 'layer': 'architecture_solid'};

Map<String, dynamic> _tile(String hash, double x, int bytes) => {
      'hash': hash,
      'url': '/api/bim/ar/tiles/$hash',
      'bytes': bytes,
      'layer': 'mep',
      'bboxMin': [x, 0, 0],
      'bboxMax': [x + 8, 3, 8],
      'triangleCount': 1000,
      'buildId': 'build-7',
    };

Map<String, dynamic> _manifest({List<Map<String, dynamic>>? tiles}) => {
      'buildingId': 'bld-1',
      'floorId': 'flr-3',
      'floorName': 'Level 3',
      'builds': [
        {
          'buildId': 'build-7',
          'lineage': 'mep',
          'modelName': 'MEP',
          'version': 7,
          'coordMatrix': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
          'buildingFrame': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        },
      ],
      'tiles': tiles ??
          [
            _tile(_hashFar, 60, 300),
            _tile(_hashNear, 0, 200),
            _tile(_hashHave, 8, 100),
          ],
      'corners': [
        {'id': 'c1', 'pos': [0, 0, 0], 'faceA': [1, 0], 'faceB': [0, 1], 'angleDeg': 90, 'kind': 'inside'},
      ],
      'gridLines': [
        {'name': 'A', 'p0': [0, 0], 'p1': [0, 8]},
      ],
      'markers': [
        {
          'code': '7K3QX9R',
          'label': 'L03-M07',
          'status': 'active',
          'accuracyClass': 'feature',
          'mounting': 'wall',
          'posTile': [4, 1.5, 0],
          'normalTile': [0, 0, 1],
        },
      ],
      'etag': 'body-etag',
    };

Map<String, dynamic> _resolveJson() => {
      'marker': {
        'code': '7K3QX9R',
        'label': 'L03-M07',
        'status': 'active',
        'accuracyClass': 'feature',
        'floorId': 'flr-3',
        'buildingId': 'bld-1',
        'posTile': [4, 1.5, 0],
        'normalTile': [0, 0, 1],
      },
      'building': {'id': 'bld-1', 'name': 'Tower A'},
      'floor': {'id': 'flr-3', 'name': 'Level 3'},
      'builds': [],
      'manifest': {'url': '/api/bim/ar/manifest?scope=floor&id=flr-3&focus=7K3QX9R', 'focusBytes': 200, 'totalBytes': 600},
      'badges': [],
    };

const _manifestPath = '/api/bim/ar/manifest';

void main() {
  late _FakeTransport transport;
  late _FakeSync sync;
  late _MemoryPackStore store;
  late _MemoryTileFiles files;
  late ArRepository repo;
  var now = DateTime.utc(2026, 9, 26, 10);

  setUp(() {
    transport = _FakeTransport();
    sync = _FakeSync();
    store = _MemoryPackStore();
    files = _MemoryTileFiles();
    now = DateTime.utc(2026, 9, 26, 10);
    repo = ArRepository.withSeams(
      transport: transport,
      sync: sync,
      store: store,
      files: files,
      clock: () => now,
    );
  });

  group('fetchManifest — ETag and the explicit 304', () {
    test('first fetch stores the manifest, its ETag and the floor\'s markers/corners/grid', () async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: {'success': true, 'data': _manifest()}, etag: 'W/"m1"'));
      final m = await repo.fetchManifest('flr-3', focusCode: '7K3QX9-R');

      expect(transport.calls.single.ifNoneMatch, isNull);
      expect(transport.calls.single.query, {'scope': 'floor', 'id': 'flr-3', 'focus': '7K3QX9R'});
      expect(m.etag, 'W/"m1"', reason: 'the header wins over the body');
      expect(m.notModified, isFalse);
      expect(store.manifests['flr-3']!.etag, 'W/"m1"');
      expect(store.manifests['flr-3']!.tileHashes, hasLength(3));
      expect(store.markers['7K3QX9R']!.$1['floorId'], 'flr-3');
      expect(store.corners['flr-3'], hasLength(1));
      expect(store.grid['flr-3'], hasLength(1));
    });

    test('second fetch sends If-None-Match; a 304 returns the stored copy untouched', () async {
      transport
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(), etag: 'W/"m1"'))
        ..answer(_manifestPath, const ArHttpResponse(status: 304));
      await repo.fetchManifest('flr-3');
      now = now.add(const Duration(hours: 2));
      final again = await repo.fetchManifest('flr-3');

      expect(transport.calls.last.ifNoneMatch, 'W/"m1"');
      expect(again.notModified, isTrue);
      expect(again.tiles, hasLength(3), reason: 'a 304 must never be parsed as an empty manifest');
      expect(store.manifestSaves, 1);
      expect(store.manifests['flr-3']!.savedAt, DateTime.utc(2026, 9, 26, 10));
    });

    test('a 304 for a copy no longer held asks again without the tag', () async {
      transport
        ..answer(_manifestPath, const ArHttpResponse(status: 304))
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      final m = await repo.fetchManifest('flr-3');
      expect(transport.calls, hasLength(2));
      expect(transport.calls.last.ifNoneMatch, isNull);
      expect(m.tiles, hasLength(3));
      expect(m.etag, 'body-etag', reason: 'no header: the body etag is kept');
    });

    test('offline: the stored copy, marked fromCache', () async {
      transport
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(), etag: 'e1'))
        ..answer(_manifestPath, const NetworkFailure());
      await repo.fetchManifest('flr-3');
      final offline = await repo.fetchManifest('flr-3');
      expect(offline.fromCache, isTrue);
      expect(offline.floorName, 'Level 3');
    });

    test('offline with nothing stored: the network failure propagates', () async {
      transport.answer(_manifestPath, const NetworkFailure());
      await expectLater(repo.fetchManifest('flr-3'), throwsA(isA<NetworkFailure>()));
    });

    test('an HTTP error becomes an ArApiError with the server\'s code', () async {
      transport.answer(
        _manifestPath,
        const HttpFailure(status: 409, message: 'No build', body: {'code': 'NO_PUBLISHED_BUILD', 'message': 'No build'}),
      );
      await expectLater(
        repo.fetchManifest('flr-3'),
        throwsA(isA<ArApiError>().having((e) => e.code, 'code', ArErrorCode.noPublishedBuild)),
      );
    });
  });

  group('downloadTiles', () {
    Future<Manifest> manifest() async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      return repo.fetchManifest('flr-3');
    }

    setUp(() {
      transport.bytes['/api/bim/ar/tiles/$_hashNear'] = _tileNear;
      transport.bytes['/api/bim/ar/tiles/$_hashFar'] = _tileFar;
      transport.bytes['/api/bim/ar/tiles/$_hashHave'] = _tileHave;
    });

    test('hash diff, focus tiles first, progress reports focusReady', () async {
      final m = await manifest();
      files.files[_hashHave] = _tileHave;
      await store.upsertArTile(StoredArTile(hash: _hashHave, path: 'x', bytes: 100, lastUsedAt: now));

      final progress = <ArDownloadProgress>[];
      final result = await repo.downloadTiles(m, focusTile: const Vec3(4, 1.5, 0), onProgress: progress.add);

      expect(transport.byteCalls, ['/api/bim/ar/tiles/$_hashNear', '/api/bim/ar/tiles/$_hashFar']);
      expect(result.downloaded, 2);
      expect(result.alreadyOnDevice, 1);
      expect(result.complete, isTrue);
      expect(progress.first.focusReady, isFalse);
      expect(progress.first.bytesTotal, 500);
      final afterFocus = progress.firstWhere((p) => p.tilesDone == 1);
      expect(afterFocus.focusReady, isTrue);
      expect(progress.last.fraction, 1.0);
      expect(store.tiles.keys, containsAll([_hashNear, _hashFar, _hashHave]));
      expect(store.tiles[_hashNear]!.path, '/support/ar/tiles/$_hashNear.glb');
    });

    test('a corrupt download is counted and never written', () async {
      final m = await manifest();
      transport.bytes['/api/bim/ar/tiles/$_hashFar'] = _bytes('truncated');
      final result = await repo.downloadTiles(m);
      expect(result.hashMismatches, 1);
      expect(result.failed, [_hashFar]);
      expect(files.files.containsKey(_hashFar), isFalse);
      expect(store.tiles.containsKey(_hashFar), isFalse);
      expect(result.complete, isFalse);
    });

    test('a dropped connection stops the run; the next run resumes', () async {
      final m = await manifest();
      transport.bytes['/api/bim/ar/tiles/$_hashNear'] = const NetworkFailure();
      final first = await repo.downloadTiles(m); // manifest order: far, near, have
      expect(first.interrupted, isTrue);
      expect(first.downloaded, 1);

      transport.bytes['/api/bim/ar/tiles/$_hashNear'] = _tileNear;
      transport.byteCalls.clear();
      final second = await repo.downloadTiles(m);
      expect(transport.byteCalls, ['/api/bim/ar/tiles/$_hashNear', '/api/bim/ar/tiles/$_hashHave']);
      expect(second.alreadyOnDevice, 1);
      expect(second.complete, isTrue);
    });

    test('a file left on disk after a logout wipe is re-adopted, not re-downloaded', () async {
      final m = await manifest();
      files.files[_hashFar] = _tileFar; // no ar_tiles row
      await repo.downloadTiles(m);
      expect(transport.byteCalls, isNot(contains('/api/bim/ar/tiles/$_hashFar')));
      expect(store.tiles.containsKey(_hashFar), isTrue);
    });

    test('a hash that is not 64 hex chars never becomes a file path', () async {
      transport.answer(
        _manifestPath,
        ArHttpResponse(status: 200, body: _manifest(tiles: [_tile('../../etc/passwd', 0, 1)])),
      );
      final m = await repo.fetchManifest('flr-3');
      final result = await repo.downloadTiles(m);
      expect(result.failed, ['../../etc/passwd']);
      expect(transport.byteCalls, isEmpty);
    });

    test('tileRefs lists what is on the phone and gc keeps referenced tiles', () async {
      final m = await manifest();
      await repo.downloadTiles(m);
      await store.upsertArTile(StoredArTile(hash: 'orphan', path: 'p', bytes: 50, lastUsedAt: now));
      files.files['orphan'] = _bytes('x');

      final refs = await repo.tileRefs(m.tiles);
      expect(refs.map((r) => r.hash), m.tiles.map((t) => t.hash));

      final freed = await repo.gcTiles(all: true);
      expect(freed, 50);
      expect(store.tiles.containsKey('orphan'), isFalse);
      expect(files.files.containsKey('orphan'), isFalse);
      expect(store.tiles, hasLength(3));
    });
  });

  group('resolveMarker', () {
    test('a board on a downloaded floor resolves with no network at all', () async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      await repo.fetchManifest('flr-3');
      await store.setArPref('buildingName:bld-1', 'Tower A');
      transport.calls.clear();

      final r = await repo.resolveMarker('HTTPS://FE.EXAMPLE/M/7K3QX9-R');
      expect(transport.calls, isEmpty);
      expect(r.fromCache, isTrue);
      expect(r.packOnDevice, isTrue);
      expect(r.building.name, 'Tower A');
      expect(r.floor.name, 'Level 3');
      expect(r.marker.label, 'L03-M07');
      expect(r.totalBytes, 600);
      expect(r.focusBytes, 300, reason: 'tiles within 15 m of the board (x 0–16)');
    });

    test('online: the server decides, and the building name is remembered', () async {
      transport.answer('/api/bim/ar/markers/resolve/7K3QX9R', ArHttpResponse(status: 200, body: {'data': _resolveJson()}));
      final r = await repo.resolveMarker('7k3qx9-r');
      expect(r.building.name, 'Tower A');
      expect(r.fromCache, isFalse);
      expect(r.packOnDevice, isFalse);
      expect(store.prefs['buildingName:bld-1'], 'Tower A');
    });

    test('a retired board names the nearest active one', () async {
      transport.answer(
        '/api/bim/ar/markers/resolve/7K3QX9R',
        const HttpFailure(status: 410, message: 'Retired', body: {
          'code': 'RETIRED',
          'message': 'This board was retired on 3 Sep.',
          'nearest': {'code': 'M0R5E85', 'label': 'L03-M06', 'distanceM': 4},
        }),
      );
      await expectLater(
        repo.resolveMarker('7K3QX9R'),
        throwsA(isA<ArApiError>()
            .having((e) => e.code, 'code', ArErrorCode.retired)
            .having((e) => e.nearest?.label, 'nearest', 'L03-M06')),
      );
    });

    test('offline and not on the phone: "needs signal once"', () async {
      transport.answer('/api/bim/ar/markers/resolve/7K3QX9R', const NetworkFailure());
      await expectLater(
        repo.resolveMarker('7K3QX9R'),
        throwsA(isA<ArApiError>().having((e) => e.code, 'code', ArErrorCode.needsSignal)),
      );
    });

    test('a bad check character is not a marker, and costs no request', () async {
      await expectLater(
        repo.resolveMarker('7K3QX9-M'),
        throwsA(isA<ArApiError>().having((e) => e.code, 'code', ArErrorCode.notAMarker)),
      );
      expect(transport.calls, isEmpty);
    });
  });

  group('progress — local first, four-eyes', () {
    test('queued: rows change at once and stay pending', () async {
      final result = await repo.setProgress(
        floorId: 'flr-3',
        globalIds: ['g1', 'g2', 'g1'],
        status: ArProgressStatus.installed,
        actorId: 'foreman',
        note: 'Run 3',
      );
      expect(result.queued, isTrue);
      expect(result.updated, 2);
      final req = sync.requests.single;
      expect(req.url, '/api/bim/ar/progress');
      expect(req.entityType, kArProgressEntity);
      expect(req.entityId, 'flr-3');
      expect((req.data as Map)['globalIds'], ['g1', 'g2']);
      expect(store.progress['flr-3']!['g1']!.$2, isTrue, reason: 'pending');
      expect(store.progress['flr-3']!['g1']!.$1['installedBy'], 'foreman');
    });

    test('verifying your own install is refused before anything is queued', () async {
      await store.upsertArProgress('flr-3', [
        {'globalId': 'g1', 'status': 'installed', 'installedBy': 'me'},
      ], pending: false);
      final result = await repo.setProgress(
        floorId: 'flr-3',
        globalIds: ['g1'],
        status: ArProgressStatus.verified,
        actorId: 'me',
      );
      expect(result.updated, 0);
      expect(result.rejected.single.reason, ProgressRejectReason.secondPersonRequired);
      expect(sync.requests, isEmpty);
    });

    test('the server\'s rejections are rolled back locally', () async {
      await store.upsertArProgress('flr-3', [
        {'globalId': 'g1', 'status': 'installed', 'installedBy': 'u1'},
        {'globalId': 'g2', 'status': 'installed', 'installedBy': 'u2'},
      ], pending: false);
      sync.writeAnswer = const SyncedWrite(synced: true, data: {
        'success': true,
        'data': {
          'updated': 1,
          'rejected': [
            {'globalId': 'g2', 'reason': 'SECOND_PERSON_REQUIRED'},
          ],
        },
      });
      final result = await repo.setProgress(
        floorId: 'flr-3',
        globalIds: ['g1', 'g2'],
        status: ArProgressStatus.verified,
        actorId: 'supervisor',
      );
      expect(result.updated, 1);
      expect(result.rejected.single.globalId, 'g2');
      expect(store.progress['flr-3']!['g1']!.$1['status'], 'verified');
      expect(store.progress['flr-3']!['g1']!.$2, isFalse);
      expect(store.progress['flr-3']!['g2']!.$1['status'], 'installed');
    });

    test('a photo travels as a queued attachment, never inline', () async {
      await repo.setProgress(
        floorId: 'flr-3',
        globalIds: ['g1'],
        status: ArProgressStatus.issue,
        photo: _bytes('jpeg'),
      );
      final req = sync.requests.single;
      final placeholder = req.attachments.single.placeholder;
      expect((req.data as Map)['photoUrl'], placeholder);
      expect(placeholder, startsWith('__pending_'));
    });

    test('fetch keeps rows still in the queue, then takes the server\'s once synced', () async {
      await store.upsertArProgress('flr-3', [
        {'globalId': 'g1', 'status': 'verified'},
      ], pending: true);
      transport.answer(
        '/api/bim/ar/progress',
        const ArHttpResponse(status: 200, body: {
          'data': {
            'statuses': [
              {'globalId': 'g1', 'status': 'installed'},
              {'globalId': 'g2', 'status': 'issue'},
            ],
            'summary': {'total': 10, 'installed': 1, 'verified': 0, 'issue': 1},
          },
        }),
      );
      sync.pending = {'flr-3'};
      final ahead = await repo.fetchProgress('flr-3');
      expect(ahead.byGlobalId['g1']!.status, 'verified');
      expect(ahead.summary.total, 10);

      sync.pending = {};
      final synced = await repo.fetchProgress('flr-3');
      expect(synced.byGlobalId['g1']!.status, 'installed');
    });

    test('offline: the stored rows, with the last known total', () async {
      transport
        ..answer(
          '/api/bim/ar/progress',
          const ArHttpResponse(status: 200, body: {
            'statuses': [
              {'globalId': 'g1', 'status': 'installed'},
            ],
            'summary': {'total': 25},
          }),
        )
        ..answer('/api/bim/ar/progress', const NetworkFailure());
      await repo.fetchProgress('flr-3');
      final offline = await repo.fetchProgress('flr-3');
      expect(offline.fromCache, isTrue);
      expect(offline.summary.total, 25);
      expect(offline.summary.installed, 1);
    });
  });

  group('boards', () {
    test('a spare saved offline resolves on the next scan with no signal', () async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      await repo.fetchManifest('flr-3');

      final write = await repo.bindSpare(
        '4Q2MA7-6',
        floorId: 'flr-3',
        buildId: 'build-7',
        posTile: const Vec3(0, 1.5, 6.8),
        normalTile: const Vec3(1, 0, 0),
        sigmaM: 0.03,
        buildingId: 'bld-1',
      );
      expect(write.synced, isFalse);
      expect(write.data!.label, 'SP-4Q2M');
      expect(write.data!.accuracyClass, 'derived');
      expect(store.markers['4Q2MA76']!.$2, isTrue, reason: 'localOnly until the server confirms');
      final req = sync.requests.single;
      expect(req.url, '/api/bim/ar/spares/4Q2MA76/bind');
      expect((req.data as Map)['posTile'], [0, 1.5, 6.8]);

      transport.calls.clear();
      final r = await repo.resolveMarker('HTTPS://FE.EXAMPLE/M/4Q2MA7-6');
      expect(r.fromCache, isTrue);
      expect(r.marker.status, ArMarkerStatus.installed);
      expect(transport.calls, isEmpty);
    });

    test('a spare bound elsewhere first: the local copy is dropped and the error surfaces', () async {
      sync.writeAnswer = const HttpFailure(
        status: 409,
        message: 'Already bound',
        body: {'code': 'ALREADY_BOUND', 'message': 'This board was saved somewhere else first.'},
      );
      await expectLater(
        repo.bindSpare('4Q2MA76', floorId: 'flr-3', buildId: 'b', posTile: Vec3.zero, normalTile: const Vec3(1, 0, 0)),
        throwsA(isA<ArApiError>().having((e) => e.code, 'code', ArErrorCode.alreadyBound)),
      );
      expect(store.markers.containsKey('4Q2MA76'), isFalse);
    });

    test('confirm-install turns the stored board Installed and queues the checks with the photo', () async {
      await store.upsertArMarker({
        'code': '7K3QX9R',
        'label': 'L03-M07',
        'status': 'printed',
        'accuracyClass': 'feature',
        'floorId': 'flr-3',
      });
      final write = await repo.confirmInstall(
        '7K3QX9-R',
        buildId: 'build-7',
        checks: const {'code': true, 'scalePct': 100.2, 'positionM': 0.011, 'tiltDeg': 0.8},
        photo: _bytes('jpeg'),
      );
      expect(write.synced, isFalse);
      expect(write.data!.status, ArMarkerStatus.installed);
      expect(store.markers['7K3QX9R']!.$1['status'], ArMarkerStatus.installed);
      final req = sync.requests.single;
      expect(req.url, '/api/bim/ar/markers/7K3QX9R/confirm-install');
      expect((req.data as Map)['checks'], containsPair('positionM', 0.011));
      expect(req.attachments.single.field, 'image');
    });

    test('alignment events are batched through the queue', () async {
      final event = ArAlignmentEvent(
        buildingId: 'bld-1',
        floorId: 'flr-3',
        buildIds: const ['build-7'],
        observations: const [ArObservationSummary(kind: 'corner', ref: 'c1', residualMm: 4)],
        maxResidualMm: 4,
        method: 'positions',
        quality: 'locked',
        distanceWalkedM: 9,
        deviceTier: 'A+',
        capturedAt: now,
      );
      final write = await repo.postAlignmentEvents([event, event]);
      expect(write.synced, isFalse);
      expect(write.data, 2);
      final req = sync.requests.single;
      expect(req.url, '/api/bim/ar/alignment-events');
      expect(((req.data as Map)['events'] as List), hasLength(2));
      expect(req.entityType, kArSessionEntity);
    });
  });

  group('fetchViewerManifest — the model viewer\'s solid-wall pack', () {
    test('asks for the solid layer and stores it beside the floor pack, never over it', () async {
      transport
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(), etag: 'floor-1'))
        ..answer(
          _manifestPath,
          ArHttpResponse(
            status: 200,
            body: {
              ..._manifest(tiles: [_solidTile(_hashSolid)]),
              'corners': <Object>[],
              'gridLines': <Object>[],
              'markers': <Object>[],
            },
            etag: 'viewer-1',
          ),
        );
      await repo.fetchManifest('flr-3');
      final v = await repo.fetchViewerManifest('flr-3');

      expect(transport.calls.last.query, {'scope': 'floor', 'id': 'flr-3', 'layers': 'architecture_solid'});
      expect(v!.tiles.single.layer, 'architecture_solid');
      expect(store.manifests['viewer:flr-3']!.etag, 'viewer-1');
      expect(store.manifests['viewer:flr-3']!.tileHashes, [_hashSolid]);
      // The AR floor pack and its side tables are untouched.
      expect(store.manifests['flr-3']!.etag, 'floor-1');
      expect(store.manifests['flr-3']!.tileHashes, hasLength(3));
      expect(store.corners['flr-3'], hasLength(1));
      expect(store.markers['7K3QX9R'], isNotNull);
    });

    test('304 → the stored copy; offline → the stored copy; nothing stored offline → null', () async {
      transport
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(tiles: [_solidTile(_hashSolid)]), etag: 'v1'))
        ..answer(_manifestPath, const ArHttpResponse(status: 304))
        ..answer(_manifestPath, const NetworkFailure());
      await repo.fetchViewerManifest('flr-3');
      final again = await repo.fetchViewerManifest('flr-3');
      expect(transport.calls[1].ifNoneMatch, 'v1');
      expect(again!.notModified, isTrue);
      expect(again.tiles.single.hash, _hashSolid);
      final offline = await repo.fetchViewerManifest('flr-3');
      expect(offline!.fromCache, isTrue);
      expect(await repo.localViewerManifest('flr-3'), isNotNull);

      final other = ArRepository.withSeams(
        transport: _FakeTransport()..answer(_manifestPath, const NetworkFailure()),
        sync: sync,
        store: _MemoryPackStore(),
        files: files,
      );
      expect(await other.fetchViewerManifest('flr-3'), isNull);
    });

    test('a server from before the solid layer (400 BAD_LAYERS) is not an error: null', () async {
      transport.answer(
        _manifestPath,
        const HttpFailure(status: 400, message: 'bad', body: {'code': 'BAD_LAYERS', 'message': 'bad'}),
      );
      expect(await repo.fetchViewerManifest('flr-3'), isNull);
    });

    test('tile GC keeps the viewer pack\'s tiles; deleting the floor pack drops both', () async {
      transport
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(tiles: [_tile(_hashNear, 0, 200)])))
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(tiles: [_solidTile(_hashSolid)])));
      final floor = await repo.fetchManifest('flr-3');
      final viewer = await repo.fetchViewerManifest('flr-3');
      transport.bytes['/api/bim/ar/tiles/$_hashNear'] = _tileNear;
      transport.bytes['/api/bim/ar/tiles/$_hashSolid'] = _tileSolid;
      await repo.downloadTiles(floor);
      await repo.downloadTiles(viewer!);
      expect(store.tiles.keys, containsAll([_hashNear, _hashSolid]));

      await repo.gcTiles(capBytes: 0);
      expect(store.tiles.keys, containsAll([_hashNear, _hashSolid]), reason: 'both still referenced');

      await repo.deleteFloorPack('flr-3');
      expect(store.manifests, isEmpty);
      expect(store.tiles, isEmpty);
    });
  });

  group('AR availability — the "Show in AR" door', () {
    test('available only when the server says so for this floor', () async {
      sync.gets['/api/bim/ar/availability'] = const SyncedRead<dynamic>(
        fromCache: false,
        data: {'available': true, 'buildingId': 'bld-1', 'floorId': 'flr-3', 'floorsWithAr': ['flr-3']},
      );
      expect(await repo.isArAvailable(floorId: 'flr-3'), isTrue);
      sync.gets['/api/bim/ar/availability'] = const SyncedRead<dynamic>(
        fromCache: false,
        data: {'success': true, 'data': {'available': false, 'reason': "AR isn't set up for this building."}},
      );
      expect(await repo.isArAvailable(assetId: 'AST001'), isFalse);
      expect(await repo.isArAvailable(), isFalse); // nothing to ask about
    });

    test('offline with no cached answer: only a floor whose AR pack is on this phone', () async {
      expect(await repo.isArAvailable(floorId: 'flr-3'), isFalse);
      expect(await repo.anyArBuilding(), isFalse);
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      await repo.fetchManifest('flr-3');
      expect(await repo.isArAvailable(floorId: 'flr-3'), isTrue);
      expect(await repo.isArAvailable(floorId: 'flr-9'), isFalse);
      expect(await repo.isArAvailable(assetId: 'AST001'), isFalse); // asset → floor needs the server
      expect(await repo.anyArBuilding(), isTrue);
    });

    test('dashboard card: any building with AR', () async {
      sync.gets['/api/bim/ar/availability/buildings'] =
          const SyncedRead<dynamic>(fromCache: false, data: {'buildingIds': <String>[]});
      expect(await repo.anyArBuilding(), isFalse);
      sync.gets['/api/bim/ar/availability/buildings'] =
          const SyncedRead<dynamic>(fromCache: true, data: {'buildingIds': ['bld-1']});
      expect(await repo.anyArBuilding(), isTrue);
    });
  });

  group('floors and preferences', () {
    test('floors show what is on the phone and what has an update', () async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(tiles: [_tile(_hashNear, 0, 200)])));
      final m = await repo.fetchManifest('flr-3');
      transport.bytes['/api/bim/ar/tiles/$_hashNear'] = _tileNear;
      await repo.downloadTiles(m);

      sync.gets['/api/bim/ar/buildings/bld-1/floors'] = const SyncedRead<dynamic>(
        fromCache: false,
        data: {
          'success': true,
          'data': [
            {
              'floorId': 'flr-3',
              'name': 'Level 3',
              'models': [
                {'lineage': 'mep', 'modelName': 'MEP', 'buildId': 'build-7', 'status': 'ready', 'bytes': 200},
              ],
            },
            {
              'floorId': 'flr-4',
              'name': 'Level 4',
              'models': [
                {'lineage': 'mep', 'modelName': 'MEP', 'buildId': 'build-8', 'status': 'ready', 'bytes': 900},
              ],
            },
          ],
        },
      );
      final floors = await repo.floorsForBuilding('bld-1');
      expect(floors[0].isOnDevice, isTrue);
      expect(floors[0].models.single.onDevice, isTrue);
      expect(floors[1].isOnDevice, isFalse);
      expect(floors[1].models.single.onDevice, isFalse);
    });

    test('offline with no cached list: the floors downloaded to this phone', () async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      await repo.fetchManifest('flr-3');
      final floors = await repo.floorsForBuilding('bld-1'); // syncGet: NetworkFailure
      expect(floors.single.floorId, 'flr-3');
      expect(floors.single.isOnDevice, isTrue);
      expect(floors.single.models.single.onDevice, isTrue);
      expect(floors.single.models.single.bytes, 600);
      expect(floors.single.markerCount, 1);
      expect(floors.single.recommendedMethod, ArSetupMethod.board);
      await expectLater(repo.floorsForBuilding('other-building'), throwsA(isA<NetworkFailure>()));
    });

    test('remember my method for this floor', () async {
      expect(await repo.rememberedMethod('flr-3'), isNull);
      await repo.rememberMethod('flr-3', ArSetupMethod.corners);
      expect(await repo.rememberedMethod('flr-3'), ArSetupMethod.corners);
      await repo.rememberMethod('flr-3', null);
      expect(await repo.rememberedMethod('flr-3'), isNull);
    });

    test('a viewer pack on the same floor is not a second floor', () async {
      transport
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()))
        ..answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest(tiles: [_solidTile(_hashSolid)])));
      await repo.fetchManifest('flr-3');
      await repo.fetchViewerManifest('flr-3');
      final floors = await repo.floorsForBuilding('bld-1'); // offline: built from packs
      expect(floors, hasLength(1));
      expect(floors.single.models.single.bytes, 600, reason: 'AR sizes only');
    });

    test('plan offline falls back to the stored manifest\'s corners', () async {
      transport.answer(_manifestPath, ArHttpResponse(status: 200, body: _manifest()));
      await repo.fetchManifest('flr-3');
      final plan = await repo.fetchFloorPlanCorners('flr-3'); // syncGet has nothing: NetworkFailure
      expect(plan.fromCache, isTrue);
      expect(plan.corners.single.id, 'c1');
      expect(plan.gridLines.single.name, 'A');
    });
  });
}

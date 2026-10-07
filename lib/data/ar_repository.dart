import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/env.dart';
import '../core/ar/ar_engine.dart' show TileRef;
import '../core/ar/marker_code.dart';
import '../core/ar/sha256.dart';
import '../core/ar/vec.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../core/network/envelope.dart';
import '../core/offline/offline_db.dart';
import '../core/offline/sync_client.dart';
import '../domain/ar_models.dart';

/// `entityType` on AR writes in the offline queue, so the Sync Center groups
/// them and a fetch can tell a floor whose progress is still queued (the
/// phone is ahead of the server) from one that is in step.
const kArProgressEntity = 'ArProgress';
const kArMarkerEntity = 'ArMarker';
const kArSessionEntity = 'ArSession';

const _base = '/api/bim/ar';

/// An AR GET's outcome. A 304 is a normal answer here, not an error.
class ArHttpResponse {
  const ArHttpResponse({required this.status, this.body, this.etag});

  final int status;
  final dynamic body;
  final String? etag;

  bool get notModified => status == 304;
}

/// The network reads [ArRepository] makes, behind a seam so tests fake them
/// (house rule: hand-written fakes of abstract interface classes).
abstract interface class ArTransport {
  /// GET returning JSON. Sends `If-None-Match` when [ifNoneMatch] is set and
  /// returns a 304 as `status: 304` with no body. Throws [HttpFailure] for
  /// ≥ 400 and [NetworkFailure] when the server was never reached.
  Future<ArHttpResponse> getJson(
    String path, {
    Map<String, dynamic>? query,
    String? ifNoneMatch,
  });

  /// GET raw bytes (a tile). Same failures as [getJson].
  Future<Uint8List> getBytes(
    String path, {
    void Function(int received, int total)? onProgress,
  });
}

/// The offline-queue side: cached reads and queued writes, over [SyncClient].
abstract interface class ArSync {
  Future<SyncedRead<dynamic>> syncGet(String url, {Map<String, dynamic>? query});

  Future<SyncedWrite> syncRequest(
    String method,
    String url, {
    dynamic data,
    required String label,
    List<QueuedAttachment> attachments = const [],
    String? entityType,
    String? entityId,
  });

  /// Entity ids of one type with a write still waiting in the queue.
  Future<Set<String>> pendingEntityIds(String entityType);
}

/// Tile files on disk (`<appSupport>/ar/tiles/<hash>.glb`).
abstract interface class ArTileFiles {
  Future<String> pathFor(String hash);
  Future<bool> exists(String hash);
  Future<Uint8List?> read(String hash);

  /// Writes atomically (temp file, then rename), so a kill mid-write never
  /// leaves a truncated file under a real tile name.
  Future<void> write(String hash, Uint8List bytes);
  Future<void> delete(String hash);

  /// Lower-case hex SHA-256 of [bytes] (off the UI isolate in production).
  Future<String> hashOf(Uint8List bytes);
}

/// A queued-or-sent AR write: [synced] false means it is parked in the
/// offline queue (show `kOfflineQueuedMessage`) and [data] is the local,
/// optimistic version.
class ArWrite<T> {
  const ArWrite({required this.synced, this.data});

  final bool synced;
  final T? data;
}

/// Progress of [ArRepository.downloadTiles]: "3 MB around you first, 14 MB
/// in all".
class ArDownloadProgress {
  const ArDownloadProgress({
    required this.tilesDone,
    required this.tilesTotal,
    required this.bytesDone,
    required this.bytesTotal,
    required this.focusTilesDone,
    required this.focusTilesTotal,
    this.currentHash,
  });

  final int tilesDone;
  final int tilesTotal;
  final int bytesDone;
  final int bytesTotal;
  final int focusTilesDone;
  final int focusTilesTotal;
  final String? currentHash;

  double get fraction => bytesTotal <= 0
      ? (tilesTotal == 0 ? 1 : tilesDone / tilesTotal)
      : (bytesDone / bytesTotal).clamp(0.0, 1.0).toDouble();

  /// The tiles around the user are in: M2Ready's "Start aligning" can enable
  /// while the rest of the floor streams.
  bool get focusReady => focusTilesDone >= focusTilesTotal;
}

class ArDownloadResult {
  const ArDownloadResult({
    required this.downloaded,
    required this.alreadyOnDevice,
    required this.failed,
    required this.bytesDownloaded,
    this.hashMismatches = 0,
    this.interrupted = false,
  });

  final int downloaded;
  final int alreadyOnDevice;
  final List<String> failed;
  final int bytesDownloaded;

  /// Downloads whose bytes didn't hash to the tile's name (corrupt or
  /// truncated). Never written to disk.
  final int hashMismatches;

  /// The connection dropped (or the caller cancelled) part way; the next
  /// call resumes where this one stopped, because finished tiles are kept.
  final bool interrupted;

  bool get complete => failed.isEmpty && !interrupted;
}

/// A floor-pack download that stopped short, for callers that prefer an
/// exception to inspecting [ArDownloadResult]. [offline] is true when the
/// connection dropped (the tiles already down stay; the next call resumes)
/// and false when tiles failed their hash check or the server refused them.
class ArDownloadInterrupted implements Exception {
  const ArDownloadInterrupted(this.offline, [this.failedHashes = const []]);

  final bool offline;
  final List<String> failedHashes;

  @override
  String toString() => 'ArDownloadInterrupted(offline: $offline, failed: ${failedHashes.length})';
}

/// AR floor packs, board resolution and AR writes (CONTRACT C6/C8).
///
/// Offline-first like the rest of the app: a floor that was downloaded
/// works with no signal — the manifest, markers, corners, grid lines,
/// features, progress and tile files all live on the phone — and every
/// write goes through `syncRequest`, so it survives a plant room with no
/// signal and replays in order.
///
/// Reads that must see the server's HTTP status (the manifest's 304, the
/// resolve errors) go through [ArTransport] on the raw client; small
/// cache-friendly reads (floors, plan, marker lists) ride the sync cache.
class ArRepository {
  /// Production wiring: `ArRepository(api: ref.watch(apiClientProvider),
  /// sync: ref.watch(syncClientProvider))`. The pack store defaults to the
  /// sync client's [OfflineDb].
  ArRepository({
    required ApiClient api,
    required SyncClient sync,
    ArPackStore? store,
    ArTileFiles? files,
  }) : this.withSeams(
          transport: DioArTransport(api),
          sync: SyncClientArSync(sync),
          store: store ?? sync.db,
          files: files ?? AppSupportTileFiles(),
        );

  ArRepository.withSeams({
    required ArTransport transport,
    required ArSync sync,
    required ArPackStore store,
    required ArTileFiles files,
    DateTime Function()? clock,
  })  : _transport = transport,
        _sync = sync,
        _store = store,
        _files = files,
        _clock = clock ?? DateTime.now;

  final ArTransport _transport;
  final ArSync _sync;
  final ArPackStore _store;
  final ArTileFiles _files;
  final DateTime Function() _clock;

  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

  // ------------------------------------------------------------------ floors

  /// The models picker (TabModels / PhModels): every floor with its models'
  /// state, marked with what is already on this phone. With no signal and
  /// no cached list, the floors downloaded to this phone are still offered
  /// ("Floors you've downloaded work offline"), built from their packs.
  Future<List<ArFloorSummary>> floorsForBuilding(String buildingId) async {
    final SyncedRead<dynamic> read;
    try {
      read = await _sync.syncGet('$_base/buildings/$buildingId/floors');
    } on NetworkFailure {
      final offline = await _floorsOnDevice(buildingId);
      if (offline.isEmpty) rethrow;
      return offline;
    }
    final floors = ArFloorSummary.listFromBody(read.data);
    if (floors.isEmpty) return floors;

    // Floor packs only: the model viewer's solid-wall pack (scope `viewer`)
    // shares the floor id and would otherwise overwrite the floor's entry.
    final stored = {
      for (final m in await _store.listArManifests())
        if (m.scope == 'floor') m.scopeId: m,
    };
    if (stored.isEmpty) return floors;
    final tilesOnDevice = {for (final t in await _store.listArTiles()) t.hash};

    return [
      for (final f in floors)
        if (stored[f.floorId] case final s?)
          _withLocal(f, s, tilesOnDevice)
        else
          f,
    ];
  }

  Future<List<ArFloorSummary>> _floorsOnDevice(String buildingId) async {
    final out = <ArFloorSummary>[];
    for (final s in await _store.listArManifests()) {
      if (s.scope != 'floor' || s.buildingId != buildingId) continue;
      final m = Manifest.fromJson(s.json);
      if (m == null) continue;
      out.add(ArFloorSummary(
        floorId: m.floorId,
        name: m.floorName,
        models: [
          for (final b in m.builds)
            ArFloorModel(
              lineage: b.lineage,
              modelName: b.modelName,
              buildId: b.buildId,
              version: b.version,
              publishedAt: b.publishedAt,
              bytes: m.tiles
                  .where((t) => t.buildId == b.buildId)
                  .fold<int>(0, (sum, t) => sum + t.bytes),
              status: ArModelStatus.ready,
              onDevice: true,
            ),
        ],
        markerCount: m.markers.length,
        cornerCount: m.corners.length,
        gridNames: {for (final g in m.gridLines) g.name}.toList(),
        downloadedAt: s.savedAt,
      ));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  ArFloorSummary _withLocal(ArFloorSummary f, StoredArManifest s, Set<String> tilesOnDevice) {
    final manifest = Manifest.fromJson(s.json);
    if (manifest == null) return f;
    final storedByLineage = {for (final b in manifest.builds) b.lineage: b.buildId};
    bool complete(String buildId) => manifest.tiles
        .where((t) => t.buildId == buildId)
        .every((t) => tilesOnDevice.contains(t.hash));
    return f.copyWith(
      downloadedAt: s.savedAt,
      models: [
        for (final m in f.models)
          m.withLocal(
            onDevice: m.buildId != null &&
                storedByLineage[m.lineage] == m.buildId &&
                complete(m.buildId!),
            updateAvailable: storedByLineage.containsKey(m.lineage) &&
                m.buildId != null &&
                storedByLineage[m.lineage] != m.buildId,
          ),
      ],
    );
  }

  // ------------------------------------------------------------ availability

  /// Can AR open for this floor / asset? Asked by every "Show in AR" door
  /// before it draws itself — not every client or building has AR
  /// (`GET /availability`, services/ar/arAvailabilityService.ts). Cached like
  /// the floors list; with no signal and no cached answer, a floor whose AR
  /// pack is already on this phone still counts as available.
  Future<bool> isArAvailable({String? floorId, String? assetId}) async {
    if (floorId == null && assetId == null) return false;
    try {
      final read = await _sync.syncGet('$_base/availability', query: {
        'floorId': ?floorId,
        if (floorId == null) 'assetId': ?assetId,
      });
      final body = _bareBody(read.data);
      return body is Map && body['available'] == true;
    } on NetworkFailure {
      if (floorId == null) return false;
      for (final m in await _store.listArManifests()) {
        if (m.scope == 'floor' && m.scopeId == floorId) return true;
      }
      return false;
    }
  }

  /// Does any building this user can see have a published AR model? Decides
  /// what the dashboard's AR card offers (models vs. "No AR model for your
  /// buildings yet" + the demo room) — it no longer hides the card.
  /// Offline with no cached answer: true only if an AR floor pack is already
  /// on this phone.
  ///
  /// Any answer that is not a network failure — a 404 from a server older
  /// than this route, a 500, an odd body — means "no models" (2026-10-06:
  /// the dev server's 404 made the provider error out, which read as "no
  /// AR" and hid the card on the owner's phone).
  Future<bool> anyArBuilding() async {
    try {
      final read = await _sync.syncGet('$_base/availability/buildings');
      final body = _bareBody(read.data);
      final ids = body is Map ? body['buildingIds'] : null;
      return ids is List && ids.isNotEmpty;
    } on NetworkFailure {
      return (await _store.listArManifests()).any((m) => m.scope == 'floor');
    } catch (_) {
      return false;
    }
  }

  /// AR endpoints answer with the bare body; tolerate a `{success, data}` envelope too.
  static Object? _bareBody(Object? d) =>
      d is Map && d.containsKey('data') && (d.containsKey('success') || d.containsKey('message')) ? d['data'] : d;

  // ----------------------------------------------------------------- resolve

  /// One scan → building, floor and model (docs/ar-markers-and-qr.md §3.2).
  ///
  /// Local first: a board on a downloaded floor resolves from the phone with
  /// no signal ("Model is on this phone"). Otherwise the server decides.
  /// Throws [ArApiError] with a [ArErrorCode] the screen turns into a next
  /// step: `NOT_A_MARKER`, `UNKNOWN_CODE`, `NO_ACCESS`, `RETIRED` (with the
  /// nearest active board), `SPARE_UNBOUND`, `NO_PUBLISHED_BUILD`, or
  /// `NEEDS_SIGNAL` ("This board needs signal once. Floors you've downloaded
  /// work offline.").
  Future<MarkerResolution> resolveMarker(String rawCode) async {
    final code = MarkerCode.normalize(rawCode) ?? MarkerCode.fromScan(rawCode);
    if (code == null) {
      throw const ArApiError(
        code: ArErrorCode.notAMarker,
        message: 'Not a FusionEco marker.',
      );
    }

    final local = await _localResolution(code);
    if (local != null) return local;

    try {
      final response = await _transport.getJson('$_base/markers/resolve/$code');
      final resolution = MarkerResolution.fromBody(response.body);
      if (resolution == null) {
        throw const ArApiError(
          code: 'BAD_RESPONSE',
          message: "The server's answer for this board couldn't be read.",
        );
      }
      await _rememberBuildingName(resolution.building);
      final pack = await _store.getArManifest(resolution.floor.id);
      return resolution.copyWith(packOnDevice: pack != null);
    } on HttpFailure catch (e) {
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    } on NetworkFailure {
      throw const ArApiError(
        code: ArErrorCode.needsSignal,
        message: "This board needs signal once. Floors you've downloaded work offline.",
      );
    }
  }

  Future<MarkerResolution?> _localResolution(String code) async {
    final json = await _store.getArMarker(code);
    if (json == null) return null;
    final marker = ArMarker.fromJson(json);
    final floorId = marker?.floorId;
    // Spare and retired boards need the server's answer (the spare flow,
    // "nearest active board"), so they never resolve locally.
    if (marker == null || floorId == null || marker.isSpare || marker.isRetired) return null;
    final stored = await _store.getArManifest(floorId);
    final manifest = stored == null ? null : Manifest.fromJson(stored.json);
    if (stored == null || manifest == null) return null;

    final focus = marker.posTile;
    final focusBytes = manifest.focusTiles(focus).fold<int>(0, (sum, t) => sum + t.bytes);
    final buildingName = stored.meta['buildingName']?.toString() ??
        await _store.getArPref(_buildingNameKey(manifest.buildingId)) ??
        '';
    return MarkerResolution(
      marker: marker,
      building: ArNamedRef(id: manifest.buildingId, name: buildingName),
      floor: ArNamedRef(id: manifest.floorId, name: manifest.floorName),
      builds: manifest.builds,
      manifestUrl: '$_base/manifest?scope=floor&id=${manifest.floorId}&focus=$code',
      focusBytes: focusBytes,
      totalBytes: manifest.totalBytes,
      fromCache: true,
      packOnDevice: true,
    );
  }

  static String _buildingNameKey(String buildingId) => 'buildingName:$buildingId';

  Future<void> _rememberBuildingName(ArNamedRef building) async {
    if (building.name.isEmpty) return;
    await _store.setArPref(_buildingNameKey(building.id), building.name);
  }

  // ---------------------------------------------------------------- manifest

  /// The floor's manifest. Sends the stored ETag as `If-None-Match`; a 304
  /// returns the stored copy with `notModified: true`. Dio treats anything
  /// under 400 as success, so the 304 is checked explicitly and never parsed
  /// as a (empty) manifest — that is what would silently wipe a floor.
  /// Offline, the stored copy comes back with `fromCache: true`.
  Future<Manifest> fetchManifest(String floorId, {String? focusCode}) async {
    final stored = await _store.getArManifest(floorId);
    final storedManifest = stored == null ? null : Manifest.fromJson(stored.json);
    final query = <String, dynamic>{
      'scope': 'floor',
      'id': floorId,
      if (focusCode != null) 'focus': MarkerCode.normalize(focusCode) ?? focusCode,
    };

    try {
      var response = await _transport.getJson(
        '$_base/manifest',
        query: query,
        ifNoneMatch: storedManifest == null ? null : stored!.etag,
      );
      if (response.notModified) {
        if (storedManifest != null) {
          return storedManifest.copyWith(notModified: true, etag: stored!.etag);
        }
        // A 304 for a copy we no longer hold (wiped mid-call): ask again
        // without the tag rather than return nothing.
        response = await _transport.getJson('$_base/manifest', query: query);
      }

      final manifest = Manifest.fromBody(response.body);
      if (manifest == null) {
        throw const ArApiError(
          code: 'BAD_MANIFEST',
          message: "This floor's model package couldn't be read.",
        );
      }
      final etag = response.etag ?? manifest.etag;
      final buildingName = await _store.getArPref(_buildingNameKey(manifest.buildingId));
      await _store.saveArManifest(
        StoredArManifest(
          scopeId: floorId,
          buildingId: manifest.buildingId,
          etag: etag,
          json: manifest.raw,
          meta: {
            'buildingName': ?buildingName,
            'focusCode': ?focusCode,
          },
          tileHashes: [for (final t in manifest.tiles) t.hash],
          savedAt: _clock(),
        ),
        markers: [for (final m in manifest.markers) m.toJson()],
        corners: [for (final c in manifest.corners) c.toJson()],
        gridLines: [for (final g in manifest.gridLines) g.toJson()],
      );
      return manifest.copyWith(etag: etag);
    } on NetworkFailure {
      if (storedManifest != null) return storedManifest.copyWith(fromCache: true);
      rethrow;
    } on HttpFailure catch (e) {
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
  }

  /// The stored manifest for a floor, without touching the network.
  Future<Manifest?> localManifest(String floorId) async {
    final stored = await _store.getArManifest(floorId);
    return stored == null ? null : Manifest.fromJson(stored.json)?.copyWith(fromCache: true, etag: stored.etag);
  }

  // ------------------------------------------------------- model viewer pack

  /// Scope of the model viewer's extra pack in `ar_manifests` (next to the
  /// floor's own `floor` pack, same scope id = floor id).
  static const viewerScope = 'viewer';

  /// The tile layer only the model viewer asks for: architecture as shaded
  /// triangles (the AR `architecture` layer is edges only). Server:
  /// `GET /manifest?layers=architecture_solid` (docs/bim-viewer.md §3).
  static const solidArchitectureLayer = 'architecture_solid';

  /// The floor's `architecture_solid` tiles for the 2D/3D model viewer,
  /// stored as a second, tiny pack (scope [viewerScope]) so the AR floor
  /// pack and its ETag are never touched. The viewer loads the AR pack's
  /// tiles plus these. Same ETag / 304 / offline rules as [fetchManifest].
  ///
  /// Kept as a manifest row (not a pref) on purpose: tile GC keeps whatever
  /// a stored manifest references, so the solid tiles survive a clean-up
  /// exactly as long as the viewer pack does.
  ///
  /// A server that predates the layer answers 400 `BAD_LAYERS`; that and a
  /// build without solid tiles both come back as an empty tile list, and the
  /// viewer falls back to walls extruded from the plan.
  Future<Manifest?> fetchViewerManifest(String floorId) async {
    final stored = await _store.getArManifest(floorId, scope: viewerScope);
    final storedManifest = stored == null ? null : Manifest.fromJson(stored.json);
    final query = <String, dynamic>{'scope': 'floor', 'id': floorId, 'layers': solidArchitectureLayer};
    try {
      var response = await _transport.getJson(
        '$_base/manifest',
        query: query,
        ifNoneMatch: storedManifest == null ? null : stored!.etag,
      );
      if (response.notModified) {
        if (storedManifest != null) return storedManifest.copyWith(notModified: true, etag: stored!.etag);
        response = await _transport.getJson('$_base/manifest', query: query);
      }
      final manifest = Manifest.fromBody(response.body);
      if (manifest == null) return storedManifest?.copyWith(fromCache: true);
      final solid = [for (final t in manifest.tiles) if (t.layer == solidArchitectureLayer) t];
      final etag = response.etag ?? manifest.etag;
      await _store.saveArManifest(
        StoredArManifest(
          scope: viewerScope,
          scopeId: floorId,
          buildingId: manifest.buildingId,
          etag: etag,
          json: manifest.raw,
          tileHashes: [for (final t in solid) t.hash],
          savedAt: _clock(),
        ),
      );
      return manifest.copyWith(etag: etag);
    } on NetworkFailure {
      return storedManifest?.copyWith(fromCache: true);
    } on HttpFailure catch (e) {
      // 400 BAD_LAYERS: a server from before the solid layer. Not an error
      // for the viewer — it draws plan massing instead.
      if (e.status == 400) return null;
      if (storedManifest != null) return storedManifest.copyWith(fromCache: true);
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
  }

  /// The stored viewer pack for a floor, without touching the network.
  Future<Manifest?> localViewerManifest(String floorId) async {
    final stored = await _store.getArManifest(floorId, scope: viewerScope);
    return stored == null ? null : Manifest.fromJson(stored.json)?.copyWith(fromCache: true, etag: stored.etag);
  }

  // ------------------------------------------------------------------- tiles

  /// Downloads the manifest's tiles that aren't on the phone yet (a hash
  /// diff: a new model version re-downloads only the cells that changed),
  /// **focus tiles first** — those within [focusRadiusM] of [focusTile],
  /// nearest first — then the rest in manifest order.
  ///
  /// Each tile's bytes are hashed and must equal its name before they are
  /// written; a mismatch is counted and skipped, never stored. A file left
  /// on disk without a row (after a logout wiped the database) is re-adopted
  /// when its bytes still hash right. A dropped connection stops the run
  /// (`interrupted`); the next call resumes, because finished tiles stay.
  Future<ArDownloadResult> downloadTiles(
    Manifest manifest, {
    Vec3? focusTile,
    double focusRadiusM = 15,
    void Function(ArDownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final focusSet = <String>{};
    final ordered = List<ManifestTile>.of(manifest.tiles);
    if (focusTile != null) {
      final near = ordered.where((t) => t.distanceTo(focusTile) <= focusRadiusM).toList()
        ..sort((a, b) => a.distanceTo(focusTile).compareTo(b.distanceTo(focusTile)));
      focusSet.addAll(near.map((t) => t.hash));
      ordered
        ..removeWhere((t) => focusSet.contains(t.hash))
        ..insertAll(0, near);
    }

    final failed = <String>[];
    final missing = <ManifestTile>[];
    final seen = <String>{};
    var alreadyOnDevice = 0;
    for (final t in ordered) {
      if (!seen.add(t.hash)) continue;
      if (!_hashPattern.hasMatch(t.hash)) {
        failed.add(t.hash); // never let a server string become a file path
        continue;
      }
      if (await _tileOnDevice(t.hash)) {
        alreadyOnDevice++;
        continue;
      }
      missing.add(t);
    }

    final focusTotal = missing.where((t) => focusSet.contains(t.hash)).length;
    final bytesTotal = missing.fold<int>(0, (sum, t) => sum + t.bytes);
    var tilesDone = 0;
    var bytesDone = 0;
    var focusDone = 0;
    var bytesDownloaded = 0;
    var mismatches = 0;
    var interrupted = false;

    void report({String? current, int partial = 0}) => onProgress?.call(ArDownloadProgress(
          tilesDone: tilesDone,
          tilesTotal: missing.length,
          bytesDone: bytesDone + partial,
          bytesTotal: bytesTotal,
          focusTilesDone: focusDone,
          focusTilesTotal: focusTotal,
          currentHash: current,
        ));

    report();
    for (final t in missing) {
      if (isCancelled?.call() ?? false) {
        interrupted = true;
        break;
      }
      try {
        final bytes = await _transport.getBytes(
          t.url,
          onProgress: (received, _) => report(current: t.hash, partial: received),
        );
        final actual = await _files.hashOf(bytes);
        if (actual != t.hash) {
          mismatches++;
          failed.add(t.hash);
          continue;
        }
        await _files.write(t.hash, bytes);
        await _store.upsertArTile(StoredArTile(
          hash: t.hash,
          path: await _files.pathFor(t.hash),
          bytes: bytes.length,
          lastUsedAt: _clock(),
        ));
        tilesDone++;
        bytesDone += t.bytes > 0 ? t.bytes : bytes.length;
        bytesDownloaded += bytes.length;
        if (focusSet.contains(t.hash)) focusDone++;
        report(current: t.hash);
      } on NetworkFailure {
        interrupted = true;
        break;
      } on HttpFailure {
        failed.add(t.hash);
      }
    }

    return ArDownloadResult(
      downloaded: tilesDone,
      alreadyOnDevice: alreadyOnDevice,
      failed: failed,
      bytesDownloaded: bytesDownloaded,
      hashMismatches: mismatches,
      interrupted: interrupted,
    );
  }

  Future<bool> _tileOnDevice(String hash) async {
    final row = await _store.getArTile(hash);
    final onDisk = await _files.exists(hash);
    if (row != null && onDisk) return true;
    if (row != null && !onDisk) {
      await _store.deleteArTiles([hash]); // the OS or the user cleared the file
      return false;
    }
    if (!onDisk) return false;
    // A file with no row: adopt it if its bytes still hash to its name.
    final bytes = await _files.read(hash);
    if (bytes != null && await _files.hashOf(bytes) == hash) {
      await _store.upsertArTile(StoredArTile(
        hash: hash,
        path: await _files.pathFor(hash),
        bytes: bytes.length,
        lastUsedAt: _clock(),
      ));
      return true;
    }
    await _files.delete(hash);
    return false;
  }

  /// `TileRef`s for the tiles that are on the phone, in the given order,
  /// for `ArEngine.loadTiles`. Marks them used, for LRU clean-up.
  Future<List<TileRef>> tileRefs(List<ManifestTile> tiles) async {
    final refs = <TileRef>[];
    for (final t in tiles) {
      final row = await _store.getArTile(t.hash);
      if (row != null) refs.add(TileRef(hash: t.hash, path: row.path));
    }
    await _store.touchArTiles([for (final r in refs) r.hash], _clock());
    return refs;
  }

  /// Deletes tiles no stored manifest references, least recently used
  /// first, until the store is under [capBytes] (docs/ar-bim-overlay.md
  /// §6.8). With [all], every unreferenced tile goes. Returns bytes freed.
  Future<int> gcTiles({int capBytes = 1024 * 1024 * 1024, bool all = false}) async {
    final referenced = <String>{
      for (final m in await _store.listArManifests()) ...m.tileHashes,
    };
    final tiles = await _store.listArTiles(); // oldest use first
    var total = tiles.fold<int>(0, (sum, t) => sum + t.bytes);
    var freed = 0;
    final doomed = <String>[];
    for (final t in tiles) {
      if (!all && total <= capBytes) break;
      if (referenced.contains(t.hash)) continue;
      doomed.add(t.hash);
      total -= t.bytes;
      freed += t.bytes;
    }
    for (final hash in doomed) {
      await _files.delete(hash);
    }
    await _store.deleteArTiles(doomed);
    return freed;
  }

  /// Removes a floor's pack (manifest, markers, corners, grid lines, synced
  /// progress) and then every tile no other floor still needs.
  Future<int> deleteFloorPack(String floorId) async {
    await _store.deleteArManifest(floorId);
    await _store.deleteArManifest(floorId, scope: viewerScope);
    return gcTiles(all: true);
  }

  // ---------------------------------------------------------------- features

  /// Feature rows for [buildId] (optionally only those in [tileHashes]),
  /// stored for offline picking and "Show in AR". Offline, the stored rows.
  Future<List<ArFeature>> fetchFeatures(
    String buildId, {
    List<String>? tileHashes,
    String? url,
  }) async {
    final path = url ?? '$_base/features/$buildId';
    try {
      final byId = <int, ArFeature>{};
      final chunks = tileHashes == null || tileHashes.isEmpty
          ? const <List<String>?>[null]
          : _chunks(tileHashes, 40);
      for (final chunk in chunks) {
        final response = await _transport.getJson(
          path,
          query: chunk == null ? null : {'tiles': chunk.join(',')},
        );
        for (final f in ArFeature.listFromBody(response.body, buildId: buildId)) {
          byId[f.featureId] = f;
        }
      }
      final features = byId.values.toList()..sort((a, b) => a.featureId.compareTo(b.featureId));
      await _store.upsertArFeatures(buildId, [for (final f in features) f.toJson()]);
      return features;
    } on NetworkFailure {
      final local = (await _store.listArFeatures(buildId))
          .map((j) => ArFeature.fromJson(j, buildId: buildId))
          .whereType<ArFeature>();
      if (tileHashes == null || tileHashes.isEmpty) return local.toList();
      final wanted = tileHashes.toSet();
      return local.where((f) => f.tiles.any((t) => wanted.contains(t.hash))).toList();
    } on HttpFailure catch (e) {
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
  }

  /// Stored features for a GlobalId or a register asset, across every
  /// downloaded build — the target for "Show in AR".
  Future<List<ArFeature>> findFeatures({String? globalId, String? assetId}) async {
    final rows = await _store.findArFeatures(globalId: globalId, assetId: assetId);
    return rows.map((j) => ArFeature.fromJson(j)).whereType<ArFeature>().toList();
  }

  static List<List<String>> _chunks(List<String> items, int size) => [
        for (var i = 0; i < items.length; i += size)
          items.sublist(i, i + size > items.length ? items.length : i + size),
      ];

  // --------------------------------------------------------- plan & markers

  /// The floor's cut plan with its corner candidates (mini plan, corner A
  /// picker, ghost board). Rides the sync cache; with neither signal nor a
  /// cached copy, falls back to the corners and grid lines in the stored
  /// manifest so the corner picker still works.
  Future<FloorPlan> fetchFloorPlanCorners(String floorId) async {
    try {
      final read = await _sync.syncGet('$_base/floors/$floorId/plan');
      final plan = FloorPlan.fromBody(read.data, floorId: floorId);
      if (plan != null) return plan.withFromCache(read.fromCache);
    } on NetworkFailure {
      // fall through to the manifest's corners
    } on HttpFailure catch (e) {
      final manifest = await localManifest(floorId);
      if (manifest != null) return FloorPlan.fromManifest(manifest);
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
    final manifest = await localManifest(floorId);
    if (manifest != null) return FloorPlan.fromManifest(manifest);
    throw const ArApiError(
      code: ArErrorCode.needsSignal,
      message: "This floor's plan needs signal once.",
    );
  }

  /// Boards for a floor or building (the installer's list). Rides the sync
  /// cache; offline without a cache, the boards in the stored floor pack.
  Future<List<ArMarker>> fetchMarkers({String? buildingId, String? floorId}) async {
    try {
      final read = await _sync.syncGet('$_base/markers', query: {
        'buildingId': ?buildingId,
        'floorId': ?floorId,
      });
      return ArMarker.listFromBody(read.data);
    } on NetworkFailure {
      final rows = await _store.listArMarkers(floorId: floorId, buildingId: buildingId);
      return rows.map(ArMarker.fromJson).whereType<ArMarker>().toList();
    }
  }

  /// Boards in the stored floor pack, for alignment offline.
  Future<List<ManifestMarker>> localMarkers(String floorId) async {
    final rows = await _store.listArMarkers(floorId: floorId);
    return [
      for (final r in rows)
        if (ManifestMarker.fromJson(r) case final m?) m,
    ];
  }

  // ---------------------------------------------------------------- progress

  static String _progressTotalKey(String floorId) => 'progressTotal:$floorId';

  /// Element statuses for a floor (Progress mode). Local changes still in
  /// the queue win over the server's copy until they sync.
  Future<FloorProgress> fetchProgress(String floorId) async {
    try {
      final response = await _transport.getJson('$_base/progress', query: {'floorId': floorId});
      final server = FloorProgress.fromBody(floorId, response.body);
      final pending = await _sync.pendingEntityIds(kArProgressEntity);
      await _store.replaceArProgress(
        floorId,
        [for (final s in server.statuses) s.toJson()],
        keepPending: pending.contains(floorId),
      );
      await _store.setArPref(_progressTotalKey(floorId), '${server.summary.total}');
      return await _localProgress(floorId, fromCache: false, total: server.summary.total);
    } on NetworkFailure {
      final total = int.tryParse(await _store.getArPref(_progressTotalKey(floorId)) ?? '');
      return await _localProgress(floorId, fromCache: true, total: total);
    } on HttpFailure catch (e) {
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
  }

  Future<FloorProgress> _localProgress(String floorId, {required bool fromCache, int? total}) async {
    final rows = (await _store.listArProgress(floorId))
        .map(ElementProgress.fromJson)
        .whereType<ElementProgress>()
        .toList();
    return FloorProgress(
      floorId: floorId,
      statuses: rows,
      summary: ProgressSummary.of(rows, total: total),
      fromCache: fromCache,
    );
  }

  /// Marks elements installed / verified / issue (tap or lasso). Local
  /// first: the floor's colours change at once, and the write is queued
  /// when there is no signal. The four-eyes rule is pre-checked here (a
  /// verify by the person who installed, or of an element not installed,
  /// is refused before it is queued); the server still decides, and its
  /// rejections are rolled back locally.
  Future<ProgressUpdateResult> setProgress({
    required String floorId,
    required List<String> globalIds,
    required String status,
    String? note,
    Uint8List? photo,
    String? actorId,
  }) async {
    final before = {
      for (final r in await _store.listArProgress(floorId))
        if (ElementProgress.fromJson(r) case final e?) e.globalId: e,
    };
    final rejected = <ProgressRejection>[];
    final accepted = <String>[];
    for (final id in globalIds.toSet()) {
      final reason = ProgressRules.precheck(before[id], status, actorId);
      if (reason != null) {
        rejected.add(ProgressRejection(globalId: id, reason: reason));
      } else {
        accepted.add(id);
      }
    }
    if (accepted.isEmpty) return ProgressUpdateResult(updated: 0, rejected: rejected);

    final now = _clock();
    await _store.upsertArProgress(
      floorId,
      [
        for (final id in accepted)
          (before[id] ?? ElementProgress(globalId: id, status: ArProgressStatus.notStarted))
              .applied(status, actorId: actorId, note: note, at: now)
              .toJson(),
      ],
      pending: true,
    );

    final placeholder = '__pending_ar_progress_${now.microsecondsSinceEpoch}__';
    final body = <String, dynamic>{
      'floorId': floorId,
      'globalIds': accepted,
      'status': status,
      'note': ?note,
      if (photo != null) 'photoUrl': placeholder,
    };

    final SyncedWrite write;
    try {
      write = await _sync.syncRequest(
        'POST',
        '$_base/progress',
        data: body,
        label: 'AR progress: ${accepted.length} × $status',
        attachments: [
          if (photo != null)
            QueuedAttachment(
              bytes: photo,
              fileName: 'ar-progress-${now.millisecondsSinceEpoch}.jpg',
              placeholder: placeholder,
              field: 'image',
            ),
        ],
        entityType: kArProgressEntity,
        entityId: floorId,
      );
    } on HttpFailure catch (e) {
      await _restoreProgress(floorId, accepted, before);
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }

    if (!write.synced) {
      return ProgressUpdateResult(updated: accepted.length, rejected: rejected, queued: true);
    }
    final result = ProgressUpdateResult.fromBody(write.data);
    final refused = {for (final r in result.rejected) r.globalId};
    if (refused.isNotEmpty) await _restoreProgress(floorId, refused.toList(), before);
    // The rest are now the server's truth: no longer ahead of it.
    await _store.upsertArProgress(
      floorId,
      [
        for (final id in accepted)
          if (!refused.contains(id))
            (before[id] ?? ElementProgress(globalId: id, status: ArProgressStatus.notStarted))
                .applied(status, actorId: actorId, note: note, at: now)
                .toJson()
              ..['pending'] = false,
      ],
      pending: false,
    );
    return ProgressUpdateResult(
      updated: result.updated,
      rejected: [...rejected, ...result.rejected],
    );
  }

  Future<void> _restoreProgress(
    String floorId,
    List<String> ids,
    Map<String, ElementProgress> before,
  ) =>
      _store.upsertArProgress(
        floorId,
        [
          for (final id in ids)
            (before[id] ?? ElementProgress(globalId: id, status: ArProgressStatus.notStarted)).toJson()
              ..['pending'] = false,
        ],
        pending: false,
      );

  // ------------------------------------------------------------ board writes

  /// "Save board here": turns a scanned spare into a Derived marker at the
  /// pose the current fit gives it (docs/ar-markers-and-qr.md §5.4). Stored
  /// on the phone first (`localOnly`), so the next scan of this board
  /// resolves offline even before the queue drains. If the server says the
  /// spare was bound somewhere else first, the local row is dropped and the
  /// error surfaces.
  Future<ArWrite<ArMarker>> bindSpare(
    String code, {
    required String floorId,
    required String buildId,
    required Vec3 posTile,
    required Vec3 normalTile,
    String? label,
    double? sigmaM,
    String? buildingId,
  }) async {
    final canonical = MarkerCode.normalize(code);
    if (canonical == null) {
      throw const ArApiError(code: ArErrorCode.notAMarker, message: 'Not a FusionEco marker.');
    }
    final local = ArMarker(
      code: canonical,
      label: label ?? MarkerCode.spareLabel(canonical),
      status: ArMarkerStatus.installed,
      accuracyClass: 'derived',
      buildingId: buildingId,
      floorId: floorId,
      posTile: posTile,
      normalTile: normalTile,
      installedAt: _clock(),
    );
    await _store.upsertArMarker(local.toJson(), localOnly: true);

    try {
      final write = await _sync.syncRequest(
        'POST',
        '$_base/spares/$canonical/bind',
        data: {
          'floorId': floorId,
          'buildId': buildId,
          'posTile': posTile.toList(),
          'normalTile': normalTile.toList(),
          'label': ?label,
          'sigmaM': ?sigmaM,
        },
        label: 'AR: save board ${local.label}',
        entityType: kArMarkerEntity,
        entityId: canonical,
      );
      if (!write.synced) return ArWrite(synced: false, data: local);
      final server = ArMarker.fromJson(unwrapMap(write.data)) ?? local;
      await _store.upsertArMarker({
        ...server.toJson(),
        'floorId': server.floorId ?? floorId,
        'buildingId': server.buildingId ?? buildingId,
      });
      return ArWrite(synced: true, data: server);
    } on HttpFailure catch (e) {
      await _store.deleteArMarker(canonical);
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
  }

  /// The installer's confirm after the self-check (`checks` from
  /// `InstallCheckResult.toChecksJson`), with the automatic photo. The
  /// stored board turns Installed locally at once.
  Future<ArWrite<ArMarker>> confirmInstall(
    String code, {
    required String buildId,
    required Map<String, dynamic> checks,
    Vec3? posTile,
    Vec3? normalTile,
    Uint8List? photo,
  }) async {
    final canonical = MarkerCode.normalize(code);
    if (canonical == null) {
      throw const ArApiError(code: ArErrorCode.notAMarker, message: 'Not a FusionEco marker.');
    }
    final now = _clock();
    final storedJson = await _store.getArMarker(canonical);
    final stored = storedJson == null ? null : ArMarker.fromJson(storedJson);
    ArMarker? local;
    if (stored != null && storedJson != null) {
      local = stored.copyWith(
        status: stored.awaitsInstall ? ArMarkerStatus.installed : stored.status,
        installedAt: now,
        posTile: posTile,
        normalTile: normalTile,
      );
      await _store.upsertArMarker({
        ...storedJson,
        ...local.toJson(),
      });
    }

    final placeholder = '__pending_ar_install_${now.microsecondsSinceEpoch}__';
    try {
      final write = await _sync.syncRequest(
        'POST',
        '$_base/markers/$canonical/confirm-install',
        data: {
          'buildId': buildId,
          if (posTile != null) 'posTile': posTile.toList(),
          if (normalTile != null) 'normalTile': normalTile.toList(),
          'checks': checks,
          if (photo != null) 'photoUrl': placeholder,
        },
        label: 'AR: board ${local?.label ?? MarkerCode.display(canonical)} installed',
        attachments: [
          if (photo != null)
            QueuedAttachment(
              bytes: photo,
              fileName: 'ar-install-$canonical-${now.millisecondsSinceEpoch}.jpg',
              placeholder: placeholder,
              field: 'image',
            ),
        ],
        entityType: kArMarkerEntity,
        entityId: canonical,
      );
      if (!write.synced) return ArWrite(synced: false, data: local);
      final server = ArMarker.fromJson(unwrapMap(write.data)) ?? local;
      if (server != null && storedJson != null) {
        await _store.upsertArMarker({...storedJson, ...server.toJson()});
      }
      return ArWrite(synced: true, data: server);
    } on HttpFailure catch (e) {
      if (storedJson != null) await _store.upsertArMarker(storedJson); // roll back
      throw ArApiError.fromBody(e.status, e.body, fallbackMessage: e.message);
    }
  }

  /// Session alignment telemetry, batched and queued like any write (it is
  /// what marker health and promotion run on, so it must survive offline).
  Future<ArWrite<int>> postAlignmentEvents(List<ArAlignmentEvent> events) async {
    if (events.isEmpty) return const ArWrite(synced: true, data: 0);
    final write = await _sync.syncRequest(
      'POST',
      '$_base/alignment-events',
      data: {'events': [for (final e in events) e.toJson()]},
      label: 'AR session log',
      entityType: kArSessionEntity,
      entityId: events.first.floorId,
    );
    if (!write.synced) return ArWrite(synced: false, data: events.length);
    return ArWrite(synced: true, data: asInt(unwrapMap(write.data)['accepted']) ?? events.length);
  }

  // ------------------------------------------------------------------- prefs

  static String _methodKey(String floorId) => 'method:$floorId';

  /// "Remember my choice for this floor" (AR-54).
  Future<String?> rememberedMethod(String floorId) => _store.getArPref(_methodKey(floorId));

  Future<void> rememberMethod(String floorId, String? method) =>
      _store.setArPref(_methodKey(floorId), method);
}

// --------------------------------------------------------- production seams

/// [ArTransport] on the app's authenticated Dio (bearer token and mutation
/// id interceptors included). It uses the raw client because [ApiClient.get]
/// can't send `If-None-Match` or read response headers.
class DioArTransport implements ArTransport {
  DioArTransport(this._api);

  final ApiClient _api;

  @override
  Future<ArHttpResponse> getJson(
    String path, {
    Map<String, dynamic>? query,
    String? ifNoneMatch,
  }) async {
    try {
      final response = await _api.raw.get<dynamic>(
        path,
        queryParameters: query,
        options: Options(headers: {'If-None-Match': ?ifNoneMatch}),
      );
      final status = response.statusCode ?? 200;
      // `validateStatus` is `< 400`, so a 304 lands here as a "success"
      // with an empty body. Surface it as a 304, never as data.
      return ArHttpResponse(
        status: status,
        body: status == 304 ? null : response.data,
        etag: response.headers.value('etag'),
      );
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  @override
  Future<Uint8List> getBytes(
    String path, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final response = await _api.raw.get<List<int>>(
        path,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: Env.uploadTimeout,
        ),
        onReceiveProgress: onProgress,
      );
      final data = response.data;
      if (data == null) throw const UnknownFailure('The download returned no data.');
      return data is Uint8List ? data : Uint8List.fromList(data);
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }
}

class SyncClientArSync implements ArSync {
  SyncClientArSync(this._sync);

  final SyncClient _sync;

  @override
  Future<SyncedRead<dynamic>> syncGet(String url, {Map<String, dynamic>? query}) =>
      _sync.syncGet(url, query: query);

  @override
  Future<SyncedWrite> syncRequest(
    String method,
    String url, {
    dynamic data,
    required String label,
    List<QueuedAttachment> attachments = const [],
    String? entityType,
    String? entityId,
  }) =>
      _sync.syncRequest(
        method,
        url,
        data: data,
        label: label,
        attachments: attachments,
        entityType: entityType,
        entityId: entityId,
      );

  @override
  Future<Set<String>> pendingEntityIds(String entityType) =>
      _sync.db.pendingEntityIds(entityType);
}

/// Tile files under `<appSupport>/ar/tiles/`. App support, not cache: the OS
/// may purge a cache directory under storage pressure, and a floor pack
/// vanishing in a plant room with no signal is exactly what offline packs
/// exist to prevent.
class AppSupportTileFiles implements ArTileFiles {
  AppSupportTileFiles({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;
  Directory? _dir;

  Future<Directory> _tilesDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await _baseDir();
    final dir = Directory(p.join(base.path, 'ar', 'tiles'));
    await dir.create(recursive: true);
    return _dir = dir;
  }

  @override
  Future<String> pathFor(String hash) async => p.join((await _tilesDir()).path, '$hash.glb');

  @override
  Future<bool> exists(String hash) async => File(await pathFor(hash)).exists();

  @override
  Future<Uint8List?> read(String hash) async {
    final file = File(await pathFor(hash));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> write(String hash, Uint8List bytes) async {
    final path = await pathFor(hash);
    final tmp = File('$path.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  @override
  Future<void> delete(String hash) async {
    final file = File(await pathFor(hash));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<String> hashOf(Uint8List bytes) => Isolate.run(() => Sha256.hex(bytes));
}

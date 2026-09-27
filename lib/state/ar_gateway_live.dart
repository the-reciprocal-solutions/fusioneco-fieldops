import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ar/vec.dart';
import '../data/ar_repository.dart' as repo;
import '../domain/ar_models.dart' as wire;
import 'ar_engine_bridge.dart' show ArTile;
import 'ar_gateway.dart';
import 'ar_view_models.dart';
import 'auth_controller.dart';
import 'providers.dart';
import 'snag_controller.dart' show snagBuildingsProvider;

/// [ArGateway] over the real [repo.ArRepository]: the offline floor pack,
/// the tile store and the offline queue. This is the only file that maps
/// the wire models (`domain/ar_models.dart`, imported as `wire`) onto the
/// screens' view models, so a wire change stays a one-file fix.
ArGateway createLiveArGateway(Ref ref) => LiveArGateway(
  repository: ref.watch(arRepositoryProvider),
  actorId: () => ref.read(authControllerProvider).session?.userId,
  // P-008 (4): the building list the models picker and the snag module
  // already load (and cache offline) names the building when no board has
  // been resolved yet this run, so eyebrows aren't blank.
  buildingNameOf: (id) {
    try {
      for (final b in ref.read(snagBuildingsProvider).valueOrNull ?? const []) {
        if (b.id == id) return b.name;
      }
    } catch (_) {}
    return null;
  },
);

class LiveArGateway implements ArGateway {
  LiveArGateway({required this.repository, required this.actorId, this.buildingNameOf});

  final repo.ArRepository repository;
  final String? Function() actorId;

  /// A building's name from elsewhere in the app, when known.
  final String? Function(String buildingId)? buildingNameOf;

  /// The last manifest per floor, so `download` and `features` don't refetch.
  final _manifests = <String, wire.Manifest>{};
  final _focusByFloor = <String, String>{};
  final _buildingNames = <String, String>{};

  @override
  bool get isDemo => false;

  // ------------------------------------------------------------- floors

  @override
  Future<List<ArFloorSummary>> floorsForBuilding(String buildingId) async {
    final floors = await repository.floorsForBuilding(buildingId);
    return [
      for (final f in floors)
        ArFloorSummary(
          floorId: f.floorId,
          name: f.name,
          elevation: f.elevation,
          markerCount: f.markerCount,
          cornerCount: f.cornerCount,
          gridNames: f.gridNames,
          models: [
            for (final m in f.models)
              ArModelEntry(
                lineage: m.lineage,
                modelName: m.modelName,
                state: ArModelState.parse(m.status),
                buildId: m.buildId,
                version: m.version,
                publishedAt: m.publishedAt,
                bytes: m.bytes,
                onDevice: m.onDevice,
                updateAvailable: m.updateAvailable,
                onDeviceBytes: m.onDevice ? m.bytes : 0,
                reason: m.reason,
              ),
          ],
        ),
    ];
  }

  @override
  Future<ArFloorContext> floorContext(String floorId, {String? focusCode}) async {
    final m = await repository.fetchManifest(floorId, focusCode: focusCode);
    _manifests[floorId] = m;
    if (focusCode != null) _focusByFloor[floorId] = focusCode;

    // Richer marker rows (install note, height) when the list is reachable
    // or cached; the manifest's rows are enough to align with.
    final details = <String, wire.ArMarker>{};
    try {
      for (final full in await repository.fetchMarkers(floorId: floorId)) {
        details[full.code] = full;
      }
    } catch (_) {}

    final corners = m.corners;
    final datum = corners.isEmpty ? 0.0 : corners.map((c) => c.posTile.y).reduce((a, b) => a + b) / corners.length;
    final focus = focusCode == null ? null : m.markerByCode(focusCode)?.posTile;
    return ArFloorContext(
      buildingId: m.buildingId,
      buildingName: _buildingNames[m.buildingId] ?? buildingNameOf?.call(m.buildingId) ?? '',
      floorId: m.floorId,
      floorName: m.floorName,
      builds: [for (final b in m.builds) _build(b)],
      tiles: m.tiles,
      markers: [
        for (final mk in m.markers)
          ArMarkerInfo(
            code: mk.code,
            label: mk.label,
            status: mk.status,
            accuracyClass: mk.accuracyClass,
            mounting: mk.mounting,
            posTile: mk.posTile,
            normalTile: mk.normalTile,
            sigmaM: mk.sigmaM,
            floorId: m.floorId,
            heightAboveFloorM: details[mk.code]?.heightAboveFloorM,
            installNote: details[mk.code]?.installNote,
          ),
      ],
      corners: corners,
      gridLines: [for (final g in m.gridLines) ArGridLine(name: g.name, p0: g.p0, p1: g.p1)],
      floorFinishOffsetM: m.floorFinishOffsetM,
      floorDatumY: datum,
      totalBytes: m.totalBytes,
      focusBytes: m.focusTiles(focus).fold<int>(0, (s, t) => s + t.bytes),
      fromCache: m.fromCache,
    );
  }

  ArBuildRef _build(wire.ArBuildRef b) => ArBuildRef(
    buildId: b.buildId,
    lineage: b.lineage,
    modelName: b.modelName,
    version: b.version,
    publishedAt: b.publishedAt,
  );

  @override
  Future<void> download(ArFloorContext floor, {void Function(ArDownloadProgress progress)? onProgress}) async {
    final manifest = _manifests[floor.floorId] ?? await repository.fetchManifest(floor.floorId);
    _manifests[floor.floorId] = manifest;
    final focusCode = _focusByFloor[floor.floorId];
    final focus = focusCode == null ? null : manifest.markerByCode(focusCode)?.posTile;
    // Tiles of the models the user ticked only.
    final buildIds = floor.builds.map((b) => b.buildId).toSet();
    final wanted = manifest.tiles.where((t) => buildIds.contains(t.buildId)).map((t) => t.hash).toSet();
    final scoped = wanted.length == manifest.tiles.length
        ? manifest
        : wire.Manifest(
            buildingId: manifest.buildingId,
            floorId: manifest.floorId,
            floorName: manifest.floorName,
            floorFinishOffsetM: manifest.floorFinishOffsetM,
            builds: manifest.builds,
            tiles: manifest.tiles.where((t) => wanted.contains(t.hash)).toList(),
            features: manifest.features,
            corners: manifest.corners,
            gridLines: manifest.gridLines,
            markers: manifest.markers,
            etag: manifest.etag,
          );
    final total = floor.totalBytes;
    final focusBytes = floor.focusBytes;
    final result = await repository.downloadTiles(
      scoped,
      focusTile: focus,
      onProgress: (p) {
        final alreadyLocal = math.max(0, total - p.bytesTotal);
        final focusDone = p.focusReady
            ? focusBytes
            : (p.focusTilesTotal == 0 ? focusBytes : (focusBytes * p.focusTilesDone / p.focusTilesTotal).round());
        onProgress?.call(ArDownloadProgress(
          focusDoneBytes: focusDone,
          focusTotalBytes: focusBytes,
          doneBytes: math.min(total, alreadyLocal + p.bytesDone),
          totalBytes: total,
        ));
      },
    );
    if (!result.complete) {
      // Surface a stop in the stream as an error the screen words; the
      // tiles already down stay and the next call resumes.
      throw ArDownloadStopped(interrupted: result.interrupted);
    }
    // P-008 (3): keep the tile store under its 1 GB cap. Only tiles no
    // stored manifest references go, least recently used first, so this
    // floor (just stored) is safe. Off the critical path.
    unawaited(repository.gcTiles().then<void>((_) {}, onError: (_) {}));
  }

  @override
  Future<Map<String, String>> tilePaths(List<ArTile> tiles) async {
    final refs = await repository.tileRefs(tiles);
    return {for (final r in refs) r.hash: r.path};
  }

  // ------------------------------------------------------------- resolve

  @override
  Future<ArResolveResult> resolveMarker(String code) async {
    try {
      final r = await repository.resolveMarker(code);
      _buildingNames[r.building.id] = r.building.name;
      final m = r.marker;
      return ArResolved(
        marker: _marker(m),
        building: ArBuildingRef(id: r.building.id, name: r.building.name),
        floorId: r.floor.id,
        floorName: r.floor.name,
        builds: [for (final b in r.builds) _build(b)],
        focusBytes: r.focusBytes,
        totalBytes: r.totalBytes,
        onDeviceBytes: r.packOnDevice ? r.totalBytes : 0,
        badges: r.badges,
        fromCache: r.fromCache,
      );
    } on wire.ArApiError catch (e) {
      return ArResolveFailed(
        code: e.code,
        nearestCode: e.nearest?.code,
        nearestLabel: e.nearest?.label,
        nearestDistanceM: e.nearest?.distanceM,
        message: e.message,
      );
    } catch (_) {
      return const ArResolveFailed(code: 'ERROR');
    }
  }

  ArMarkerInfo _marker(wire.ArMarker m) => ArMarkerInfo(
    code: m.code,
    label: m.label,
    status: m.status,
    accuracyClass: m.accuracyClass,
    mounting: m.mounting,
    posTile: m.posTile ?? Vec3.zero,
    normalTile: m.normalTile ?? const Vec3(1, 0, 0),
    floorId: m.floorId,
    heightAboveFloorM: m.heightAboveFloorM,
    installNote: m.installNote,
  );

  // ---------------------------------------------------------------- plan

  /// The full plans [floorPlan] fetched, for callers that need more than the
  /// mini-plan reduction (the ghost-spot finder's door and equipment clearance).
  final Map<String, wire.FloorPlan> _fullPlans = {};

  wire.FloorPlan? cachedFloorPlan(String floorId) => _fullPlans[floorId];

  @override
  Future<ArPlan?> floorPlan(String floorId) async {
    final wire.FloorPlan p;
    try {
      p = await repository.fetchFloorPlanCorners(floorId);
    } catch (_) {
      return null;
    }
    _fullPlans[floorId] = p;
    final points = <Vec2>[
      for (final w in p.walls) ...w.polyline,
      for (final s in p.spaces) ...s.polygon,
      for (final c in p.corners) c.posTile.xz,
    ];
    final b = p.bounds;
    double minX, minZ, maxX, maxZ;
    if (b != null) {
      minX = b.minX;
      minZ = b.minZ;
      maxX = b.maxX;
      maxZ = b.maxZ;
    } else if (points.isNotEmpty) {
      minX = points.map((v) => v.x).reduce(math.min) - 1;
      maxX = points.map((v) => v.x).reduce(math.max) + 1;
      minZ = points.map((v) => v.y).reduce(math.min) - 1;
      maxZ = points.map((v) => v.y).reduce(math.max) + 1;
    } else {
      return null;
    }
    return ArPlan(
      minX: minX,
      minZ: minZ,
      maxX: maxX,
      maxZ: maxZ,
      walls: [for (final w in p.walls) w.polyline],
      wallThicknesses: [for (final w in p.walls) w.thickness],
      columns: [for (final c in p.columns) c.polygon],
      doors: [
        for (final o in p.openings)
          if (o.kind == 'door') [o.a, o.b],
      ],
      spaces: [
        for (final s in p.spaces)
          if (s.polygon.length >= 3)
            ArPlanSpace(spaceId: s.spaceId, name: s.name, polygon: s.polygon, labelAt: s.labelAt ?? _centroid(s.polygon)),
      ],
      equipment: [
        for (final e in p.equipment)
          ArPlanEquipment(name: e.name ?? '', polygon: e.polygon, globalId: e.globalId, assetId: e.assetId),
      ],
    );
  }

  static Vec2 _centroid(List<Vec2> poly) {
    var x = 0.0, z = 0.0;
    for (final v in poly) {
      x += v.x;
      z += v.y;
    }
    return Vec2(x / poly.length, z / poly.length);
  }

  // ------------------------------------------------------------ features

  @override
  Future<List<ArFeature>> features(ArFloorContext floor, {Set<String>? tileHashes}) async {
    final manifest = _manifests[floor.floorId];
    final out = <ArFeature>[];
    for (final b in floor.builds) {
      String? url;
      for (final ref in manifest?.features ?? const <wire.ManifestFeatureRef>[]) {
        if (ref.buildId == b.buildId) url = ref.url;
      }
      final rows = await repository.fetchFeatures(b.buildId, tileHashes: tileHashes?.toList(), url: url);
      for (final f in rows) {
        final min = f.bboxMin;
        final max = f.bboxMax;
        if (min == null || max == null) continue;
        out.add(ArFeature(
          buildId: f.buildId,
          featureId: f.featureId,
          globalId: f.globalId,
          assetId: f.assetId,
          name: f.name,
          discipline: f.discipline,
          systemGlobalId: f.systemGlobalId,
          // The server sends only the system's GlobalId; a model that names
          // the system in a property set (e.g. "System") gives the readable name.
          systemName: f.prop('System'),
          ifcType: f.ifcType,
          bboxMin: min,
          bboxMax: max,
          floorId: f.floorId,
          tileHashes: {for (final t in f.tiles) t.hash},
          props: f.props,
        ));
      }
    }
    return out;
  }

  // ------------------------------------------------------------ progress

  @override
  Future<ArProgressSnapshot> progress(String floorId) async {
    final p = await repository.fetchProgress(floorId);
    return ArProgressSnapshot(
      entries: {
        for (final s in p.statuses)
          s.globalId: ArProgressEntry(
            globalId: s.globalId,
            status: ArProgressStatus.parse(s.status),
            assetId: s.assetId,
            installedBy: s.installedBy,
            installedAt: s.installedAt,
            verifiedBy: s.verifiedBy,
            verifiedAt: s.verifiedAt,
            note: s.note,
          ),
      },
      total: p.summary.total,
      installed: p.summary.installed,
      verified: p.summary.verified,
      issue: p.summary.issue,
    );
  }

  @override
  Future<ArProgressWriteResult> setProgress({
    required String floorId,
    required List<String> globalIds,
    required ArProgressStatus status,
    String? note,
  }) async {
    try {
      final r = await repository.setProgress(
        floorId: floorId,
        globalIds: globalIds,
        status: status.wire,
        note: note,
        actorId: actorId(),
      );
      return ArProgressWriteResult(
        updated: r.updated,
        queued: r.queued,
        rejected: [for (final x in r.rejected) ArProgressRejection(globalId: x.globalId, reason: x.reason)],
      );
    } on wire.ArApiError catch (e) {
      return ArProgressWriteResult(errorCode: e.code);
    } catch (_) {
      return const ArProgressWriteResult(errorCode: 'ERROR');
    }
  }

  // -------------------------------------------------------------- writes

  @override
  Future<ArWriteResult> bindSpare({
    required String code,
    required String floorId,
    required String buildId,
    required Vec3 posTile,
    required Vec3 normalTile,
    String? label,
    double? sigmaM,
  }) async {
    try {
      final w = await repository.bindSpare(
        code,
        floorId: floorId,
        buildId: buildId,
        posTile: posTile,
        normalTile: normalTile,
        label: label,
        sigmaM: sigmaM,
        buildingId: _manifests[floorId]?.buildingId,
      );
      return ArWriteResult(synced: w.synced, queued: !w.synced, marker: w.data == null ? null : _marker(w.data!));
    } on wire.ArApiError catch (e) {
      return ArWriteResult(errorCode: e.code, message: e.message);
    } catch (_) {
      return const ArWriteResult(errorCode: 'ERROR');
    }
  }

  @override
  Future<ArWriteResult> confirmInstall({
    required String code,
    required String buildId,
    required ArInstallChecks checks,
    Vec3? posTile,
    Vec3? normalTile,
    String? photoPath,
  }) async {
    Uint8List? photo;
    if (photoPath != null) {
      try {
        photo = await File(photoPath).readAsBytes();
      } catch (_) {
        photo = null; // the confirm still goes; the photo is a nice-to-have
      }
    }
    try {
      final w = await repository.confirmInstall(
        code,
        buildId: buildId,
        checks: checks.toJson(),
        posTile: posTile,
        normalTile: normalTile,
        photo: photo,
      );
      return ArWriteResult(synced: w.synced, queued: !w.synced, marker: w.data == null ? null : _marker(w.data!));
    } on wire.ArApiError catch (e) {
      return ArWriteResult(errorCode: e.code, message: e.message);
    } catch (_) {
      return const ArWriteResult(errorCode: 'ERROR');
    }
  }

  @override
  Future<void> postAlignmentEvents(List<ArAlignmentReport> reports) async {
    await repository.postAlignmentEvents([
      for (final r in reports)
        wire.ArAlignmentEvent(
          buildingId: r.buildingId,
          floorId: r.floorId,
          buildIds: r.buildIds,
          observations: [
            for (final o in r.observations)
              wire.ArObservationSummary(
                kind: '${o['kind']}',
                ref: '${o['ref']}',
                residualMm: (o['residualMm'] as num?)?.toDouble() ?? 0,
                posTile: (o['posTile'] as List?)?.map((v) => (v as num).toDouble()).toList(),
              ),
          ],
          maxResidualMm: r.maxResidualMm,
          method: r.method,
          quality: r.quality,
          distanceWalkedM: r.distanceWalkedM,
          deviceTier: r.deviceTier,
          capturedAt: r.capturedAt,
        ),
    ]);
  }
}

/// A floor download that stopped part way (no signal) or had tiles fail.
/// Finished tiles stay on the phone; the next download resumes.
class ArDownloadStopped implements Exception {
  const ArDownloadStopped({required this.interrupted});
  final bool interrupted;

  /// Worded by `arErrorKey`: "network" reads as offline, the rest generic.
  @override
  String toString() => interrupted ? 'network: download interrupted' : 'download failed for some tiles';
}

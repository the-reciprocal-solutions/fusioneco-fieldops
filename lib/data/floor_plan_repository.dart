import '../app/env.dart';
import '../core/c2o/route_download_service.dart';
import '../core/floorplan/floor_plan_image_cache.dart';
import '../core/network/envelope.dart';
import '../core/offline/sync_client.dart';

/// FR-2.8 — a floor's plan image plus every asset already pinned on it.
class FloorPlanRecord {
  const FloorPlanRecord({
    required this.floorId,
    this.floorName,
    this.imageUrl,
    this.pins = const {},
  });

  final String floorId;
  final String? floorName;

  /// Null when this floor has never had a plan image uploaded — distinct
  /// from a download failure, which the image cache reports separately.
  final String? imageUrl;

  /// assetId -> (x%, y%) for every asset on this floor that has been
  /// pinned. Most assets in this dataset have not been, so looking up one
  /// that is not a key here is the normal "not pinned yet" case, not
  /// an error.
  final Map<String, FloorPin> pins;

  FloorPin? pinFor(String assetId) => pins[assetId];

  static FloorPlanRecord? fromJson(String floorId, Map<String, dynamic> json) {
    if (json.isEmpty) return null;

    final pins = <String, FloorPin>{};
    final assets = json['floorAssets'];
    if (assets is List) {
      for (final raw in assets.whereType<Map>()) {
        final a = Map<String, dynamic>.from(raw);
        final id = a['id']?.toString();
        final attrs = a['customAttributes'];
        if (id == null || attrs is! Map) continue;
        final x = _asDouble(attrs['x']);
        final y = _asDouble(attrs['y']);
        if (x == null || y == null) continue;
        pins[id] = FloorPin(xPct: x, yPct: y);
      }
    }

    return FloorPlanRecord(
      floorId: floorId,
      floorName: json['floorName']?.toString(),
      imageUrl: _nonEmptyUrl(json['imageUrl']),
      pins: pins,
    );
  }
}

/// A pin position as a percentage of the image's width/height — stays
/// correct regardless of what size the image renders at.
class FloorPin {
  const FloorPin({required this.xPct, required this.yPct});

  final double xPct;
  final double yPct;
}

/// FR-2.8 — offline-first via the same [SyncClient] cache-then-network
/// pattern as every other read in this app: the floor+pin *metadata* is
/// small JSON and rides the existing sync cache for free. The plan
/// *image*'s bytes are a separate, much larger download handled by
/// [FloorPlanImageCache] — caching those the same way as JSON would blow up
/// the sync cache, which is sized for small records.
class FloorPlanRepository {
  FloorPlanRepository(this._sync);

  final SyncClient _sync;

  Future<FloorPlanRecord?> get(String floorId, {Duration ttl = Env.cacheTtl}) async {
    final read = await _sync.syncGet('/api/floors/floors/$floorId', ttl: ttl);
    final data = unwrap(read.data);
    // `GET /floors/:id` returns its match wrapped in a one-element list
    // (`Floor.findAll({where: {id}})` server-side), not a bare object.
    final floorJson = data is List
        ? (data.whereType<Map>().firstOrNull)
        : (data is Map ? data : null);
    if (floorJson == null) return null;
    return FloorPlanRecord.fromJson(floorId, Map<String, dynamic>.from(floorJson));
  }
}

/// FR-2.8 — what a route download uses to put a floor's plan on the device:
/// the floor record into the sync cache (where [FloorPlanScreen] reads it)
/// and the image into [FloorPlanImageCache].
class RouteFloorPlanPrefetcher implements FloorPlanPrefetcher {
  RouteFloorPlanPrefetcher(this._repository, this._images);

  /// Longer than the default 24h cache: an expired entry is never served,
  /// even offline, and a route is used for up to a day after download. A
  /// plan is only looked at, never verified against, so a week is safe.
  static const recordTtl = Duration(days: 7);

  final FloorPlanRepository _repository;
  final FloorPlanImageCache _images;

  @override
  Future<void> prefetch(String floorId) async {
    final record = await _repository.get(floorId, ttl: recordTtl);
    final imageUrl = record?.imageUrl;
    if (imageUrl != null) await _images.getOrDownload(imageUrl);
  }
}

String? _nonEmptyUrl(dynamic v) {
  final s = v?.toString();
  if (s == null || s.isEmpty) return null;
  // Seed/demo data carries placeholder paths like "/images/floors/x.jpg"
  // that were never actually uploaded anywhere and 404 — indistinguishable
  // from "no plan" to a technician, so treated the same rather than shown
  // as a broken image.
  if (!s.startsWith('http://') && !s.startsWith('https://')) return null;
  return s;
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

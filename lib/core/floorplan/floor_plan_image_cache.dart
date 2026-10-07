import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// FR-2.8's offline support for the floor-plan *image* — deliberately
/// separate from [FloorPlanRepository]/[SyncClient], which only ever cache
/// small JSON. A floor plan is a few MB of image bytes; caching that the
/// same way would blow up the JSON cache's expected size, so it gets its
/// own store: a plain file on disk, downloaded once and kept until the
/// image's URL changes (a re-upload gets a new URL, so the old file is
/// simply never looked up again — no explicit invalidation needed).
///
/// Never prefetched per scan — these files are too large for that. Filled
/// either on first open, or when a route is downloaded (the technician is
/// deliberately preparing to lose signal, and a route touches few floors —
/// see `RouteFloorPlanPrefetcher`).
class FloorPlanImageCache {
  FloorPlanImageCache({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// The cached file for [imageUrl], or null if it has never been
  /// downloaded (or the on-disk copy has gone missing). Never touches the
  /// network — safe to call to decide whether a download is needed at all.
  Future<File?> cached(String imageUrl) async {
    final file = await _fileFor(imageUrl);
    return file.existsSync() ? file : null;
  }

  /// Returns the cached copy if one exists; otherwise downloads it and
  /// writes it to disk first. Throws on a network failure — the caller
  /// (already holding the offline-first "check [cached] first" result)
  /// decides how to present that as "not available offline yet" rather
  /// than a generic error.
  Future<File> getOrDownload(String imageUrl) async {
    final existing = await cached(imageUrl);
    if (existing != null) return existing;

    final file = await _fileFor(imageUrl);
    await file.parent.create(recursive: true);

    final response = await _dio.get<List<int>>(
      imageUrl,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null) {
      throw StateError('Floor plan download returned no data: $imageUrl');
    }

    // Write to a temp file first — a crash or kill mid-write must never
    // leave a truncated file sitting under the real cache key, which
    // [cached] would then treat as a good, complete download forever.
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file;
  }

  Future<File> _fileFor(String imageUrl) async {
    final dir = await getApplicationSupportDirectory();
    final ext = _extensionFor(imageUrl);
    return File(p.join(dir.path, 'floor_plans', '${_keyFor(imageUrl)}$ext'));
  }

  String _keyFor(String url) => url.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  String _extensionFor(String url) {
    final ext = p.extension(Uri.parse(url).path);
    return ext.isEmpty ? '.img' : ext;
  }
}

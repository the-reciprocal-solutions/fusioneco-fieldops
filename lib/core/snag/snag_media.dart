import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/snag.dart';

/// Snag photos and voice notes on disk, under `<documents>/snag_media/`.
///
/// Two kinds of file live here:
/// - **own captures** (`own/<snagId>/<evidenceId>.<ext>`): written the moment
///   a snag is raised, so the list, the detail screen and the duplicate
///   guard show the photo with no network — and keep showing it after sync
///   (the evidence row keeps its `localPath`).
/// - **downloaded copies** (`cache/<hash>.<ext>`): other people's photos,
///   fetched by "Download for offline" so a verifier standing in a basement
///   can still compare before and after.
///
/// The queue carries its own copy of the bytes for upload (`PendingAttachment`)
/// — deliberately separate, so clearing one can never lose the other.
class SnagMedia {
  /// [rootDir] is for tests; the app resolves `<documents>/snag_media`.
  SnagMedia({Dio? dio, Directory? rootDir}) : _dio = dio ?? Dio(), _root = rootDir;

  final Dio _dio;
  Directory? _root;

  /// Resolved files by evidence key, so a list rebuild (every snag write
  /// bumps the tick) does not re-stat every thumbnail — and a [SnagPhoto]
  /// can paint the file on its first frame instead of flashing blank.
  final _resolved = <String, File>{};

  static const _folder = 'snag_media';

  Future<Directory> _rootDir() async {
    return _root ??= Directory(p.join((await getApplicationDocumentsDirectory()).path, _folder));
  }

  Future<Directory> _dir(String sub) async {
    final dir = Directory(p.join((await _rootDir()).path, sub));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// The same file under today's root. **iOS moves the app's container on
  /// every app update or reinstall** (a new TestFlight build included): the
  /// UUID in `/var/mobile/Containers/Data/Application/<UUID>/Documents` is
  /// new, the files come along, but every absolute path stored before the
  /// update points at a folder that no longer exists. Own captures saved
  /// their absolute path into the snag row, so after an update the photos of
  /// every unsent snag "disappeared" and a re-send went out without them
  /// (2026-10-06). Re-rooting on the `snag_media/` segment finds them again.
  /// Pure, for tests. Null when [stored] is not under a `snag_media` folder.
  static String? reroot(String stored, String currentRoot) {
    final normalised = stored.replaceAll(r'\', '/');
    const marker = '/$_folder/';
    final at = normalised.lastIndexOf(marker);
    if (at < 0) return null;
    final rest = normalised.substring(at + marker.length);
    if (rest.isEmpty) return null;
    return p.joinAll([currentRoot, ...rest.split('/')]);
  }

  /// A developer diagnostics file under `snag_media/diag/` (the snag
  /// integrity log). Lives beside the photos because, unlike `sync_meta`,
  /// this folder survives sign-out.
  Future<File> diagnosticsFile(String name) async => File(p.join((await _dir('diag')).path, name));

  /// True when [stored] is this device's own capture for [snagId]
  /// (`own/<snagId>/<evidenceId>.<ext>`). The folder is named by the snag id
  /// at capture time, so it proves which snag a photo was taken for. Pure.
  static bool isOwnCaptureFor(String stored, String snagId) =>
      stored.replaceAll(r'\', '/').contains('/$_folder/own/$snagId/');

  /// Synchronous peek at an already-resolved file, for a first-frame paint.
  File? peek(SnagEvidence e) => _resolved[_key(e)];

  static String _key(SnagEvidence e) => '${e.id}|${e.localPath ?? ''}|${e.url ?? ''}';

  /// Writes an own capture and returns its absolute path.
  Future<String> saveOwn({
    required String snagId,
    required String evidenceId,
    required Uint8List bytes,
    String extension = 'jpg',
  }) async {
    final dir = await _dir(p.join('own', snagId));
    final file = File(p.join(dir.path, '$evidenceId.$extension'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// The best local file for [e]: the own capture if it still exists, else a
  /// downloaded copy of its URL. Null means "only the network has it".
  Future<File?> localFile(SnagEvidence e) async {
    final key = _key(e);
    final hit = _resolved[key];
    if (hit != null && hit.existsSync()) return hit;
    final own = e.localPath;
    if (own != null) {
      final f = await ownFile(own);
      if (f != null) return _resolved[key] = f;
    }
    final url = e.url;
    if (url == null) return null;
    final cached = await _cacheFile(url);
    return cached.existsSync() ? _resolved[key] = cached : null;
  }

  /// An own capture by its stored path, re-rooted if the app container moved
  /// (see [reroot]). Null when the file is gone.
  Future<File?> ownFile(String stored) async {
    final f = File(stored);
    if (f.existsSync()) return f;
    final moved = reroot(stored, (await _rootDir()).path);
    if (moved == null) return null;
    final g = File(moved);
    return g.existsSync() ? g : null;
  }

  /// Downloads [url] into the cache unless it is already there. Writes to a
  /// `.part` file first so a kill mid-download never leaves a truncated file
  /// under the real name (same rule as `FloorPlanImageCache`).
  Future<File> download(String url) async {
    final file = await _cacheFile(url);
    if (file.existsSync()) return file;
    final response = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) throw StateError('Empty download: $url');
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file;
  }

  /// Best-effort bulk download; returns how many files are now available
  /// offline. A single failure never stops the rest.
  Future<int> prefetch(Iterable<SnagEvidence> evidence) async {
    var ok = 0;
    for (final e in evidence) {
      if (!e.isPhoto) continue;
      if (await localFile(e) != null) {
        ok++;
        continue;
      }
      final url = e.url;
      if (url == null) continue;
      try {
        await download(url);
        ok++;
      } catch (_) {
        // Keep going: one missing photo shouldn't cost the other fifty.
      }
    }
    return ok;
  }

  Future<File> _cacheFile(String url) async {
    final dir = await _dir('cache');
    final uri = Uri.tryParse(url);
    final ext = p.extension(uri?.path ?? '').replaceAll('.', '');
    // A stable, filesystem-safe key without pulling in a hashing package.
    final key = url.codeUnits.fold<int>(0x811c9dc5, (h, c) => ((h ^ c) * 0x01000193) & 0xffffffff);
    final name = '${key.toRadixString(16)}_${url.length}.${ext.isEmpty ? 'jpg' : ext}';
    return File(p.join(dir.path, name));
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The start / end of day pictures on disk, under
/// `<documents>/job_visit_media/<eventId>/in.jpg` and `out.jpg`.
///
/// The day row stores the RELATIVE path (`<eventId>/in.jpg`), never an
/// absolute one: iOS moves the app container on every update or reinstall, so
/// an absolute path saved before an update points at a folder that no longer
/// exists (the snag photos lost this way on 2026-10-06, see [SnagMedia.reroot]).
///
/// The offline queue carries its own copy of the bytes for the upload, so
/// deleting or losing one can never lose the other.
class CaptureMedia {
  /// [rootDir] is for tests; the app resolves `<documents>/job_visit_media`.
  CaptureMedia({Directory? rootDir}) : _root = rootDir;

  Directory? _root;

  // Folder name kept from the first build so pictures already on a phone still resolve.
  static const _folder = 'job_visit_media';

  Future<Directory> _rootDir() async =>
      _root ??= Directory(p.join((await getApplicationDocumentsDirectory()).path, _folder));

  /// `<eventId>/in.jpg` or `<eventId>/out.jpg`. Pure.
  static String relativePath(String eventId, {required bool isCheckIn}) =>
      p.join(eventId, isCheckIn ? 'in.jpg' : 'out.jpg');

  /// Writes the picture and returns the relative path to store on the day.
  /// Written before the day row, so a day never points at a missing file.
  Future<String> save(String eventId, Uint8List bytes, {required bool isCheckIn}) async {
    final rel = relativePath(eventId, isCheckIn: isCheckIn);
    final file = File(p.join((await _rootDir()).path, rel));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return rel;
  }

  /// The file for a stored relative path, or null if it is gone.
  Future<File?> file(String? relative) async {
    if (relative == null || relative.isEmpty) return null;
    final f = File(p.join((await _rootDir()).path, relative));
    return f.existsSync() ? f : null;
  }
}

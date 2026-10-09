import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'push_content.dart';

/// Downloads the photo a push names (`imageUrl`) for the rich notification:
/// Android BigPicture (bytes) and the iOS attachment (a file — iOS only
/// attaches a file it can read, with a real image extension).
///
/// Runs in the FCM background isolate as well as the app, so it uses
/// `dart:io` only (no Dio, no session): the URL is a public or pre-signed one
/// the server chose for exactly this. Any failure — slow network in a plant
/// room, a 403 on an expired signature, not an image, too big — returns null
/// and the notification is drawn without the picture (BigText instead).
class NotificationImages {
  NotificationImages._();

  static const timeout = Duration(seconds: 6);
  static const maxBytes = 5 * 1024 * 1024;

  static Future<Uint8List?> download(String? url) async {
    if (url == null || !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return null;
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final type = response.headers.contentType?.mimeType ?? '';
      if (type.isNotEmpty && !type.startsWith('image/')) return null;
      if (response.contentLength > maxBytes) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) return null;
      }
      final bytes = builder.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Writes [bytes] where iOS can attach them. iOS moves the file into its
  /// own store when the notification is posted, so a fresh name each time.
  static Future<String?> saveForAttachment(Uint8List bytes, String url, {required String key}) async {
    try {
      Directory dir;
      try {
        dir = await getTemporaryDirectory();
      } catch (_) {
        dir = Directory.systemTemp;
      }
      final ext = extensionFor(url, bytes);
      final file = File('${dir.path}/fe_push_${pushIdFor(key)}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// jpg | png | gif | heic from the magic bytes, else from the URL path,
  /// else jpg (iOS refuses an attachment without a known image extension).
  static String extensionFor(String url, Uint8List bytes) {
    if (bytes.length >= 4) {
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return 'png';
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return 'gif';
    }
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['png', 'gif', 'heic', 'jpeg', 'jpg']) {
      if (path.endsWith('.$ext')) return ext == 'jpeg' ? 'jpg' : ext;
    }
    return 'jpg';
  }
}

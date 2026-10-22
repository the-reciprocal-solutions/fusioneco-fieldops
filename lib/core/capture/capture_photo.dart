
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'capture_services.dart';

/// The start / end of day photo (docs/daily-attendance-shift-plan.md).
///
/// - **Live camera only**: no gallery picker, so an old or borrowed picture
///   cannot be used. The front camera (a selfie) is the decided photo type.
/// - **1280 px long edge, JPEG q75** (about 150-250 KB): a basement shift can
///   queue many of these, and smaller files finish uploading on a weak link.
///   Deliberately smaller than the 1600 px field-photo rule.
/// - **A stamp is burned into the picture** (time, job, position), so the
///   photo carries its own evidence when someone opens it later.
class CapturePhoto {
  const CapturePhoto({required this.bytes, required this.fileName});
  final Uint8List bytes;
  final String fileName;
}

const kCapturePhotoMaxEdge = 1280;
const kCapturePhotoQuality = 75;

/// Opens the system camera (front) and returns the picture, or null if the
/// technician backed out. NOT stamped yet: the position may still be arriving
/// while the camera is open, so the stamp is applied afterwards by
/// [stampPhoto], once the fix is known.
Future<CapturePhoto?> takeCapturePhoto({ImagePicker? picker}) async {
  final file = await (picker ?? ImagePicker()).pickImage(
    source: ImageSource.camera,
    preferredCameraDevice: CameraDevice.front,
    maxWidth: kCapturePhotoMaxEdge.toDouble(),
    imageQuality: kCapturePhotoQuality,
  );
  if (file == null) return null;
  return CapturePhoto(
    bytes: await file.readAsBytes(),
    fileName: 'capture-${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
}

/// Burns [lines] into [photo]. Decoding and re-encoding is real CPU work, so it
/// runs off the main isolate and the confirm sheet does not jank.
Future<CapturePhoto> stampPhoto(CapturePhoto photo, List<String> lines) async {
  final stamped = await compute(_stampJob, _StampJob(photo.bytes, lines));
  return CapturePhoto(bytes: stamped, fileName: photo.fileName);
}

class _StampJob {
  const _StampJob(this.bytes, this.lines);
  final Uint8List bytes;
  final List<String> lines;
}

Uint8List _stampJob(_StampJob j) => stampCapturePhoto(j.bytes, j.lines);

/// Downscales to [kCapturePhotoMaxEdge] and burns [lines] into a dark band along
/// the bottom. Pure (bytes in, bytes out), so it is testable. If the bytes are
/// not an image, they are returned unchanged: a photo must never be lost
/// because of a stamping problem.
Uint8List stampCapturePhoto(Uint8List bytes, List<String> lines) {
  try {
    var image = img.decodeImage(bytes);
    if (image == null) return bytes;

    final longest = image.width > image.height ? image.width : image.height;
    if (longest > kCapturePhotoMaxEdge) {
      image = image.width >= image.height
          ? img.copyResize(image, width: kCapturePhotoMaxEdge)
          : img.copyResize(image, height: kCapturePhotoMaxEdge);
    }

    final font = image.width >= 900 ? img.arial24 : img.arial14;
    final lineHeight = font.lineHeight + 4;
    final band = lineHeight * lines.length + 8;
    final top = image.height - band;
    if (top > 0 && lines.isNotEmpty) {
      img.fillRect(
        image,
        x1: 0,
        y1: top,
        x2: image.width,
        y2: image.height,
        color: img.ColorRgba8(0, 0, 0, 170),
      );
      for (var i = 0; i < lines.length; i++) {
        img.drawString(
          image,
          lines[i],
          font: font,
          x: 8,
          y: top + 4 + i * lineHeight,
          color: img.ColorRgb8(255, 255, 255),
        );
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: kCapturePhotoQuality));
  } catch (_) {
    return bytes;
  }
}

/// The same photo as the capture services' type, for the queue.
CapturedPhoto asCaptured(CapturePhoto p) => CapturedPhoto(bytes: p.bytes, fileName: p.fileName);

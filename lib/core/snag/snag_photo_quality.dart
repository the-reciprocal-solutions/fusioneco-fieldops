import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// On-device photo checks for the AI assist (2026-10-06). Run with
/// `compute(prepareSnagPhotoForAi, bytes)` — decoding is real CPU work.
///
/// Two jobs:
/// 1. a small JPEG (longest edge [kAiPhotoEdge]) for the assistant: the
///    image is most of the model's prompt, and a 768 px copy answered in
///    ~8.5 s where a 1952 px one took ~10 s (measured on the live engine);
/// 2. brightness and sharpness, so "too dark" / "blurry" tips show even
///    offline. Thresholds are mirrored by the server
///    (`services/snag/snagAiAssist.ts` `tipsFromQuality`); change both.
///    They are heuristics calibrated on desk photos only — not yet tuned on
///    a real plant room (see PENDING).
const kAiPhotoEdge = 768;
const kTooDarkBelow = 0.22;
const kBlurryBelow = 0.12;

class SnagPhotoPrep {
  const SnagPhotoPrep({required this.jpeg, required this.brightness, required this.sharpness});

  /// Downscaled JPEG for the assistant (the original stays the evidence).
  final Uint8List jpeg;

  /// Mean luminance, 0 (black) … 1 (white).
  final double brightness;

  /// Mean Laplacian edge energy, normalised 0 … 1 (higher = sharper).
  final double sharpness;

  /// Tip codes the phone can tell by itself (`kSnagCaptureTips`).
  List<String> get deviceTips => snagQualityTips(brightness: brightness, sharpness: sharpness);
}

List<String> snagQualityTips({required double brightness, required double sharpness}) => [
  if (brightness < kTooDarkBelow) 'too_dark',
  if (sharpness < kBlurryBelow) 'blurry',
];

/// Null when the bytes are not an image this package can decode (HEIC).
SnagPhotoPrep? prepareSnagPhotoForAi(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // The format sniffers throw on short or corrupt input instead of
    // returning null.
    decoded = null;
  }
  if (decoded == null) return null;
  final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
  final small = longest <= kAiPhotoEdge
      ? decoded
      : (decoded.width >= decoded.height
            ? img.copyResize(decoded, width: kAiPhotoEdge)
            : img.copyResize(decoded, height: kAiPhotoEdge));
  final jpeg = Uint8List.fromList(img.encodeJpg(small, quality: 75));
  final (brightness, sharpness) = measureLumaQuality(small);
  return SnagPhotoPrep(jpeg: jpeg, brightness: brightness, sharpness: sharpness);
}

/// Brightness and sharpness on a 160 px greyscale copy. Pure, for tests.
(double, double) measureLumaQuality(img.Image source) {
  final probe = source.width > 160 || source.height > 160
      ? (source.width >= source.height ? img.copyResize(source, width: 160) : img.copyResize(source, height: 160))
      : source;
  final w = probe.width;
  final h = probe.height;
  if (w < 3 || h < 3) return (0.5, 1.0);
  final luma = List<double>.filled(w * h, 0);
  var sum = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = probe.getPixel(x, y);
      final l = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      luma[y * w + x] = l;
      sum += l;
    }
  }
  final maxChannel = probe.maxChannelValue.toDouble();
  final brightness = (sum / (w * h)) / maxChannel;
  var energy = 0.0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final lap = 4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - w] - luma[i + w];
      energy += lap.abs();
    }
  }
  final meanLap = energy / ((w - 2) * (h - 2)) / maxChannel * 255;
  // ~4.8 grey levels of mean edge energy maps to the 0.12 "blurry" cut.
  final sharpness = (meanLap / 40).clamp(0.0, 1.0);
  return (brightness.clamp(0.0, 1.0), sharpness);
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

/// A photo held in memory until it is uploaded — either straight away, or by
/// the offline queue on the next flush.
class CapturedPhoto {
  const CapturedPhoto({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;

  /// MIME type inferred from the file's extension. `_take`'s maxWidth/
  /// imageQuality resize does not force every output to JPEG — a PNG picked
  /// from the gallery (a screenshot, say) stays a PNG — so this can't be
  /// hard-coded. Falls back to JPEG, what the camera and most gallery photos
  /// actually are.
  String get mimeType {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'gif':
        return 'image/gif';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }

  /// The exact `data:<mime>;base64,<data>` shape the AI chat endpoint expects
  /// for an attached image (`POST /api/fm/ai/technician-checklist/chat`'s
  /// `images` array) — see `fmAgentCore.ts`'s inline-data regex on the server.
  String get dataUrl => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

class CapturedLocation {
  const CapturedLocation({
    required this.latitude,
    required this.longitude,
    this.city,
    this.district,
    this.accuracyMeters,
  });

  final double latitude;
  final double longitude;

  /// The radius the device reports the fix is good to. FR-3.9 sends it with
  /// a check, so a 5 m fix and a stale 500 m last-known one are told apart.
  final double? accuracyMeters;

  /// Place names for the coordinates, when the device could resolve them.
  /// Always optional: the coordinates are the record, these two are the
  /// readable label put beside them.
  final String? city;
  final String? district;

  /// "Tiruppur, Tamil Nadu" — or null when neither name resolved, so callers
  /// can fall back to printing the numbers.
  String? get placeLabel {
    final parts = [city, district].where((p) => p != null && p.isNotEmpty);
    return parts.isEmpty ? null : parts.join(', ');
  }
}

/// Thrown when the technician can be told what to do about it.
class CaptureFailure implements Exception {
  const CaptureFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Downscales a captured JPEG so its longest edge is at most 1600px —
/// `_take`'s `maxWidth: 1600` below, for the one capture path that can't go
/// through `image_picker` to get it for free: `camera_capture_screen.dart`
/// owns the live preview itself (for the torch button and bubble level,
/// which `image_picker`'s OS-camera-app handoff can't support), so it reads
/// raw bytes straight off `CameraController.takePicture()` with no resize
/// step of its own. Top-level with no optional params so it can be handed
/// directly to `compute()` — decoding and re-encoding a full-res photo is
/// real CPU work, and doing it on the main isolate would jank the
/// capture-confirm UI.
Uint8List downscaleJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  const maxEdge = 1600;
  final longestEdge = decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longestEdge <= maxEdge) return bytes;
  final resized = decoded.width >= decoded.height
      ? img.copyResize(decoded, width: maxEdge)
      : img.copyResize(decoded, height: maxEdge);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
}

class PhotoCapture {
  PhotoCapture([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Verification selfie. The web runs a live webcam preview; the system
  /// camera is the equivalent that works across Android and iOS without
  /// shipping a preview surface of our own.
  Future<CapturedPhoto?> takeFacePhoto() => _take(
    source: ImageSource.camera,
    camera: CameraDevice.front,
    fallbackName: 'face-capture.jpg',
  );

  /// [maxWidth] mirrors an inspection photo field's `compressToWidth`
  /// (web default 1600, `FormRenderer.tsx`'s `downscaleImage`) — kept
  /// overridable per call rather than hard-coded so a schema-specified
  /// width can flow through from `InspectionField.compressToWidth`.
  Future<CapturedPhoto?> takeJobPhoto({double maxWidth = 1600}) => _take(
    source: ImageSource.camera,
    camera: CameraDevice.rear,
    fallbackName: 'photo.jpg',
    maxWidth: maxWidth,
  );

  Future<CapturedPhoto?> pickFromGallery({double maxWidth = 1600}) => _take(
    source: ImageSource.gallery,
    fallbackName: 'attachment.jpg',
    maxWidth: maxWidth,
  );

  /// The inspection `file` field type stores whatever bytes the device hands
  /// back with no resize/re-encode at all — matching the web, which reads
  /// the picked file straight via `FileReader.readAsDataURL` with no
  /// compression step (unlike the `photo` field type's `downscaleImage`).
  Future<CapturedPhoto?> takeRawPhoto() => _take(
    source: ImageSource.camera,
    camera: CameraDevice.rear,
    fallbackName: 'photo.jpg',
    maxWidth: null,
    imageQuality: null,
  );

  Future<CapturedPhoto?> pickRawFromGallery() => _take(
    source: ImageSource.gallery,
    fallbackName: 'attachment.jpg',
    maxWidth: null,
    imageQuality: null,
  );

  Future<CapturedPhoto?> _take({
    required ImageSource source,
    required String fallbackName,
    CameraDevice camera = CameraDevice.rear,
    double? maxWidth = 1600,
    int? imageQuality = 80,
  }) async {
    final file = await _picker.pickImage(
      source: source,
      preferredCameraDevice: camera,
      // Field photos go straight into object storage and are only ever viewed
      // on a phone; full-resolution originals waste the technician's data.
      // Null (the `file`-field path) skips this entirely.
      maxWidth: maxWidth,
      imageQuality: imageQuality,
    );
    if (file == null) return null;
    return CapturedPhoto(
      bytes: await file.readAsBytes(),
      fileName: file.name.isEmpty ? fallbackName : file.name,
    );
  }
}

class LocationCapture {
  final _geocoding = Geocoding();

  /// Coordinates, plus the place names for them when the device can supply
  /// them.
  ///
  /// The web resolves names from the browser's *IP address* through
  /// ipgeolocation.io, which reports where the internet connection appears to
  /// be — on mobile data that is the carrier's gateway, often a different
  /// city. Here the names are reverse-geocoded from the GPS fix we already
  /// hold, by the operating system's own geocoder (Android's `Geocoder`,
  /// iOS's `CLGeocoder`). No API key to ship, nothing billed per lookup, and
  /// the answer describes where the technician actually stands.
  Future<CapturedLocation> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const CaptureFailure(
        'Turn on location services to record where this task was worked.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const CaptureFailure('Please enable location access to proceed.');
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        // `.high` holds out for a GPS-grade fix, which routinely fails to
        // ever arrive with no signal indoors — a fresh fix this precise is
        // not worth blocking the job over. `.medium` is satisfied by
        // network- or cell-assisted positioning too, so it settles quickly
        // in exactly the conditions `.high` was timing out in.
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return await _named(position.latitude, position.longitude, position.accuracy);
    } catch (_) {
      // A fresh fix can still fail outright — no GPS lock and no network to
      // assist with one. The device's last fix is usually close enough to
      // say which site the technician is at, and it comes back from cache
      // instantly rather than needing signal at all.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return _named(last.latitude, last.longitude, last.accuracy);
      throw const CaptureFailure('Could not get your location.');
    }
  }

  /// Attaches place names to a fix, and never fails because of them: a device
  /// with no geocoder backend, no network, or an unnamed spot in the middle of
  /// a field still returns its coordinates. Losing the label must never cost
  /// us the location that gates the job.
  Future<CapturedLocation> _named(double lat, double lng, double accuracy) async {
    // Geolocator reports 0 when the platform gives no accuracy at all.
    final accuracyMeters = accuracy > 0 ? accuracy : null;
    try {
      final places = await _geocoding
          .placemarkFromCoordinates(lat, lng)
          .timeout(const Duration(seconds: 5));
      if (places.isEmpty) {
        return CapturedLocation(latitude: lat, longitude: lng, accuracyMeters: accuracyMeters);
      }

      final place = places.first;
      final city = _firstNamed([
        place.locality,
        place.subLocality,
        place.subAdministrativeArea,
      ]);
      // The district proper, falling back to the state — and never the same
      // word twice, which is common where a city names its own district.
      final district = _firstNamed([
        if (place.subAdministrativeArea != city) place.subAdministrativeArea,
        place.administrativeArea,
      ]);

      return CapturedLocation(
        latitude: lat,
        longitude: lng,
        city: city,
        district: district,
        accuracyMeters: accuracyMeters,
      );
    } catch (_) {
      return CapturedLocation(latitude: lat, longitude: lng, accuracyMeters: accuracyMeters);
    }
  }

  static String? _firstNamed(List<String?> candidates) {
    for (final c in candidates) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return null;
  }
}

class VoiceRecording {
  const VoiceRecording({
    required this.bytes,
    required this.fileName,
    required this.duration,
  });

  final Uint8List bytes;
  final String fileName;
  final Duration duration;

  /// The exact `data:<mime>;base64,<data>` shape the AI chat endpoint expects
  /// for an attached voice note (`POST /api/fm/ai/technician-checklist/chat`'s
  /// `audio` field) — see `fmAgentCore.ts`'s inline-data regex on the server.
  /// `VoiceCapture` always records with the `record` package's default
  /// encoder (AAC-LC) into an `.m4a` file, so the codec — not the container —
  /// is declared here: Gemini's documented audio mime allow-list has
  /// `audio/aac` but no separate `audio/mp4`/`audio/x-m4a` entry.
  String get dataUrl => 'data:audio/aac;base64,${base64Encode(bytes)}';
}

class VoiceCapture {
  VoiceCapture([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  /// The web caps a recording at three minutes; the same cap keeps a stray
  /// running recorder from producing an unsendable file.
  static const maxDuration = Duration(minutes: 3);

  final AudioRecorder _recorder;
  String? _path;
  DateTime? _startedAt;

  bool get isRecording => _startedAt != null;

  /// Live mic level while recording, for a waveform display. Only emits
  /// between [start] and [stop]/[cancel] — the underlying recorder has
  /// nothing to report outside that window.
  Stream<Amplitude> amplitudeStream({
    Duration interval = const Duration(milliseconds: 100),
  }) => _recorder.onAmplitudeChanged(interval);

  Future<void> start(String directory) async {
    if (!await _recorder.hasPermission()) {
      throw const CaptureFailure(
        'Microphone access is needed to record a voice note.',
      );
    }
    final path = '$directory/note-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: path);
    _path = path;
    _startedAt = DateTime.now();
  }

  /// Returns null when the recorder produced nothing to send.
  Future<VoiceRecording?> stop() async {
    final startedAt = _startedAt;
    _startedAt = null;
    await _recorder.stop();

    final path = _path;
    _path = null;
    if (path == null || startedAt == null) return null;

    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();
    if (bytes.isEmpty) return null;

    return VoiceRecording(
      bytes: bytes,
      fileName: path.split(Platform.pathSeparator).last,
      duration: DateTime.now().difference(startedAt),
    );
  }

  Future<void> cancel() async {
    _startedAt = null;
    await _recorder.cancel();
    final path = _path;
    _path = null;
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  Future<void> dispose() => _recorder.dispose();
}

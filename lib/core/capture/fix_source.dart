import 'package:geolocator/geolocator.dart';

import '../../domain/capture.dart';

/// Where a start / end of day position comes from. An interface so the
/// fallback ladder below is tested without a phone.
abstract interface class FixSource {
  /// Never throws. A phone with GPS off, no permission, or no sky still
  /// answers, with [FixKind.none]: the technician is never stuck.
  Future<CaptureFix> acquire();
}

/// One try at a fresh position. Returns null on timeout or failure.
typedef PositionTry = Future<Position?> Function(LocationAccuracy accuracy, Duration limit);

/// The ladder. GPS itself needs no
/// network, so this works fully offline:
///
///   1. services on? permission? (ask once)        else  none
///   2. fresh fix, medium accuracy, 10 s            -> gps
///   3. fresh fix, low accuracy (cell/Wi-Fi), 5 s   -> gps
///   4. the phone's last remembered position        -> lastKnown (age kept)
///   5. nothing                                     -> none
///
/// No reverse geocoding: attendance needs coordinates only, and a place-name
/// lookup is one more thing that can fail with no signal.
class LadderFixSource implements FixSource {
  LadderFixSource({
    Future<bool> Function()? serviceEnabled,
    Future<LocationPermission> Function()? checkPermission,
    Future<LocationPermission> Function()? requestPermission,
    PositionTry? tryFresh,
    Future<Position?> Function()? lastKnown,
    DateTime Function()? now,
  }) : _serviceEnabled = serviceEnabled ?? Geolocator.isLocationServiceEnabled,
       _checkPermission = checkPermission ?? Geolocator.checkPermission,
       _requestPermission = requestPermission ?? Geolocator.requestPermission,
       _tryFresh = tryFresh ?? _geolocatorTry,
       _lastKnown = lastKnown ?? Geolocator.getLastKnownPosition,
       _now = now ?? DateTime.now;

  final Future<bool> Function() _serviceEnabled;
  final Future<LocationPermission> Function() _checkPermission;
  final Future<LocationPermission> Function() _requestPermission;
  final PositionTry _tryFresh;
  final Future<Position?> Function() _lastKnown;
  final DateTime Function() _now;

  static const mediumLimit = Duration(seconds: 10);
  static const lowLimit = Duration(seconds: 5);

  static Future<Position?> _geolocatorTry(LocationAccuracy accuracy, Duration limit) async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: accuracy, timeLimit: limit),
      );
    } catch (_) {
      return null;
    }
  }

  CaptureFix _fromPosition(Position p, FixKind kind, {int? ageSeconds}) => CaptureFix(
    kind: kind,
    lat: p.latitude,
    lng: p.longitude,
    accuracyM: p.accuracy,
    mock: p.isMocked,
    ageSeconds: ageSeconds,
  );

  @override
  Future<CaptureFix> acquire() async {
    try {
      if (!await _serviceEnabled()) return const CaptureFix.none();

      var permission = await _checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const CaptureFix.none();
      }

      final medium = await _tryFresh(LocationAccuracy.medium, mediumLimit);
      if (medium != null) return _fromPosition(medium, FixKind.gps);

      final low = await _tryFresh(LocationAccuracy.low, lowLimit);
      if (low != null) return _fromPosition(low, FixKind.gps);

      final last = await _lastKnown();
      if (last != null) {
        final age = _now().difference(last.timestamp).inSeconds;
        return _fromPosition(last, FixKind.lastKnown, ageSeconds: age < 0 ? 0 : age);
      }
    } catch (_) {
      // Any plugin failure degrades to "no fix"; it must never block a check-in.
    }
    return const CaptureFix.none();
  }
}

import 'ar_engine.dart';

/// The room scan shown during AR setup: how much of the room the device has
/// measured, and when the animated scan overlay should show. Pure, so the
/// rules are tested without a device (test/ar_scan_overlay_test.dart).
///
/// The native side draws the overlay (fe_ar `setScanOverlay`: the LiDAR mesh
/// on iPhones and iPads that have it, an animated plane grid elsewhere) and
/// reports what it found ([ScanProgressEvent], at most 1 Hz).
class ScanProgress {
  const ScanProgress({
    this.mesh = false,
    this.walls = 0,
    this.floors = 0,
    this.floorM2 = 0,
    this.wallM2 = 0,
  });

  factory ScanProgress.fromEvent(ScanProgressEvent e) => ScanProgress(
        mesh: e.source == 'mesh',
        walls: e.walls,
        floors: e.floors,
        floorM2: e.floorM2,
        wallM2: e.wallM2,
      );

  /// Measured by the depth sensor's mesh (LiDAR), not just tracked planes.
  final bool mesh;
  final int walls;
  final int floors;
  final double floorM2;
  final double wallM2;

  /// What setup needs measured around the corners it snaps: a patch of floor
  /// and the two walls either side of a corner (about 1.5 m wide × 2 m high
  /// each). Generous enough that 100 % means "snaps will find surfaces",
  /// not "the whole room is scanned".
  static const targetFloorM2 = 4.0;
  static const targetWallM2 = 6.0;

  /// 0–1: floor and walls weigh half each.
  double get coverage {
    final f = (floorM2 / targetFloorM2).clamp(0.0, 1.0);
    final w = (wallM2 / targetWallM2).clamp(0.0, 1.0);
    return 0.5 * f + 0.5 * w;
  }

  int get percent => (coverage * 100).round();

  /// Floors plus walls the tracker holds as surfaces.
  int get surfaces => walls + floors;

  bool get isEmpty => floorM2 <= 0 && wallM2 <= 0 && surfaces == 0;
}

/// When the room-scan overlay shows.
///
/// - The user's own choice (Menu → View → "Show room scan") wins, for the
///   rest of the session.
/// - Otherwise it shows during setup and goes away once the model is locked
///   or the user moves on to work: it would only clutter the model then.
/// - Never in Demo mode (there is no camera), never while AR is paused, and
///   not when the phone runs warm (thermal moderate or worse) unless the
///   user turned it on themselves.
abstract final class ScanOverlayPolicy {
  static bool show({
    required bool? userChoice,
    required bool setup,
    required bool locked,
    required bool paused,
    required bool demo,
    int thermalStatus = 0,
  }) {
    if (demo || paused) return false;
    if (userChoice != null) return userChoice;
    if (thermalStatus >= 2) return false;
    return setup && !locked;
  }
}

/// The colour of the pulse ring on a confirmed board or corner, from the
/// engine's LiDAR check (`surfaceResidualMm`): `ok` within
/// [okWithinMm] of the measured surface, `warn` beyond it, `info` when
/// nothing was measured (no LiDAR, or depth off).
abstract final class SurfaceCheck {
  /// A board is a few mm thick and LiDAR reads ±1 cm at room distances; a
  /// snapped corner line sits within ~2 cm of the crease it found. Beyond
  /// 3 cm the snap or the board's pose disagrees with the real wall.
  static const okWithinMm = 30.0;

  static String tone(double? residualMm) {
    if (residualMm == null || !residualMm.isFinite) return 'info';
    return residualMm.abs() <= okWithinMm ? 'ok' : 'warn';
  }
}

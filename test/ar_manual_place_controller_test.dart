import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/manual_place_math.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/state/ar_manual_place_controller.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/state/providers.dart';

import 'manual_place_test_fakes.dart';

/// "Place by hand" end to end through the controller: load, drag, twist,
/// pinch, undo/redo, snaps, the scale badge and the lock hand-off to the
/// real session code (applyManualPlacement → manual fit → workspace).

class _Rig {
  _Rig({TestManualIo? io, ArSessionState? s}) : io = io ?? TestManualIo() {
    session = ManualFakeSession(s ?? manualSession());
    container = ProviderContainer(overrides: [
      arPackStoreProvider.overrideWithValue(store),
      arSessionProvider.overrideWith(() => session),
      arSetupProvider.overrideWith(IdleSetup.new),
      arManualIoProvider.overrideWithValue(this.io),
    ]);
    container.listen(arManualPlaceProvider, (_, _) {});
  }

  final TestManualIo io;
  final store = PrefStore();
  late final ManualFakeSession session;
  late final ProviderContainer container;

  ArManualPlaceController get ctrl => container.read(arManualPlaceProvider.notifier);
  ArManualPlaceState get m => container.read(arManualPlaceProvider);
  ArSessionState get s => container.read(arSessionProvider);

  /// Lets the throttled preview push run.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));
}

Future<_Rig> _begun({TestManualIo? io}) async {
  final r = _Rig(io: io);
  addTearDown(r.container.dispose);
  await r.ctrl.begin();
  await r.settle();
  return r;
}

void main() {
  test('begin: loads 1.5 m ahead on the floor at true size, semi-transparent, previewed', () async {
    final r = await _begun();
    expect(r.m.active, isTrue);
    final pose = r.m.pose!;
    expect(pose.pos.x, closeTo(0, 1e-6));
    expect(pose.pos.y, closeTo(-ManualLimits.loadDistanceM, 1e-6));
    expect(pose.floorY, 0);
    expect(pose.isTrueSize, isTrue);
    expect(r.m.floorKnown, isTrue);
    expect(r.session.manualPreviewing, isTrue);
    expect(r.session.opacities.first, ArManualPlaceController.previewOpacity);
    expect(r.session.previews, isNotEmpty);
    expect(r.session.previews.last.closeTo(pose.arFromTile(r.m.footprint!.pivotTile)), isTrue);
    // The bedroom's centre is the pivot.
    expect(r.m.footprint!.pivotTile.x, closeTo(1.525, 1e-9));
    expect(r.m.screen.pivot, isNotNull, reason: 'the centre puck is projected');
    expect(r.m.coach, ManualCoachStep.drag);
  });

  test('one-finger drag follows the finger on the floor; undo/redo', () async {
    final r = await _begun();
    final before = r.m.pose!;
    r.ctrl.moveStart(195, 600);
    r.ctrl.moveUpdate(225, 560);
    r.ctrl.moveUpdate(255, 520);
    await r.ctrl.moveEnd();
    final after = r.m.pose!;
    final h0 = ManualGestures.floorHit(r.io.camera.ray(195, 600), 0)!;
    final h1 = ManualGestures.floorHit(r.io.camera.ray(255, 520), 0)!;
    expect(after.pos.x, closeTo(before.pos.x + h1.x - h0.x, 1e-9));
    expect(after.pos.y, closeTo(before.pos.y + h1.z - h0.z, 1e-9));
    expect(r.m.moved, isTrue);
    expect(r.m.canUndo, isTrue);

    r.ctrl.undo();
    expect(r.m.pose, before);
    expect(r.m.canRedo, isTrue);
    r.ctrl.redo();
    expect(r.m.pose, after);
  });

  test('fine mode drags at a quarter speed', () async {
    final r = await _begun();
    r.ctrl.toggleFine();
    final before = r.m.pose!;
    r.ctrl.moveStart(195, 600);
    r.ctrl.moveUpdate(255, 600);
    await r.ctrl.moveEnd();
    final h0 = ManualGestures.floorHit(r.io.camera.ray(195, 600), 0)!;
    final h1 = ManualGestures.floorHit(r.io.camera.ray(255, 600), 0)!;
    expect(r.m.pose!.pos.x, closeTo(before.pos.x + (h1.x - h0.x) * ManualLimits.fineFactor, 1e-9));
    expect(r.session.toasts, contains('ar.manual.fine_on'));
  });

  test('twist + pinch, the scale badge, and one tap back to true size', () async {
    final r = await _begun();
    final start = r.m.pose!;
    r.ctrl.twoStart();
    r.ctrl.twoUpdate(rotationRad: 0.3, scale: 1.25, dxPx: 0, dyPx: 0);
    r.ctrl.twoEnd();
    var p = r.m.pose!;
    expect(p.yawRad, closeTo(start.yawRad - 0.3, 1e-9));
    expect(p.scale, closeTo(1.25, 1e-9));
    expect(r.m.notTrueSize, isTrue);
    expect(r.m.turned, isTrue);

    r.ctrl.trueSize();
    p = r.m.pose!;
    expect(p.scale, 1);
    expect(r.m.notTrueSize, isFalse);
    r.ctrl.undo();
    expect(r.m.pose!.scale, closeTo(1.25, 1e-9));
  });

  test('a pinch never leaves 50–200 %, and a small one stays at true size', () async {
    final r = await _begun();
    r.ctrl.twoStart();
    r.ctrl.twoUpdate(rotationRad: 0, scale: 9, dxPx: 0, dyPx: 0);
    expect(r.m.pose!.scale, ManualLimits.maxScale);
    r.ctrl.twoUpdate(rotationRad: 0, scale: 0.01, dxPx: 0, dyPx: 0);
    expect(r.m.pose!.scale, ManualLimits.minScale);
    r.ctrl.twoUpdate(rotationRad: 0, scale: 1.025, dxPx: 0, dyPx: 0);
    expect(r.m.pose!.scale, 1);
    r.ctrl.twoEnd();
  });

  test('two fingers dragged straight up raise the model instead', () async {
    final r = await _begun();
    r.ctrl.twoStart();
    r.ctrl.twoUpdate(rotationRad: 0, scale: 1, dxPx: 2, dyPx: -60);
    r.ctrl.twoEnd();
    expect(r.m.pose!.heightM, closeTo(0.12, 1e-9));
    expect(r.m.pose!.scale, 1);
  });

  test('twist soft-snaps to the detected wall heading', () async {
    final n = rotateXz(const Vec2(0, 1), degToRad(10));
    final io = TestManualIo(walls: [testWall('north', const Vec2(-2, -4), const Vec2(2, -4), n)]);
    final r = await _begun(io: io);
    // Loaded squared to the wall.
    expect(ManualGestures.quarterDiff(r.m.pose!.yawRad, degToRad(10)), closeTo(0, 1e-9));
    r.ctrl.twoStart();
    final seqBefore = r.m.snapSeq;
    // 92° clockwise lands 2° from a quarter turn: clicks onto it.
    r.ctrl.twoUpdate(rotationRad: degToRad(92), scale: 1, dxPx: 0, dyPx: 0);
    r.ctrl.twoEnd();
    expect(ManualGestures.quarterDiff(r.m.pose!.yawRad, degToRad(10)), closeTo(0, 1e-9));
    expect(r.m.snapSeq, greaterThan(seqBefore));
  });

  test('Snap to wall puts the nearest model face on the measured wall', () async {
    final n = rotateXz(const Vec2(0, 1), degToRad(3));
    final wall = testWall('north', const Vec2(-2, -4.2), const Vec2(2, -4.2), n);
    final r = await _begun(io: TestManualIo(walls: [wall]));
    // Turn it a little off first, so the snap has work to do.
    r.ctrl.nudge(ManualNudge.turnRight);
    r.ctrl.nudge(ManualNudge.turnRight);
    r.ctrl.snapToWall();
    final fp = r.m.footprint!;
    final pose = r.m.pose!;
    final snap = ManualSnaps.snapToWall(pose, fp, [wall])!;
    expect(snap.movedM, closeTo(0, 1e-9), reason: 'already on it');
    expect(snap.turnedRad, closeTo(0, 1e-9));
    expect(r.session.toasts, contains('ar.manual.snapped_wall'));
    expect(r.m.moved && r.m.turned, isTrue);
  });

  test('Snap to wall with no wall measured says so', () async {
    final r = await _begun();
    final before = r.m.pose;
    r.ctrl.snapToWall();
    expect(r.m.pose, before);
    expect(r.session.toasts, contains('ar.manual.no_wall'));
  });

  test('Snap corner: a dragged corner lands on the room corner and pins; a pinch grows from it', () async {
    // The real room's north-west corner at AR (−1.2, −3.9).
    final io = TestManualIo(walls: [
      testWall('north', const Vec2(-1.2, -3.9), const Vec2(2, -3.9), const Vec2(0, 1)),
      testWall('west', const Vec2(-1.2, -3.9), const Vec2(-1.2, 0), const Vec2(1, 0)),
    ]);
    final r = await _begun(io: io);
    expect(r.m.roomCorners, hasLength(1));
    r.ctrl.toggleCornerMode();
    expect(r.m.cornerMode, isTrue);
    final fp = r.m.footprint!;
    // The model's corner at tile (0, 0): drag it to 20 cm short of the room corner.
    final ci = fp.corners.indexWhere((c) => c.distanceTo(Vec2.zero) < 1e-9);
    final m = r.m.pose!.arFromTile(fp.pivotTile);
    final c = m.transformPoint(fp.tile(fp.corners[ci]));
    final from = io.camera.project(c)!;
    final to = io.camera.project(const Vec3(-1.2 + 0.15, 0, -3.9 + 0.12))!;
    r.ctrl.moveStart(from.$1, from.$2, corner: ci);
    r.ctrl.moveUpdate(to.$1, to.$2);
    await Future<void>.delayed(Duration.zero);
    await r.ctrl.moveEnd();
    final landed = r.m.pose!.arFromTile(fp.pivotTile).transformPoint(fp.tile(fp.corners[ci])).xz;
    expect(landed.distanceTo(const Vec2(-1.2, -3.9)), lessThan(1e-9));
    expect(r.m.pinnedCorner, fp.corners[ci]);
    expect(r.session.toasts, contains('ar.manual.corner_snapped'));

    // Pinch out: the pinned corner stays on the room corner.
    r.ctrl.twoStart();
    r.ctrl.twoUpdate(rotationRad: 0, scale: 1.2, dxPx: 0, dyPx: 0);
    r.ctrl.twoEnd();
    final still = r.m.pose!.arFromTile(fp.pivotTile).transformPoint(fp.tile(fp.corners[ci])).xz;
    expect(still.distanceTo(const Vec2(-1.2, -3.9)), lessThan(1e-9));
    expect(r.m.pose!.scale, closeTo(1.2, 1e-9));
  });

  test('a corner dropped far from any room corner stays where it was dropped', () async {
    final io = TestManualIo(walls: [
      testWall('north', const Vec2(-1.2, -3.9), const Vec2(2, -3.9), const Vec2(0, 1)),
      testWall('west', const Vec2(-1.2, -3.9), const Vec2(-1.2, 0), const Vec2(1, 0)),
    ]);
    final r = await _begun(io: io);
    r.ctrl.toggleCornerMode();
    r.ctrl.moveStart(195, 600, corner: 0);
    r.ctrl.moveUpdate(205, 600);
    await r.ctrl.moveEnd();
    expect(r.m.pinnedCorner, isNull);
    expect(r.session.toasts, contains('ar.manual.corner_no_match'));
  });

  test('stretch is off by default, per axis when on, and back to 1 when off', () async {
    final r = await _begun();
    r.ctrl.setStretch(x: 1.2);
    expect(r.m.pose!.stretchX, 1, reason: 'off: ignored');
    r.ctrl.setStretchOn(true);
    r.ctrl.sliderStart();
    r.ctrl.setStretch(x: 1.2);
    r.ctrl.sliderEnd();
    expect(r.m.pose!.stretchX, closeTo(1.2, 1e-9));
    expect(r.m.pose!.isTrueSize, isFalse);
    r.ctrl.setStretchOn(false);
    expect(r.m.pose!.stretchX, 1);
  });

  test('double-tap reset returns to the load pose (undoable)', () async {
    final r = await _begun();
    final load = r.m.pose!;
    r.ctrl.nudge(ManualNudge.right);
    r.ctrl.nudge(ManualNudge.up);
    expect(r.m.pose, isNot(load));
    r.ctrl.reset();
    expect(r.m.pose, load);
    r.ctrl.undo();
    expect(r.m.pose, isNot(load));
  });

  test('Lock hands over: manual fit with its scale, workspace, size remembered, preview over', () async {
    final r = await _begun();
    r.ctrl.twoStart();
    r.ctrl.twoUpdate(rotationRad: 0, scale: 1.12, dxPx: 0, dyPx: 0);
    r.ctrl.twoEnd();
    final pose = r.m.pose!;
    final ok = await r.ctrl.lock();
    expect(ok, isTrue);
    final s = r.s;
    expect(s.stage, ArSessionStage.work);
    expect(s.quality, AlignmentQuality.manual);
    expect(s.isPlaced, isTrue);
    expect(s.fit!.isHandPlaced, isTrue);
    expect(s.fit!.method, 'manual');
    expect(s.fit!.scale, closeTo(1.12, 1e-9));
    expect(s.fit!.arFromTile.closeTo(pose.arFromTile(r.m.footprint!.pivotTile)), isTrue);
    expect(s.observations, isEmpty);
    expect(s.badge.handPlaced, isTrue);
    expect(s.badge.scalePct, 112);
    expect(r.session.manualPreviewing, isFalse);
    expect(r.session.manualPlacement, isNotNull);
    expect(r.m.active, isFalse);
    expect(r.m.lockSeq, 1);
    expect(r.session.toasts, contains('ar.manual.locked_toast_scaled'));
    final saved = jsonDecode(r.store.prefs['manual:size:f-bed']!) as Map<String, dynamic>;
    expect(saved['scale'], closeTo(1.12, 1e-9));
  });

  test('true-size lock: no "not true size" anywhere', () async {
    final r = await _begun();
    await r.ctrl.lock();
    expect(r.s.badge.handPlaced, isTrue);
    expect(r.s.badge.scalePct, isNull);
    expect(r.s.fit!.isTrueSize, isTrue);
    expect(r.session.toasts, contains('ar.manual.locked_toast'));
  });

  test('a measured corner afterwards replaces the hand placement', () async {
    final r = await _begun();
    await r.ctrl.lock();
    expect(r.session.manualPlacement, isNotNull);
    r.session.addObservation(const CornerObs(
      id: 'c1',
      aAr: Vec3(0, 0, -2),
      bTile: Vec3(0, 0, 0),
      sigmaM: 0.02,
      faceAAr: Vec2(1, 0),
      faceBAr: Vec2(0, 1),
      faceATile: Vec2(1, 0),
      faceBTile: Vec2(0, 1),
    ));
    expect(r.session.manualPlacement, isNull);
    expect(r.s.fit!.isHandPlaced, isFalse);
    expect(r.s.fit!.isTrueSize, isTrue);
  });

  test('cancel hides the preview again and keeps the pose for this session', () async {
    final r = await _begun();
    r.ctrl.nudge(ManualNudge.away);
    final kept = r.m.pose!;
    await r.ctrl.cancel();
    expect(r.m.active, isFalse);
    expect(r.session.manualPreviewing, isFalse);
    expect(r.session.opacities.last, 0, reason: 'nothing placed: hidden');
    await r.ctrl.begin();
    expect(r.m.pose, kept, reason: 'restored in the same session');
  });

  test('the last size is offered next time, but true size stays the default', () async {
    final r = _Rig();
    addTearDown(r.container.dispose);
    r.store.prefs['manual:size:f-bed'] = jsonEncode({'scale': 1.1, 'stretchX': 1, 'stretchZ': 1, 'heightM': 0});
    await r.ctrl.begin();
    await r.settle();
    expect(r.m.pose!.isTrueSize, isTrue);
    expect(r.m.lastSize!.scale, closeTo(1.1, 1e-9));
    r.ctrl.useLastSize();
    expect(r.m.pose!.scale, closeTo(1.1, 1e-9));
  });

  test('the remembered choice opens straight into Place by hand', () async {
    final r = _Rig(s: manualSession().copyWith(phase: ArSessionPhase.loading));
    addTearDown(r.container.dispose);
    r.store.prefs['manual:method:f-bed'] = '1';
    r.session.put(manualSession());
    await r.settle();
    expect(r.m.active, isTrue);
  });

  test('chooser advice: few corners → suggested', () {
    final r = _Rig();
    addTearDown(r.container.dispose);
    expect(arManualRecommended(r.s, const ArSetupState(), 0), isTrue);
  });
}

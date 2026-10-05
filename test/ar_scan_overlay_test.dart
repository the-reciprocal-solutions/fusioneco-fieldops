import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/ar_engine.dart';
import 'package:technician_portal/core/ar/channel_ar_engine.dart';
import 'package:technician_portal/core/ar/corner_matcher.dart';
import 'package:technician_portal/core/ar/fake_ar_engine.dart';
import 'package:technician_portal/core/ar/scan_overlay.dart';
import 'package:technician_portal/core/ar/vec.dart';

/// The room scan (fe_ar `setScanOverlay` / `scan` / `pulseAt`) and the LiDAR
/// surface check (`surfaceResidualMm`): the pure rules and the wire shapes.
void main() {
  group('ScanProgress coverage', () {
    test('nothing measured is 0 %', () {
      const p = ScanProgress();
      expect(p.percent, 0);
      expect(p.isEmpty, isTrue);
    });

    test('floor and walls weigh half each, each capped at its target', () {
      expect(const ScanProgress(floorM2: 4, wallM2: 0).percent, 50);
      expect(const ScanProgress(floorM2: 0, wallM2: 6).percent, 50);
      expect(const ScanProgress(floorM2: 2, wallM2: 3).percent, 50);
      expect(const ScanProgress(floorM2: 40, wallM2: 3).percent, 75); // a huge floor can't make up for walls
      expect(const ScanProgress(floorM2: 4, wallM2: 6).percent, 100);
      expect(const ScanProgress(floorM2: 9, wallM2: 30).percent, 100);
    });

    test('surfaces counts tracked floors and walls', () {
      expect(const ScanProgress(walls: 2, floors: 1).surfaces, 3);
    });

    test('from the engine event, mesh source marks LiDAR', () {
      final p = ScanProgress.fromEvent(const ScanProgressEvent(source: 'mesh', walls: 2, floors: 1, floorM2: 2, wallM2: 6));
      expect(p.mesh, isTrue);
      expect(p.percent, 75);
      expect(ScanProgress.fromEvent(const ScanProgressEvent()).mesh, isFalse);
    });
  });

  group('ScanOverlayPolicy', () {
    bool show({bool? choice, bool setup = true, bool locked = false, bool paused = false, bool demo = false, int thermal = 0}) =>
        ScanOverlayPolicy.show(userChoice: choice, setup: setup, locked: locked, paused: paused, demo: demo, thermalStatus: thermal);

    test('automatic: on during setup, off once locked or at work', () {
      expect(show(), isTrue);
      expect(show(locked: true), isFalse);
      expect(show(setup: false), isFalse);
    });

    test("the user's choice wins both ways", () {
      expect(show(choice: false), isFalse);
      expect(show(choice: true, locked: true, setup: false), isTrue);
    });

    test('never in Demo mode or while paused, even when chosen', () {
      expect(show(demo: true, choice: true), isFalse);
      expect(show(paused: true, choice: true), isFalse);
    });

    test('a warm phone drops the automatic overlay, not a chosen one', () {
      expect(show(thermal: 1), isTrue);
      expect(show(thermal: 2), isFalse);
      expect(show(thermal: 3, choice: true), isTrue);
    });
  });

  group('SurfaceCheck tone', () {
    test('within 3 cm is ok, beyond is warn, unmeasured is info', () {
      expect(SurfaceCheck.tone(null), 'info');
      expect(SurfaceCheck.tone(double.nan), 'info');
      expect(SurfaceCheck.tone(0), 'ok');
      expect(SurfaceCheck.tone(-29.9), 'ok');
      expect(SurfaceCheck.tone(30), 'ok');
      expect(SurfaceCheck.tone(31), 'warn');
      expect(SurfaceCheck.tone(-120), 'warn');
    });
  });

  group('wire shapes', () {
    test('scan event parses, with ints or strings, and round-trips', () {
      final e = ArEvent.fromMap({
        'type': 'scan',
        'source': 'mesh',
        'surfaces': 3,
        'walls': 2,
        'floors': '1',
        'floorM2': 3.25,
        'wallM2': '5.5',
        'ceilingM2': 0,
        'otherM2': 1.2,
      });
      expect(e, isA<ScanProgressEvent>());
      final s = e as ScanProgressEvent;
      expect(s.source, 'mesh');
      expect(s.walls, 2);
      expect(s.floors, 1);
      expect(s.wallM2, 5.5);
      expect(ArEvent.fromMap(s.toMap())!.toMap(), s.toMap());
    });

    test('marker and corner carry the LiDAR residual when sent', () {
      final m = ArEvent.fromMap({
        'type': 'marker',
        'rawPayload': 'HTTPS://FE.EXAMPLE/M/7K3QX9-R',
        'anchorId': 'a',
        'centreAr': [0, 1.4, -1],
        'normalAr': [0, 0, 1],
        'method': 'tag',
        'surfaceResidualMm': 4.5,
      }) as MarkerSeenEvent;
      expect(m.surfaceResidualMm, 4.5);
      final c = CornerSeenEvent.tryParse({
        'posAr': [1, 0, 2],
        'faceAAr': [1, 0],
        'faceBAr': [0, 1],
        'surfaceResidualMm': -41,
      })!;
      expect(c.surfaceResidualMm, -41);
      expect(DetectedCorner.fromSeen(c).surfaceResidualMm, -41);
      // Android (no LiDAR) sends none: null, and the key stays off the wire.
      final plain = CornerSeenEvent.tryParse({'posAr': [1, 0, 2], 'faceAAr': [1, 0], 'faceBAr': [0, 1]})!;
      expect(plain.surfaceResidualMm, isNull);
      expect(plain.toMap().containsKey('surfaceResidualMm'), isFalse);
    });

    test('capabilities read the mesh and scan-overlay extras, default off', () {
      final caps = ArCapabilities.fromMap({'supported': true, 'platform': 'ios', 'lidar': true, 'mesh': true, 'scanOverlay': true});
      expect(caps.mesh, isTrue);
      expect(caps.scanOverlay, isTrue);
      final old = ArCapabilities.fromMap({'supported': true, 'platform': 'android'});
      expect(old.mesh, isFalse);
      expect(old.scanOverlay, isFalse);
    });
  });

  group('ChannelArEngine scan extensions', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('without the plugin both answer false, never throw', () async {
      final engine = ChannelArEngine(methods: const MethodChannel('test/no-plugin-scan'));
      expect(await engine.setScanOverlay(true), isFalse);
      expect(await engine.pulseAt(const Vec3(0, 0, 0)), isFalse);
    });

    test('argument names and the tone travel as CHANNEL.md says', () async {
      const channel = MethodChannel('test/ar-scan');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'pulseAt') throw MissingPluginException(); // Android has no rings
        return true;
      });
      final engine = ChannelArEngine(methods: channel);
      expect(await engine.setScanOverlay(true, contrast: true), isTrue);
      expect(await engine.pulseAt(const Vec3(1, 2, 3), tone: 'ok'), isFalse);
      expect(calls[0].arguments, {'on': true, 'contrast': true});
      final pulse = calls[1].arguments as Map;
      expect(pulse['posAr'], [1.0, 2.0, 3.0]);
      expect(pulse.containsKey('normalAr'), isFalse);
      expect(pulse['tone'], 'ok');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('the fake engine records overlay and pulses', () async {
      final fake = FakeArEngine(
        script: FakeArScript.manual,
        autoplay: false,
        capabilities: const ArCapabilities(supported: true, scanOverlay: true, platform: 'demo'),
      );
      expect(await fake.setScanOverlay(true), isTrue);
      expect(fake.scanOverlay, isTrue);
      await fake.pulseAt(const Vec3(0, 1, 0), tone: 'warn');
      expect(fake.pulses.single.$2, 'warn');
    });
  });
}

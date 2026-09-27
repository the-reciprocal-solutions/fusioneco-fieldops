// Uint8List comes through package:flutter/services.dart (a direct
// dart:typed_data import trips `unnecessary_import`).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/ar_engine.dart';
import 'package:technician_portal/core/ar/channel_ar_engine.dart';
import 'package:technician_portal/core/ar/corner_matcher.dart';
import 'package:technician_portal/core/ar/fake_ar_engine.dart';
import 'package:technician_portal/core/ar/marker_code.dart';
import 'package:technician_portal/core/ar/vec.dart';

void main() {
  group('ArEvent wire format (EventChannel maps)', () {
    final samples = <ArEvent>[
      const TrackingEvent(state: ArTracking.limited, reason: 'excessiveMotion'),
      const MarkerSeenEvent(
        rawPayload: 'HTTPS://FE.EXAMPLE/M/7K3QX9-R',
        anchorId: 'a1',
        centreAr: Vec3(1, 2, 3),
        normalAr: Vec3(0, 0, 1),
        method: 'lidar',
        spreadMm: 4,
        distanceM: 1.1,
        viewAngleDeg: 8,
        qrEdgeMm: 115.2,
      ),
      const CornerSeenEvent(
        posAr: Vec3(1, -1.4, 2),
        faceAAr: Vec2(1, 0),
        faceBAr: Vec2(0, 1),
        angleDeg: 90,
        kind: 'inside',
        method: 'planes',
      ),
      const AnchorUpdatedEvent(anchorId: 'a1', posAr: Vec3(1, 2, 3.01)),
      CameraPoseEvent(arFromCamera: Mat4.fromYawTranslation(0.5, const Vec3(1, 1.4, 0))),
      const TargetScreenEvent(x: 120, y: 360, onScreen: true),
      const ArErrorEvent(code: 'camera-denied', detail: 'no permission'),
    ];

    for (final e in samples) {
      test('${e.type} round-trips', () {
        final back = ArEvent.fromMap(e.toMap())!;
        expect(back.runtimeType, e.runtimeType);
        expect(back.toMap(), e.toMap());
      });
    }

    test('an unknown type is ignored, never a crash', () {
      expect(ArEvent.fromMap({'type': 'somethingNew', 'x': 1}), isNull);
      expect(ArEvent.fromMap('not a map'), isNull);
    });

    test('a known type missing its fields surfaces as a bad-event error', () {
      final e = ArEvent.fromMap({'type': 'marker', 'anchorId': 'x'});
      expect(e, isA<ArErrorEvent>());
      expect((e as ArErrorEvent).code, 'bad-event');
    });

    test('numbers may arrive as ints or strings', () {
      final e = ArEvent.fromMap({
        'type': 'corner',
        'posAr': [1, '-1.4', 2],
        'faceAAr': [1, 0],
        'faceBAr': [0, 1],
        'angleDeg': 90,
        'kind': 'outside',
        'method': 'lidar',
      });
      expect((e as CornerSeenEvent).posAr, const Vec3(1, -1.4, 2));
    });

    test('camera pose exposes position and a forward along −Z', () {
      final pose = CameraPoseEvent(arFromCamera: Mat4.fromYawTranslation(0, const Vec3(1, 1.4, 0)));
      expect(pose.positionAr, const Vec3(1, 1.4, 0));
      expect(pose.forwardAr.distanceTo(const Vec3(0, 0, -1)), lessThan(1e-12));
    });
  });

  group('ArCapabilities', () {
    test('tiers A+, A, B, C', () {
      expect(const ArCapabilities(supported: true, lidar: true, depth: true).tier, 'A+');
      expect(const ArCapabilities(supported: true, depth: true).tier, 'A');
      expect(const ArCapabilities(supported: true).tier, 'B');
      expect(const ArCapabilities.unsupported('arcore-missing').tier, 'C');
    });

    test('fromMap tolerates missing keys', () {
      final caps = ArCapabilities.fromMap({'supported': true, 'platform': 'android'});
      expect(caps.supported, isTrue);
      expect(caps.depth, isFalse);
      expect(caps.platform, 'android');
    });
  });

  group('ChannelArEngine without the plugin', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('capabilities: unsupported, engine-not-installed (no crash)', () async {
      final caps = await ChannelArEngine(methods: const MethodChannel('test/no-plugin')).capabilities();
      expect(caps.supported, isFalse);
      expect(caps.reason, ArCapabilities.engineNotInstalled);
    });

    test('commands throw a typed ArEngineException', () async {
      final engine = ChannelArEngine(methods: const MethodChannel('test/no-plugin'));
      await expectLater(
        engine.setFeatureState(Uint8List(4), 1),
        throwsA(isA<ArEngineException>().having((e) => e.code, 'code', ArCapabilities.engineNotInstalled)),
      );
    });

    test('arguments use the Dart parameter names', () async {
      const channel = MethodChannel('test/ar-args');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          if (call.method == 'pick') {
            return {'featureId': 7, 'hitPointTile': [1, 2, 3], 'distanceM': 2.5};
          }
          return null;
        },
      );
      final engine = ChannelArEngine(methods: channel);
      await engine.setModelTransform(Mat4.identity(), easeMs: 250);
      await engine.setTarget([3, 4]);
      final hit = await engine.pick(10, 20);
      expect(calls[0].method, 'setModelTransform');
      expect((calls[0].arguments as Map)['arFromTile'], hasLength(16));
      expect((calls[0].arguments as Map)['easeMs'], 250);
      expect((calls[1].arguments as Map)['featureIds'], [3, 4]);
      expect(hit?.featureId, 7);
      expect(hit?.hitPointTile, const Vec3(1, 2, 3));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    // Feature ids are dense per build: the texture and the target must name
    // their build (fe_ar CHANNEL.md), and an unscoped call must not send a
    // null buildId the native side would read as "every build".
    test('setFeatureState / setTarget carry buildId only when given', () async {
      const channel = MethodChannel('test/ar-build');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      final engine = ChannelArEngine(methods: channel);
      await engine.setFeatureState(Uint8List(4), 1, buildId: 'build-mep');
      await engine.setFeatureState(Uint8List(4), 1);
      await engine.setTarget([9], buildId: 'build-arch');
      final a0 = calls[0].arguments as Map;
      final a1 = calls[1].arguments as Map;
      final a2 = calls[2].arguments as Map;
      expect(a0['buildId'], 'build-mep');
      expect(a1.containsKey('buildId'), isFalse);
      expect(a2['featureIds'], [9]);
      expect(a2['buildId'], 'build-arch');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
  });

  group('FakeArEngine — the demo really locks through the real pipeline', () {
    test('no corner before tracking, then corner A → placed, corner B → locked', () async {
      final engine = FakeArEngine(autoplay: false);
      await engine.startSession();
      expect(await engine.detectCornerAt(200, 400), isNull, reason: 'not tracking yet');

      engine.advance(const Duration(milliseconds: 1400));
      expect(
        engine.emitted.whereType<TrackingEvent>().map((e) => e.state),
        [ArTracking.initializing, ArTracking.tracking],
      );
      Vec3 camera() => engine.emitted.whereType<CameraPoseEvent>().last.positionAr;

      const matcher = CornerMatcher();
      const estimator = AlignmentEstimator();
      const corners = ArDemoScenario.corners;
      final first = matcher.rankForRoom(corners, spaceName: 'Plant Room B').first;
      expect(first.id, ArDemoScenario.cornerAId, reason: 'the picker suggests column C-2 first');

      final a = DetectedCorner.fromSeen((await engine.detectCornerAt(200, 400))!);
      final obsA = matcher.firstCorner(a, first, cameraAr: camera());
      final fitA = estimator.fit([obsA]);
      expect(fitA.quality, AlignmentQuality.placed);
      expect(fitA.yawDeg, closeTo(ArDemoScenario.truthYawDeg, 1e-6));

      engine.advance(const Duration(seconds: 3)); // walk to the door corner
      final b = DetectedCorner.fromSeen((await engine.detectCornerAt(200, 400))!);
      final matched = matcher.matchSecond(b, fitA, corners);
      expect(matched?.id, ArDemoScenario.cornerBId);
      final obsB = matcher.observe(b, matched!, cameraAr: camera(), yawPrior: fitA.yawRad);
      final fit = estimator.fit([obsA, obsB]);
      expect(fit.quality, AlignmentQuality.locked);
      expect(fit.yawDeg, closeTo(ArDemoScenario.truthYawDeg, 0.2));
      expect(fit.t.distanceTo(ArDemoScenario.truthT), lessThan(0.02));
      expect(fit.maxResidualM, lessThan(0.01));
    });

    test('after the lock a spare board shows up where the ghost board is, then a drift', () async {
      final engine = FakeArEngine(autoplay: false);
      await engine.startSession();
      engine.advance(const Duration(milliseconds: 1400));
      await engine.detectCornerAt(0, 0);
      await engine.detectCornerAt(0, 0);

      engine.advance(const Duration(milliseconds: 6200));
      final spare = engine.emitted.whereType<MarkerSeenEvent>().single;
      expect(MarkerCode.fromScan(spare.rawPayload), ArDemoScenario.spareCode);
      final ghost = engine.ghostSpot()!;
      final truth = ArDemoScenario.truth;
      expect(truth.invertRigid().transformPoint(spare.centreAr).distanceTo(ghost.posTile), lessThan(0.01));

      engine.advance(const Duration(seconds: 13));
      final states = engine.emitted.whereType<TrackingEvent>().map((e) => e.state).toList();
      expect(states.sublist(states.length - 2), [ArTracking.limited, ArTracking.tracking]);
      final anchor = engine.emitted.whereType<AnchorUpdatedEvent>().single;
      expect(anchor.posAr.distanceTo(spare.centreAr), closeTo(0.04, 0.006));
    });

    test('board script: two boards lock the model', () async {
      final engine = FakeArEngine(script: FakeArScript.boards, autoplay: false);
      await engine.startSession();
      engine.advance(const Duration(seconds: 10));
      final seen = engine.emitted.whereType<MarkerSeenEvent>().toList();
      expect(seen, hasLength(2));

      final manifest = ArDemoScenario.manifest();
      final obs = <ArObservation>[
        for (final e in seen)
          if (manifest.markerByCode(MarkerCode.fromScan(e.rawPayload)!) case final m?)
            MarkerObs(
              id: m.code,
              aAr: e.centreAr,
              bTile: m.posTile,
              sigmaM: ArSigma.forMarker(m.accuracyClass, e.method),
              normalAr: e.normalAr,
              normalTile: m.normalTile,
              method: e.method,
            ),
      ];
      final fit = const AlignmentEstimator().fit(obs);
      expect(fit.quality, AlignmentQuality.locked);
      expect(fit.yawDeg, closeTo(ArDemoScenario.truthYawDeg, 0.2));
    });

    test('records commands for widget tests', () async {
      final engine = FakeArEngine(autoplay: false, script: FakeArScript.manual);
      await engine.setModelTransform(Mat4.identity());
      await engine.setLayers(const LayerState(architecture: false, opacity: 0.6));
      await engine.loadTiles(const [TileRef(hash: 'h1', path: '/tmp/h1.glb')]);
      expect(engine.commands, ['setModelTransform', 'setLayers', 'loadTiles']);
      expect(engine.layers.architecture, isFalse);
      expect(engine.loadedTiles, {'h1'});
      await engine.dispose();
    });

    test('events stream to listeners', () async {
      final engine = FakeArEngine(autoplay: false, script: FakeArScript.manual);
      final received = <ArEvent>[];
      final sub = engine.events.listen(received.add);
      await engine.startSession();
      engine.advance(const Duration(milliseconds: 1400));
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<TrackingEvent>(), isNotEmpty);
      await sub.cancel();
      await engine.dispose();
    });
  });

  group('fe_ar extensions (torch, pickMany, depthPointAt, recording)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('wire shapes', () async {
      const channel = MethodChannel('test/ar-ext');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          switch (call.method) {
            case 'capabilities':
              return {'supported': true, 'platform': 'android', 'torch': true};
            case 'pickMany':
              return [
                {'featureId': 3, 'hitPointTile': [1, 2, 3], 'distanceM': 1.5},
                null,
              ];
            case 'depthPointAt':
              return {
                'posAr': [0.5, -0.2, -1.8],
                'normalAr': [0, 0, 1],
                'confidence': 0.82,
                'method': 'rawDepth',
                'samples': 61,
              };
            case 'setTorch':
            case 'startRecording':
              return true;
            case 'stopRecording':
              return '/files/ar_recordings/ar_1.mp4';
          }
          return null;
        },
      );
      final engine = ChannelArEngine(methods: channel);
      expect((await engine.capabilities()).torch, isTrue);
      await engine.startSession(playbackFrom: '/files/ar_recordings/ar_1.mp4');
      await engine.startSession();
      final picks = await engine.pickMany(const [(10, 20), (30, 40)]);
      final dp = await engine.depthPointAt(100, 200);
      expect(await engine.setTorch(true), isTrue);
      expect(await engine.startRecording('/files/ar_recordings/ar_2.mp4'), isTrue);
      expect(await engine.stopRecording(), '/files/ar_recordings/ar_1.mp4');

      Map args(String method, [int nth = 0]) => calls.where((c) => c.method == method).elementAt(nth).arguments as Map;
      expect(args('startSession'), {'playbackFrom': '/files/ar_recordings/ar_1.mp4'});
      expect(args('startSession', 1), isEmpty, reason: 'no nulls on the wire');
      expect(args('pickMany')['points'], [
        [10, 20],
        [30, 40],
      ]);
      expect(picks, hasLength(2));
      expect(picks[0]?.featureId, 3);
      expect(picks[1], isNull);
      expect(args('depthPointAt'), {'x': 100, 'y': 200});
      expect(dp?.posAr, const Vec3(0.5, -0.2, -1.8));
      expect(dp?.normalAr, const Vec3(0, 0, 1));
      expect(dp?.confidence, closeTo(0.82, 1e-12));
      expect(dp?.method, 'rawDepth');
      expect(args('setTorch'), {'on': true});
      expect(args('startRecording'), {'path': '/files/ar_recordings/ar_2.mp4'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('an older plugin: pickMany falls back to single picks, the rest to null/false', () async {
      const channel = MethodChannel('test/ar-old');
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          methods.add(call.method);
          if (call.method == 'pick') {
            final a = call.arguments as Map;
            return {'featureId': (a['x'] as num).toInt(), 'hitPointTile': [0, 0, 0], 'distanceM': 1};
          }
          if (call.method == 'capabilities') return {'supported': true};
          throw MissingPluginException(); // what notImplemented() looks like to Dart
        },
      );
      final engine = ChannelArEngine(methods: channel);
      final picks = await engine.pickMany(const [(7, 0), (8, 0)]);
      expect(picks.map((p) => p?.featureId), [7, 8]);
      expect(methods.where((m) => m == 'pick'), hasLength(2));
      expect(await engine.depthPointAt(1, 2), isNull);
      expect(await engine.setTorch(true), isFalse);
      expect(await engine.startRecording('/x.mp4'), isFalse);
      expect(await engine.stopRecording(), isNull);
      expect((await engine.capabilities()).torch, isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('ArDepthPoint and capabilities round-trip; a point without posAr is null', () {
      const p = ArDepthPoint(posAr: Vec3(1, 2, 3), normalAr: Vec3(0, 1, 0), confidence: 0.5, method: 'plane');
      final back = ArDepthPoint.fromMap(p.toMap())!;
      expect(back.toMap(), p.toMap());
      expect(ArDepthPoint.fromMap({'confidence': 1}), isNull);
      const caps = ArCapabilities(supported: true, torch: true);
      expect(ArCapabilities.fromMap(caps.toMap()).torch, isTrue);
    });

    test('FakeArEngine: queued depth points, torch, recording', () async {
      final engine = FakeArEngine(autoplay: false, script: FakeArScript.manual);
      await engine.startSession(playbackFrom: '/r.mp4');
      expect(engine.playbackFrom, '/r.mp4');
      expect(await engine.depthPointAt(0, 0), isNull);
      engine.depthPoints.add(const ArDepthPoint(posAr: Vec3(1, 0, 0), confidence: 0.9));
      expect((await engine.depthPointAt(0, 0))?.posAr, const Vec3(1, 0, 0));
      expect(await engine.setTorch(true), isTrue, reason: 'Demo reports a torch');
      expect(engine.torchOn, isTrue);
      expect(await engine.startRecording('/a.mp4'), isTrue);
      expect(await engine.stopRecording(), '/a.mp4');
      expect(await engine.pickMany(const [(1, 1), (2, 2)]), hasLength(2));
      await engine.stop();
      expect(engine.torchOn, isFalse);
      await engine.dispose();
    });
  });
}

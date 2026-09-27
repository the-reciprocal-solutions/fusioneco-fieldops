import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/ar_engine.dart';
import 'package:technician_portal/core/ar/reanchor_rule.dart';

void main() {
  final t0 = DateTime(2026, 9, 27, 10);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('tracking', () {
    test('a short blip of excessive motion never fires', () {
      final m = ReanchorMonitor();
      expect(m.tracking(at(0), ArTracking.limited, 'excessiveMotion'), isNull);
      expect(m.tracking(at(900), ArTracking.tracking, null), isNull);
      expect(m.fired, isFalse);
    });

    test('a loss of 1.5 s or more fires when tracking comes back, not before', () {
      final m = ReanchorMonitor();
      expect(m.tracking(at(0), ArTracking.limited, 'insufficientFeatures'), isNull);
      expect(m.tracking(at(1000), ArTracking.limited, 'insufficientLight'), isNull);
      expect(m.tracking(at(2000), ArTracking.tracking, null), ReanchorReason.trackingLost);
    });

    test('relocalizing fires on recovery however short', () {
      final m = ReanchorMonitor();
      m.tracking(at(0), ArTracking.limited, 'relocalizing');
      expect(m.tracking(at(300), ArTracking.tracking, null), ReanchorReason.relocalized);
    });

    test('backgrounding (paused) counts as a loss', () {
      final m = ReanchorMonitor();
      m.tracking(at(0), ArTracking.paused, null);
      expect(m.tracking(at(20000), ArTracking.tracking, null), ReanchorReason.trackingLost);
    });

    test('initializing is not a loss', () {
      final m = ReanchorMonitor();
      expect(m.tracking(at(0), ArTracking.initializing, 'initializing'), isNull);
      expect(m.tracking(at(5000), ArTracking.tracking, null), isNull);
    });

    test('fires once per reference; reset re-arms it', () {
      final m = ReanchorMonitor();
      m.tracking(at(0), ArTracking.limited, 'relocalizing');
      expect(m.tracking(at(100), ArTracking.tracking, null), ReanchorReason.relocalized);
      m.tracking(at(200), ArTracking.limited, 'relocalizing');
      expect(m.tracking(at(300), ArTracking.tracking, null), isNull, reason: 'already prompting');
      m.reset();
      m.tracking(at(400), ArTracking.limited, 'relocalizing');
      expect(m.tracking(at(500), ArTracking.tracking, null), ReanchorReason.relocalized);
    });

    test('reset forgets a loss in progress', () {
      final m = ReanchorMonitor();
      m.tracking(at(0), ArTracking.limited, 'insufficientFeatures');
      m.reset(); // a corner was snapped meanwhile
      expect(m.tracking(at(3000), ArTracking.tracking, null), isNull);
    });
  });

  group('walking', () {
    test('7 m is fine, beyond fires once', () {
      final m = ReanchorMonitor();
      expect(m.walked(3), isNull);
      expect(m.walked(7), isNull);
      expect(m.walked(7.2), ReanchorReason.walkedFar);
      expect(m.walked(9), isNull);
      m.reset();
      expect(m.walked(0.5), isNull);
      expect(m.walked(8), ReanchorReason.walkedFar);
    });

    test('a walk prompt and a tracking prompt share the once-per-reference budget', () {
      final m = ReanchorMonitor();
      expect(m.walked(8), ReanchorReason.walkedFar);
      m.tracking(at(0), ArTracking.limited, 'relocalizing');
      expect(m.tracking(at(100), ArTracking.tracking, null), isNull);
    });
  });
}

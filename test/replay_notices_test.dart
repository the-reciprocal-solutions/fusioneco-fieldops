import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/offline/replay_notices.dart';

/// PENDING P-008 (2): a queued write that replays inside a 200 can still carry
/// per-item refusals (AR progress four-eyes → `rejected[]`). The phone must
/// tell the technician, not silently keep showing the refused status.
void main() {
  group('replayNoticesFrom — what a successful replay still has to say', () {
    test('a four-eyes rejected[] becomes one "could not be saved" notice', () {
      final notices = replayNoticesFrom({
        'success': true,
        'data': {
          'updated': 1,
          'rejected': [
            {'globalId': 'g1', 'reason': 'The installer cannot verify their own work.'},
            {'globalId': 'g2', 'reason': 'The installer cannot verify their own work.'},
          ],
        },
      });

      expect(notices, hasLength(1));
      expect(notices.single.dropped, isTrue);
      expect(notices.single.reason, contains('2'));
      expect(notices.single.reason, contains('The installer cannot verify their own work.'));
    });

    test('distinct refusal reasons are all listed', () {
      final notices = replayNoticesFrom({
        'rejected': [
          {'globalId': 'g1', 'reason': 'Not installed yet.'},
          {'globalId': 'g2', 'reason': 'The installer cannot verify their own work.'},
        ],
      });

      expect(notices.single.reason, contains('Not installed yet.'));
      expect(notices.single.reason, contains('The installer cannot verify their own work.'));
    });

    test('a captureConflict stays an informational "flagged" notice (FR-4.8)', () {
      final notices = replayNoticesFrom({
        'data': {
          'captureConflict': {'message': 'The register changed since this check.'},
        },
      });

      expect(notices, hasLength(1));
      expect(notices.single.dropped, isFalse);
      expect(notices.single.reason, 'The register changed since this check.');
    });

    test('a numeric rejected count (alignment events) is not a refusal list', () {
      expect(replayNoticesFrom({'data': {'accepted': 3, 'rejected': 1}}), isEmpty);
    });

    test('an empty rejected[] or a plain body says nothing', () {
      expect(replayNoticesFrom({'data': {'rejected': []}}), isEmpty);
      expect(replayNoticesFrom({'success': true}), isEmpty);
      expect(replayNoticesFrom(null), isEmpty);
      expect(replayNoticesFrom('ok'), isEmpty);
    });
  });
}

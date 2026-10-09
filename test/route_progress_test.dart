import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/c2o/route_progress.dart';
import 'package:technician_portal/core/offline/offline_db.dart';

Map<String, dynamic> _claims({
  String? assetName,
  String? verificationStatus,
  List<Map<String, dynamic>>? locationPath,
}) => {
  'asset': {
    'id': 'irrelevant',
    'assetName': assetName,
    'verificationStatus': verificationStatus,
    'locationPath': locationPath ?? const [],
  },
};

void main() {
  group('routeAssetRowFromClaims', () {
    test('reads name, status and the Room step of the location walk', () {
      final row = routeAssetRowFromClaims(
        assetId: 'asset-1',
        claims: _claims(
          assetName: 'Chiller 01',
          verificationStatus: 'verified',
          locationPath: [
            {'level': 'Building', 'label': 'Tower A', 'code': null},
            {'level': 'Room', 'label': 'Plant Room 3', 'code': 'R-303'},
          ],
        ),
      );

      expect(row.name, 'Chiller 01');
      expect(row.status, 'verified');
      // Code wins over label — same convention as the plan's wayfinding note.
      expect(row.roomLabel, 'R-303');
    });

    test('falls back to the room label when there is no code', () {
      final row = routeAssetRowFromClaims(
        assetId: 'asset-1',
        claims: _claims(
          locationPath: [
            {'level': 'Room', 'label': 'Plant Room 3', 'code': null},
          ],
        ),
      );
      expect(row.roomLabel, 'Plant Room 3');
    });

    test('an asset with no Room step at all has a null roomLabel', () {
      final row = routeAssetRowFromClaims(
        assetId: 'asset-1',
        claims: _claims(
          locationPath: [
            {'level': 'Building', 'label': 'Tower A', 'code': null},
          ],
        ),
      );
      expect(row.roomLabel, isNull);
    });

    test('a missing status defaults to pending, not a crash', () {
      final row = routeAssetRowFromClaims(assetId: 'asset-1', claims: _claims());
      expect(row.status, 'pending');
      expect(row.isOutstanding, isTrue);
    });

    test('falls back to assetReferenceId when the register has no name', () {
      final row = routeAssetRowFromClaims(
        assetId: 'asset-1',
        assetReferenceId: 'AST228',
        claims: _claims(),
      );
      expect(row.name, 'AST228');
    });
  });

  group('RouteAssetRow status buckets (FR-5.3)', () {
    test('verified means verified, nothing else', () {
      const row = RouteAssetRow(id: '1', name: null, roomLabel: null, status: 'verified');
      expect(row.isVerified, isTrue);
      expect(row.isFlagged, isFalse);
      expect(row.isOutstanding, isFalse);
    });

    for (final flaggedStatus in ['mismatch', 'missing']) {
      test('"$flaggedStatus" is flagged, not outstanding', () {
        final row = RouteAssetRow(id: '1', name: null, roomLabel: null, status: flaggedStatus);
        expect(row.isFlagged, isTrue);
        expect(row.isOutstanding, isFalse);
      });
    }

    test('"pending" (or anything else) is outstanding', () {
      const row = RouteAssetRow(id: '1', name: null, roomLabel: null, status: 'pending');
      expect(row.isOutstanding, isTrue);
    });
  });

  group('RouteProgress.from (FR-5.3)', () {
    test('tallies verified/outstanding/flagged correctly', () {
      final rows = [
        const RouteAssetRow(id: '1', name: null, roomLabel: null, status: 'verified'),
        const RouteAssetRow(id: '2', name: null, roomLabel: null, status: 'verified'),
        const RouteAssetRow(id: '3', name: null, roomLabel: null, status: 'pending'),
        const RouteAssetRow(id: '4', name: null, roomLabel: null, status: 'mismatch'),
        const RouteAssetRow(id: '5', name: null, roomLabel: null, status: 'missing'),
      ];

      final progress = RouteProgress.from(rows);

      expect(progress.verified, 2);
      expect(progress.outstanding, 1);
      expect(progress.flagged, 2);
      expect(progress.total, 5);
    });

    test('an empty route has all-zero progress, not an error', () {
      final progress = RouteProgress.from(const []);
      expect(progress.total, 0);
    });
  });

  group('groupRouteForWalk (FR-5.2)', () {
    RouteAssetRow r(String id, {String? level, String? room, String? name}) =>
        RouteAssetRow(id: id, name: name ?? id, roomLabel: room, levelLabel: level, status: 'pending');

    test('walks level by level, then room by room, never interleaving floors', () {
      final stops = groupRouteForWalk([
        r('1', level: 'L2', room: 'R-101'),
        r('2', level: 'L1', room: 'R-102'),
        r('3', level: 'L1', room: 'R-101'),
        r('4', level: 'L2', room: 'R-001'),
      ]);
      expect(stops.map((s) => '${s.level}/${s.room}'), ['L1/R-101', 'L1/R-102', 'L2/R-001', 'L2/R-101']);
    });

    test('numbers sort as numbers: Room 9 before Room 10, L2 before L10', () {
      final stops = groupRouteForWalk([
        r('a', level: 'L10', room: 'Room 1'),
        r('b', level: 'L2', room: 'Room 10'),
        r('c', level: 'L2', room: 'Room 9'),
      ]);
      expect(stops.map((s) => '${s.level}/${s.room}'), ['L2/Room 9', 'L2/Room 10', 'L10/Room 1']);
    });

    test('assets with no room or level come after the known stops', () {
      final stops = groupRouteForWalk([
        r('1'),
        r('2', level: 'L1'),
        r('3', level: 'L1', room: 'R-1'),
        r('4', room: 'Zebra'),
      ]);
      expect(stops.map((s) => '${s.level}/${s.room}'), ['L1/R-1', 'L1/null', 'null/Zebra', 'null/null']);
    });

    test('assets inside a room are in natural name order', () {
      final stops = groupRouteForWalk([
        r('x', room: 'R', name: 'AHU-10'),
        r('y', room: 'R', name: 'ahu-2'),
        r('z', room: 'R', name: 'AHU-1'),
      ]);
      expect(stops.single.rows.map((r) => r.name), ['AHU-1', 'ahu-2', 'AHU-10']);
    });

    test('reads the Level step of the location walk', () {
      final row = routeAssetRowFromClaims(
        assetId: 'a',
        claims: _claims(
          locationPath: [
            {'level': 'Level', 'label': 'Basement', 'code': 'B1'},
            {'level': 'Room', 'label': 'Plant Room', 'code': null},
          ],
        ),
      );
      expect((row.levelLabel, row.roomLabel), ('B1', 'Plant Room'));
    });
  });

  // FR-5.3 "live and offline" — found in the 2026-10-08 review: the count
  // only moved on the next pack download, so an offline walk read 0 verified.
  group('offline progress', () {
    PendingMutation verify(String assetId, String result, {String id = 'm'}) => PendingMutation(
      clientMutationId: '$id-$assetId',
      method: 'post',
      url: '/api/c2o/assets/$assetId/verify',
      body: {'result': result},
      label: 'Submit asset verification',
      attempts: 0,
      createdAt: DateTime(2026, 10, 8),
      entityType: 'Asset',
      entityId: assetId,
    );

    RouteAssetRow row(String id, [String status = 'pending']) =>
        RouteAssetRow(id: id, name: id, roomLabel: null, status: status);

    test('maps a result to the status the server will set', () {
      expect(verificationStatusForResult('verified'), 'verified');
      expect(verificationStatusForResult('missing'), 'missing');
      expect(verificationStatusForResult('mismatch'), 'mismatch');
      expect(verificationStatusForResult('damaged'), 'mismatch');
      expect(verificationStatusForResult('inaccessible'), 'mismatch');
    });

    test('a queued check counts at once and is marked waiting', () {
      final rows = applyQueuedChecks(
        [row('a'), row('b'), row('c')],
        [verify('a', 'verified'), verify('b', 'missing')],
      );
      final progress = RouteProgress.from(rows);
      expect((progress.verified, progress.flagged, progress.outstanding), (1, 1, 1));
      expect(rows.map((r) => r.queued), [true, true, false]);
    });

    test('a queued check beats a re-downloaded "pending", newest wins', () {
      final rows = applyQueuedChecks(
        [row('a', 'pending')],
        [verify('a', 'mismatch', id: '1'), verify('a', 'verified', id: '2')],
      );
      expect(rows.single.status, 'verified');
    });

    test('other queued writes and other assets are ignored', () {
      final other = PendingMutation(
        clientMutationId: 'x',
        method: 'patch',
        url: '/api/fm/work-orders/a',
        body: const {'result': 'verified'},
        label: 'Close',
        attempts: 0,
        createdAt: DateTime(2026, 10, 8),
        entityType: 'Asset',
        entityId: 'a',
      );
      final rows = applyQueuedChecks([row('a')], [other, verify('zzz', 'verified')]);
      expect(rows.single.status, 'pending');
      expect(rows.single.queued, isFalse);
    });

    test('the cached claim keeps every field and takes the new status', () {
      final cached = CachedC2oAsset(
        assetId: 'a',
        assetReferenceId: 'REF-1',
        scanToken: 'tok',
        claims: {
          'asset': {'id': 'a', 'assetName': 'Pump', 'verificationStatus': 'pending'},
          'history': const [],
        },
        cachedAt: DateTime(2026, 10, 1),
        packStamp: 'v1',
      );
      final out = withLocalVerificationStatus(cached, 'verified');
      expect(out.claims['asset'], {'id': 'a', 'assetName': 'Pump', 'verificationStatus': 'verified'});
      expect(out.claims['history'], const []);
      expect((out.scanToken, out.packStamp, out.assetReferenceId), ('tok', 'v1', 'REF-1'));
      expect(routeAssetRowFromClaims(assetId: 'a', claims: out.claims).isVerified, isTrue);
      expect(cached.claims['asset']['verificationStatus'], 'pending', reason: 'the original is not mutated');
    });
  });
}

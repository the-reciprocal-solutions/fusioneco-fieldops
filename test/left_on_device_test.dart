import 'package:technician_portal/core/offline/left_on_device.dart';
import 'package:technician_portal/core/offline/sign_out_wipe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FR-4.10 unsentLocalCountQueries', () {
    test('counts the rows each filtered sign-out step keeps, and nothing else', () {
      final queries = unsentLocalCountQueries(const [
        SignOutWipeStep('cached_entities'), // wiped whole: never unsent work
        SignOutWipeStep('snags', where: 'local_only = 0'),
        SignOutWipeStep('ar_progress', where: 'pending = 0'),
      ]);
      expect(queries, [
        'SELECT COUNT(*) FROM snags WHERE NOT (local_only = 0)',
        'SELECT COUNT(*) FROM ar_progress WHERE NOT (pending = 0)',
      ]);
    });

    test('follows the real sign-out plan, so "unsent" is defined in one place', () {
      final filtered = kSignOutWipe.where((s) => s.where != null).length;
      expect(unsentLocalCountQueries(), hasLength(filtered));
      expect(filtered, greaterThan(0));
    });
  });

  group('FR-4.10 DraftSummary.fromPayload', () {
    final at = DateTime(2026, 10, 8, 10, 30);

    test('reads the name, claims and photo count the form stored', () {
      final d = DraftSummary.fromPayload('a-1', at, {
        'assetName': 'VLV-03',
        'claimedSerial': 'BEL-1',
        'claimedTag': 'TAG-1',
        'floorId': 'f-1',
        'photos': [
          {'bytesBase64': '', 'fileName': 'a.jpg'},
          {'bytesBase64': '', 'fileName': 'b.jpg'},
        ],
      });
      expect(d.assetName, 'VLV-03');
      expect(d.claimedSerial, 'BEL-1');
      expect(d.claimedTag, 'TAG-1');
      expect(d.floorId, 'f-1');
      expect(d.photoCount, 2);
      expect(d.updatedAt, at);
    });

    test('a draft saved before names were stored still lists, unnamed', () {
      final d = DraftSummary.fromPayload('a-2', at, {'result': 'verified', 'assetName': ''});
      expect(d.assetName, isNull);
      expect(d.photoCount, 0);
    });
  });

  group('FR-4.10 LeftOnDevice.isEmpty', () {
    final draft = DraftSummary(assetId: 'a', updatedAt: DateTime(2026));

    test('only when queue, drafts and local-only rows are all empty', () {
      expect(LeftOnDevice.empty.isEmpty, isTrue);
      expect(const LeftOnDevice(queued: 1, drafts: [], unsentLocal: 0).isEmpty, isFalse);
      expect(LeftOnDevice(queued: 0, drafts: [draft], unsentLocal: 0).isEmpty, isFalse);
      expect(const LeftOnDevice(queued: 0, drafts: [], unsentLocal: 2).isEmpty, isFalse);
    });
  });
}

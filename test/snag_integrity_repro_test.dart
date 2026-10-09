// Reproducers for the owner's iPhone snag report (2026-10-10):
//   2. "I started one snag in walk mode and captured one photo … it somehow
//      got added to an existing snag's after-photos."
//   3. "Some of the snags were not visible, and some of the status and
//      other metadata was missing."
// Each test is written against the repository API as it was before the fix
// and failed on that code (see docs/snag-assistant.md §6 "Integrity").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/capture/capture_services.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/snag/snag_rules.dart';
import 'package:technician_portal/data/snag_repository.dart';
import 'package:technician_portal/domain/snag.dart';

import 'snag_test_rig.dart';

const _s = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

Map<String, dynamic> _serverRow(Snag s, {String status = 'in-progress', List<Map<String, dynamic>>? evidence, bool withActivity = true}) => {
  'id': s.id,
  'reference': s.reference,
  'number': s.number,
  'context': s.context.wire,
  'issueType': s.issueType,
  'trade': s.trade,
  'priority': s.priority.wire,
  'title': s.title,
  'status': status,
  'buildingId': s.buildingId,
  'floorId': s.floorId,
  'spaceId': s.spaceId,
  'locationLabel': s.locationLabel,
  'surveyId': s.surveyId,
  'raisedBy': s.raisedBy,
  'evidence': evidence ?? [for (final e in s.evidence) e.toJson()..remove('localPath')],
  if (withActivity)
    'activity': [
      {'id': 'srv-1', 'type': 'raised', 'at': '2026-10-09T08:00:00Z', 'by': s.raisedBy},
    ],
  'createdAt': '2026-10-09T08:00:00Z',
  'updatedAt': '2026-10-09T08:00:00Z',
};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('snag_repro'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('bug 2 — a walk shot lands on another snag', () {
    // What a walk shot looks like to the duplicate guard: room, trade and the
    // default issue type, no title, a new survey.
    const walkShot = SnagDraftSignature(
      trade: 'electrical',
      buildingId: rigBuilding,
      floorId: 'f1',
      spaceId: 'r1',
      issueType: 'defect',
      surveyId: 'walk-2',
      raisedBy: 'me',
    );

    test('a snag already marked ready (fix photos waiting for verification) is never offered as a duplicate', () {
      final ready = rigSnag(
        status: SnagStatus.ready,
        evidence: [rigPhoto('b1'), rigPhoto('a1', stage: 'after')],
      );
      expect(SnagDuplicateFinder.find(walkShot, [ready]), isEmpty,
          reason: '"Same issue — add my photo" would put the shot beside its after-photos');
    });

    test('raise() refuses an id that already names another snag instead of replacing it', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      final existing = rigSnag(status: SnagStatus.ready, evidence: [rigPhoto('b1', url: 'https://f/b1.jpg')]);
      await rig.put(existing);
      Object? error;
      try {
        await rig.repo.raise(
          SnagDraft(
            id: existing.id,
            context: SnagContext.fmTakeover,
            trade: 'plumbing',
            priority: SnagPriority.major,
            buildingId: rigBuilding,
            photos: [CapturedPhoto(bytes: rigJpeg, fileName: 'snag.jpg')],
          ),
          rigMe,
        );
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      final after = (await rig.local(existing.id))!;
      expect(after.status, SnagStatus.ready);
      expect(after.trade, 'electrical');
      expect(after.evidence.map((e) => e.id), ['b1']);
    });

    test('a write built from an older copy keeps the newer status and after-photo on the phone', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      final stale = rigSnag(status: SnagStatus.inProgress, evidence: [rigPhoto('b1', url: 'https://f/b1.jpg')]);
      // Saved since the screen built `stale`: the fix was marked ready.
      final fresh = rigSnag(
        status: SnagStatus.ready,
        evidence: [rigPhoto('b1', url: 'https://f/b1.jpg'), rigPhoto('a1', stage: 'after', url: 'https://f/a1.jpg')],
      );
      await rig.put(fresh);
      await rig.repo.addEvidence(stale, rigMe, photos: [CapturedPhoto(bytes: rigJpeg, fileName: 'x.jpg')]);
      final after = (await rig.local(_s))!;
      expect(after.status, SnagStatus.ready);
      expect(after.evidence.map((e) => e.id), containsAll(['b1', 'a1']));
      expect(after.evidence, hasLength(3));
    });
  });

  group('bug 3 — snags or their metadata go missing', () {
    test('a pull keeps this phone\'s own photo that the server does not have', () async {
      final own = '${tmp.path}/snag_media/own/$_s/e2.jpg';
      final local = rigSnag(evidence: [
        rigPhoto('e1', url: 'https://f/e1.jpg', localPath: '${tmp.path}/snag_media/own/$_s/e1.jpg'),
        rigPhoto('e2', stage: 'extra', localPath: own, by: 'me'),
      ]);
      final server = _serverRow(local, status: 'open', evidence: [
        {'id': 'e1', 'kind': 'photo', 'stage': 'before', 'url': 'https://f/e1.jpg'},
      ]);
      final rig = SnagRig((m, p, d, q) => p == '/api/snags' ? rigList([server]) : {'data': server}, tmp);
      await rig.put(local);
      await rig.repo.refresh(buildingId: rigBuilding);
      final after = (await rig.local(_s))!;
      expect(after.evidence.map((e) => e.id), ['e1', 'e2']);
      expect(after.evidence.last.localPath, own);
    });

    test('a refused change on a known snag is replaced by the server\'s truth, even when later pulls are deltas', () async {
      final base = rigSnag(status: SnagStatus.inProgress, raisedBy: 'someone', evidence: [rigPhoto('b1', url: 'https://f/b1.jpg')]);
      var transitionCalls = 0;
      final rig = SnagRig((m, p, d, q) {
        if (p == '/api/upload/image') return {'data': {'url': 'https://f/new.jpg'}};
        if (p == '/api/snags/$_s/transition') {
          // First try: no signal (queued). On replay: refused.
          if (transitionCalls++ == 0) throw const NetworkFailure();
          throw const HttpFailure(status: 409, message: 'Snag is already closed.', body: {'code': 'INVALID_TRANSITION'});
        }
        if (m == 'GET' && p == '/api/snags/$_s') return {'data': _serverRow(base, status: 'in-progress')};
        if (m == 'GET' && p == '/api/snags') return rigList(const [], serverTime: '2026-10-10T09:00:00.000Z');
        throw StateError('unexpected $m $p');
      }, tmp);
      await rig.put(base);
      // A cursor from a recent full pull: the next pulls are deltas.
      final cursor = '${DateTime.utc(2026, 10, 10, 8).millisecondsSinceEpoch}|${DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch}';
      rig.db.meta['snag.cursor.$rigBuilding'] = cursor;
      rig.db.meta['snag.cursor.v2.$rigBuilding'] = cursor;

      await rig.repo.transition(base, SnagAction.ready, rigMe, photos: [CapturedPhoto(bytes: rigJpeg, fileName: 'after.jpg')]);
      expect((await rig.local(_s))!.status, SnagStatus.ready, reason: 'optimistic, queued');
      await rig.sync.flushQueue();
      await rig.settle();
      await rig.repo.refresh(buildingId: rigBuilding);

      final after = (await rig.local(_s))!;
      expect(rig.api.queries.last!.containsKey('updatedSince'), isTrue, reason: 'a delta, which never re-sends an unchanged row');
      expect(after.status, SnagStatus.inProgress, reason: 'the server never accepted "ready"');
      expect(after.sendIssue?.dropped, isTrue, reason: 'still says Not sent');
    });

    test('a full pull never prunes a server-known snag that still holds an unsent photo', () async {
      final local = rigSnag(evidence: [
        rigPhoto('e1', url: 'https://f/e1.jpg'),
        rigPhoto('e2', stage: 'extra', localPath: '${tmp.path}/snag_media/own/$_s/e2.jpg', by: 'me'),
      ]);
      final rig = SnagRig((m, p, d, q) => rigList(const []), tmp);
      await rig.put(local);
      await rig.repo.refresh(buildingId: rigBuilding);
      expect(await rig.local(_s), isNotNull);
    });

    test('a device clock that went backwards forces a full pull instead of deltas forever', () async {
      final rig = SnagRig((m, p, d, q) => rigList(const [], serverTime: '2026-10-10T09:00:00.000Z'), tmp);
      // Last full pull stamped "tomorrow" by a clock that has since been corrected.
      final cursor = '${DateTime.utc(2026, 10, 10, 8).millisecondsSinceEpoch}|${DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch}';
      rig.db.meta['snag.cursor.$rigBuilding'] = cursor;
      rig.db.meta['snag.cursor.v2.$rigBuilding'] = cursor;
      await rig.repo.refresh(buildingId: rigBuilding);
      expect(rig.api.queries.first!.containsKey('updatedSince'), isFalse);
    });

    test('a full pull restores the timeline a lean row left out', () async {
      final known = rigSnag(status: SnagStatus.inProgress);
      final rig = SnagRig((m, p, d, q) {
        if (p == '/api/snags') return rigList([_serverRow(known, withActivity: false)]);
        if (p == '/api/snags/$_s') return {'data': _serverRow(known)};
        throw StateError('unexpected $m $p');
      }, tmp);
      await rig.repo.refresh(buildingId: rigBuilding);
      final after = (await rig.local(_s))!;
      expect(after.activity, isNotEmpty, reason: 'status history comes back without opening the snag');
    });

    test('a list row that leaves a field out keeps the device\'s value', () async {
      final local = rigSnag(status: SnagStatus.inProgress);
      final row = _serverRow(local)
        ..remove('locationLabel')
        ..remove('surveyId')
        ..remove('activity');
      final rig = SnagRig((m, p, d, q) => p == '/api/snags' ? rigList([row]) : {'data': _serverRow(local)}, tmp);
      await rig.put(local);
      await rig.repo.refresh(buildingId: rigBuilding);
      final after = (await rig.local(_s))!;
      expect(after.locationLabel, 'Tower A › L1 › Room 101');
      expect(after.surveyId, 'walk-1');
    });
  });
}

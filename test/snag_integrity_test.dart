// The 2026-10-10 snag integrity fixes: one walk shot = one new snag, the
// guarded "+1" on the raise form, the developer integrity log and the pure
// merge / scan helpers. Reproducers for the owner's report are in
// snag_integrity_repro_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/capture/capture_services.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/snag/snag_integrity_log.dart';
import 'package:technician_portal/core/snag/snag_integrity_scan.dart';
import 'package:technician_portal/core/snag/snag_rules.dart';
import 'package:technician_portal/data/snag_repository.dart';
import 'package:technician_portal/domain/snag.dart';

import 'snag_test_rig.dart';

const _existing = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _new = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

SnagDraft _shot({String id = _new, String? surveyId = 'walk-2', String? title}) => SnagDraft(
  id: id,
  context: SnagContext.fmTakeover,
  trade: 'electrical',
  priority: SnagPriority.minor,
  title: title,
  buildingId: rigBuilding,
  floorId: 'f1',
  spaceId: 'r1',
  surveyId: surveyId,
  photos: [CapturedPhoto(bytes: rigJpeg, fileName: 'snag.jpg')],
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('snag_integrity'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('saveShot', () {
    test('walk: a shot in a room with a matching live snag raises a NEW snag and never touches the other', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      final other = rigSnag(status: SnagStatus.inProgress, surveyId: 'walk-1', evidence: [rigPhoto('b1', url: 'https://f/b1.jpg')]);
      await rig.put(other);
      // The guard WOULD flag it (room + trade + default type = 0.65)…
      expect(SnagDuplicateFinder.find(_shot().signature(raisedBy: 'me'), [other]), hasLength(1));
      var asked = 0;
      final r = await rig.repo.saveShot(_shot(), rigMe, mode: SnagShotMode.walk, confirmDuplicate: (c) async {
        asked++;
        return DuplicateDecision(DuplicateChoice.sameIssue, other);
      });
      // …but walk mode never asks and never attaches.
      expect(asked, 0);
      expect(r.addedToExisting, isFalse);
      expect(r.snag.id, _new);
      final untouched = (await rig.local(_existing))!;
      expect(untouched.evidence.map((e) => e.id), ['b1']);
      expect(untouched.reportCount, 1);
      expect((await rig.local(_new))!.evidence.single.stage, 'before');
      expect(rig.db.queue.map((m) => m.url), ['/api/snags'], reason: 'one create, no evidence POST to another snag');
    });

    test('raise form: "Same issue" adds an extra photo to the chosen open snag', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      final other = rigSnag(status: SnagStatus.open, surveyId: null);
      await rig.put(other);
      final r = await rig.repo.saveShot(
        _shot(surveyId: null),
        rigMe,
        mode: SnagShotMode.single,
        confirmDuplicate: (c) async => DuplicateDecision(DuplicateChoice.sameIssue, c.single.snag),
      );
      expect(r.addedToExisting, isTrue);
      final s = (await rig.local(_existing))!;
      expect(s.evidence.single.stage, 'extra', reason: 'never an after-photo');
      expect(await rig.local(_new), isNull);
    });

    test('raise form: a pick that is no longer a candidate (or never synced) raises a new snag instead', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      await rig.put(rigSnag(status: SnagStatus.open, surveyId: null));
      final stranger = rigSnag(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', status: SnagStatus.ready, surveyId: null);
      final r = await rig.repo.saveShot(
        _shot(surveyId: null),
        rigMe,
        mode: SnagShotMode.single,
        confirmDuplicate: (c) async => DuplicateDecision(DuplicateChoice.sameIssue, stranger),
      );
      expect(r.addedToExisting, isFalse);
      expect(r.snag.id, _new);
    });

    test('raise form: a ready snag is not offered at all', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      await rig.put(rigSnag(status: SnagStatus.ready, surveyId: null));
      var asked = 0;
      await rig.repo.saveShot(_shot(surveyId: null), rigMe, mode: SnagShotMode.single, confirmDuplicate: (c) async {
        asked++;
        return const DuplicateDecision(DuplicateChoice.different);
      });
      expect(asked, 0);
    });
  });

  group('integrity log (developer only)', () {
    test('a reused id is refused and logged', () async {
      final rig = SnagRig((m, p, d, q) => throw const NetworkFailure(), tmp);
      await rig.put(rigSnag(id: _new));
      await expectLater(rig.repo.raise(_shot(), rigMe), throwsStateError);
      final events = await rig.repo.integrity.read();
      expect(events.single['kind'], SnagIntegrityLog.idReused);
      expect(events.single['snagId'], _new);
    });

    test('dedupe key writes once; the file is capped', () async {
      final log = SnagIntegrityLog(() async => File('${tmp.path}/diag/i.jsonl'));
      await log.record('k', snagId: 's', dedupeKey: 'once');
      await log.record('k', snagId: 's', dedupeKey: 'once');
      expect(await log.read(), hasLength(1));
      for (var i = 0; i < SnagIntegrityLog.maxLines + 5; i++) {
        await log.record('n', detail: {'i': i});
      }
      final all = await log.read();
      expect(all, hasLength(SnagIntegrityLog.maxLines));
      expect(all.last['detail'], {'i': SnagIntegrityLog.maxLines + 4});
    });

    test('a full pull logs +1 photos and lone after-photos, once', () async {
      final plusOne = rigSnag(
        evidence: [rigPhoto('b1', url: 'https://f/b1'), rigPhoto('x1', stage: 'extra', url: 'https://f/x1', by: 'me')],
        activity: [
          SnagActivity(id: 'a1', at: DateTime.utc(2026, 10, 9), type: 'raised', by: 'someone'),
          SnagActivity(id: 'a2', at: DateTime.utc(2026, 10, 9), type: 'duplicate-report', by: 'me'),
        ],
      );
      final rows = [
        {...plusOne.toJson()..remove('localOnly'), 'reference': 'SN-00007'},
      ];
      final rig = SnagRig((m, p, d, q) => rigList(rows, lean: false), tmp);
      await rig.repo.refresh(buildingId: rigBuilding, actorId: 'me');
      await rig.repo.refresh(buildingId: rigBuilding, actorId: 'me', full: true);
      final found = (await rig.repo.integrity.read()).where((e) => e['kind'] == SnagIntegrityScan.possibleMisattached).toList();
      expect(found, hasLength(1));
      expect(found.single['detail'], {'ref': 'SN-00007', 'evidenceIds': ['x1']});
    });
  });

  group('pure helpers', () {
    test('scan: lone after-photo is reported; a lean row (no timeline) is not judged', () {
      final lone = rigSnag(
        evidence: [rigPhoto('a1', stage: 'after', by: 'x')],
        activity: [SnagActivity(id: 'r', at: DateTime.utc(2026), type: 'raised', by: 'me')],
      );
      final fixed = rigSnag(
        id: 'f',
        evidence: [rigPhoto('a2', stage: 'after', by: 'x')],
        activity: [SnagActivity(id: 'r', at: DateTime.utc(2026), type: 'ready', by: 'x')],
      );
      final lean = rigSnag(id: 'l', evidence: [rigPhoto('a3', stage: 'after', by: 'x')]);
      final f = SnagIntegrityScan.find([lone, fixed, lean]);
      expect(f.single.kind, SnagIntegrityScan.afterPhotoWithoutReady);
      expect(f.single.evidenceIds, ['a1']);
    });

    test('mergeServerRow: absent keys keep the device value, explicit null clears it', () {
      final local = rigSnag(status: SnagStatus.ready);
      final merged = SnagRepository.mergeServerRow(
        {'id': _existing, 'status': 'in-progress', 'readyAt': null, 'locationLabel': null},
        local,
        lean: true,
      );
      expect(merged.status, SnagStatus.inProgress);
      expect(merged.locationLabel, isNull, reason: 'the server said null');
      expect(merged.surveyId, 'walk-1', reason: 'not in the row: kept');
      expect(merged.reference, 'SN-00007');
    });

    test('mergeServerRow ignores a local copy of a DIFFERENT snag', () {
      final other = rigSnag(id: 'zzz', title: 'Someone else', evidence: [rigPhoto('p', localPath: '/x/snag_media/own/zzz/p.jpg')]);
      final merged = SnagRepository.mergeServerRow({'id': _existing, 'title': 'Mine'}, other);
      expect(merged.title, 'Mine');
      expect(merged.evidence, isEmpty);
    });

    test('mergeEvidence keeps only own captures filed under THIS snag', () {
      final local = [
        rigPhoto('mine', localPath: '/d/snag_media/own/$_existing/mine.jpg'),
        rigPhoto('elsewhere', localPath: '/d/snag_media/own/$_new/elsewhere.jpg'),
        rigPhoto('sent', localPath: '/d/snag_media/own/$_existing/sent.jpg'),
      ];
      final server = [rigPhoto('sent', url: 'https://f/sent.jpg')];
      final merged = SnagRepository.mergeEvidence(_existing, server, local);
      expect(merged.map((e) => e.id), ['sent', 'mine']);
      expect(merged.first.localPath, '/d/snag_media/own/$_existing/sent.jpg');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/domain/permit.dart';

void main() {
  group('PermitSummary.fromJson — server DTO', () {
    final server = {
      'id': 'p1',
      'permitNo': 'PTW-00042',
      'type': 'hot_work',
      'status': 'active',
      'title': 'Weld repair on chiller pipework',
      'buildingId': 'b1',
      'buildingName': 'Tower A',
      'riskScore': '7.5', // Sequelize DECIMAL as string
      'riskLevel': 'high',
      'crewOnSite': '2',
      'isolationsLive': '1',
      'conflictCount': '0',
      'currentStage': {'stage': 'issuer', 'label': 'Issuer sign-off'},
      'validUntil': '2026-09-26T18:00:00.000Z',
      'createdAt': '2026-09-26T08:00:00.000Z',
      'updatedAt': '2026-09-26T09:00:00.000Z',
    };

    test('parses string numbers, dates and the current stage', () {
      final p = PermitSummary.fromJson(server);
      expect(p.riskScore, 7.5);
      expect(p.crewOnSite, 2);
      expect(p.isolationsLive, 1);
      expect(p.conflictCount, 0);
      expect(p.currentStage!.stage, 'issuer');
      expect(p.currentStage!.label, 'Issuer sign-off');
      expect(p.isLive, isTrue);
      expect(p.isActive, isTrue);
      expect(p.isSuspended, isFalse);
    });

    test('missing optional fields fall back rather than throwing', () {
      final p = PermitSummary.fromJson({'id': 'p2'});
      expect(p.permitNo, '');
      expect(p.type, 'general');
      expect(p.status, 'draft');
      expect(p.title, 'Permit');
      expect(p.riskScore, 0);
      expect(p.riskLevel, 'low');
      expect(p.currentStage, isNull);
      expect(p.crewOnSite, 0);
      expect(p.flags.occupiedArea, isFalse);
      expect(p.isLive, isFalse);
      expect(p.isSuspended, isFalse);
      // createdAt/updatedAt are required-with-fallback: never null.
      expect(p.createdAt, isNotNull);
      expect(p.updatedAt, isNotNull);
    });

    test('validityMinutesLeft is null with no validity window, negative once expired', () {
      final noWindow = PermitSummary.fromJson({'id': 'p3'});
      expect(noWindow.validityMinutesLeft(DateTime.now()), isNull);

      final expired = PermitSummary.fromJson({
        ...server,
        'validUntil': '2026-09-26T08:00:00.000Z',
      });
      // `asDate` converts the wire UTC timestamp `.toLocal()`, so "now" must
      // be derived from that same parsed value rather than a literal
      // wall-clock DateTime — a literal like `DateTime(2026, 9, 26, 9)` is
      // implicitly local, and comparing it against a UTC-parsed instant
      // makes the assertion's sign depend on the test machine's timezone
      // offset (this failed on a UTC+5:30 machine).
      final now = expired.validUntil!.add(const Duration(hours: 1));
      expect(expired.validityMinutesLeft(now), lessThan(0));
    });

    test('listFromJson unwraps a bare items list, the way PermitRepository.mine calls it', () {
      // `PermitRepository.mine` unwraps the `{success,data:{items}}` envelope
      // itself (`unwrapMap`) and hands `listFromJson` the bare items array —
      // `listFromJson`'s own `unwrapList` only strips one further envelope
      // layer (a `{data:[...]}` shape), not a nested `items` key.
      final list = PermitSummary.listFromJson([server, {'id': 'p2'}]);
      expect(list, hasLength(2));
      expect(list.first.id, 'p1');
    });

    test('listFromJson also unwraps a single-level {data:[...]} envelope', () {
      final list = PermitSummary.listFromJson({
        'success': true,
        'data': [server, {'id': 'p2'}],
      });
      expect(list, hasLength(2));
      expect(list.first.id, 'p1');
    });

    test('listFromJson returns empty for a missing or malformed items list', () {
      expect(PermitSummary.listFromJson({'success': true, 'data': {}}), isEmpty);
      expect(PermitSummary.listFromJson(null), isEmpty);
    });
  });

  group('PermitFlags.fromJson', () {
    test('parses booleans and the impaired-zones list, defaulting a non-map', () {
      final flags = PermitFlags.fromJson({
        'occupiedArea': true,
        'outOfHours': 'true', // tolerant string bool
        'outdoor': false,
        'fireSystemImpairment': 1,
        'impairedZones': ['z1', 'z2'],
      });
      expect(flags.occupiedArea, isTrue);
      expect(flags.outOfHours, isTrue);
      expect(flags.fireSystemImpairment, isTrue);
      expect(flags.impairedZones, ['z1', 'z2']);

      final none = PermitFlags.fromJson('not a map');
      expect(none.occupiedArea, isFalse);
      expect(none.impairedZones, isEmpty);
    });
  });

  group('PermitReadiness.fromJson', () {
    final readinessJson = {
      'lifecycle': [
        {'key': 'request', 'label': 'Request', 'state': 'done'},
        {'key': 'approve', 'label': 'Approve', 'state': 'current'},
      ],
      'nextAction': {'action': 'record_gas_test', 'label': 'Record a gas test', 'by': 'crew'},
      'issueBlockers': [
        {'code': 'GAS_STALE', 'message': 'Gas test needed', 'severity': 'block', 'target': 'gas'},
      ],
      'closeBlockers': [
        {'code': 'ISO_NOT_RESTORED', 'message': 'Isolations not restored', 'severity': 'warn', 'target': 'isolations'},
      ],
      'gas': {
        'required': true,
        'lastTestAt': '2026-09-26T07:00:00.000Z',
        'lastResult': 'pass',
        'retestMinutes': '60',
        'fresh': true,
      },
      'isolation': {'required': true, 'total': '3', 'planned': '0', 'isolated': '2', 'verified': '1', 'restored': '0'},
      'crew': {'total': '4', 'onSite': '3', 'signedOff': '0', 'missingRoles': ['fire_watch']},
      'checks': {'preDone': '2', 'preTotal': '5', 'closeDone': '0', 'closeTotal': '3'},
      'validity': {'minutesLeft': '45'},
      'fireWatch': {'running': true, 'minutesLeft': '10'},
      'risk': {'score': '7.5', 'level': 'high'},
      'conflicts': [
        {'id': 'c1'},
      ],
    };

    test('folds every section, tolerating string numbers throughout', () {
      final r = PermitReadiness.fromJson(readinessJson);
      expect(r.lifecycle, hasLength(2));
      expect(r.lifecycle.first.isDone, isTrue);
      expect(r.lifecycle.last.isCurrent, isTrue);
      expect(r.nextAction!.action, 'record_gas_test');
      expect(r.nextAction!.isForCrew, isTrue);
      expect(r.issueBlockers.single.isBlocking, isTrue);
      expect(r.closeBlockers.single.isBlocking, isFalse);
      expect(r.allBlockers, hasLength(2));
      expect(r.hasBlockingIssue, isTrue);
      expect(r.gasRequired, isTrue);
      expect(r.gasRetestMinutes, 60);
      expect(r.isolationTotal, 3);
      expect(r.isolationVerified, 1);
      expect(r.crewTotal, 4);
      expect(r.crewMissingRoles, ['fire_watch']);
      expect(r.checksPreDone, 2);
      expect(r.validityMinutesLeft, 45);
      expect(r.fireWatchRunning, isTrue);
      expect(r.fireWatchMinutesLeft, 10);
      expect(r.riskScore, 7.5);
      expect(r.riskLevel, 'high');
      expect(r.conflictCount, 1);
    });

    test('a missing fireWatch section reads as not running, not a crash', () {
      final r = PermitReadiness.fromJson({...readinessJson, 'fireWatch': null});
      expect(r.fireWatchRunning, isFalse);
      expect(r.fireWatchMinutesLeft, isNull);
    });

    test('PermitReadiness.empty is the default for a missing readiness object', () {
      final r = PermitReadiness.fromJson(null);
      expect(r.lifecycle, isEmpty);
      expect(r.nextAction, isNull);
      expect(r.issueBlockers, isEmpty);
      expect(r.hasBlockingIssue, isFalse);
      expect(r.riskLevel, 'low');
    });

    test('nextAction and blockers with no action/code fall back to null / empty defaults', () {
      expect(PermitNextAction.fromJson(null), isNull);
      expect(PermitNextAction.fromJson({'label': 'no action key'}), isNull);
      expect(PermitNextAction.fromJson({'action': 'suspend'})!.by, 'anyone');
      expect(PermitNextAction.fromJson({'action': 'suspend'})!.isForCrew, isTrue);
      expect(PermitNextAction.fromJson({'action': 'sign_on_crew', 'by': 'issuer'})!.isForCrew, isFalse);

      final blocker = PermitBlocker.fromJson({});
      expect(blocker.code, '');
      expect(blocker.severity, 'warn');
      expect(blocker.isBlocking, isFalse);
      expect(blocker.target, 'details');
    });
  });

  group('GasProfile.fromJson', () {
    test('parses limits (min may be absent) and retestMinutes as a string', () {
      final profile = GasProfile.fromJson({
        'limits': [
          {'gas': 'o2', 'label': 'Oxygen', 'unit': '% vol', 'min': 19.5, 'max': 23.5},
          {'gas': 'lel', 'label': 'LEL', 'unit': '% LEL', 'max': '10'},
        ],
        'retestMinutes': '30',
      });
      expect(profile.limits, hasLength(2));
      expect(profile.retestMinutes, 30);
      expect(profile.limitFor('o2')!.min, 19.5);
      expect(profile.limitFor('lel')!.min, isNull);
      expect(profile.limitFor('lel')!.max, 10);
      expect(profile.limitFor('co'), isNull);
    });

    test('GasProfile.empty is the default for a missing profile', () {
      expect(GasProfile.fromJson(null).limits, isEmpty);
      expect(GasProfile.fromJson('nonsense').retestMinutes, 0);
    });
  });

  group('PermitCrew — sign-on/off and restore ownership', () {
    test('isMe matches either technicianId or userId', () {
      final crew = PermitCrew.fromJson({
        'id': 'c1',
        'permitId': 'p1',
        'name': 'Sam',
        'role': 'performer',
        'technicianId': 't1',
      });
      expect(crew.isMe('t1'), isTrue);
      expect(crew.isMe('someone-else'), isFalse);
      expect(crew.isMe(null), isFalse);
      expect(crew.needsSignOn, isTrue);
    });

    test('status helpers and defaults for a bare server row', () {
      final crew = PermitCrew.fromJson({'id': 'c2', 'permitId': 'p1'});
      expect(crew.role, 'performer'); // default
      expect(crew.status, 'expected'); // default
      expect(crew.isOnSite, isFalse);
      expect(crew.isSignedOff, isFalse);
      expect(crew.competencyMissing, isEmpty);
    });
  });

  group('PermitIsolation.canRestore — only the person who applied the lock', () {
    test('true only when verified and the same session user isolated it', () {
      final iso = PermitIsolation.fromJson({
        'id': 'i1',
        'permitId': 'p1',
        'pointTag': 'MCC-1',
        'energyType': 'electrical',
        'method': 'lockout',
        'status': 'verified',
        'isolatedBy': 't1',
      });
      expect(iso.canRestore('t1'), isTrue);
      expect(iso.canRestore('t2'), isFalse);
      expect(iso.canRestore(null), isFalse);

      final planned = PermitIsolation.fromJson({
        'id': 'i2',
        'permitId': 'p1',
        'pointTag': 'MCC-2',
        'energyType': 'electrical',
        'method': 'lockout',
        'isolatedBy': 't1',
      });
      expect(planned.isPlanned, isTrue);
      expect(planned.canRestore('t1'), isFalse); // not verified yet
    });
  });

  group('PermitDetail.fromJson / fromJsonOrNull', () {
    Map<String, dynamic> fullPermit() => {
          'id': 'p1',
          'permitNo': 'PTW-00042',
          'type': 'hot_work',
          'status': 'active',
          'title': 'Weld repair',
          'riskLikelihood': '3',
          'riskSeverity': '4',
          'hazards': ['fire', 'fumes'],
          'controls': ['fire_watch', 'ventilation'],
          'ppe': ['gloves'],
          'qrToken': 'tok123',
          'checks': {
            'chk1': {'done': true, 'by': 't1', 'byName': 'Sam'},
          },
          'closeChecks': {},
          'checklist': {
            'pre': [
              {'id': 'chk1', 'text': 'Fire extinguisher on site', 'critical': true},
            ],
            'close': [
              {'id': 'cchk1', 'text': 'Area clear'},
            ],
          },
          'approvals': [
            {'stage': 'area', 'label': 'Area', 'status': 'approved'},
          ],
          'attachments': [
            {'id': 'a1', 'url': 'https://x/y.jpg', 'name': 'Photo', 'kind': 'photo', 'at': '2026-09-26T08:00:00.000Z'},
          ],
          'activity': [
            {'id': 'act1', 'at': '2026-09-26T08:00:00.000Z', 'type': 'issued'},
          ],
          'isolations': [
            {'id': 'i1', 'permitId': 'p1', 'pointTag': 'MCC-1', 'energyType': 'electrical', 'method': 'lockout'},
          ],
          'gasTests': [
            {'id': 'g1', 'permitId': 'p1', 'testedAt': '2026-09-26T07:00:00.000Z', 'o2': '20.9', 'result': 'pass'},
          ],
          'crew': [
            {'id': 'c1', 'permitId': 'p1', 'name': 'Sam', 'role': 'performer'},
          ],
          'readiness': {'gas': {}, 'isolation': {}, 'crew': {}, 'checks': {}, 'validity': {}, 'risk': {}},
          'gasProfile': {
            'limits': [
              {'gas': 'o2', 'label': 'Oxygen', 'unit': '% vol', 'min': '19.5', 'max': '23.5'},
            ],
            'retestMinutes': 60,
          },
          'effective': {
            'types': ['hot_work'],
            'requiresIsolation': true,
            'fireWatchMinutes': '60',
            'requiredRoles': ['fire_watch'],
            'maxHours': '8',
            'maxExtensions': '1',
            'gasRequired': true,
          },
          'createdAt': '2026-09-26T06:00:00.000Z',
          'updatedAt': '2026-09-26T09:00:00.000Z',
        };

    test('parses every nested collection and the checklist split by pre/close', () {
      final permit = PermitDetail.fromJson(fullPermit());
      expect(permit.riskLikelihood, 3);
      expect(permit.riskSeverity, 4);
      expect(permit.hazards, ['fire', 'fumes']);
      expect(permit.controls, ['fire_watch', 'ventilation']);
      expect(permit.ppe, ['gloves']);
      expect(permit.qrToken, 'tok123');
      expect(permit.checks['chk1']!.done, isTrue);
      expect(permit.closeChecks, isEmpty);
      expect(permit.checklistPre.single.id, 'chk1');
      expect(permit.checklistPre.single.critical, isTrue);
      expect(permit.checklistClose.single.id, 'cchk1');
      expect(permit.approvals.single.stage, 'area');
      expect(permit.attachments.single.kind, 'photo');
      expect(permit.activity.single.type, 'issued');
      expect(permit.isolations.single.pointTag, 'MCC-1');
      expect(permit.gasTests.single.o2, 20.9);
      expect(permit.latestGasTest!.id, 'g1');
      expect(permit.crew.single.name, 'Sam');
      expect(permit.gasProfile.limitFor('o2')!.min, 19.5);
      expect(permit.effective.fireWatchMinutes, 60);
      expect(permit.effective.maxHours, 8);
      expect(permit.effective.gasRequired, isTrue);
    });

    test('myCrew finds this session\'s crew row by technicianId or userId', () {
      final permit = PermitDetail.fromJson({
        ...fullPermit(),
        'crew': [
          {'id': 'c1', 'permitId': 'p1', 'name': 'Sam', 'role': 'performer', 'technicianId': 't1'},
          {'id': 'c2', 'permitId': 'p1', 'name': 'Ann', 'role': 'fire_watch', 'userId': 'u2'},
        ],
      });
      expect(permit.myCrew('t1')!.name, 'Sam');
      expect(permit.myCrew('u2')!.name, 'Ann');
      expect(permit.myCrew('nobody'), isNull);
    });

    test('a permit missing every optional collection parses to empty ones', () {
      final permit = PermitDetail.fromJson({'id': 'bare'});
      expect(permit.hazards, isEmpty);
      expect(permit.controls, isEmpty);
      expect(permit.checks, isEmpty);
      expect(permit.checklistPre, isEmpty);
      expect(permit.checklistClose, isEmpty);
      expect(permit.isolations, isEmpty);
      expect(permit.gasTests, isEmpty);
      expect(permit.latestGasTest, isNull);
      expect(permit.crew, isEmpty);
      expect(permit.gasProfile.limits, isEmpty);
      expect(permit.effective.types, isEmpty);
      expect(permit.readiness.riskLevel, 'low');
    });

    test('fromJsonOrNull unwraps every envelope shape and is null when empty', () {
      final permit = fullPermit();
      expect(PermitDetail.fromJsonOrNull({'success': true, 'data': permit})!.id, 'p1');
      expect(PermitDetail.fromJsonOrNull({'message': 'ok', 'data': permit})!.id, 'p1');
      expect(PermitDetail.fromJsonOrNull({'data': permit})!.id, 'p1');
      expect(PermitDetail.fromJsonOrNull(permit)!.id, 'p1'); // raw record
      expect(PermitDetail.fromJsonOrNull({'data': null}), isNull);
      expect(PermitDetail.fromJsonOrNull(null), isNull);
      expect(PermitDetail.fromJsonOrNull({}), isNull);
    });
  });

  group('PermitCatalog.fromJson', () {
    test('parses labels, roles and gas limits, and looks them up with a raw-id fallback', () {
      final catalog = PermitCatalog.fromJson({
        'data': {
          'types': [
            {'key': 'hot_work', 'label': 'Hot Work'},
          ],
          'hazards': {'fire': 'Fire'},
          'controls': {'ventilation': 'Ventilation'},
          'ppe': {'gloves': 'Gloves'},
          'crewRoles': [
            {'key': 'fire_watch', 'label': 'Fire Watch'},
          ],
          'gasLimits': {
            'o2': {'gas': 'o2', 'label': 'Oxygen', 'unit': '% vol', 'min': 19.5, 'max': 23.5},
          },
        },
      });
      expect(catalog.typeLabel('hot_work'), 'Hot Work');
      expect(catalog.typeLabel('unknown_type'), 'unknown_type'); // fallback to the raw id
      expect(catalog.hazardLabel('fire'), 'Fire');
      expect(catalog.hazardLabel('unknown'), 'unknown');
      expect(catalog.roleLabel('fire_watch'), 'Fire Watch');
      expect(catalog.roleLabel('nope'), 'nope');
      expect(catalog.gasLimits['o2']!.max, 23.5);
    });

    test('PermitCatalog.empty is the default for a missing catalog', () {
      final catalog = PermitCatalog.fromJson(null);
      expect(catalog.types, isEmpty);
      expect(catalog.typeLabel('x'), 'x');
    });
  });
}

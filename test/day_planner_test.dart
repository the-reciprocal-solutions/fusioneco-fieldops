import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/day/day_planner.dart';
import 'package:technician_portal/domain/day_brief.dart';
import 'package:technician_portal/domain/maintenance_record.dart';

/// The phone's own day plan (docs/day-brief.md §Offline) — a port of the
/// server's dayBrief/rules.ts ordering over cached work orders.
final _now = DateTime(2026, 10, 10, 10, 0);

var _n = 0;
MaintenanceRecord wo(String title, {String priority = 'Medium', String status = 'Open', DateTime? due, String? building, String? floor, Map<String, dynamic> extra = const {}}) {
  _n++;
  return MaintenanceRecord.fromJson({
    'id': 'id-$title',
    'workOrderId': 'WO-${100 + _n}',
    'title': title,
    'priority': priority,
    'status': status,
    'dueDate': (due ?? DateTime(2026, 10, 10, 15)).toIso8601String(),
    'buildingId': ?building,
    if (floor != null) 'relatedAsset': {'buildingID': building, 'floorID': floor},
    ...extra,
  }, OrderType.workOrder);
}

List<String> titles(List<DayStep> steps) => steps.map((s) => s.title).toList();

void main() {
  group('selection', () {
    test('today, overdue, in progress and invites in; later work and old completions out', () {
      final steps = DayPlanner.plan([
        wo('today'),
        wo('overdue', due: DateTime(2026, 10, 8, 9)),
        wo('tomorrow', due: DateTime(2026, 10, 11, 9)),
        wo('started', status: 'In Progress', due: DateTime(2026, 10, 20)),
        wo('invite', due: DateTime(2026, 10, 25), extra: {'assignmentStatus': 'pending'}),
        wo('done today', status: 'Completed', extra: {'completedDate': DateTime(2026, 10, 10, 8).toIso8601String()}),
        wo('done before', status: 'Completed', extra: {'completedDate': DateTime(2026, 10, 9, 8).toIso8601String()}),
        wo('cancelled', status: 'Cancelled'),
      ], _now);
      expect(titles(steps)..sort(), ['done today', 'invite', 'overdue', 'started', 'today']);
      final done = steps.firstWhere((s) => s.title == 'done today');
      expect(done.done, isTrue);
      expect(steps.last.title, 'done today');
      expect(steps.firstWhere((s) => s.title == 'invite').kind, 'invite');
    });
  });

  group('ordering mirrors the server rules', () {
    test('safety, invite, SLA, overdue, in progress, today, on hold', () {
      final steps = DayPlanner.plan([
        wo('hold', status: 'On Hold'),
        wo('today'),
        wo('started', status: 'In Progress'),
        wo('overdue', due: DateTime(2026, 10, 9, 9)),
        wo('sla', extra: {'slaState': 'at_risk'}),
        wo('invite', extra: {'assignmentStatus': 'pending'}),
        wo('Smoke from DB room'),
      ], _now);
      expect(titles(steps), ['Smoke from DB room', 'invite', 'sla', 'overdue', 'started', 'today', 'hold']);
      expect(steps.first.reasonCode, 'safety');
      expect(steps.first.safety, isTrue);
    });

    test('routine "Fire Safety" work is not an emergency; Critical always is', () {
      final steps = DayPlanner.plan([
        wo('Fire Safety — Extinguisher Check', due: DateTime(2026, 10, 10, 11)),
        wo('critical one', priority: 'critical', due: DateTime(2026, 10, 10, 16)),
      ], _now);
      expect(titles(steps), ['critical one', 'Fire Safety — Extinguisher Check']);
      expect(steps[1].reasonCode, 'due_today');
    });

    test('SLA resolve-by within 2 h is SLA risk', () {
      final steps = DayPlanner.plan([
        wo('later'),
        wo('sla soon', extra: {'slaResolveDueAt': DateTime(2026, 10, 10, 11, 30).toIso8601String()}),
      ], _now);
      expect(titles(steps), ['sla soon', 'later']);
      expect(steps.first.reasonCode, 'sla_risk');
    });

    test('inside a tier: blocked last, then priority, then due', () {
      final steps = DayPlanner.plan([
        wo('medium 14', due: DateTime(2026, 10, 10, 14)),
        wo('high 16', priority: 'High', due: DateTime(2026, 10, 10, 16)),
        wo('high blocked', priority: 'High'),
        wo('medium 11', due: DateTime(2026, 10, 10, 11)),
      ], _now, blockedIds: {'id-high blocked'});
      expect(titles(steps), ['high 16', 'medium 11', 'medium 14', 'high blocked']);
      expect(steps.last.permitBlocked, isTrue);
    });

    test('groups by building + floor to cut walking, and says so', () {
      final steps = DayPlanner.plan([
        wo('A1 first', due: DateTime(2026, 10, 10, 11), building: 'A', floor: '1'),
        wo('B2', due: DateTime(2026, 10, 10, 12), building: 'B', floor: '2'),
        wo('A1 later', due: DateTime(2026, 10, 10, 16), building: 'A', floor: '1'),
      ], _now);
      expect(titles(steps), ['A1 first', 'A1 later', 'B2']);
      expect(steps[1].samePlaceAsPrevious, isTrue);
      expect(steps[2].samePlaceAsPrevious, isFalse);
    });

    test('rules items from the job itself', () {
      final s = DayPlanner.plan([
        wo('with checklist', extra: {
          'requireFaceCapture': true,
          'checklists': [
            {'name': 'a', 'isCompleted': true},
            {'name': 'b'},
            {'name': 'sig', 'isSignature': true},
          ],
        }),
      ], _now).single;
      expect(s.items.map((i) => i.code), ['checklist', 'face_capture', 'signature']);
      expect(s.items.first.params, {'done': '1', 'total': '2'});
      expect(s.route, '/technician/orders/work-order/id-with checklist');
    });
  });

  group('saved server brief', () {
    final saved = DayBrief.fromJson({
      'summary': 'AI text',
      'summarySource': 'ai',
      'aiAvailable': true,
      'generatedAt': DateTime(2026, 10, 10, 7).toIso8601String(),
      'steps': [
        {
          'order': 1,
          'kind': 'wo',
          'id': 'id-today',
          'title': 'today',
          'permit': {'state': 'not_live', 'permitId': 'p1', 'permitNo': 'PTW-0009', 'status': 'approved'},
          'flags': {'permitBlocked': true},
          'beforeYouGoItems': [
            {'code': 'permit_not_live', 'params': {'permitNo': 'PTW-0009'}, 'text': 'Permit PTW-0009 is not live yet.', 'source': 'rules'},
            {'code': 'ai_tip', 'params': {}, 'text': 'Bring the ladder', 'source': 'ai'},
          ],
        },
        {'order': 2, 'kind': 'inspection', 'id': 'insp-1', 'title': 'Fire door inspection', 'route': '/technician/inspections/insp-1'},
      ],
    });

    test('keeps the server permit + rules items (not model tips), adds open inspections', () {
      final local = DayPlanner.plan([wo('today')], _now, blockedIds: {'id-today'});
      final merged = DayPlanner.mergeCached(local, saved);
      expect(merged.map((s) => s.id), ['id-today', 'insp-1']);
      expect(merged.first.permit?.permitNo, 'PTW-0009');
      expect(merged.first.permitBlocked, isTrue);
      expect(merged.first.items.map((i) => i.code), ['permit_not_live']);
      expect(merged.last.order, 2);
    });

    test('ticks a server step done only from the phone\'s copy of the job', () {
      final steps = DayPlanner.overlayDone(saved.steps, [wo('today', status: 'Completed')]);
      expect(steps.first.done, isTrue);
      expect(steps.last.done, isFalse);
    });
  });

  group('contract parsing', () {
    test('a full server answer parses; missing bits are tolerated', () {
      final b = DayBrief.fromJson({
        'summary': 'Start with WO-1.',
        'summarySource': 'ai',
        'aiAvailable': true,
        'generatedAt': '2026-10-10T06:00:00.000Z',
        'counts': {'open': 2, 'overdue': 1, 'invites': 1, 'reminders': 2},
        'tips': [
          {'code': 'permit_first', 'stepId': 'w1', 'permitId': null, 'params': {'typeLabel': 'Hot work'}},
        ],
        'steps': [
          {'order': 1, 'kind': 'wo', 'id': 'w1', 'ref': 'WO-1', 'title': 'x', 'reason': 'AI line', 'reasonSource': 'ai', 'reasonCode': 'overdue', 'done': false},
          {'id': 'w2'},
        ],
      });
      expect(b.aiSummary, isTrue);
      expect(b.counts.reminders, 2);
      expect(b.tips.single.params['typeLabel'], 'Hot work');
      expect(b.steps.first.reasonSource, TextSource.ai);
      expect(b.steps.last.kind, 'wo');
      expect(b.steps.last.done, isFalse);
      expect(DayBrief.fromJson(const {}).steps, isEmpty);
    });
  });
}

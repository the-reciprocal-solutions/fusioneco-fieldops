import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/conversation/cadence_text.dart';
import 'package:technician_portal/domain/user_schedule.dart';

/// The real English strings, so a missing key shows up here.
final Map<String, dynamic> _en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
String _t(String key) => _en[key]?.toString() ?? '<<$key>>';

UserSchedule _s(Map<String, dynamic> json) => UserSchedule.fromJson({'id': 's', 'title': 't', ...json});

void main() {
  group('describeCadence', () {
    test("the server's own words win", () {
      expect(describeCadence(_s({'human': 'Every Monday 08:00', 'cron': '0 9 * * *'}), _t), 'Every Monday 08:00');
    });

    test('cron fallbacks: daily, weekdays, weekly, every N hours, monthly', () {
      expect(describeCadence(_s({'cron': '0 8 * * *'}), _t), 'Every day 08:00');
      expect(describeCadence(_s({'cron': '30 7 * * 1-5'}), _t), 'Every weekday 07:30');
      expect(describeCadence(_s({'cron': '0 8 * * 1'}), _t), 'Every Monday 08:00');
      expect(describeCadence(_s({'cron': '0 8 * * 1,4'}), _t), 'Every Monday, Thursday 08:00');
      expect(describeCadence(_s({'cron': '0 */2 * * *'}), _t), 'Every 2 hours');
      expect(describeCadence(_s({'cron': '0 9 1 * *'}), _t), 'Every month 09:00');
    });

    test('Sunday is day 0 and 7 in cron', () {
      expect(describeCadence(_s({'cron': '0 8 * * 0'}), _t), 'Every Sunday 08:00');
      expect(describeCadence(_s({'cron': '0 8 * * 7'}), _t), 'Every Sunday 08:00');
    });

    test('a one-off from runAt', () {
      final text = describeCadence(_s({'runAt': '2026-10-06T05:00:00Z'}), _t);
      expect(text, startsWith('Once · '));
    });

    test('an unreadable cron says when it next runs rather than guessing', () {
      expect(describeCadence(_s({'cron': '0 8 1-7 * 1'}), _t), 'Schedule set');
      final withNext = describeCadence(_s({'cron': 'weird', 'nextRunAt': '2026-10-06T05:00:00Z'}), _t);
      expect(withNext, startsWith('Next run '));
    });

    test('no raw i18n key ever leaks', () {
      for (final json in [
        {'cron': '0 8 * * *'},
        {'cadence': {'freq': 'daily'}},
        {'cadence': {'freq': 'weekly'}},
        {'cadence': {'freq': 'weekly', 'days': ['sat', 'sun'], 'at': '10:00'}},
        {'cadence': {'freq': 'daily', 'interval': 3, 'at': '06:00'}},
        {'cadence': {'freq': 'hourly'}},
        {'cadence': {'freq': 'monthly'}},
        {'cadence': {'freq': 'once'}},
        <String, dynamic>{},
      ]) {
        expect(describeCadence(_s(json), _t), isNot(contains('<<')), reason: '$json');
      }
    });
  });

  group('describeNextRun', () {
    final now = DateTime(2026, 9, 30, 10, 0);
    test('minutes, today, tomorrow, later, due', () {
      expect(describeNextRun(now.add(const Duration(minutes: 25)), _t, now: now), 'in 25 min');
      expect(describeNextRun(DateTime(2026, 9, 30, 16, 30), _t, now: now), 'today 16:30');
      expect(describeNextRun(DateTime(2026, 10, 1, 9, 0), _t, now: now), 'tomorrow 09:00');
      expect(describeNextRun(DateTime(2026, 10, 6, 8, 0), _t, now: now), contains('Oct'));
      expect(describeNextRun(now.subtract(const Duration(minutes: 1)), _t, now: now), 'due now');
      expect(describeNextRun(null, _t, now: now), 'not planned');
    });
  });

  test('ScheduleDTO (server C3) parses', () {
    final s = UserSchedule.fromJson({
      'id': 'sch-1',
      'kind': 'agent_task',
      'title': 'Check this WO again',
      'request': 'check this WO again tomorrow at 9 and tell me if it is still open',
      'record': {'entity': 'work_order', 'id': 'wo-uuid', 'ref': 'WO-161', 'title': 'Chiller', 'href': '/x'},
      'origin': {'entity': 'work_order', 'entityId': 'wo-uuid', 'messageId': 'm-1'},
      'cron': null,
      'runAt': '2026-10-01T05:00:00Z',
      'tz': 'Asia/Dubai',
      'human': 'Tomorrow 09:00',
      'status': 'failed',
      'nextRunAt': null,
      'lastRunAt': '2026-10-01T05:00:03Z',
      'lastResult': {'status': 'skipped', 'summary': 'Over the daily run budget', 'at': '2026-10-01T05:00:03Z', 'runId': 'r'},
      'canEdit': false,
    });
    expect(s.kind, ScheduleKind.agentTask);
    expect(s.status, ScheduleStatus.failed);
    expect(s.cadence.freq, 'once');
    expect(s.entity, 'work_order');
    expect(s.entityId, 'wo-uuid');
    expect(s.originMessageId, 'm-1');
    expect(s.recordRef, 'WO-161');
    expect(s.lastRun!.result, ScheduleRunResult.failed, reason: 'skipped = over budget = told it failed');
    expect(s.lastRun!.summary, 'Over the daily run budget');
    expect(s.canEdit, isFalse);
    expect(UserSchedule.fromJson({'id': 'x', 'status': 'paused'}).isPaused, isTrue);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/core/storage/session_store.dart';
import 'package:technician_portal/domain/day_brief.dart';
import 'package:technician_portal/domain/maintenance_record.dart';
import 'package:technician_portal/state/auth_controller.dart';
import 'package:technician_portal/state/dashboard_controller.dart';
import 'package:technician_portal/state/day_brief_controller.dart';

/// Which state the card lands in for each server outcome (docs/day-brief.md
/// §Offline): fresh → ready; saved copy → offline (+ "Saved earlier" only if
/// it is today's); no signal and nothing saved → offline with the phone's
/// plan; a server refusal → error with the phone's plan.
class _Auth extends AuthController {
  @override
  AuthState build() => const AuthState(session: Session(userId: 't1', name: 'Ravi'));
}

final _today = DateTime.now();
final _records = [
  MaintenanceRecord.fromJson({
    'id': 'w1',
    'workOrderId': 'WO-1',
    'title': 'Local job',
    'status': 'Open',
    'priority': 'High',
    'dueDate': DateTime(_today.year, _today.month, _today.day, 23, 0).toIso8601String(),
  }, OrderType.workOrder),
  MaintenanceRecord.fromJson({
    'id': 'w2',
    'workOrderId': 'WO-2',
    'title': 'Finished locally',
    'status': 'Completed',
    'completedDate': DateTime(_today.year, _today.month, _today.day, 0, 1).toIso8601String(),
  }, OrderType.workOrder),
];

class _Dashboard extends DashboardController {
  @override
  DashboardState build() => DashboardState(records: _records, loading: false, loaded: true);
  @override
  Future<void> refresh() async {}
}

class _Source implements DayBriefSource {
  _Source(this.answer);
  final Object Function() answer;
  @override
  Future<({DayBrief brief, bool fromCache})> fetch({required int tzOffsetMinutes, required String lang}) async {
    final a = answer();
    if (a is Exception) throw a;
    return a as ({DayBrief brief, bool fromCache});
  }
}

DayBrief _brief({DateTime? at}) => DayBrief.fromJson({
      'summary': 'AI summary.',
      'summarySource': 'ai',
      'aiAvailable': true,
      'generatedAt': (at ?? DateTime.now()).toIso8601String(),
      'steps': [
        {'order': 1, 'kind': 'wo', 'id': 'w2', 'title': 'Server says open', 'done': false},
        {'order': 2, 'kind': 'inspection', 'id': 'i1', 'title': 'Inspection', 'done': false},
      ],
    });

Future<DayBriefState> _run(Object Function() answer) async {
  final c = ProviderContainer(overrides: [
    authControllerProvider.overrideWith(_Auth.new),
    dashboardControllerProvider.overrideWith(_Dashboard.new),
    dayBriefSourceProvider.overrideWithValue(_Source(answer)),
  ]);
  addTearDown(c.dispose);
  c.read(dayBriefControllerProvider); // build() schedules the first refresh
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return c.read(dayBriefControllerProvider);
}

void main() {
  test('fresh brief → ready; a job the phone knows is finished is ticked', () async {
    final s = await _run(() => (brief: _brief(), fromCache: false));
    expect(s.phase, DayBriefPhase.ready);
    expect(s.showAiSummary, isTrue);
    expect(s.steps.first.done, isTrue); // w2 is Completed in the phone's copy
    expect(s.next?.id, 'i1');
  });

  test("saved copy from today → offline + Saved earlier, phone plan + saved inspection", () async {
    final s = await _run(() => (brief: _brief(), fromCache: true));
    expect(s.phase, DayBriefPhase.offline);
    expect(s.savedAt, isNotNull);
    expect(s.steps.map((x) => x.id), containsAll(['w1', 'i1']));
  });

  test("a saved copy from another day is not today's plan", () async {
    final s = await _run(() => (brief: _brief(at: DateTime.now().subtract(const Duration(days: 2))), fromCache: true));
    expect(s.phase, DayBriefPhase.offline);
    expect(s.brief, isNull);
    expect(s.savedAt, isNull);
    expect(s.steps.map((x) => x.id), contains('w1'));
  });

  test('no signal and nothing saved → offline with the phone plan', () async {
    final s = await _run(() => const NetworkFailure());
    expect(s.phase, DayBriefPhase.offline);
    expect(s.steps.first.id, 'w1');
    expect(s.showAiSummary, isFalse);
  });

  test('server refusal (e.g. an older server without the route) → error with the phone plan', () async {
    final s = await _run(() => const HttpFailure(status: 404, message: 'Not found'));
    expect(s.phase, DayBriefPhase.error);
    expect(s.steps.first.id, 'w1');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/features/efficiency/ask_ai.dart';

/// The finding and summary shapes of the live `/hvac-efficiency/summary` (2026-11-02).
final _finding = {
  'id': 'f1',
  'rule': 'setpoint_out_of_policy',
  'title': 'FCU corridor L5 setpoint is 17.8 °C, outside the 21–26 °C policy',
  'severity': 'warn',
  'pillar': 'comfort',
  'equipment': ['fcu5'],
  'related': ['ahu9'],
  'summary': 'The setpoint is too low.',
  'actions': [
    {'tier': 'now', 'text': 'Set it to about 24 °C'},
  ],
  'causes': ['Someone lowered it by hand'],
  'evidence': [
    {'label': 'Setpoint', 'value': '17.8 °C'},
  ],
  'hours': 22.04,
};

final _summary = {
  'stats': [
    {
      'key': 'fcu5',
      'label': 'FCU corridor L5',
      'running': true,
      'auto': false,
      'livePoints': 4,
      'totalPoints': 5,
      'readings': [
        {'label': 'Supply temp', 'value': 22, 'unit': '°C', 'live': true, 'pointKey': 'FCU5/SAT'},
      ],
    },
    {'key': 'ahu9', 'label': 'AHU-09', 'stale': true, 'lastSeen': '2026-11-02T04:00:00Z', 'livePoints': 0, 'totalPoints': 3, 'readings': <Object>[]},
  ],
};

class _Api extends ApiClient {
  _Api(this.polls) : super(secureStore: SecureStore());
  final List<Map<String, dynamic>> polls;
  Map<String, dynamic>? first;
  Object? posted;
  final gets = <String>[];

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    expect(path, '/api/fm/hvac-efficiency/explain');
    posted = body;
    return {'success': true, 'data': first ?? {'status': 'pending', 'id': 'abc'}};
  }

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    gets.add(path);
    return {'success': true, 'data': polls.removeAt(0)};
  }
}

const _answer = {
  'kind': 'ask',
  'ok': true,
  'ask': {
    'reply': 'Raise the setpoint to 24 °C.',
    'steps': [
      {'title': 'Open the BMS', 'detail': 'FCU5 page'},
    ],
    'safety': <String>[],
    'followUps': ['How do I lock the setpoint?'],
  },
};

void main() {
  test('the context: the finding, its facts, its units live, the conversation', () {
    final ctx = askContext(_finding, _summary, [const AskTurn.user('Why?'), const AskTurn.ai({'reply': 'Hand override.', 'steps': [{'title': 'Check'}]})], 'How do I fix this?');
    expect(ctx['kind'], 'ask');
    expect(ctx['severity'], 'Fix soon');
    expect(ctx['area'], 'Comfort');
    expect(ctx['units'], ['FCU corridor L5']);
    expect(ctx['alsoInvolves'], ['AHU-09']);
    expect(ctx['steps'], ['now: Set it to about 24 °C']);
    final facts = [for (final f in ctx['facts'] as List) (f as Map)['text']];
    expect(facts.first, 'Setpoint: 17.8 °C');
    expect(facts, contains('The problem was present for 22.0 hours in the period'));
    expect(facts, contains('FCU corridor L5: running in hand (not in auto); 4 of 5 BMS points live'));
    expect(facts.any((t) => '$t'.startsWith('AHU-09: stopped reporting')), isTrue);
    expect([for (final f in ctx['facts'] as List) (f as Map)['id']].take(2), ['F1', 'F2']);
    expect(ctx['conversation'], [
      {'role': 'user', 'text': 'Why?'},
      {'role': 'assistant', 'text': 'Hand override. Steps: 1. Check'},
    ]);
    expect(ctx['question'], 'How do I fix this?');
  });

  test('a job: pending → progress → done', () async {
    final api = _Api([
      {'status': 'pending', 'id': 'abc', 'progress': {'stage': 'Writing the steps', 'chars': 40}},
      {'status': 'done', 'result': _answer},
    ]);
    final stages = <String>[];
    final a = await runAsk(api, {'q': 1}, every: Duration.zero, onProgress: stages.add);
    expect(a['reply'], 'Raise the setpoint to 24 °C.');
    expect(api.posted, {'kind': 'ask', 'context': {'q': 1}});
    expect(api.gets, ['/api/fm/hvac-efficiency/explain/abc', '/api/fm/hvac-efficiency/explain/abc']);
    expect(stages, ['Writing the steps']);
  });

  test('cached answers come at once; an older server answers directly', () async {
    final cached = _Api([])..first = {'status': 'done', 'result': _answer};
    expect((await runAsk(cached, {}, every: Duration.zero))['reply'], isNotNull);
    expect(cached.gets, isEmpty);
    final old = _Api([])..first = Map<String, dynamic>.from(_answer);
    expect((await runAsk(old, {}, every: Duration.zero))['reply'], isNotNull);
  });

  test('a failed job says why', () async {
    final api = _Api([
      {'status': 'failed', 'id': 'abc', 'reason': 'disabled'},
    ]);
    expect(() => runAsk(api, {}, every: Duration.zero), throwsA(isA<AskFailure>().having((e) => e.reason, 'reason', 'disabled')));
  });

  test('suggested questions name the unit', () {
    final g = suggestedQuestions(_finding, _summary);
    expect(g.first.$2[1], 'Give me a step-by-step plan for the technician at FCU corridor L5');
  });
}

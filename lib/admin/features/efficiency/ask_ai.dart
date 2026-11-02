import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../modules/module_spec.dart';
import 'efficiency_data.dart';

/// "Ask AI" on one finding — the web's AskAi.tsx chat (finding page), over
///   POST /api/fm/hvac-efficiency/explain {kind: "ask", context}
///     → {status: "done", result} | {status: "pending", id, progress?} | {status: "failed", reason}
///   GET  /api/fm/hvac-efficiency/explain/:id   (poll, same shape)
/// (server hvacEfficiency/explain.ts). The context is built here exactly as
/// the web's askContext / findingContext do: the finding, its facts, the live
/// readings of its units and the last 10 turns; the server answers only from
/// those facts. Each question is a paid LLM call (cached 10 min per context),
/// so nothing is asked until the user does.

const _severityLabel = {'risk': 'Urgent', 'warn': 'Fix soon', 'info': 'Good to know'};
const _pillarLabel = {
  'comfort': 'Comfort',
  'energy': 'Energy',
  'equipment': 'Equipment health',
  'power': 'Power quality',
  'safety': 'Life safety',
  'data': 'Data you can trust',
};

String _hhmm(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  return t == null ? '?' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String _r(Object? v) => fmtNum(v, decimals: 2);

/// One turn of the conversation: the user's question, or the AI's answer.
class AskTurn {
  const AskTurn.user(this.text) : answer = null;
  const AskTurn.ai(Json this.answer) : text = '';
  final String text;
  final Json? answer;
  bool get fromUser => answer == null;
}

/// The finding's own facts (web AiPanel.tsx findingFacts), F1…
List<Json> findingFacts(Json f, Map<String, String> labels) {
  final out = <Json>[];
  void add(String text, String src) => out.add({'id': 'F${out.length + 1}', 'text': text, 'src': src});
  for (final e in rowsOf({'data': f['evidence']})) {
    add('${e['label']}: ${e['value']}', 'BMS reading');
  }
  final m = at(f, 'playbook.metric');
  if (m is Map) {
    add('${m['label']}: now ${m['now']} ${m['unit'] ?? ''}, target ${m['better'] == 'lower' ? 'at most' : 'at least'} ${m['target']} ${m['unit'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' '), 'rule check');
  }
  if (n(f['hours']) != null) add('The problem was present for ${(n(f['hours'])! * 10).round() / 10} hours in the period', '15-minute history');
  final cost = f['costPerDay'];
  if (cost is Map) add('Cost estimate: ${cost['amount']} ${cost['currency']} per day (${cost['basis']})', 'metered energy × tariff');
  for (final i in rowsOf({'data': at(f, 'playbook.impact')})) {
    add('${i['label']}: ${i['value']} (${i['kind']}; ${i['basis']})', 'playbook · ${i['kind']}');
  }
  final related = [for (final k in f['related'] is List ? f['related'] as List : const []) labels['$k'] ?? '$k'];
  if (related.isNotEmpty) add('Also involved: ${related.join(', ')}', 'rule check');
  if (f['staleSince'] != null) add('These units stopped reporting at ${_hhmm(f['staleSince'])}; the finding uses their last readings', 'data quality');
  final cur = s(at(f, 'impact.currency')) ?? '';
  for (final l in rowsOf({'data': at(f, 'impact.lines')})) {
    final qty = l['qty'] is Map ? l['qty'] as Map : null;
    if (qty == null && l['perDay'] == null && l['kind'] != 'qualitative') continue;
    final money = n(l['perDay']) == null ? '' : ' ≈ ${_r(l['perDay'])} $cur/day ≈ ${(n(l['perDay'])! * 365).round()} $cur/year';
    final q = qty == null ? 'not costed' : '${qty['value']} ${qty['unit']}${qty['per'] == 'event' ? '' : ' per ${qty['per']}'}';
    add('Impact · ${l['label']}: $q$money (${l['kind'] == 'needs-price' ? 'price not set' : l['kind']}; ${l['basis']})', 'impact model');
  }
  if (n(at(f, 'impact.perDay')) != null && n(at(f, 'impact.perDay'))! > 0) {
    add('Total impact of this finding: ≈ ${_r(at(f, 'impact.perDay'))} $cur/day ≈ ${at(f, 'impact.perYear')} $cur/year (estimate)', 'impact model');
  }
  return out;
}

/// The page context for one Ask turn (web AskAi.tsx askContext).
Json askContext(Json f, Json? summary, List<AskTurn> turns, String question, {String research = 'off'}) {
  final stats = rowsOf({'data': summary?['stats']});
  final labels = {for (final u in stats) '${u['key']}': s(u['label']) ?? '${u['key']}'};
  final equipment = [for (final k in f['equipment'] is List ? f['equipment'] as List : const []) '$k'];
  final related = [for (final k in f['related'] is List ? f['related'] as List : const []) '$k'];
  final facts = findingFacts(f, labels);
  void add(String text, String src) => facts.add({'id': 'F${facts.length + 1}', 'text': text, 'src': src});
  final units = [...equipment, ...related.where((k) => !equipment.contains(k))];
  for (final k in units) {
    final u = stats.where((x) => '${x['key']}' == k).firstOrNull;
    if (u == null) continue;
    final state = u['stale'] == true
        ? 'stopped reporting at ${_hhmm(u['lastSeen'])} (values below are its last readings)'
        : u['tripped'] == true
            ? 'tripped'
            : u['running'] == null
                ? 'state not reported'
                : u['running'] == true
                    ? 'running${u['auto'] == false ? ' in hand (not in auto)' : u['auto'] == true ? ' in auto' : ''}'
                    : 'off';
    add('${u['label']}: $state; ${u['livePoints']} of ${u['totalPoints']} BMS points live${u['runHours'] != null ? '; ${u['runHours']} run hours' : ''}${u['trips'] != null ? '; ${u['trips']} trips in the period' : ''}', 'live BMS reading');
    for (final r in rowsOf({'data': u['readings']}).take(units.length > 3 ? 8 : 14)) {
      final v = '${r['value'] ?? '–'}${r['unit'] == null ? '' : ' ${r['unit']}'}';
      final note = r['problem'] != null ? ' — ${r['problem']}' : r['live'] == false ? ' — not updating' : '';
      add('${u['label']} · ${r['label']}: $v$note (BMS point ${r['point'] ?? r['pointKey'] ?? '?'}, updated ${_hhmm(r['lastAt'])})', 'live BMS reading');
    }
  }
  if (facts.length > 60) facts.removeRange(60, facts.length);
  final conversation = [
    for (final t in turns.length > 10 ? turns.sublist(turns.length - 10) : turns)
      if (t.fromUser)
        {'role': 'user', 'text': t.text}
      else
        {
          'role': 'assistant',
          'text': [
            s(t.answer!['reply']),
            () {
              final steps = rowsOf({'data': t.answer!['steps']});
              return steps.isEmpty ? null : 'Steps: ${[for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]['title']}'].join('; ')}';
            }(),
            if (at(t.answer!, 'clarify.text') != null) 'Asked: ${at(t.answer!, 'clarify.text')}',
          ].whereType<String>().join(' '),
        },
  ];
  return {
    'kind': 'ask',
    'title': f['title'],
    'severity': _severityLabel['${f['severity']}'] ?? f['severity'],
    'area': _pillarLabel['${f['pillar'] ?? 'equipment'}'],
    'units': [for (final k in equipment) labels[k] ?? k],
    'alsoInvolves': [for (final k in related) labels[k] ?? k],
    'summary': f['summary'],
    'steps': [for (final a in rowsOf({'data': f['actions']})) '${a['tier']}: ${a['text']}'],
    'likelyCauses': f['causes'],
    if (f['playbook'] is Map) 'playbook': {'process': at(f, 'playbook.process'), 'verify': at(f, 'playbook.verify'), 'detect': at(f, 'playbook.detect')},
    'facts': facts,
    'rule': f['rule'],
    'research': research,
    'question': question,
    'conversation': conversation,
  };
}

/// Why an answer didn't come (the web's reasonText keys).
class AskFailure implements Exception {
  const AskFailure(this.reason);
  final String reason;
}

/// Starts the job and polls it (web lib/apis/hvacEfficiency.ts explainHvac):
/// every [every]; gives up after 120 s with no progress or 6 min in all;
/// 4 network misses in a row = offline. Returns the `ask` answer.
Future<Json> runAsk(
  ApiClient api,
  Json context, {
  void Function(String stage)? onProgress,
  Duration every = const Duration(seconds: 2),
  bool Function()? alive,
}) async {
  Json? data(Object? body) => body is Map && body['data'] is Map ? (body['data'] as Map).cast<String, dynamic>() : null;
  Json answer(Json result) {
    if (result['ok'] == false) throw AskFailure(s(result['reason']) ?? 'invalid');
    final ask = result['ask'];
    if (ask is! Map) throw const AskFailure('invalid');
    return ask.cast<String, dynamic>();
  }

  final Json? first;
  try {
    first = data(await api.post('/api/fm/hvac-efficiency/explain', body: {'kind': 'ask', 'context': context}));
  } on ApiFailure catch (e) {
    throw AskFailure(e is HttpFailure && e.status == 400 ? 'invalid' : 'offline');
  }
  if (first == null) throw const AskFailure('invalid');
  if (first.containsKey('ok')) return answer(first); // an older server answers at once
  var job = first;
  final started = DateTime.now();
  var lastChange = started;
  String? lastMark;
  var misses = 0;
  while (true) {
    switch (job['status']) {
      case 'done':
        return answer((job['result'] as Map).cast<String, dynamic>());
      case 'failed':
        throw AskFailure(s(job['reason']) ?? 'unknown');
    }
    final p = job['progress'];
    final mark = p is Map ? '${p['stage']}|${p['chars']}' : null;
    if (mark != lastMark) {
      lastMark = mark;
      lastChange = DateTime.now();
      if (p is Map && s(p['stage']) != null) onProgress?.call(s(p['stage'])!);
    }
    final now = DateTime.now();
    if (now.difference(lastChange) > const Duration(seconds: 120) || now.difference(started) > const Duration(minutes: 6)) {
      throw const AskFailure('timeout');
    }
    await Future<void>.delayed(every);
    if (alive != null && !alive()) throw const AskFailure('expired');
    try {
      job = data(await api.get('/api/fm/hvac-efficiency/explain/${job['id']}')) ?? job;
      misses = 0;
    } on ApiFailure {
      if (++misses >= 4) throw const AskFailure('offline');
    }
  }
}

/// The suggested questions (web suggestedQuestions), by group.
List<(String, List<String>)> suggestedQuestions(Json f, Json? summary) {
  final stats = rowsOf({'data': summary?['stats']});
  final first = f['equipment'] is List && (f['equipment'] as List).isNotEmpty ? '${(f['equipment'] as List).first}' : null;
  final unit = stats.where((u) => '${u['key']}' == first).map((u) => s(u['label'])).firstOrNull ?? first ?? 'this unit';
  final tripped = RegExp('trip', caseSensitive: false).hasMatch('${f['rule']} ${f['title']}');
  return [
    ('ask.fix', ['How do I fix this?', 'Give me a step-by-step plan for the technician at $unit', 'What should I check first, and why?']),
    ('ask.safety', [tripped ? 'Is it safe to reset $unit?' : 'How do I work on $unit safely?', 'What tools, parts and permits do I need?']),
    ('ask.understand', ['Why is this happening?', 'What happens if we leave it for a week?', 'How do I confirm it is fixed on the BMS?']),
  ];
}

class AskAiCard extends ConsumerStatefulWidget {
  const AskAiCard({super.key, required this.finding});
  final Json finding;

  @override
  ConsumerState<AskAiCard> createState() => _AskAiCardState();
}

class _AskAiCardState extends ConsumerState<AskAiCard> {
  final _q = TextEditingController();
  final _turns = <AskTurn>[];
  bool _busy = false;
  String? _stage;
  String? _failed;
  int _gen = 0;

  @override
  void dispose() {
    _gen++;
    _q.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    final summary = ref.read(effSummaryProvider).valueOrNull;
    final ctx = askContext(widget.finding, summary, _turns, q);
    final gen = ++_gen;
    _q.clear();
    setState(() {
      _turns.add(AskTurn.user(q));
      _busy = true;
      _stage = null;
      _failed = null;
    });
    final api = ref.read(apiClientProvider);
    try {
      Json? a;
      // One quiet retry when the engine was slow or briefly away (the web's AiPanel).
      for (var attempt = 1; attempt <= 2 && a == null; attempt++) {
        try {
          a = await runAsk(api, ctx, alive: () => mounted && gen == _gen, onProgress: (st) {
            if (mounted && gen == _gen) setState(() => _stage = st);
          });
        } on AskFailure catch (e) {
          if (attempt == 2 || !{'timeout', 'offline', 'invalid'}.contains(e.reason)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 2500));
        }
      }
      if (mounted && gen == _gen) setState(() => _turns.add(AskTurn.ai(a!)));
    } on AskFailure catch (e) {
      if (mounted && gen == _gen) setState(() => _failed = e.reason);
    } finally {
      if (mounted && gen == _gen) setState(() => (_busy = false, _stage = null));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(effSummaryProvider).valueOrNull;
    final groups = suggestedQuestions(widget.finding, summary);
    final lastAnswer = _turns.lastOrNull?.answer;
    final followUps = [for (final x in lastAnswer?['followUps'] is List ? lastAnswer!['followUps'] as List : const []) '$x'];
    final clarify = lastAnswer?['clarify'] is Map ? lastAnswer!['clarify'] as Map : null;
    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.sparkles, size: 18, color: FeColors.ai),
              const SizedBox(width: 8),
              Expanded(child: AppText.titleSmall('ask.title'.getString(context))),
            ],
          ),
          const SizedBox(height: 4),
          AppText.caption('ask.hint'.getString(context)),
          const SizedBox(height: 10),
          for (final t in _turns) t.fromUser ? _Question(t.text) : _Answer(t.answer!),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const TechSpinner(size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: AppText.caption(_stage ?? 'ask.thinking'.getString(context))),
                ],
              ),
            ),
          if (_failed != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: AppText.bodySmall(
                'ask.fail_$_failed'.getString(context).endsWith(' not found') ? 'ask.fail_offline'.getString(context) : 'ask.fail_$_failed'.getString(context),
                color: FeColors.danger,
              ),
            ),
          if (!_busy && clarify != null)
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final o in rowsOf({'data': clarify['options']}))
                  ActionChip(
                    label: AppText('${o['label']}${o['recommended'] == true ? ' ★' : ''}'),
                    onPressed: () => _ask('${o['label']}'),
                  ),
              ],
            ),
          if (!_busy && followUps.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 6, children: [for (final q in followUps) ActionChip(label: AppText(q), onPressed: () => _ask(q))]),
          if (!_busy && _turns.isEmpty)
            for (final (key, items) in groups) ...[
              Padding(padding: const EdgeInsets.only(top: 6, bottom: 4), child: AppText.caption(key.getString(context).toUpperCase(), weight: FontWeight.w700)),
              Wrap(spacing: 8, runSpacing: 6, children: [for (final q in items) ActionChip(label: AppText(q), onPressed: () => _ask(q))]),
            ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _q,
                  enabled: !_busy,
                  maxLength: 600,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _ask,
                  decoration: InputDecoration(hintText: 'ask.input'.getString(context), counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _busy ? null : () => _ask(_q.text), icon: const Icon(LucideIcons.send, size: 18)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: FeColors.primary, borderRadius: BorderRadius.circular(14)),
          child: AppText.bodySmall(text, color: Colors.white),
        ),
      );
}

class _Answer extends StatelessWidget {
  const _Answer(this.a);
  final Json a;

  @override
  Widget build(BuildContext context) {
    final steps = rowsOf({'data': a['steps']});
    final safety = [for (final x in a['safety'] is List ? a['safety'] as List : const []) '$x'];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: FeColors.aiSoft, borderRadius: BorderRadius.circular(14), border: Border.all(color: FeColors.aiLine)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (safety.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: FeColors.warningSoft, borderRadius: BorderRadius.circular(10)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.caption('ask.safety_first'.getString(context).toUpperCase(), weight: FontWeight.w700, color: FeColors.warning),
                  for (final x in safety) AppText.bodySmall('• $x'),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          // The server's reply is plain text (the web's RichText), not markdown.
          SelectableText(s(a['reply']) ?? '', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: FeColors.ink, height: 1.4)),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 22, child: AppText.bodySmall('${i + 1}.', weight: FontWeight.w700)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.bodySmall(s(steps[i]['title']) ?? '', weight: FontWeight.w700),
                        if (s(steps[i]['detail']) != null) AppText.bodySmall(s(steps[i]['detail'])!),
                        if (s(steps[i]['who']) != null || s(steps[i]['check']) != null)
                          AppText.caption([s(steps[i]['who']), if (s(steps[i]['check']) != null) '✓ ${steps[i]['check']}'].whereType<String>().join(' · ')),
                        if (s(steps[i]['caution']) != null) AppText.caption('⚠ ${steps[i]['caution']}', color: FeColors.warning),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (at(a, 'clarify.text') != null) ...[
            const SizedBox(height: 8),
            AppText.bodySmall('${at(a, 'clarify.text')}', weight: FontWeight.w600),
          ],
        ],
      ),
    );
  }
}

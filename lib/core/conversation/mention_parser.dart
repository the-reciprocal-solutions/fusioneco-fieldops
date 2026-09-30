import '../../domain/conversation.dart';

/// Pure text rules for @mentions in the conversation composer
/// (docs/conversations-and-schedules.md). The server re-parses every message
/// itself (`services/conversations/mentions.ts`), so nothing here decides who
/// gets asked — this only drives the picker and the hints under the box.

/// The one handle that reaches the Orchestrator ("Flow Agent"), plus the
/// aliases the server accepts for it (orchestrator spec O1).
const kOrchestratorHandle = 'agent';
const kOrchestratorAliases = {'agent', 'flowagent', 'orbit', 'ai'};

/// The `@query` being typed at the cursor, if any.
class MentionQuery {
  const MentionQuery({required this.start, required this.end, required this.query});

  /// Index of the `@`.
  final int start;

  /// The cursor (exclusive end of the query).
  final int end;

  /// What follows the `@`, without it. May be empty (just typed `@`).
  final String query;
}

/// A handle character: letters (any script — Arabic names are real), digits,
/// `.`, `_`, `-`.
bool _isHandleChar(String ch) => RegExp(r'[\p{L}\p{N}._\-]', unicode: true).hasMatch(ch);

/// Finds the mention being typed immediately before [cursor]. The `@` must
/// start the text or follow whitespace/an opening bracket, so an email
/// address (`ali@site.com`) never opens the picker.
MentionQuery? activeMention(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  var i = cursor - 1;
  while (i >= 0 && _isHandleChar(text[i])) {
    i--;
  }
  if (i < 0 || text[i] != '@') return null;
  if (i > 0 && !RegExp(r'[\s(\[{"]').hasMatch(text[i - 1])) return null;
  final query = text.substring(i + 1, cursor);
  if (query.length > 40) return null;
  return MentionQuery(start: i, end: cursor, query: query);
}

/// The text after picking [handle] for [q], and where the cursor goes.
({String text, int cursor}) insertMention(String text, MentionQuery q, String handle) {
  final clean = handle.startsWith('@') ? handle.substring(1) : handle;
  final before = text.substring(0, q.start);
  var after = text.substring(q.end);
  // Swallow the rest of a half-typed handle the cursor sat in the middle of.
  var k = 0;
  while (k < after.length && _isHandleChar(after[k])) {
    k++;
  }
  after = after.substring(k);
  final spacer = after.startsWith(' ') ? '' : ' ';
  final inserted = '@$clean$spacer';
  // The cursor lands after the space either way, ready for the next word.
  return (text: '$before$inserted$after', cursor: before.length + '@$clean'.length + 1);
}

/// Every `@handle` in [text], lower-cased, in order, without duplicates.
List<String> mentionHandles(String text) {
  final out = <String>[];
  final re = RegExp(r'(^|[\s(\[{"])@([\p{L}\p{N}][\p{L}\p{N}._\-]*)', unicode: true);
  for (final m in re.allMatches(text)) {
    var h = m.group(2)!.toLowerCase();
    // A sentence ending right after a handle ("ask @agent.") is not part of it.
    while (h.endsWith('.') || h.endsWith('-')) {
      h = h.substring(0, h.length - 1);
    }
    if (h.isNotEmpty && !out.contains(h)) out.add(h);
  }
  return out;
}

/// True when [text] mentions the Orchestrator or any of [agentHandles].
bool mentionsAgent(String text, {Set<String> agentHandles = const {}}) {
  final lower = {for (final h in agentHandles) h.toLowerCase()};
  return mentionHandles(text).any((h) => kOrchestratorAliases.contains(h) || lower.contains(h));
}

/// Phrases that ask for something later or on repeat (orchestrator spec O3
/// "Capture"). Only a hint for the composer ("add @agent so it sets this
/// up") — the server's rules and model decide what becomes a schedule.
bool looksLikeScheduleRequest(String text) {
  final t = text.toLowerCase();
  return RegExp(
    r'\b(remind me|every (day|weekday|morning|evening|week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d+ ?h(ou)?rs?)|'
    r'tomorrow at|tell me when|check (this|it) again|in \d+ ?(hours?|hrs?|minutes?|days?)|each (day|morning|week))\b',
  ).hasMatch(t) ||
      // Arabic: ذكرني (remind me), كل يوم (every day), غدا (tomorrow), أخبرني عندما (tell me when)
      RegExp(r'(ذكرني|ذكّرني|كل يوم|كل أسبوع|غدا|غداً|أخبرني عندما)').hasMatch(text);
}

/// What the @ picker lists for [query], in order (orchestrator spec O1
/// "Seamless tagging"):
/// 1. `@agent` — Flow Agent, "picks the right specialist" — always first;
/// 2. the specialists (agents) the server offers;
/// 3. people.
/// Agents appear only when the server says this person may ask them
/// ([canMentionAgents]); people always. [fetched] is the server's answer
/// for the query (may be empty offline); [fallbackPeople] are the thread's
/// participants so the picker still works with no signal.
List<MentionCandidate> pickerCandidates({
  required String query,
  required List<MentionCandidate> fetched,
  required bool canMentionAgents,
  required String orchestratorName,
  required String orchestratorRole,
  List<MentionCandidate> fallbackPeople = const [],
  int max = 8,
}) {
  final q = query.trim().toLowerCase();
  bool matches(MentionCandidate c) =>
      q.isEmpty || c.handle.toLowerCase().startsWith(q) || c.name.toLowerCase().contains(q);
  final out = <MentionCandidate>[];
  final seen = <String>{};
  void add(MentionCandidate c) {
    final key = '${c.type.name}:${c.handle.toLowerCase()}';
    if (c.handle.isEmpty || seen.contains(key)) return;
    seen.add(key);
    out.add(c);
  }

  if (canMentionAgents) {
    final orchestrator = MentionCandidate(
      type: ConvAuthorType.agent,
      id: kOrchestratorHandle,
      name: orchestratorName,
      handle: kOrchestratorHandle,
      role: orchestratorRole,
      orchestrator: true,
    );
    final aliasHit = kOrchestratorAliases.any((a) => a.startsWith(q)) ||
        orchestratorName.toLowerCase().contains(q);
    if (q.isEmpty || aliasHit) add(orchestrator);
    for (final c in fetched) {
      if (c.isAgent && !kOrchestratorAliases.contains(c.handle.toLowerCase()) && matches(c)) add(c);
    }
  }
  for (final c in [...fetched, ...fallbackPeople]) {
    if (!c.isAgent && matches(c)) add(c);
  }
  return out.take(max).toList();
}

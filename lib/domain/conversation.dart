import '../core/network/envelope.dart';
import 'user_schedule.dart';

/// Conversations on a record (docs/conversations-and-schedules.md).
///
/// Mirrors the server contract in
/// `../fusion-eco-server/src/services/conversations/types.ts` (spec:
/// `docs/superpowers/specs/2026-09-30-agents-in-conversations.md`, "Contract
/// changes (server)"), plus the orchestrator additions (`routing`, schedule
/// cards, per-specialist stages) from
/// `2026-09-30-orchestrator-and-schedules.md`. Every parser is tolerant: a
/// missing field falls back rather than throwing — a thread that fails to
/// parse is worse than one that shows a little less. Orchestrator fields
/// follow "## Contract (server)" C1–C3 in the orchestrator spec.

/// Records that carry a conversation. The wire key is the URL segment in
/// `/api/conversations/:entity/:id`.
enum ConvEntity {
  snag('snag'),
  workOrder('work_order'),
  serviceRequest('service_request'),
  pmPlan('pm_plan'),
  inspectionResponse('inspection_response'),
  permit('permit'),
  asset('asset');

  const ConvEntity(this.wire);
  final String wire;

  static ConvEntity? fromWire(String? value) {
    for (final e in values) {
      if (e.wire == value) return e;
    }
    return null;
  }
}

enum ConvAuthorType { user, agent }

class ConvAuthor {
  const ConvAuthor({
    required this.type,
    required this.id,
    required this.name,
    this.handle,
    this.icon,
    this.templateId,
    this.role,
  });

  final ConvAuthorType type;
  final String id;
  final String name;

  /// Mention handle without "@" (agents: "visual-inspector"; people: username).
  final String? handle;
  final String? icon;
  final String? templateId;

  /// Agents: what it does in plain words ("checks photos"). People: role.
  final String? role;

  bool get isAgent => type == ConvAuthorType.agent;

  factory ConvAuthor.fromJson(Map<String, dynamic> json) => ConvAuthor(
    type: json['type'] == 'agent' ? ConvAuthorType.agent : ConvAuthorType.user,
    id: json['id']?.toString() ?? '',
    name: firstNonEmpty([json['name']]) ?? '—',
    handle: firstNonEmpty([json['handle']]),
    icon: firstNonEmpty([json['icon']]),
    templateId: firstNonEmpty([json['templateId']]),
    role: firstNonEmpty([json['role']]),
  );
}

class ConvMention {
  const ConvMention({required this.type, required this.id, required this.name, this.handle});
  final ConvAuthorType type;
  final String id;
  final String name;
  final String? handle;

  factory ConvMention.fromJson(Map<String, dynamic> json) => ConvMention(
    type: json['type'] == 'agent' ? ConvAuthorType.agent : ConvAuthorType.user,
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    handle: firstNonEmpty([json['handle']]),
  );
}

class ConvAttachment {
  const ConvAttachment({required this.url, this.name, this.type});
  final String url;
  final String? name;
  final String? type;

  bool get isImage => (type ?? '').startsWith('image/') ||
      RegExp(r'\.(jpe?g|png|webp|heic)$', caseSensitive: false).hasMatch(url);

  factory ConvAttachment.fromJson(Map<String, dynamic> json) => ConvAttachment(
    url: json['url']?.toString() ?? '',
    name: firstNonEmpty([json['name']]),
    type: firstNonEmpty([json['type']]),
  );
}

/// suggested → waiting for a person; approved → OK'd but the agent only
/// suggests this kind, so nothing ran; done; held (Governance wants a second
/// look); blocked; dismissed; failed.
enum ActionCardStatus { suggested, approved, done, held, blocked, dismissed, failed }

ActionCardStatus _cardStatus(String? v) => switch (v) {
  'approved' => ActionCardStatus.approved,
  'done' => ActionCardStatus.done,
  'held' => ActionCardStatus.held,
  'blocked' => ActionCardStatus.blocked,
  'dismissed' => ActionCardStatus.dismissed,
  'failed' => ActionCardStatus.failed,
  _ => ActionCardStatus.suggested,
};

/// An action inside an agent's reply — a draft under the hood. Approving one
/// is `POST /api/conversations/:entity/:id/cards/:draftId`, which the server
/// restricts to the Flow Agents admin roles; this app never shows the
/// Approve button to a technician (see [ConversationThread.canApproveCards]).
class ActionCard {
  const ActionCard({
    required this.kind,
    required this.title,
    required this.status,
    required this.draftId,
    this.reason,
    this.executionNote,
  });

  final String kind;
  final String title;
  final ActionCardStatus status;
  final String draftId;
  final String? reason;
  final String? executionNote;

  factory ActionCard.fromJson(Map<String, dynamic> json) => ActionCard(
    kind: json['kind']?.toString() ?? '',
    title: firstNonEmpty([json['title'], json['kind']]) ?? '',
    status: _cardStatus(json['status']?.toString()),
    draftId: json['draftId']?.toString() ?? '',
    reason: firstNonEmpty([json['reason']]),
    executionNote: firstNonEmpty([json['executionNote']]),
  );
}

class ConvGrounding {
  const ConvGrounding({required this.checked, required this.grounded, required this.dropped});
  final int checked;
  final int grounded;
  final int dropped;

  static ConvGrounding? fromJson(dynamic json) {
    if (json is! Map) return null;
    return ConvGrounding(
      checked: asInt(json['checked']) ?? 0,
      grounded: asInt(json['grounded']) ?? 0,
      dropped: asInt(json['dropped']) ?? 0,
    );
  }
}

/// The Orchestrator's routing decision, shown in the thread as "Routing to
/// Visual Inspector (photos) and SLA Guardian (due dates)".
class ConvRouting {
  const ConvRouting({this.rule, this.agents = const [], this.line});
  final String? rule;
  final List<ConvRoutedAgent> agents;

  /// The server's own sentence ("Routing to Visual Inspector (photos) and
  /// SLA Guardian (due dates)" / "Answering myself — …").
  final String? line;

  static ConvRouting? fromJson(dynamic json) {
    if (json is! Map) return null;
    final agents = json['agents'];
    return ConvRouting(
      rule: firstNonEmpty([json['rule']]),
      line: firstNonEmpty([json['line']]),
      agents: agents is List
          ? agents.whereType<Map>().map((a) => ConvRoutedAgent.fromJson(Map<String, dynamic>.from(a))).toList()
          : const [],
    );
  }
}

class ConvRoutedAgent {
  const ConvRoutedAgent({required this.name, this.templateId, this.reason});
  final String name;
  final String? templateId;
  final String? reason;

  factory ConvRoutedAgent.fromJson(Map<String, dynamic> json) => ConvRoutedAgent(
    name: firstNonEmpty([json['name'], json['agentName'], json['templateId']]) ?? '—',
    templateId: firstNonEmpty([json['templateId']]),
    reason: firstNonEmpty([json['reason']]),
  );
}

enum ConvMessageKind { message, finding, system }

/// Where a message stands on this phone. Server messages are always [sent].
enum OutgoingState { sent, sending, queued, failed }

class ConvMessage {
  const ConvMessage({
    required this.id,
    required this.author,
    required this.body,
    required this.createdAt,
    this.mentions = const [],
    this.replyTo,
    this.attachments = const [],
    this.editedAt,
    this.deletedAt,
    this.kind = ConvMessageKind.message,
    this.runId,
    this.grounding,
    this.notInData = const [],
    this.cards = const [],
    this.clientId,
    this.mine = false,
    this.routing,
    this.schedules = const [],
    this.scheduleDeleted = false,
    this.followUps = const [],
    this.clarify,
    this.outgoing = OutgoingState.sent,
    this.failure,
  });

  final String id;
  final ConvAuthor author;

  /// Markdown for agents, plain text for people. "" once deleted.
  final String body;
  final List<ConvMention> mentions;
  final String? replyTo;
  final List<ConvAttachment> attachments;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final ConvMessageKind kind;
  final String? runId;
  final ConvGrounding? grounding;
  final List<String> notInData;
  final List<ActionCard> cards;
  final String? clientId;
  final bool mine;
  final ConvRouting? routing;

  /// Schedules this message created or shows (orchestrator O3 schedule cards).
  final List<UserSchedule> schedules;

  /// The message carried a Schedule card whose schedule was since deleted.
  final bool scheduleDeleted;

  /// One-click follow-ups at the end of a Flow Agent reply ("Check this
  /// again tomorrow at 09:00") — each creates a schedule (C1).
  final List<ConvFollowUp> followUps;

  /// The Flow Agent's one clarifying question; answering means replying to
  /// this message with another `@agent` message (C1).
  final String? clarify;

  /// Local-only: a message this phone is still sending (or holding offline).
  final OutgoingState outgoing;

  /// Local-only: why a send failed, in the server's words.
  final String? failure;

  bool get isDeleted => deletedAt != null;
  bool get isAgent => author.isAgent;
  bool get isLocal => outgoing != OutgoingState.sent;

  ConvMessage copyWith({OutgoingState? outgoing, String? failure, bool clearFailure = false, bool? mine}) => ConvMessage(
    id: id,
    author: author,
    body: body,
    createdAt: createdAt,
    mentions: mentions,
    replyTo: replyTo,
    attachments: attachments,
    editedAt: editedAt,
    deletedAt: deletedAt,
    kind: kind,
    runId: runId,
    grounding: grounding,
    notInData: notInData,
    cards: cards,
    clientId: clientId,
    mine: mine ?? this.mine,
    routing: routing,
    schedules: schedules,
    scheduleDeleted: scheduleDeleted,
    followUps: followUps,
    clarify: clarify,
    outgoing: outgoing ?? this.outgoing,
    failure: clearFailure ? null : (failure ?? this.failure),
  );

  factory ConvMessage.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> maps(dynamic v) =>
        v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final author = json['author'];
    // C1 Schedule card: `schedule: {scheduleId, schedule: ScheduleDTO | null}`
    // (read live; null once deleted). A bare DTO is accepted too.
    final card = json['schedule'] is Map ? Map<String, dynamic>.from(json['schedule'] as Map) : null;
    final cardHasWrapper = card != null && card.containsKey('scheduleId');
    final inner = cardHasWrapper
        ? (card['schedule'] is Map ? Map<String, dynamic>.from(card['schedule'] as Map) : null)
        : card;
    final schedules = [...maps(json['schedules']), ?inner];
    final clarify = json['clarify'];
    return ConvMessage(
      id: json['id']?.toString() ?? '',
      author: author is Map
          ? ConvAuthor.fromJson(Map<String, dynamic>.from(author))
          : const ConvAuthor(type: ConvAuthorType.user, id: '', name: '—'),
      body: json['body']?.toString() ?? '',
      mentions: maps(json['mentions']).map(ConvMention.fromJson).toList(),
      replyTo: firstNonEmpty([json['replyTo']]),
      attachments: maps(json['attachments']).map(ConvAttachment.fromJson).where((a) => a.url.isNotEmpty).toList(),
      createdAt: asDate(json['createdAt']) ?? DateTime.now(),
      editedAt: asDate(json['editedAt']),
      deletedAt: asDate(json['deletedAt']),
      kind: switch (json['kind']) {
        'finding' => ConvMessageKind.finding,
        'system' => ConvMessageKind.system,
        _ => ConvMessageKind.message,
      },
      runId: firstNonEmpty([json['runId']]),
      grounding: ConvGrounding.fromJson(json['grounding']),
      notInData: json['notInData'] is List
          ? (json['notInData'] as List).map((e) => e.toString()).toList()
          : const [],
      cards: maps(json['cards']).map(ActionCard.fromJson).toList(),
      clientId: firstNonEmpty([json['clientId']]),
      mine: asBool(json['mine']) ?? false,
      routing: ConvRouting.fromJson(json['routing']),
      schedules: schedules.map(UserSchedule.fromJson).where((s) => s.id.isNotEmpty || s.title.isNotEmpty).toList(),
      scheduleDeleted: cardHasWrapper && inner == null,
      followUps: maps(json['followUps']).map(ConvFollowUp.fromJson).where((f) => f.label.isNotEmpty).toList(),
      clarify: clarify is Map ? firstNonEmpty([clarify['question']]) : null,
    );
  }
}

/// A one-click follow-up under a Flow Agent reply. [draft] is the server's
/// `ScheduleDraft`, sent back as-is to `POST /api/schedules`.
class ConvFollowUp {
  const ConvFollowUp({required this.id, required this.label, this.draft = const {}});
  final String id;
  final String label;
  final Map<String, dynamic> draft;

  factory ConvFollowUp.fromJson(Map<String, dynamic> json) => ConvFollowUp(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    draft: json['draft'] is Map ? Map<String, dynamic>.from(json['draft'] as Map) : const {},
  );
}

/// queued → working (live stage) → replied | failed | offline | stopped.
/// Specialists say running / completed on the wire; those map to working /
/// replied here.
enum SessionStatus { queued, working, replied, failed, offline, stopped }

SessionStatus _sessionStatus(String? v) => switch (v) {
  'working' || 'running' => SessionStatus.working,
  'replied' || 'completed' => SessionStatus.replied,
  'failed' => SessionStatus.failed,
  'offline' => SessionStatus.offline,
  'stopped' => SessionStatus.stopped,
  _ => SessionStatus.queued,
};

/// One specialist the Orchestrator handed part of the job to, with its own
/// live stage ("reading 3 photos").
class ConvSpecialist {
  const ConvSpecialist({required this.name, this.stage, this.status = SessionStatus.working});
  final String name;
  final String? stage;
  final SessionStatus status;

  factory ConvSpecialist.fromJson(Map<String, dynamic> json) => ConvSpecialist(
    name: firstNonEmpty([json['agentName'], json['name'], json['templateId']]) ?? '—',
    stage: firstNonEmpty([json['stage']]),
    status: _sessionStatus(json['status']?.toString()),
  );
}

class ConvSession {
  const ConvSession({
    required this.id,
    required this.agentId,
    required this.agentName,
    required this.messageId,
    required this.status,
    required this.startedAt,
    this.runId,
    this.stage,
    this.finishedAt,
    this.replyId,
    this.requesterName,
    this.routing,
    this.specialists = const [],
    this.requesterId,
    this.canStop = false,
    this.elapsed,
    this.receivedAt,
  });

  final String id;
  final String agentId;
  final String agentName;

  /// The mentioning message.
  final String messageId;
  final SessionStatus status;

  /// Plain words, only from real run stages ("checking photos").
  final String? stage;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? runId;
  final String? replyId;
  final String? requesterName;
  final ConvRouting? routing;
  final List<ConvSpecialist> specialists;
  final String? requesterId;

  /// The server says this viewer may Stop it (GET only; always false on
  /// the socket — the app also allows it when [requesterId] is the viewer).
  final bool canStop;

  /// The server's `elapsedMs` when the DTO was built.
  final Duration? elapsed;

  /// When this phone received the DTO (pairs with [elapsed]).
  final DateTime? receivedAt;

  /// When to count the elapsed time from. Uses the server's `elapsedMs`
  /// against the moment this phone received it, so a phone clock that is
  /// minutes off doesn't show "working · -3:12" (or 7:40 on a fresh run).
  DateTime get countFrom {
    final e = elapsed;
    final r = receivedAt;
    return e != null && r != null ? r.subtract(e) : startedAt;
  }

  bool get isLive => status == SessionStatus.queued || status == SessionStatus.working;

  ConvSession copyWith({SessionStatus? status, String? stage}) => ConvSession(
    id: id,
    agentId: agentId,
    agentName: agentName,
    messageId: messageId,
    status: status ?? this.status,
    startedAt: startedAt,
    stage: stage ?? this.stage,
    finishedAt: finishedAt,
    runId: runId,
    replyId: replyId,
    requesterName: requesterName,
    routing: routing,
    specialists: specialists,
    requesterId: requesterId,
    canStop: canStop,
    elapsed: elapsed,
    receivedAt: receivedAt,
  );

  factory ConvSession.fromJson(Map<String, dynamic> json) {
    final team = json['specialists'] ?? json['team'] ?? json['children'];
    return ConvSession(
      id: firstNonEmpty([json['id'], json['sessionId']]) ?? '',
      agentId: json['agentId']?.toString() ?? '',
      agentName: firstNonEmpty([json['agentName']]) ?? '—',
      messageId: json['messageId']?.toString() ?? '',
      status: _sessionStatus(json['status']?.toString()),
      stage: firstNonEmpty([json['stage']]),
      startedAt: asDate(json['startedAt']) ?? DateTime.now(),
      finishedAt: asDate(json['finishedAt']),
      runId: firstNonEmpty([json['runId']]),
      replyId: firstNonEmpty([json['replyId']]),
      requesterName: firstNonEmpty([json['requesterName']]),
      routing: ConvRouting.fromJson(json['routing']),
      specialists: team is List
          ? team.whereType<Map>().map((e) => ConvSpecialist.fromJson(Map<String, dynamic>.from(e))).toList()
          : const [],
      requesterId: firstNonEmpty([json['requesterId']]),
      canStop: asBool(json['canStop']) ?? false,
      elapsed: asInt(json['elapsedMs']) == null ? null : Duration(milliseconds: asInt(json['elapsedMs'])!),
      receivedAt: DateTime.now(),
    );
  }
}

class ConvRecordRef {
  const ConvRecordRef({required this.title, this.ref});
  final String title;
  final String? ref;

  factory ConvRecordRef.fromJson(dynamic json) => json is Map
      ? ConvRecordRef(title: json['title']?.toString() ?? '', ref: firstNonEmpty([json['ref']]))
      : const ConvRecordRef(title: '');
}

/// `GET /api/conversations/:entity/:id`.
class ConversationThread {
  const ConversationThread({
    required this.entity,
    required this.entityId,
    required this.record,
    required this.messages,
    this.participants = const [],
    this.following = false,
    this.muted = false,
    this.lastReadAt,
    this.unread = 0,
    this.sessions = const [],
    this.nextCursor,
    this.canMentionAgents = false,
    this.canApproveCards = false,
  });

  final ConvEntity entity;

  /// Always the record's UUID, even when the thread was opened by reference.
  final String entityId;
  final ConvRecordRef record;

  /// Oldest first.
  final List<ConvMessage> messages;
  final List<ConvAuthor> participants;
  final bool following;
  final bool muted;

  /// Where this person had read up to BEFORE this GET (the unread divider).
  final DateTime? lastReadAt;
  final int unread;
  final List<ConvSession> sessions;
  final String? nextCursor;

  /// The server's answer to "may this person start agent sessions?"
  /// (Flow Agents roles). The picker only offers agents when true.
  final bool canMentionAgents;

  /// `canApproveCards` from the server (Admin only today; the cards route
  /// answers 403 to a Technician). This app has no Approve button — when
  /// false a suggested card says "Needs an admin's OK".
  final bool canApproveCards;

  /// The same thread with a new "load older" cursor.
  ConversationThread withCursor(String? cursor) => ConversationThread(
    entity: entity,
    entityId: entityId,
    record: record,
    messages: messages,
    participants: participants,
    following: following,
    muted: muted,
    lastReadAt: lastReadAt,
    unread: unread,
    sessions: sessions,
    nextCursor: cursor,
    canMentionAgents: canMentionAgents,
    canApproveCards: canApproveCards,
  );

  factory ConversationThread.fromJson(Map<String, dynamic> json, {required ConvEntity fallbackEntity}) {
    List<Map<String, dynamic>> maps(dynamic v) =>
        v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final me = json['me'] is Map ? Map<String, dynamic>.from(json['me'] as Map) : const <String, dynamic>{};
    return ConversationThread(
      entity: ConvEntity.fromWire(json['entity']?.toString()) ?? fallbackEntity,
      entityId: json['entityId']?.toString() ?? '',
      record: ConvRecordRef.fromJson(json['record']),
      messages: maps(json['messages']).map(ConvMessage.fromJson).toList(),
      participants: maps(json['participants']).map(ConvAuthor.fromJson).toList(),
      following: asBool(me['following']) ?? false,
      muted: asBool(me['muted']) ?? false,
      lastReadAt: asDate(me['lastReadAt']),
      unread: asInt(json['unread']) ?? 0,
      sessions: maps(json['sessions']).map(ConvSession.fromJson).toList(),
      nextCursor: firstNonEmpty([json['nextCursor']]),
      canMentionAgents: asBool(json['canMentionAgents']) ?? false,
      canApproveCards: asBool(json['canApproveCards']) ?? false,
    );
  }
}

class MentionCandidate {
  const MentionCandidate({
    required this.type,
    required this.id,
    required this.name,
    required this.handle,
    this.role,
    this.onCall = false,
    this.orchestrator = false,
  });

  final ConvAuthorType type;
  final String id;
  final String name;
  final String handle;
  final String? role;
  final bool onCall;

  /// `@agent` — the one handle that picks the right specialist.
  final bool orchestrator;

  bool get isAgent => type == ConvAuthorType.agent;

  factory MentionCandidate.fromJson(Map<String, dynamic> json) => MentionCandidate(
    type: json['type'] == 'agent' ? ConvAuthorType.agent : ConvAuthorType.user,
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    handle: firstNonEmpty([json['handle'], json['name']])?.replaceAll(' ', '') ?? '',
    role: firstNonEmpty([json['role']]),
    onCall: asBool(json['onCall']) ?? false,
    orchestrator: asBool(json['orchestrator']) ?? (json['handle'] == 'agent'),
  );
}

/// Plain-words note about a mention that did not start a session.
class MentionNote {
  const MentionNote({required this.code, required this.text, this.mention});
  final String code;
  final String text;
  final String? mention;

  factory MentionNote.fromJson(Map<String, dynamic> json) => MentionNote(
    code: json['code']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    mention: firstNonEmpty([json['mention']]),
  );
}

class PostMessageResult {
  const PostMessageResult({required this.message, this.invoked = const [], this.notes = const []});
  final ConvMessage message;
  final List<ConvSession> invoked;
  final List<MentionNote> notes;

  /// [requestMessageId] fills in the mentioning message on the invoked
  /// sessions, which the POST answer does not repeat.
  factory PostMessageResult.fromJson(Map<String, dynamic> json) {
    final message = ConvMessage.fromJson(
      json['message'] is Map ? Map<String, dynamic>.from(json['message'] as Map) : const {},
    );
    List<Map<String, dynamic>> maps(dynamic v) =>
        v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    return PostMessageResult(
      message: message,
      invoked: maps(json['invoked'])
          .map((m) => ConvSession.fromJson({
                ...m,
                'id': m['sessionId'] ?? m['id'],
                'messageId': m['messageId'] ?? message.id,
                'status': m['status'] ?? 'queued',
              }))
          .toList(),
      notes: maps(json['notes']).map(MentionNote.fromJson).where((n) => n.text.isNotEmpty).toList(),
    );
  }
}

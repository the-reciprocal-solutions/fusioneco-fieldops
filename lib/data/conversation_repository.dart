// ignore_for_file: prefer_initializing_formals — named params cannot be private
import '../core/conversation/conversation_outbox.dart';
import '../core/network/api_client.dart';
import '../core/network/envelope.dart';
import '../core/offline/offline_db.dart';
import '../core/offline/sync_client.dart';
import '../domain/conversation.dart';

/// `/api/conversations/**` (server: `documentation/conversations.md`).
///
/// Offline contract, chosen per call as the rest of `data/` does:
/// - the thread GET goes through `syncGet`, so a thread opened once opens
///   again in a plant room with no signal (from the 24 h cache, marked as a
///   saved copy);
/// - posting a message goes through `syncRequest`: no signal → it parks in
///   the offline queue and replays by itself (with its `clientId`, which the
///   server echoes, so it never shows twice). A 4xx/5xx is thrown and the
///   thread shows Retry. `queueOnServerError` is deliberately off: a chat
///   line that lands an hour after a server error, with an @agent in it, is
///   a surprise session nobody expects;
/// - everything else (mention search, follow/mute, delete) is online only.
class ConversationRepository implements ConversationPoster {
  ConversationRepository({required SyncClient sync, required ApiClient api, required OfflineDb db})
    : _sync = sync,
      _api = api,
      _db = db;

  final SyncClient _sync;
  final ApiClient _api;
  final OfflineDb _db;

  /// Offline-queue entity type for queued messages; the entity id is
  /// `<entity>:<record id>` (see [queueKey]).
  static const queueEntityType = 'conversation';

  static String queueKey(ConvEntity entity, String id) => '${entity.wire}:$id';

  static String _base(ConvEntity entity, String id) =>
      '/api/conversations/${entity.wire}/${Uri.encodeComponent(id)}';

  /// The newest page (or the page before [before]). Opening the thread marks
  /// it read unless [markRead] is false (the snag detail's preview card must
  /// not clear the unread count the person hasn't seen).
  Future<({ConversationThread thread, bool fromCache})> fetch(
    ConvEntity entity,
    String id, {
    String? before,
    int? limit,
    bool markRead = true,
  }) async {
    final query = <String, dynamic>{
      'before': ?before,
      'limit': ?limit,
      if (!markRead) 'markRead': 'false',
    };
    final read = await _sync.syncGet(_base(entity, id), query: query.isEmpty ? null : query);
    return (
      thread: ConversationThread.fromJson(unwrapMap(read.data), fallbackEntity: entity),
      fromCache: read.fromCache,
    );
  }

  @override
  Future<PostOutcome> post(
    ConvEntity entity,
    String id, {
    required String body,
    required String clientId,
    String? replyTo,
  }) async {
    final write = await _sync.syncRequest(
      'post',
      '${_base(entity, id)}/messages',
      data: {'body': body, 'replyTo': ?replyTo, 'clientId': clientId},
      label: 'Message: ${body.length > 40 ? '${body.substring(0, 40)}…' : body}',
      entityType: queueEntityType,
      entityId: queueKey(entity, id),
    );
    if (!write.synced) return const PostQueued();
    return PostSent(PostMessageResult.fromJson(unwrapMap(write.data)));
  }

  /// Messages for this thread still waiting in the offline queue — shown in
  /// the thread as "waiting for signal", including after an app restart.
  Future<List<ConvMessage>> queued(ConvEntity entity, String id, ConvAuthor me) async {
    final key = queueKey(entity, id);
    final all = await _db.listMutations();
    return [
      for (final m in all)
        if (m.entityType == queueEntityType && m.entityId == key && m.body is Map)
          ConvMessage(
            id: 'local:${(m.body as Map)['clientId'] ?? m.clientMutationId}',
            author: me,
            body: (m.body as Map)['body']?.toString() ?? '',
            replyTo: (m.body as Map)['replyTo']?.toString(),
            clientId: (m.body as Map)['clientId']?.toString() ?? m.clientMutationId,
            createdAt: m.createdAt,
            mine: true,
            outgoing: OutgoingState.queued,
          ),
    ];
  }

  /// People and agents this person can mention. Online only; the picker
  /// falls back to the thread's participants when this fails.
  Future<List<MentionCandidate>> mentions(String q, {ConvEntity? entity, String? entityId}) async {
    final res = await _api.get('/api/conversations/mentions', query: {
      'q': q,
      'entity': ?entity?.wire,
      'entityId': ?entityId,
    });
    return unwrapList(res.data).map(MentionCandidate.fromJson).where((c) => c.handle.isNotEmpty).toList();
  }

  Future<void> follow(ConvEntity entity, String id, bool on) =>
      _api.post('${_base(entity, id)}/follow', data: {'on': on});

  Future<void> mute(ConvEntity entity, String id, bool on) =>
      _api.post('${_base(entity, id)}/mute', data: {'on': on});

  /// Stops a live agent session (C2: the requester or an Admin; 409 when it
  /// already finished). Online only.
  Future<ConvSession> stop(ConvEntity entity, String id, String sessionId) async {
    final res = await _api.post('${_base(entity, id)}/sessions/${Uri.encodeComponent(sessionId)}/stop');
    return ConvSession.fromJson(unwrapMap(res.data));
  }

  /// Soft delete of the signed-in person's own message.
  Future<ConvMessage> delete(ConvEntity entity, String id, String messageId) async {
    final res = await _api.delete('${_base(entity, id)}/messages/${Uri.encodeComponent(messageId)}');
    return ConvMessage.fromJson(unwrapMap(res.data));
  }
}

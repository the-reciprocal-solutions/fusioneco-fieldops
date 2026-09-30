import '../../domain/conversation.dart';
import '../network/api_exception.dart';

/// What happened to one outgoing message.
sealed class PostOutcome {
  const PostOutcome();
}

/// The server has it.
class PostSent extends PostOutcome {
  const PostSent(this.result);
  final PostMessageResult result;
}

/// No signal: it is parked in the app's offline queue (`pending_mutations`)
/// and replays by itself — `SyncClient.syncRequest` decided that.
class PostQueued extends PostOutcome {
  const PostQueued();
}

/// The seam the outbox sends through. The real one is
/// `ConversationRepository`; tests hand-write a fake (no mocking library).
/// Throws an [ApiFailure] when the server answered with an error.
abstract interface class ConversationPoster {
  Future<PostOutcome> post(
    ConvEntity entity,
    String id, {
    required String body,
    required String clientId,
    String? replyTo,
  });
}

/// This phone's unsent messages for one thread (docs/conversations-and-schedules.md
/// "Offline"):
/// - **sending** — the request is in flight;
/// - **queued** — offline; it lives in the offline queue and survives an app
///   restart (the controller re-reads the queue, see [syncQueued]);
/// - **failed** — the server said no (4xx/5xx). Kept on screen with Retry /
///   Discard. Only in memory: leaving the thread drops it, which the
///   failure line says.
///
/// Every message carries a `clientId` minted once; the server echoes it, so a
/// retry or a queued replay can never show up twice in the thread.
class ConversationOutbox {
  final _items = <String, ConvMessage>{};

  /// Oldest first.
  List<ConvMessage> get messages =>
      _items.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  bool get isEmpty => _items.isEmpty;

  ConvMessage? byClientId(String clientId) => _items[clientId];

  /// A new local message, shown at once as "sending".
  ConvMessage draft({
    required ConvAuthor me,
    required String body,
    required String clientId,
    String? replyTo,
    DateTime? now,
  }) {
    final m = ConvMessage(
      id: 'local:$clientId',
      author: me,
      body: body,
      createdAt: now ?? DateTime.now(),
      replyTo: replyTo,
      clientId: clientId,
      mine: true,
      outgoing: OutgoingState.sending,
    );
    _items[clientId] = m;
    return m;
  }

  /// Sends (or re-sends) the local message [clientId] and records the
  /// outcome. Returns the server's answer when it was sent, else null.
  Future<PostMessageResult?> send(ConversationPoster poster, ConvEntity entity, String id, String clientId) async {
    final m = _items[clientId];
    if (m == null) return null;
    _items[clientId] = m.copyWith(outgoing: OutgoingState.sending, clearFailure: true);
    try {
      final outcome = await poster.post(entity, id, body: m.body, clientId: clientId, replyTo: m.replyTo);
      switch (outcome) {
        case PostSent(:final result):
          _items.remove(clientId);
          return result;
        case PostQueued():
          if (_items.containsKey(clientId)) {
            _items[clientId] = m.copyWith(outgoing: OutgoingState.queued, clearFailure: true);
          }
          return null;
      }
    } on ApiFailure catch (e) {
      if (_items.containsKey(clientId)) {
        _items[clientId] = m.copyWith(outgoing: OutgoingState.failed, failure: e.message);
      }
      return null;
    }
  }

  /// Drops a failed message the person gave up on.
  void discard(String clientId) => _items.remove(clientId);

  /// The offline queue is the truth for queued messages: [fromQueue] is what
  /// it holds for this thread right now. Queued ones that left it (replayed)
  /// go; ones it holds that this outbox never saw (an app restart) come back.
  void syncQueued(List<ConvMessage> fromQueue) {
    final inQueue = {for (final m in fromQueue) ?m.clientId};
    _items.removeWhere((k, v) => v.outgoing == OutgoingState.queued && !inQueue.contains(k));
    for (final m in fromQueue) {
      final k = m.clientId;
      if (k == null) continue;
      final existing = _items[k];
      if (existing == null || existing.outgoing != OutgoingState.sending) {
        _items[k] = m.copyWith(outgoing: OutgoingState.queued);
      }
    }
  }

  /// Removes local copies the server has echoed back (by `clientId`).
  void dropEchoed(Iterable<ConvMessage> server) {
    for (final m in server) {
      final k = m.clientId;
      if (k != null && _items[k]?.outgoing != OutgoingState.queued) _items.remove(k);
    }
  }
}

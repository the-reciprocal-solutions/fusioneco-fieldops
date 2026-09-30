import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/conversation/conversation_outbox.dart';
import '../core/conversation/thread_layout.dart';
import '../core/network/api_exception.dart';
import '../domain/user_schedule.dart';
import '../core/realtime/socket_service.dart';
import '../data/conversation_repository.dart';
import '../domain/conversation.dart';
import 'auth_controller.dart';
import 'providers.dart';
import 'schedules_controller.dart';
import 'socket_controller.dart';

/// One record's conversation, live (docs/conversations-and-schedules.md).
///
/// Providers live here rather than in `providers.dart` on purpose: that file
/// is shared with the offline-sync work (PENDING P-008) and this feature
/// needs nothing injected at startup.
///
/// Live updates come from two places, because either alone is not enough on
/// a phone in a plant room:
/// - the socket room `conv:<entity>:<id>` (instant, but only while connected,
///   and the server drops emits from a stand-alone worker process);
/// - polling the thread: every 5 s while an agent session is queued or
///   working, every 30 s otherwise, plus pull-to-refresh and app resume
///   (the screen calls [ConversationController.refresh]).

typedef ConvKey = ({ConvEntity entity, String id});

final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ConversationRepository(
    sync: ref.watch(syncClientProvider),
    api: ref.watch(apiClientProvider),
    db: ref.watch(offlineDbProvider),
  ),
);

/// The signed-in person as a conversation author, and every id the server
/// may know them by (a technician has a user id and a technician id).
final convMeProvider = Provider<({ConvAuthor author, Set<String> ids})?>((ref) {
  final session = ref.watch(authControllerProvider).session;
  if (session == null || session.userId.isEmpty) return null;
  return (
    author: ConvAuthor(type: ConvAuthorType.user, id: session.userId, name: session.name, handle: session.username),
    ids: {session.userId, ?session.technicianId},
  );
});

class ConvTyping {
  const ConvTyping({required this.name, required this.isAgent, this.stage});
  final String name;
  final bool isAgent;
  final String? stage;
}

class ConversationState {
  const ConversationState({
    this.thread,
    this.messages = const [],
    this.sessions = const [],
    this.loading = true,
    this.error,
    this.fromCache = false,
    this.dividerReadAt,
    this.typing = const {},
    this.notes = const [],
    this.loadingOlder = false,
    this.following = false,
    this.muted = false,
  });

  final ConversationThread? thread;

  /// Server messages plus this phone's unsent ones, oldest first.
  final List<ConvMessage> messages;
  final List<ConvSession> sessions;
  final bool loading;

  /// Why the first load failed (plain words from the server or network).
  final String? error;

  /// Showing the saved copy because there is no signal.
  final bool fromCache;

  /// Where the unread divider goes — fixed at the first load so polling
  /// (which marks the thread read) doesn't make it jump.
  final DateTime? dividerReadAt;
  final Map<String, ConvTyping> typing;

  /// Notes from the last send about mentions that didn't start a session.
  final List<MentionNote> notes;
  final bool loadingOlder;
  final bool following;
  final bool muted;

  List<ConvSession> get liveSessions => sessions.where((s) => s.isLive).toList();

  ConversationState copyWith({
    ConversationThread? thread,
    List<ConvMessage>? messages,
    List<ConvSession>? sessions,
    bool? loading,
    String? error,
    bool clearError = false,
    bool? fromCache,
    DateTime? dividerReadAt,
    Map<String, ConvTyping>? typing,
    List<MentionNote>? notes,
    bool? loadingOlder,
    bool? following,
    bool? muted,
  }) => ConversationState(
    thread: thread ?? this.thread,
    messages: messages ?? this.messages,
    sessions: sessions ?? this.sessions,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    fromCache: fromCache ?? this.fromCache,
    dividerReadAt: dividerReadAt ?? this.dividerReadAt,
    typing: typing ?? this.typing,
    notes: notes ?? this.notes,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    following: following ?? this.following,
    muted: muted ?? this.muted,
  );
}

class ConversationController extends AutoDisposeFamilyNotifier<ConversationState, ConvKey> {
  final _outbox = ConversationOutbox();
  List<ConvMessage> _server = const [];
  Timer? _poll;
  bool _pollFast = false;
  StreamSubscription<ConvSocketEvent>? _sub;
  SocketService? _socket;
  bool _disposed = false;
  bool _dividerSet = false;
  int _queuedCount = 0;

  ConversationRepository get _repo => ref.read(conversationRepositoryProvider);

  @override
  ConversationState build(ConvKey arg) {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _sub?.cancel();
      _socket?.leaveConversation(arg.entity.wire, arg.id);
    });

    try {
      final socket = ref.read(socketConnectionProvider);
      _socket = socket;
      socket.joinConversation(arg.entity.wire, arg.id);
      _sub = socket.conversationEvents.listen(_onSocket);
    } catch (_) {
      // No socket (tests, or providers not wired): polling still works.
    }

    // A queued message replaying (or a new one parked) changes the queue.
    ref.listen(queueChangedProvider, (_, _) => unawaited(_syncQueued()));

    Future.microtask(load);
    return const ConversationState();
  }

  bool _isThisThread(String? entity, String? entityId) {
    if (entity != null && entity != arg.entity.wire) return false;
    final uuid = state.thread?.entityId;
    return entityId == arg.id || (uuid != null && uuid.isNotEmpty && entityId == uuid);
  }

  Set<String> get _myIds => ref.read(convMeProvider)?.ids ?? const {};

  void _emit({ConversationState? base}) {
    if (_disposed) return;
    final b = base ?? state;
    state = b.copyWith(messages: mergeWithLocal(_server, _outbox.messages));
    _schedulePoll();
  }

  /// First load, pull-to-refresh, app resume and every poll.
  Future<void> load() => _load();
  Future<void> refresh() => _load();

  Future<void> _load() async {
    try {
      final r = await _repo.fetch(arg.entity, arg.id);
      if (_disposed) return;
      final t = r.thread;
      // Keep older pages already loaded ("Show earlier") below the new page.
      final firstNew = t.messages.isEmpty ? null : t.messages.first.createdAt;
      final kept = firstNew == null
          ? const <ConvMessage>[]
          : _server.where((m) => m.createdAt.isBefore(firstNew) && !t.messages.any((n) => n.id == m.id)).toList();
      _server = [...kept, ...t.messages];
      _outbox.dropEchoed(_server);
      final setDivider = !_dividerSet && !r.fromCache;
      if (setDivider) _dividerSet = true;
      final base = state.copyWith(
        thread: t,
        sessions: t.sessions,
        loading: false,
        clearError: true,
        fromCache: r.fromCache,
        dividerReadAt: setDivider ? t.lastReadAt : null,
        following: t.following,
        muted: t.muted,
      );
      await _syncQueued(emit: false);
      _emit(base: base);
    } on ApiFailure catch (e) {
      if (_disposed) return;
      state = state.copyWith(loading: false, error: state.thread == null ? e.message : null);
      _schedulePoll();
    }
  }

  Future<void> loadOlder() async {
    final cursor = state.thread?.nextCursor;
    if (cursor == null || state.loadingOlder) return;
    state = state.copyWith(loadingOlder: true);
    try {
      final r = await _repo.fetch(arg.entity, arg.id, before: cursor, markRead: false);
      if (_disposed) return;
      final ids = {for (final m in _server) m.id};
      _server = [...r.thread.messages.where((m) => !ids.contains(m.id)), ..._server];
      _emit(base: state.copyWith(loadingOlder: false, thread: state.thread!.withCursor(r.thread.nextCursor)));
    } on ApiFailure {
      if (!_disposed) state = state.copyWith(loadingOlder: false);
    }
  }

  Future<void> _syncQueued({bool emit = true}) async {
    final me = ref.read(convMeProvider)?.author;
    if (me == null) return;
    try {
      final queued = await _repo.queued(arg.entity, arg.id, me);
      if (_disposed) return;
      final dropped = queued.length < _queuedCount;
      _queuedCount = queued.length;
      _outbox.syncQueued(queued);
      if (emit) _emit();
      // Something replayed: fetch the server's copy (and any agent session).
      if (dropped) unawaited(_load());
    } catch (_) {
      // The queue is best effort here; the Sync Center shows it anyway.
    }
  }

  // ── sending ──

  /// Posts [text]. Offline, it parks in the offline queue and shows as
  /// "waiting for signal"; a server refusal shows Retry.
  Future<void> send(String text, {String? replyTo}) async {
    final me = ref.read(convMeProvider)?.author;
    final body = text.trim();
    if (me == null || body.isEmpty) return;
    final clientId = ref.read(apiClientProvider).newMutationId();
    _outbox.draft(me: me, body: body, clientId: clientId, replyTo: replyTo);
    _emit(base: state.copyWith(notes: const []));
    await _deliver(clientId);
  }

  Future<void> retry(String clientId) => _deliver(clientId);

  void discard(String clientId) {
    _outbox.discard(clientId);
    _emit();
  }

  Future<void> _deliver(String clientId) async {
    _emit();
    final result = await _outbox.send(_repo, arg.entity, arg.id, clientId);
    if (_disposed) return;
    if (result != null) {
      _server = upsertMessage(_server, result.message.copyWith(mine: true));
      final sessions = [...state.sessions];
      for (final s in result.invoked) {
        if (!sessions.any((x) => x.id == s.id)) sessions.add(s);
      }
      _emit(base: state.copyWith(sessions: sessions, notes: result.notes));
    } else {
      _emit();
      // It may have been parked: pick the queue count up.
      unawaited(_syncQueued());
    }
  }

  /// Soft-deletes one of the person's own messages. Online only.
  Future<String?> deleteMine(String messageId) async {
    try {
      final m = await _repo.delete(arg.entity, arg.id, messageId);
      _server = upsertMessage(_server, m.copyWith(mine: true));
      _emit();
      return null;
    } on ApiFailure catch (e) {
      return e.message;
    }
  }

  Future<String?> setFollowing(bool on) async {
    try {
      await _repo.follow(arg.entity, arg.id, on);
      if (!_disposed) state = state.copyWith(following: on, muted: on ? false : null);
      return null;
    } on ApiFailure catch (e) {
      return e.message;
    }
  }

  Future<String?> setMuted(bool on) async {
    try {
      await _repo.mute(arg.entity, arg.id, on);
      if (!_disposed) state = state.copyWith(muted: on, following: on ? false : null);
      return null;
    } on ApiFailure catch (e) {
      return e.message;
    }
  }

  /// Stop a live session (requester or Admin). Returns the failure text.
  Future<String?> stop(String sessionId) async {
    try {
      final s = await _repo.stop(arg.entity, arg.id, sessionId);
      if (_disposed) return null;
      final sessions = [...state.sessions.where((x) => x.id != s.id), if (s.id.isNotEmpty) s];
      _emit(base: state.copyWith(sessions: sessions));
      unawaited(_load());
      return null;
    } on ApiFailure catch (e) {
      return e.message;
    }
  }

  /// A one-click follow-up under a Flow Agent reply → a schedule.
  Future<({UserSchedule? schedule, ApiFailure? failure})> acceptFollowUp(ConvMessage m, ConvFollowUp f) async {
    final entityId = state.thread?.entityId ?? arg.id;
    try {
      final s = await ref.read(scheduleRepositoryProvider).createFromDraft(
            f.draft,
            entity: arg.entity.wire,
            entityId: entityId.isEmpty ? arg.id : entityId,
            messageId: m.id,
          );
      return (schedule: s, failure: null);
    } on ApiFailure catch (e) {
      return (schedule: null, failure: e);
    }
  }

  void typing(bool on) => _socket?.sendTyping(arg.entity.wire, arg.id, typing: on);

  // ── live ──

  void _schedulePoll() {
    if (_disposed) return;
    final fast = state.liveSessions.isNotEmpty ||
        state.messages.any((m) => m.outgoing == OutgoingState.sending);
    if (_poll != null && fast == _pollFast) return;
    _poll?.cancel();
    _pollFast = fast;
    _poll = Timer.periodic(Duration(seconds: fast ? 5 : 30), (_) => unawaited(_load()));
  }

  void _onSocket(ConvSocketEvent e) {
    if (_disposed || !_isThisThread(e.entity, e.entityId)) return;
    switch (e.name) {
      case 'message.created':
      case 'message.updated':
        final raw = e.data['message'];
        if (raw is! Map) return;
        var m = ConvMessage.fromJson(Map<String, dynamic>.from(raw));
        if (isMine(m, _myIds)) m = m.copyWith(mine: true);
        _server = upsertMessage(_server, m);
        _outbox.dropEchoed([m]);
        final typing = {...state.typing}..remove(m.author.id);
        _emit(base: state.copyWith(typing: typing));
      case 'typing':
        final who = e.data['who'];
        if (who is! Map) return;
        final author = ConvAuthor.fromJson(Map<String, dynamic>.from(who));
        if (!author.isAgent && _myIds.contains(author.id)) return;
        final on = e.data['state']?.toString() != 'stop';
        final stage = e.data['stage']?.toString();
        final typing = {...state.typing};
        if (on) {
          typing[author.id] = ConvTyping(name: author.name, isAgent: author.isAgent, stage: stage);
        } else {
          typing.remove(author.id);
        }
        var sessions = state.sessions;
        if (author.isAgent && stage != null && stage.isNotEmpty) {
          sessions = [
            for (final s in sessions)
              s.isLive && s.agentId == author.id ? s.copyWith(status: SessionStatus.working, stage: stage) : s,
          ];
        }
        _emit(base: state.copyWith(typing: typing, sessions: sessions));
      case 'session.started':
      case 'session.updated':
      case 'session.finished':
        final s = ConvSession.fromJson(e.data);
        if (s.id.isEmpty) return;
        final sessions = [...state.sessions.where((x) => x.id != s.id), s];
        _emit(base: state.copyWith(sessions: sessions));
        // The reply may have been posted by a process with no socket.
        if (e.name == 'session.finished') unawaited(_load());
    }
  }
}

final conversationControllerProvider =
    NotifierProvider.autoDispose.family<ConversationController, ConversationState, ConvKey>(
  ConversationController.new,
);

/// A quiet peek at a thread for a record's detail screen (the snag card):
/// the newest few messages, unread count and live sessions. It passes
/// `markRead=false`, so looking at the record doesn't clear the unread count
/// for a thread nobody opened. Null when it can't be loaded (offline with no
/// saved copy, or no access) — the card then just offers to open the thread.
final conversationPreviewProvider =
    FutureProvider.autoDispose.family<ConversationThread?, ConvKey>((ref, key) async {
  try {
    final r = await ref.watch(conversationRepositoryProvider).fetch(key.entity, key.id, limit: 3, markRead: false);
    return r.thread;
  } on ApiFailure {
    return null;
  }
});

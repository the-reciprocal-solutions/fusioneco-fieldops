import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/conversation/mention_parser.dart';
import '../../core/network/api_exception.dart';
import '../../core/conversation/thread_layout.dart';
import '../../domain/conversation.dart';
import '../../state/conversation_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/tech_popup.dart';
import 'widgets/composer.dart';
import 'widgets/conv_visuals.dart';
import 'widgets/message_tile.dart';
import 'widgets/working_card.dart';

/// A record's conversation: messages, the live "agent working" card and the
/// composer. Embedded in the work-order Comments tab and the stand-alone
/// thread screen (docs/conversations-and-schedules.md).
class ConversationView extends ConsumerStatefulWidget {
  const ConversationView({super.key, required this.entity, required this.id, this.highlightMessageId});

  final ConvEntity entity;

  /// Record UUID or reference (`SN-00001`, `WO-161`).
  final String id;

  /// Deep link target: scrolled to and tinted once loaded.
  final String? highlightMessageId;

  @override
  ConsumerState<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends ConsumerState<ConversationView> with WidgetsBindingObserver {
  late final ConvKey _key = (entity: widget.entity, id: widget.id);
  final _scroll = ScrollController();
  final _composer = GlobalKey<ConversationComposerState>();
  final _keys = <String, GlobalKey>{};
  ConvMessage? _replyTo;
  String? _highlight;
  bool _didInitialScroll = false;
  int _lastCount = 0;
  int _lastLive = 0;
  String? _seenReplyId;
  Timer? _highlightOff;
  final _acceptedFollowUps = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _highlight = widget.highlightMessageId;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightOff?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(conversationControllerProvider(_key).notifier).refresh());
    }
  }

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  bool get _nearBottom => !_scroll.hasClients || _scroll.position.maxScrollExtent - _scroll.offset < 160;

  void _afterBuild(ConversationState s) {
    if (s.loading || s.thread == null) return;
    final count = s.messages.length;
    if (!_didInitialScroll) {
      _didInitialScroll = true;
      _lastCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _highlight == null ? null : _keys[_highlight!]?.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(target, alignment: 0.3, duration: const Duration(milliseconds: 300));
          Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _highlight = null);
          });
        } else if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
      return;
    }
    // An agent starting work adds a thinking bubble at the bottom: bring it
    // into view the same way a new message is.
    final live = s.liveSessions.length;
    final liveGrew = live > _lastLive;
    _lastLive = live;
    if (count > _lastCount || liveGrew) {
      final follow = _nearBottom || (count > 0 && s.messages.last.mine) || liveGrew;
      _lastCount = count;
      if (follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.animateTo(_scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
          }
        });
      }
    } else {
      _lastCount = count;
    }
  }

  Future<void> _send(String text) async {
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await ref
        .read(conversationControllerProvider(_key).notifier)
        .send(text, replyTo: reply == null ? null : replyTargetFor(reply));
  }

  void _startReply(ConvMessage m) {
    setState(() => _replyTo = m);
    _composer.currentState?.focus();
  }

  /// The Flow Agent asked one question: the answer is an @agent message
  /// replying to it (the server reads it with the pending request).
  void _answer(ConvMessage m) {
    setState(() => _replyTo = m);
    _composer.currentState?.prefill('@$kOrchestratorHandle ');
  }

  Future<void> _followUp(ConvMessage m, ConvFollowUp f) async {
    setState(() => _acceptedFollowUps.add(f.id));
    final r = await ref.read(conversationControllerProvider(_key).notifier).acceptFollowUp(m, f);
    if (!mounted) return;
    if (r.failure != null) {
      setState(() => _acceptedFollowUps.remove(f.id));
      showTechPopup(
        context,
        message: r.failure is NetworkFailure ? 'schedules.offline'.getString(context) : r.failure!.message,
        isError: true,
      );
    } else {
      showTechPopup(context, message: convTr(context, 'conv.follow_up_set', [r.schedule?.cadenceText ?? f.label]));
    }
  }

  Future<void> _stop(ConvSession s) async {
    final error = await ref.read(conversationControllerProvider(_key).notifier).stop(s.id);
    if (error != null && mounted) showTechPopup(context, message: error, isError: true);
  }

  Future<void> _more(ConvMessage m) async {
    final controller = ref.read(conversationControllerProvider(_key).notifier);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: FeColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!m.isLocal)
              ListTile(
                leading: const Icon(LucideIcons.reply),
                title: Text('conv.reply'.getString(ctx)),
                onTap: () => Navigator.pop(ctx, 'reply'),
              ),
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: Text('conv.copy'.getString(ctx)),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            if (m.mine && !m.isLocal && !m.isAgent)
              ListTile(
                leading: const Icon(LucideIcons.trash2, color: FeColors.danger),
                title: Text('common.delete'.getString(ctx), style: const TextStyle(color: FeColors.danger)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'reply':
        _startReply(m);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.body));
      case 'delete':
        final error = await controller.deleteMine(m.id);
        if (error != null && mounted) showTechPopup(context, message: error, isError: true);
    }
  }

  /// Tints a newly arrived agent reply for a few seconds so the answer is
  /// easy to find after the thinking bubble goes away.
  void _flashReply(String id) {
    if (id == _seenReplyId) return;
    _seenReplyId = id;
    setState(() => _highlight = id);
    _highlightOff?.cancel();
    _highlightOff = Timer(const Duration(seconds: 4), () {
      if (mounted && _highlight == id) setState(() => _highlight = null);
    });
  }

  void _hideKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  Widget build(BuildContext context) {
    ref.listen(conversationControllerProvider(_key).select((s) => s.lastAgentReplyId), (_, id) {
      if (id != null) _flashReply(id);
    });
    final s = ref.watch(conversationControllerProvider(_key));
    final controller = ref.read(conversationControllerProvider(_key).notifier);
    final me = ref.watch(convMeProvider);
    _afterBuild(s);

    if (s.loading && s.thread == null) return const Center(child: TechSpinner());
    final thread = s.thread;
    if (thread == null) {
      return RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TechEmptyState(
              icon: LucideIcons.messagesSquare,
              title: 'conv.load_failed'.getString(context),
              subtitle: s.error ?? 'common.pull_down_to_retry'.getString(context),
            ),
          ],
        ),
      );
    }

    final items = layoutThread(s.messages, lastReadAt: s.dividerReadAt, myIds: me?.ids ?? const {});
    final live = s.liveSessions;
    final peopleTyping = s.typing.values.where((t) => !t.isAgent).map((t) => t.name).toList();

    // The thread's real height, after the keyboard took its share (the host
    // Scaffold resizes its body). Small → the Working card shrinks to one
    // line and the @ list gets a lower cap, so nothing overflows on an
    // iPhone SE with the keyboard up.
    return LayoutBuilder(
      builder: (context, box) {
        final tight = box.maxHeight < 460;
        final pickerMax = (box.maxHeight * 0.35).clamp(120.0, 240.0);
        return _body(context, s, thread, items, live, peopleTyping, me, controller, tight: tight, pickerMax: pickerMax);
      },
    );
  }

  Widget _body(
    BuildContext context,
    ConversationState s,
    ConversationThread thread,
    List<ThreadItem> items,
    List<ConvSession> live,
    List<String> peopleTyping,
    ({ConvAuthor author, Set<String> ids})? me,
    ConversationController controller, {
    required bool tight,
    required double pickerMax,
  }) {
    return Column(
      children: [
        if (s.fromCache)
          Container(
            width: double.infinity,
            color: FeColors.warningSoft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(LucideIcons.cloudOff, size: 14, color: FeColors.warning),
                const SizedBox(width: 8),
                Expanded(child: AppText.caption('conv.saved_copy'.getString(context), color: FeColors.ink)),
              ],
            ),
          ),
        Expanded(
          // Tap anywhere in the thread (not on a button) or drag it → the
          // keyboard goes away. Translucent, so taps still reach the messages.
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _hideKeyboard,
            child: RefreshIndicator(
            onRefresh: controller.refresh,
            child: SingleChildScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (thread.nextCursor != null)
                    Center(
                      child: TextButton(
                        onPressed: s.loadingOlder ? null : controller.loadOlder,
                        child: Text('conv.show_earlier'.getString(context)),
                      ),
                    ),
                  if (s.messages.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: TechEmptyState(
                        icon: LucideIcons.messagesSquare,
                        title: 'conv.empty_title'.getString(context),
                        subtitle: thread.canMentionAgents
                            ? 'conv.empty_subtitle_agents'.getString(context)
                            : 'conv.empty_subtitle'.getString(context),
                      ),
                    ),
                  for (final item in items) _row(item, thread),
                  // The agent's turn: thinking dots + the steps it really took.
                  for (final session in live)
                    AgentThinkingBubble(
                      session: session,
                      steps: s.trails[session.id] ?? const [],
                      typingStage: s.typing[session.agentId]?.stage,
                    ),
                  if (peopleTyping.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(52, 4, 8, 0),
                      child: AppText.caption(
                        convTr(context, 'conv.typing', [peopleTyping.join(', ')]),
                        color: FeColors.ink2,
                      ),
                    ),
                  for (final n in s.notes)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(52, 4, 8, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(LucideIcons.info, size: 13, color: FeColors.ink2),
                          const SizedBox(width: 6),
                          Expanded(
                            child: AppText.caption(
                              n.code == kAgentEndedNoteCode ? convTr(context, 'conv.agent_ended', [n.text]) : n.text,
                              color: n.code == kAgentEndedNoteCode ? FeColors.warning : FeColors.ink2,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          ),
        ),
        if (live.isNotEmpty)
          WorkingCard(sessions: live, typing: s.typing, myIds: me?.ids ?? const {}, onStop: _stop, compact: tight),
        ConversationComposer(
          key: _composer,
          pickerMaxHeight: pickerMax,
          canMentionAgents: thread.canMentionAgents,
          replyingTo: _replyTo,
          onCancelReply: () => setState(() => _replyTo = null),
          onSend: _send,
          onTypingChanged: controller.typing,
          searchMentions: (q) =>
              ref.read(conversationRepositoryProvider).mentions(q, entity: widget.entity, entityId: thread.entityId),
          fallbackPeople: [
            for (final p in thread.participants)
              if (!p.isAgent && p.id != me?.author.id)
                MentionCandidate(
                  type: ConvAuthorType.user,
                  id: p.id,
                  name: p.name,
                  handle: p.handle ?? p.name.replaceAll(' ', ''),
                  role: p.role,
                ),
          ],
        ),
      ],
    );
  }

  Widget _row(ThreadItem item, ConversationThread thread) {
    switch (item) {
      case DayDivider(:final day):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              const Expanded(child: Divider(color: FeColors.line)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: AppText.caption(_dayLabel(day), color: FeColors.ink2),
              ),
              const Expanded(child: Divider(color: FeColors.line)),
            ],
          ),
        );
      case UnreadDivider(:final count):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const Expanded(child: Divider(color: FeColors.danger)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: AppText.caption(convTr(context, 'conv.unread', [count]), color: FeColors.danger, weight: FontWeight.w700),
              ),
              const Expanded(child: Divider(color: FeColors.danger)),
            ],
          ),
        );
      case MessageItem(:final message, :final showHeader, :final parent, :final parentMissing):
        final controller = ref.read(conversationControllerProvider(_key).notifier);
        return KeyedSubtree(
          key: _keyFor(message.id),
          child: MessageTile(
            message: message,
            showHeader: showHeader,
            parent: parent,
            parentMissing: parentMissing,
            highlighted: _highlight != null && _highlight == message.id,
            canApproveCards: thread.canApproveCards,
            onReply: () => _startReply(message),
            onMore: () => _more(message),
            onRetry: message.clientId == null ? null : () => controller.retry(message.clientId!),
            onDiscard: message.clientId == null ? null : () => controller.discard(message.clientId!),
            onOpenSchedule: () => context.push(Routes.schedules()),
            onFollowUp: (f) => _followUp(message, f),
            acceptedFollowUps: _acceptedFollowUps,
            onAnswer: () => _answer(message),
          ),
        );
    }
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'conv.today'.getString(context);
    if (today.difference(day).inDays == 1) return 'conv.yesterday'.getString(context);
    return DateFormat.yMMMEd().format(day);
  }
}

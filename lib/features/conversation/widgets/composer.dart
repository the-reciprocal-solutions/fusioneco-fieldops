import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/conversation/mention_parser.dart';
import '../../../domain/conversation.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import 'conv_visuals.dart';

/// The box at the bottom of a thread: @mention picker (Flow Agent first),
/// quick "@agent" / "Remind me…" chips, the reply banner, and hints that
/// explain what will happen before the person sends.
class ConversationComposer extends StatefulWidget {
  const ConversationComposer({
    super.key,
    required this.canMentionAgents,
    required this.onSend,
    required this.searchMentions,
    this.fallbackPeople = const [],
    this.replyingTo,
    this.onCancelReply,
    this.onTypingChanged,
  });

  final bool canMentionAgents;
  final Future<void> Function(String text) onSend;

  /// Server search for the picker; may throw (offline) — the picker then
  /// shows [fallbackPeople] and `@agent` only.
  final Future<List<MentionCandidate>> Function(String query) searchMentions;
  final List<MentionCandidate> fallbackPeople;
  final ConvMessage? replyingTo;
  final VoidCallback? onCancelReply;
  final ValueChanged<bool>? onTypingChanged;

  @override
  State<ConversationComposer> createState() => ConversationComposerState();
}

class ConversationComposerState extends State<ConversationComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  MentionQuery? _query;
  List<MentionCandidate> _fetched = const [];
  Timer? _debounce;
  Timer? _typingOff;
  bool _typing = false;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _typingOff?.cancel();
    if (_typing) widget.onTypingChanged?.call(false);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Puts [text] in the box (a quick chip) and focuses it.
  void prefill(String text) {
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  void focus() => _focus.requestFocus();

  void _onChanged() {
    final sel = _controller.selection;
    final q = sel.isValid && sel.isCollapsed ? activeMention(_controller.text, sel.baseOffset) : null;
    if (q?.query != _query?.query || (q == null) != (_query == null)) {
      setState(() => _query = q);
      if (q != null) _search(q.query);
    } else {
      setState(() {});
    }
    _signalTyping();
  }

  void _signalTyping() {
    if (widget.onTypingChanged == null) return;
    if (!_typing && _controller.text.isNotEmpty) {
      _typing = true;
      widget.onTypingChanged!(true);
    }
    _typingOff?.cancel();
    _typingOff = Timer(const Duration(seconds: 4), () {
      if (_typing) {
        _typing = false;
        widget.onTypingChanged!(false);
      }
    });
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final seq = ++_searchSeq;
      try {
        final rows = await widget.searchMentions(q);
        if (mounted && seq == _searchSeq) setState(() => _fetched = rows);
      } catch (_) {
        if (mounted && seq == _searchSeq) setState(() => _fetched = const []);
      }
    });
  }

  void _pick(MentionCandidate c) {
    final q = _query;
    if (q == null) return;
    final r = insertMention(_controller.text, q, c.handle);
    _controller.value = TextEditingValue(text: r.text, selection: TextSelection.collapsed(offset: r.cursor));
    setState(() => _query = null);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    setState(() => _query = null);
    if (_typing) {
      _typing = false;
      widget.onTypingChanged?.call(false);
    }
    await widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text;
    final q = _query;
    final candidates = q == null
        ? const <MentionCandidate>[]
        : pickerCandidates(
            query: q.query,
            fetched: _fetched,
            canMentionAgents: widget.canMentionAgents,
            orchestratorName: 'conv.flow_agent'.getString(context),
            orchestratorRole: 'conv.flow_agent_role'.getString(context),
            fallbackPeople: widget.fallbackPeople,
          );
    final asksAgent = mentionsAgent(text, agentHandles: {
      for (final c in _fetched)
        if (c.isAgent) c.handle,
    });
    final wantsSchedule = looksLikeScheduleRequest(text);

    return Container(
      decoration: const BoxDecoration(
        color: FeColors.panel,
        border: Border(top: BorderSide(color: FeColors.line)),
      ),
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (q != null && (candidates.isNotEmpty || !widget.canMentionAgents))
            MentionPickerList(
              candidates: candidates,
              agentsOff: !widget.canMentionAgents,
              onPick: _pick,
            ),
          if (widget.replyingTo != null) _ReplyBanner(message: widget.replyingTo!, onCancel: widget.onCancelReply),
          if (text.isEmpty && widget.canMentionAgents && q == null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _QuickChip(
                    icon: LucideIcons.sparkles,
                    label: 'conv.chip_agent'.getString(context),
                    onTap: () => prefill('@$kOrchestratorHandle '),
                  ),
                  _QuickChip(
                    icon: LucideIcons.bellRing,
                    label: 'conv.chip_remind'.getString(context),
                    onTap: () => prefill('@$kOrchestratorHandle ${'conv.chip_remind_text'.getString(context)} '),
                  ),
                  _QuickChip(
                    icon: LucideIcons.eye,
                    label: 'conv.chip_watch'.getString(context),
                    onTap: () => prefill('@$kOrchestratorHandle ${'conv.chip_watch_text'.getString(context)}'),
                  ),
                ],
              ),
            ),
          if (wantsSchedule && !asksAgent && widget.canMentionAgents)
            _Hint(
              icon: LucideIcons.bellRing,
              text: 'conv.hint_add_agent'.getString(context),
              action: 'conv.hint_add_agent_action'.getString(context),
              onAction: () => prefill('@$kOrchestratorHandle $text'),
            )
          else if (asksAgent && !widget.canMentionAgents)
            _Hint(icon: LucideIcons.info, text: 'conv.hint_agents_off'.getString(context))
          else if (asksAgent && wantsSchedule)
            _Hint(icon: LucideIcons.calendarClock, text: 'conv.hint_schedule'.getString(context)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 4000,
                  buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.canMentionAgents
                        ? 'conv.composer_hint_agents'.getString(context)
                        : 'conv.composer_hint'.getString(context),
                    filled: true,
                    fillColor: FeColors.page,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: const BorderSide(color: FeColors.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: const BorderSide(color: FeColors.line),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'conv.send'.getString(context),
                style: IconButton.styleFrom(
                  backgroundColor: asksAgent && widget.canMentionAgents ? FeColors.ai : FeColors.primary,
                  minimumSize: const Size(46, 46),
                ),
                onPressed: text.trim().isEmpty ? null : _send,
                icon: const Icon(LucideIcons.send, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The @ list. `@agent` first, then specialists, then people.
class MentionPickerList extends StatelessWidget {
  const MentionPickerList({super.key, required this.candidates, required this.onPick, this.agentsOff = false});
  final List<MentionCandidate> candidates;
  final ValueChanged<MentionCandidate> onPick;
  final bool agentsOff;

  @override
  Widget build(BuildContext context) {
    // A Material, not a decorated Container: ListTile paints its ink on the
    // nearest Material, and a coloured box in between hides it (and asserts).
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: FeColors.panel,
        elevation: 3,
        shadowColor: FeColors.ink.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: FeColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final c in candidates)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: ConvAvatar(name: c.name, isAgent: c.isAgent, size: 30),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      c.orchestrator ? '@${c.handle} — ${c.name}' : c.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: c.isAgent ? FeColors.ai : FeColors.ink,
                      ),
                    ),
                  ),
                  if (c.isAgent) ...[const SizedBox(width: 6), const AiTag()],
                ],
              ),
              subtitle: Text(
                [if (!c.orchestrator) '@${c.handle}', ?c.role].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: FeColors.ink2),
              ),
              onTap: () => onPick(c),
            ),
          if (agentsOff)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
              child: AppText.caption('conv.agents_off_note'.getString(context), color: FeColors.ink2),
            ),
        ],
        ),
      ),
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.message, this.onCancel});
  final ConvMessage message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 4, 6),
    decoration: BoxDecoration(color: FeColors.page, borderRadius: BorderRadius.circular(10)),
    child: Row(
      children: [
        const Icon(LucideIcons.reply, size: 14, color: FeColors.ink2),
        const SizedBox(width: 6),
        Expanded(
          child: AppText.caption(
            convTr(context, 'conv.replying_to', [message.author.name]),
            color: FeColors.ink2,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'common.cancel'.getString(context),
          onPressed: onCancel,
          icon: const Icon(LucideIcons.x, size: 16),
        ),
      ],
    ),
  );
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 6, bottom: 6),
    child: ActionChip(
      avatar: Icon(icon, size: 14, color: FeColors.ai),
      label: Text(label, style: const TextStyle(fontSize: 12, color: FeColors.ai, fontWeight: FontWeight.w700)),
      backgroundColor: FeColors.aiSoft,
      side: const BorderSide(color: FeColors.aiLine),
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.action, this.onAction});
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 14, color: FeColors.ai),
        const SizedBox(width: 6),
        Expanded(child: AppText.caption(text, color: FeColors.ink2)),
        if (action != null)
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: FeColors.ai),
            onPressed: onAction,
            child: Text(action!),
          ),
      ],
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/conversation/agent_activity.dart';
import '../../../domain/conversation.dart';
import '../../../state/conversation_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import 'conv_visuals.dart';
import 'message_tile.dart';

/// "Agent working" — pinned above the composer while a session runs
/// (orchestrator spec O2): who was asked, the routing line, one row per
/// specialist with its live stage, and the elapsed time. Every stage shown
/// comes from the server (the session's `stage` or an agent `typing` event);
/// the avatar only pulses while the run is really in the `working` state.
class WorkingCard extends StatefulWidget {
  const WorkingCard({
    super.key,
    required this.sessions,
    this.typing = const {},
    this.myIds = const {},
    this.onStop,
    this.compact = false,
  });
  final List<ConvSession> sessions;
  final Map<String, ConvTyping> typing;

  /// One line per session (who, elapsed, Stop) — used while the keyboard is
  /// up, when every point of height counts. The step-by-step view is the
  /// thinking bubble in the thread ([AgentThinkingBubble]).
  final bool compact;

  /// The viewer's ids: the requester may Stop their own session (C2 —
  /// `canStop` is always false on the socket, so it is re-derived here).
  final Set<String> myIds;
  final ValueChanged<ConvSession>? onStop;

  @override
  State<WorkingCard> createState() => _WorkingCardState();
}

class _WorkingCardState extends State<WorkingCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sessions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: widget.compact ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6) : const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FeColors.aiSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FeColors.aiLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.sessions.length; i++) ...[
            if (i > 0) const Divider(height: 16, color: FeColors.aiLine),
            _SessionRow(
              session: widget.sessions[i],
              compact: widget.compact,
              typing: widget.typing[widget.sessions[i].agentId],
              onStop: widget.onStop != null &&
                      (widget.sessions[i].canStop || widget.myIds.contains(widget.sessions[i].requesterId))
                  ? () => widget.onStop!(widget.sessions[i])
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

String elapsedText(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = s ~/ 60;
  final r = s % 60;
  if (m >= 60) return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  return '$m:${r.toString().padLeft(2, '0')}';
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, this.typing, this.onStop, this.compact = false});
  final ConvSession session;
  final ConvTyping? typing;
  final VoidCallback? onStop;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final working = s.status == SessionStatus.working;
    final stage = s.stage ?? typing?.stage;
    final title = working
        ? convTr(context, 'conv.working_title', [s.agentName])
        : convTr(context, 'conv.queued_title', [s.agentName]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Pulse(active: working, child: ConvAvatar(name: s.agentName, isAgent: true, size: 28)),
            const SizedBox(width: 10),
            Expanded(
              child: AppText.bodyMedium(
                title,
                weight: FontWeight.w800,
                color: FeColors.ai,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (working) ...[const TypingDots(size: 5), const SizedBox(width: 8)],
            AppText.caption(elapsedText(DateTime.now().difference(s.countFrom)), color: FeColors.ai),
            if (onStop != null) ...[
              const SizedBox(width: 4),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: FeColors.danger,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onStop,
                child: Text('conv.stop'.getString(context)),
              ),
            ],
          ],
        ),
        if (compact)
          const SizedBox.shrink()
        else if (s.routing != null && s.routing!.agents.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: RoutingLine(routing: s.routing!)),
        if (compact)
          const SizedBox.shrink()
        else if (s.specialists.isNotEmpty)
          for (final sp in s.specialists)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 38),
              child: Row(
                children: [
                  Icon(
                    switch (sp.status) {
                      SessionStatus.replied => LucideIcons.circleCheck,
                      SessionStatus.failed || SessionStatus.stopped => LucideIcons.circleX,
                      _ => LucideIcons.circleDot,
                    },
                    size: 13,
                    color: switch (sp.status) {
                      SessionStatus.replied => FeColors.success,
                      SessionStatus.failed || SessionStatus.stopped => FeColors.danger,
                      _ => FeColors.ai,
                    },
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: AppText.caption(
                      sp.stage == null ? sp.name : '${sp.name} · ${sp.stage}',
                      color: FeColors.ink,
                    ),
                  ),
                ],
              ),
            )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 38),
            child: AppText.caption(
              stage ?? (working ? 'conv.stage_starting'.getString(context) : 'conv.stage_waiting'.getString(context)),
              color: FeColors.ink2,
            ),
          ),
      ],
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Pulse old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.active && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) => Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: widget.active
            ? [BoxShadow(color: FeColors.ai.withValues(alpha: 0.35 * _c.value), blurRadius: 10, spreadRadius: 3 * _c.value)]
            : null,
      ),
      child: child,
    ),
    child: widget.child,
  );
}

/// The small "AI working on this · 0:42" chip for a record's header.
class AiWorkingChip extends StatefulWidget {
  const AiWorkingChip({super.key, required this.since, this.onTap});
  final DateTime since;
  final VoidCallback? onTap;

  @override
  State<AiWorkingChip> createState() => _AiWorkingChipState();
}

class _AiWorkingChipState extends State<AiWorkingChip> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: widget.onTap,
    borderRadius: BorderRadius.circular(999),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: FeColors.aiSoft, borderRadius: BorderRadius.circular(999), border: Border.all(color: FeColors.aiLine)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.sparkles, size: 13, color: FeColors.ai),
          const SizedBox(width: 6),
          Text(
            convTr(context, 'conv.ai_working_chip', [elapsedText(DateTime.now().difference(widget.since))]),
            style: const TextStyle(color: FeColors.ai, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}

/// Three dots that rise and fall in turn — the "someone is typing" signal.
/// Drawn only while the server says the run is really working (the caller
/// decides); it never stands in for progress on its own.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.size = 6, this.color = FeColors.ai});
  final double size;
  final Color color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'conv.thinking'.getString(context),
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.25),
              child: Transform.translate(
                offset: Offset(0, -widget.size * 0.6 * _bump((_c.value - i * 0.18) % 1.0)),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.45 + 0.55 * _bump((_c.value - i * 0.18) % 1.0)),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  /// 0 → 1 → 0 over the first 40 % of the cycle, then rest.
  static double _bump(double t) {
    if (t < 0 || t > 0.4) return 0;
    final x = t / 0.4;
    return x < 0.5 ? x * 2 : (1 - x) * 2;
  }
}

/// The agent's turn in the thread, under the question: avatar, "Flow Agent
/// is thinking" with typing dots, then the steps it has really taken so far
/// (each one a stage the server sent — `ConversationState.trails`) with the
/// newest one live. Queued for a while → says so plainly instead of a
/// spinner that never moves.
class AgentThinkingBubble extends StatelessWidget {
  const AgentThinkingBubble({super.key, required this.session, this.steps = const [], this.typingStage});
  final ConvSession session;

  /// Stages seen for this session, oldest first.
  final List<String> steps;

  /// The newest agent `typing` stage, when it isn't in [steps] yet.
  final String? typingStage;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final working = s.status == SessionStatus.working;
    final all = appendStep(steps, typingStage ?? s.stage);
    final waitingLong = isWaitingLong(s, DateTime.now());
    final title = working
        ? convTr(context, 'conv.thinking_title', [s.agentName])
        : convTr(context, 'conv.queued_title', [s.agentName]);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Pulse(active: working, child: ConvAvatar(name: s.agentName, isAgent: true)),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              key: ValueKey('agent-thinking-${s.id}'),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: FeColors.aiSoft,
                border: Border.all(color: FeColors.aiLine),
                borderRadius: const BorderRadiusDirectional.only(
                  topEnd: Radius.circular(16),
                  bottomStart: Radius.circular(16),
                  bottomEnd: Radius.circular(16),
                  topStart: Radius.circular(4),
                ).resolve(Directionality.of(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: AppText.caption(title, color: FeColors.ai, weight: FontWeight.w800),
                      ),
                      const SizedBox(width: 8),
                      const TypingDots(size: 5),
                    ],
                  ),
                  if (all.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: AppText.caption(
                        working ? 'conv.stage_starting'.getString(context) : 'conv.stage_waiting'.getString(context),
                        color: FeColors.ink2,
                      ),
                    ),
                  for (var i = 0; i < all.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              i == all.length - 1 ? LucideIcons.loaderCircle : LucideIcons.circleCheck,
                              size: 13,
                              color: i == all.length - 1 ? FeColors.ai : FeColors.success,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: AppText.caption(
                              _sentence(all[i]),
                              color: i == all.length - 1 ? FeColors.ink : FeColors.ink2,
                              weight: i == all.length - 1 ? FontWeight.w700 : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (waitingLong)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: AppText.caption('conv.waiting_long'.getString(context), color: FeColors.warning),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "checking photos" → "Checking photos".
  static String _sentence(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}


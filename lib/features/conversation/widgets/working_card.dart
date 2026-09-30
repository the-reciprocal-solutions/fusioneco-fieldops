import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  });
  final List<ConvSession> sessions;
  final Map<String, ConvTyping> typing;

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
      padding: const EdgeInsets.all(12),
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
  const _SessionRow({required this.session, this.typing, this.onStop});
  final ConvSession session;
  final ConvTyping? typing;
  final VoidCallback? onStop;

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
            Expanded(child: AppText.bodyMedium(title, weight: FontWeight.w800, color: FeColors.ai)),
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
        if (s.routing != null && s.routing!.agents.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: RoutingLine(routing: s.routing!)),
        if (s.specialists.isNotEmpty)
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

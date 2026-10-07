import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/conversation/mention_parser.dart';
import '../../../core/conversation/next_steps.dart';
import '../../../domain/conversation.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import 'conv_visuals.dart';
import 'schedule_card.dart';

/// One message in a thread. People's messages read like chat; an AI
/// teammate's read like a teammate's, marked AI in violet, with the
/// grounding line ("Checked against your data") and any action or schedule
/// cards under the text.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.showHeader,
    this.parent,
    this.parentMissing = false,
    this.highlighted = false,
    this.canApproveCards = false,
    this.onReply,
    this.onMore,
    this.onRetry,
    this.onDiscard,
    this.onOpenSchedule,
    this.onFollowUp,
    this.acceptedFollowUps = const {},
    this.onAnswer,
    this.onNextStep,
  });

  final ConvMessage message;
  final bool showHeader;
  final ConvMessage? parent;
  final bool parentMissing;

  /// Deep-linked from a notification: tinted until the person scrolls on.
  final bool highlighted;
  final bool canApproveCards;
  final VoidCallback? onReply;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;
  final VoidCallback? onOpenSchedule;

  /// One-click follow-up ("Check this again tomorrow at 09:00") → schedule.
  final ValueChanged<ConvFollowUp>? onFollowUp;

  /// Follow-up ids already turned into schedules on this screen.
  final Set<String> acceptedFollowUps;

  /// Answer the Flow Agent's clarifying question (reply with @agent).
  final VoidCallback? onAnswer;

  /// A one-tap next step under an agent reply — opens a screen (never writes).
  final ValueChanged<ConvNextStep>? onNextStep;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final agent = m.isAgent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: EdgeInsets.fromLTRB(8, showHeader ? 10 : 2, 8, 2),
      decoration: BoxDecoration(
        color: highlighted ? FeColors.warningSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: m.isDeleted ? null : onMore,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: showHeader ? ConvAvatar(name: m.author.name, isAgent: agent) : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showHeader) _Header(message: m),
                  if (m.replyTo != null) _ReplyQuote(parent: parent, missing: parentMissing),
                  if (m.kind == ConvMessageKind.finding && !m.isDeleted)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 2),
                      child: AppText.caption(
                        convTr(context, 'conv.found_by', [m.author.name]),
                        color: FeColors.ai,
                        weight: FontWeight.w700,
                      ),
                    ),
                  // A `system` routing message already says it in its body.
                  if (agent && m.kind != ConvMessageKind.system && m.routing != null && m.routing!.agents.isNotEmpty)
                    RoutingLine(routing: m.routing!),
                  _Body(message: m),
                  for (final a in m.attachments) _AttachmentView(attachment: a),
                  if (agent && !m.isDeleted) _GroundingLine(message: m),
                  for (final c in m.cards)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ActionCardView(card: c, canApprove: canApproveCards),
                    ),
                  for (final s in m.schedules)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ScheduleCard(schedule: s, dense: true, onOpen: onOpenSchedule),
                    ),
                  if (m.scheduleDeleted)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: AppText.caption('conv.schedule_deleted'.getString(context), color: FeColors.ink2),
                    ),
                  if (m.clarify != null && !m.isDeleted && onAnswer != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: FeColors.ai,
                          side: const BorderSide(color: FeColors.aiLine),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: onAnswer,
                        icon: const Icon(LucideIcons.messageCircleQuestion, size: 16),
                        label: Text('conv.answer'.getString(context)),
                      ),
                    ),
                  if (agent && m.nextSteps.isNotEmpty && !m.isDeleted && onNextStep != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final s in m.nextSteps)
                            ActionChip(
                              key: ValueKey('next-step-${s.id}'),
                              avatar: Icon(_nextStepIcon(s.action), size: 14, color: FeColors.primary),
                              label: Text(
                                nextStepLabelKey(s.action).getString(context),
                                style: const TextStyle(fontSize: 12, color: FeColors.primary, fontWeight: FontWeight.w700),
                              ),
                              backgroundColor: FeColors.panel,
                              side: const BorderSide(color: FeColors.line),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onNextStep!(s),
                            ),
                        ],
                      ),
                    ),
                  if (m.followUps.isNotEmpty && !m.isDeleted)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final f in m.followUps)
                            ActionChip(
                              avatar: Icon(
                                acceptedFollowUps.contains(f.id) ? LucideIcons.check : LucideIcons.calendarPlus,
                                size: 14,
                                color: FeColors.ai,
                              ),
                              label: Text(f.label, style: const TextStyle(fontSize: 12, color: FeColors.ai)),
                              backgroundColor: FeColors.aiSoft,
                              side: const BorderSide(color: FeColors.aiLine),
                              onPressed: acceptedFollowUps.contains(f.id) || onFollowUp == null ? null : () => onFollowUp!(f),
                            ),
                        ],
                      ),
                    ),
                  if (m.isLocal) _OutgoingLine(message: m, onRetry: onRetry, onDiscard: onDiscard),
                  if (!m.isLocal && !m.isDeleted && onReply != null && agent)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          foregroundColor: FeColors.ai,
                        ),
                        onPressed: onReply,
                        icon: const Icon(LucideIcons.reply, size: 14),
                        label: Text('conv.reply'.getString(context), style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _nextStepIcon(ConvNextStepAction a) => switch (a) {
  ConvNextStepAction.raiseSnag => LucideIcons.flag,
  ConvNextStepAction.openAsset => LucideIcons.box,
  ConvNextStepAction.openPermits => LucideIcons.shieldCheck,
};

class _Header extends StatelessWidget {
  const _Header({required this.message});
  final ConvMessage message;

  @override
  Widget build(BuildContext context) {
    final m = message;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 2,
        children: [
          AppText.bodyMedium(m.author.name, weight: FontWeight.w800, color: m.isAgent ? FeColors.ai : FeColors.ink),
          if (m.isAgent) const AiTag(),
          if (m.isAgent && m.author.role != null) AppText.caption(m.author.role!, color: FeColors.ink2),
          AppText.caption(DateFormat.Hm().format(m.createdAt), color: FeColors.ink2),
          if (m.editedAt != null && !m.isDeleted) AppText.caption('conv.edited'.getString(context), color: FeColors.ink2),
        ],
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.parent, required this.missing});
  final ConvMessage? parent;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final p = parent;
    final text = p == null
        ? 'conv.reply_to_earlier'.getString(context)
        : (p.isDeleted ? 'conv.deleted'.getString(context) : p.body.replaceAll('\n', ' '));
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 4),
      padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: FeColors.page,
        borderRadius: BorderRadius.circular(8),
        border: BorderDirectional(
          start: BorderSide(color: p?.isAgent == true ? FeColors.ai : FeColors.primaryLight, width: 3),
        ),
      ),
      child: Text.rich(
        TextSpan(children: [
          if (p != null)
            TextSpan(text: '${p.author.name}: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: text),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: FeColors.ink2),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.message});
  final ConvMessage message;

  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m.isDeleted) {
      return Text(
        'conv.deleted'.getString(context),
        style: const TextStyle(fontStyle: FontStyle.italic, color: FeColors.ink2, fontSize: 14),
      );
    }
    if (m.kind == ConvMessageKind.system) {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: FeColors.page, borderRadius: BorderRadius.circular(10)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(LucideIcons.info, size: 14, color: FeColors.ink2),
            const SizedBox(width: 6),
            Expanded(child: AppText.bodySmall(m.body, color: FeColors.ink)),
          ],
        ),
      );
    }
    if (m.isAgent) {
      return MarkdownBody(
        data: m.body,
        shrinkWrap: true,
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet(
          p: const TextStyle(fontSize: 14, height: 1.4, color: FeColors.ink),
          listBullet: const TextStyle(fontSize: 14, color: FeColors.ink),
          strong: const TextStyle(fontWeight: FontWeight.w700),
          h1: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          h2: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          h3: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      );
    }
    return Text.rich(
      TextSpan(children: mentionSpans(m.body, agentHandles: {
        for (final x in m.mentions)
          if (x.type == ConvAuthorType.agent && x.handle != null) x.handle!.toLowerCase(),
      })),
      style: const TextStyle(fontSize: 14, height: 1.4, color: FeColors.ink),
    );
  }
}

/// Splits [text] into plain and `@mention` spans; agent mentions violet,
/// people blue.
List<InlineSpan> mentionSpans(String text, {Set<String> agentHandles = const {}}) {
  final re = RegExp(r'(^|[\s(\[{"])(@[\p{L}\p{N}][\p{L}\p{N}._\-]*)', unicode: true);
  final spans = <InlineSpan>[];
  var last = 0;
  for (final match in re.allMatches(text)) {
    final start = match.start + match.group(1)!.length;
    if (start > last) spans.add(TextSpan(text: text.substring(last, start)));
    final handle = match.group(2)!;
    final key = handle.substring(1).toLowerCase();
    final isAgent = kOrchestratorAliases.contains(key) || agentHandles.contains(key);
    spans.add(TextSpan(
      text: handle,
      style: TextStyle(fontWeight: FontWeight.w700, color: isAgent ? FeColors.ai : FeColors.primary),
    ));
    last = match.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

/// "Routing to Visual Inspector (photos) and SLA Guardian (due dates)".
class RoutingLine extends StatelessWidget {
  const RoutingLine({super.key, required this.routing});
  final ConvRouting routing;

  @override
  Widget build(BuildContext context) {
    final names = routing.agents
        .map((a) => a.reason == null ? a.name : '${a.name} (${a.reason})')
        .join(', ');
    final text = routing.line ?? convTr(context, 'conv.routing_to', [names]);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.route, size: 13, color: FeColors.ai),
          const SizedBox(width: 6),
          Expanded(child: AppText.caption(text, color: FeColors.ai)),
        ],
      ),
    );
  }
}

class _GroundingLine extends StatelessWidget {
  const _GroundingLine({required this.message});
  final ConvMessage message;

  @override
  Widget build(BuildContext context) {
    final g = message.grounding;
    final lines = <Widget>[];
    if (g != null && g.checked > 0) {
      lines.add(_chip(
        LucideIcons.shieldCheck,
        convTr(context, 'conv.grounded', [g.grounded, g.checked]),
        FeColors.success,
      ));
      if (g.dropped > 0) {
        lines.add(_chip(LucideIcons.eraser, convTr(context, 'conv.grounded_dropped', [g.dropped]), FeColors.warning));
      }
    }
    if (message.notInData.isNotEmpty) {
      lines.add(_chip(
        LucideIcons.searchX,
        convTr(context, 'conv.not_in_data', [message.notInData.join(', ')]),
        FeColors.ink2,
      ));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 4, children: lines),
    );
  }

  Widget _chip(IconData icon, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

/// An action the agent suggests. Read-only on this app: approving is an
/// Admin job on the server (the cards route is Admin-only), so a suggested
/// card says "Needs an admin's OK" instead of showing buttons.
class ActionCardView extends StatelessWidget {
  const ActionCardView({super.key, required this.card, this.canApprove = false});
  final ActionCard card;
  final bool canApprove;

  @override
  Widget build(BuildContext context) {
    final color = ConvVisuals.cardColor(card.status);
    final waiting = card.status == ActionCardStatus.suggested;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: waiting ? FeColors.aiLine : FeColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.squareCheck, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(child: AppText.bodyMedium(card.title, weight: FontWeight.w700)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                child: Text(
                  ConvVisuals.cardStatusKey(card.status).getString(context),
                  style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (card.reason != null) ...[
            const SizedBox(height: 4),
            AppText.bodySmall(card.reason!, color: FeColors.ink2),
          ],
          if (card.executionNote != null && card.status != ActionCardStatus.done) ...[
            const SizedBox(height: 4),
            AppText.caption(card.executionNote!, color: FeColors.ink2),
          ],
          if (waiting && !canApprove) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(LucideIcons.userCheck, size: 13, color: FeColors.ai),
                const SizedBox(width: 6),
                Expanded(
                  child: AppText.caption('conv.card.needs_admin'.getString(context), color: FeColors.ai, weight: FontWeight.w700),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AttachmentView extends StatelessWidget {
  const _AttachmentView({required this.attachment});
  final ConvAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    if (a.isImage) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180, maxWidth: 260),
            child: Image.network(
              a.url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const _FileChip(icon: LucideIcons.imageOff, label: '—'),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _FileChip(icon: LucideIcons.paperclip, label: a.name ?? a.url.split('/').last),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(color: FeColors.page, borderRadius: BorderRadius.circular(8)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: FeColors.ink2),
        const SizedBox(width: 6),
        Flexible(child: AppText.caption(label, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );
}

class _OutgoingLine extends StatelessWidget {
  const _OutgoingLine({required this.message, this.onRetry, this.onDiscard});
  final ConvMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    switch (message.outgoing) {
      case OutgoingState.sending:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
              const SizedBox(width: 6),
              AppText.caption('conv.sending'.getString(context), color: FeColors.ink2),
            ],
          ),
        );
      case OutgoingState.queued:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              const Icon(LucideIcons.cloudOff, size: 13, color: FeColors.warning),
              const SizedBox(width: 6),
              Expanded(child: AppText.caption('conv.queued'.getString(context), color: FeColors.warning)),
            ],
          ),
        );
      case OutgoingState.failed:
        return Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: FeColors.dangerSoft, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.caption(
                convTr(context, 'conv.failed', [failureText(context, message.failure)]),
                color: FeColors.danger,
                weight: FontWeight.w700,
              ),
              Wrap(
                children: [
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(LucideIcons.rotateCw, size: 14),
                    label: Text('conv.retry'.getString(context)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: FeColors.ink2),
                    onPressed: onDiscard,
                    child: Text('conv.discard'.getString(context)),
                  ),
                ],
              ),
            ],
          ),
        );
      case OutgoingState.sent:
        return const SizedBox.shrink();
    }
  }
}

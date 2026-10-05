import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/conversation/agent_activity.dart';
import '../../domain/conversation.dart';
import '../../state/conversation_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import 'widgets/conv_visuals.dart';
import 'widgets/working_card.dart';

/// The Conversation section on a record's detail screen (the snag detail):
/// newest two messages, the unread count, "AI working on this · 0:42" while
/// a session runs, and a button into the full thread. Loads quietly
/// (`markRead=false`), so it never clears an unread count by itself.
class ConversationPreviewCard extends ConsumerWidget {
  const ConversationPreviewCard({super.key, required this.entity, required this.id});
  final ConvEntity entity;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (entity: entity, id: id);
    final async = ref.watch(conversationPreviewProvider(key));
    final t = async.valueOrNull;
    final latest = t == null ? const <ConvMessage>[] : t.messages.reversed.take(2).toList().reversed.toList();
    // Not a stuck (30+ min) session — that is a lost run, not work in progress.
    final live = t == null ? const <ConvSession>[] : visibleLiveSessions(t.sessions, DateTime.now());

    Future<void> open() async {
      await context.push(Routes.conversation(entity.wire, id));
      // The snag screen may have gone while the thread was open.
      if (context.mounted) ref.invalidate(conversationPreviewProvider(key));
    }

    return TechCard(
      onTap: open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.messagesSquare, size: 18, color: FeColors.primary),
              const SizedBox(width: 8),
              Expanded(child: AppText.titleSmall('conv.title'.getString(context))),
              if ((t?.unread ?? 0) > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: FeColors.danger, borderRadius: BorderRadius.circular(999)),
                  child: Text(
                    convTr(context, 'conv.unread_short', [t!.unread]),
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                ),
            ],
          ),
          if (live.isNotEmpty) ...[
            const SizedBox(height: 8),
            AiWorkingChip(
              since: live.map((s) => s.countFrom).reduce((a, b) => a.isBefore(b) ? a : b),
              onTap: open,
            ),
          ],
          const SizedBox(height: 8),
          if (async.isLoading && t == null)
            const Padding(padding: EdgeInsets.all(8), child: TechSpinner(size: 20))
          else if (latest.isEmpty)
            AppText.bodySmall(
              t?.canMentionAgents == true
                  ? 'conv.preview_empty_agents'.getString(context)
                  : 'conv.preview_empty'.getString(context),
              color: FeColors.ink2,
            )
          else
            for (final m in latest)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConvAvatar(name: m.author.name, isAgent: m.isAgent, size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: '${m.author.name}  ',
                            style: TextStyle(fontWeight: FontWeight.w800, color: m.isAgent ? FeColors.ai : FeColors.ink),
                          ),
                          TextSpan(
                            text: m.isDeleted ? 'conv.deleted'.getString(context) : m.body.replaceAll('\n', ' '),
                          ),
                        ]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: FeColors.ink),
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: open,
              icon: const Icon(LucideIcons.messageSquarePlus, size: 16),
              label: Text(
                latest.isEmpty ? 'conv.start'.getString(context) : 'conv.open'.getString(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

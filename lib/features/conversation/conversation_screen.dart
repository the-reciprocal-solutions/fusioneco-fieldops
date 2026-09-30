import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../domain/conversation.dart';
import '../../state/conversation_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/tech_popup.dart';
import 'conversation_view.dart';

/// `/conversations/:entity/:id?message=` — one record's thread, full screen.
/// Opened from the snag detail's Conversation card and from notifications
/// for any record type the server sends (work orders open their own
/// Comments tab instead — see `conversation_links.dart`).
class ConversationScreen extends ConsumerWidget {
  const ConversationScreen({super.key, required this.entityWire, required this.id, this.messageId});

  final String entityWire;
  final String id;
  final String? messageId;

  static String? recordRoute(ConvEntity entity, String id) => switch (entity) {
    ConvEntity.snag => Routes.snagDetail(id),
    ConvEntity.workOrder => Routes.orderDetail('work-order', id),
    ConvEntity.permit => Routes.permitDetail(id),
    ConvEntity.asset => Routes.assetDetail(id),
    _ => null,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ConvEntity.fromWire(entityWire);
    if (entity == null) {
      return Scaffold(
        backgroundColor: FeColors.page,
        appBar: FeHeader(title: 'conv.title'.getString(context)),
        body: Center(child: Text('conv.load_failed'.getString(context))),
      );
    }
    final key = (entity: entity, id: id);
    final s = ref.watch(conversationControllerProvider(key));
    final t = s.thread;
    final title = t?.record.ref ?? (t?.record.title.isNotEmpty == true ? t!.record.title : 'conv.title'.getString(context));
    final openRoute = recordRoute(entity, t?.entityId.isNotEmpty == true ? t!.entityId : id);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: title,
        actions: [
          if (openRoute != null)
            IconButton(
              tooltip: 'conv.open_record'.getString(context),
              icon: const Icon(LucideIcons.externalLink),
              onPressed: () => context.push(openRoute),
            ),
          if (t != null)
            PopupMenuButton<String>(
              icon: Icon(s.muted ? LucideIcons.bellOff : (s.following ? LucideIcons.bellRing : LucideIcons.bell)),
              onSelected: (v) async {
                final c = ref.read(conversationControllerProvider(key).notifier);
                final error = switch (v) {
                  'follow' => await c.setFollowing(true),
                  'unfollow' => await c.setFollowing(false),
                  'mute' => await c.setMuted(true),
                  _ => await c.setMuted(false),
                };
                if (error != null && context.mounted) showTechPopup(context, message: error, isError: true);
              },
              itemBuilder: (ctx) => [
                if (!s.following)
                  PopupMenuItem(value: 'follow', child: Text('conv.follow'.getString(ctx)))
                else
                  PopupMenuItem(value: 'unfollow', child: Text('conv.unfollow'.getString(ctx))),
                if (!s.muted)
                  PopupMenuItem(value: 'mute', child: Text('conv.mute'.getString(ctx)))
                else
                  PopupMenuItem(value: 'unmute', child: Text('conv.unmute'.getString(ctx))),
              ],
            ),
        ],
      ),
      body: ConversationView(entity: entity, id: id, highlightMessageId: messageId),
    );
  }
}

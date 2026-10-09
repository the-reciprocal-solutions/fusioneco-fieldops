import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/notifications/notice_list.dart';
import '../../core/push/push_content.dart';
import '../../domain/app_notification.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/motion.dart';
import 'notification_visuals.dart';

/// One notification in the list: kind icon, title, message, record ref,
/// location, relative time, a photo thumbnail when there is one, a priority
/// stripe for urgent ones, and the quick actions that are safe from here
/// (Accept / Decline on an open invite, Reply on a thread message, Scan on a
/// route). Tapping the card opens it.
class NotificationCard extends StatelessWidget {
  const NotificationCard({
    super.key,
    required this.notification,
    required this.now,
    required this.onTap,
    required this.onAction,
  });

  final AppNotification notification;
  final DateTime now;
  final VoidCallback onTap;
  final void Function(PushAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final visual = noticeVisual(n);
    final read = n.isRead;
    final priority = n.priority;
    final stripe = switch (priority) {
      NoticePriority.critical => FeColors.danger,
      NoticePriority.high => FeColors.warning,
      _ => null,
    };
    // Accept/Decline only while the invite is still unanswered (unread); an
    // old one would only be refused.
    final actions = [
      for (final a in cardActionsFor(n))
        if (!(a == PushAction.acceptInvite || a == PushAction.declineInvite) || !read) a,
    ];
    final time = relativeTimeLabel(context, n.createdAt, now);

    return PressableScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(context.radii.xl),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              // A read notification drops back to plain white; unread keeps a
              // soft tint of its colour, so the list can be triaged at a glance.
              color: read ? FeColors.panel : visual.soft,
              borderRadius: BorderRadius.circular(context.radii.xl),
              boxShadow: read ? FeElevation.soft : FeElevation.tinted(visual.accent),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (stripe != null) Container(width: 4, color: stripe),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _KindBadge(icon: visual.icon, color: visual.accent),
                              const SizedBox(width: 12),
                              Expanded(child: _Texts(n: n, read: read, accent: visual.accent)),
                              if (n.imageUrl != null) ...[
                                const SizedBox(width: 10),
                                _Thumbnail(url: n.imageUrl!),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          _MetaRow(n: n, time: time),
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            _Actions(actions: actions, onAction: onAction, accent: visual.accent),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        width: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: color),
      );
}

class _Texts extends StatelessWidget {
  const _Texts({required this.n, required this.read, required this.accent});

  final AppNotification n;
  final bool read;
  final Color accent;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppText.titleSmall(
                  n.title,
                  weight: read ? FontWeight.w500 : FontWeight.w700,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!read)
                Container(
                  margin: const EdgeInsetsDirectional.only(start: 8, top: 6),
                  height: 8,
                  width: 8,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
            ],
          ),
          if (n.message.isNotEmpty) ...[
            const SizedBox(height: 4),
            AppText.bodySmall(n.message, color: FeColors.ink2, maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
        ],
      );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(context.radii.lg),
        child: Image.network(
          url,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          // A photo that can't load (no signal, expired link) just isn't shown.
          errorBuilder: (_, _, _) => const SizedBox(width: 56, height: 56, child: ColoredBox(color: FeColors.line)),
        ),
      );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.n, required this.time});

  final AppNotification n;
  final String time;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (n.ref != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(999)),
              child: AppText.caption(n.ref!, color: FeColors.ink, weight: FontWeight.w600),
            ),
          if (n.location != null) _IconText(icon: LucideIcons.mapPin, text: n.location!),
          if (time.isNotEmpty) _IconText(icon: LucideIcons.clock, text: time),
        ],
      );
}

class _IconText extends StatelessWidget {
  const _IconText({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: FeColors.ink2),
          const SizedBox(width: 4),
          Flexible(child: AppText.caption(text, color: FeColors.ink2, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      );
}

class _Actions extends StatelessWidget {
  const _Actions({required this.actions, required this.onAction, required this.accent});

  final List<PushAction> actions;
  final void Function(PushAction) onAction;
  final Color accent;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final a in actions)
            a == PushAction.acceptInvite
                ? FilledButton.icon(
                    onPressed: () => onAction(a),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: FeColors.success,
                    ),
                    icon: const Icon(LucideIcons.check, size: 16),
                    label: AppText('notifications.action_accept'.getString(context)),
                  )
                : OutlinedButton.icon(
                    onPressed: () => onAction(a),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: accent),
                    icon: Icon(
                      switch (a) {
                        PushAction.reply => LucideIcons.reply,
                        PushAction.scan => LucideIcons.scanLine,
                        PushAction.declineInvite => LucideIcons.userX,
                        _ => LucideIcons.check,
                      },
                      size: 16,
                    ),
                    label: AppText(
                      switch (a) {
                        PushAction.reply => 'notifications.action_reply',
                        PushAction.scan => 'notifications.action_scan',
                        PushAction.declineInvite => 'notifications.action_decline',
                        _ => 'notifications.action_open',
                      }
                          .getString(context),
                    ),
                  ),
        ],
      );
}

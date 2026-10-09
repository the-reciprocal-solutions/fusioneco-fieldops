import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/conversation/conversation_outbox.dart';
import '../../domain/app_notification.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/tech_popup.dart';
import 'notification_visuals.dart';

/// Everything a notification says, for one with no screen of its own in the
/// app (a C2O finding, an on-call page, a type this build doesn't know).
/// This is where such a tap lands instead of doing nothing.
Future<void> showNotificationDetails(BuildContext context, AppNotification n, {required DateTime now}) {
  final visual = noticeVisual(n);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: FeColors.panel,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 44,
                  width: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: visual.accent.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(visual.icon, color: visual.accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(child: AppText.titleMedium(n.title, weight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                _Fact(icon: groupIcon(n.group), text: groupLabel(context, n.group)),
                if (n.ref != null) _Fact(icon: LucideIcons.fileText, text: n.ref!),
                if (n.location != null) _Fact(icon: LucideIcons.mapPin, text: n.location!),
                if (n.createdAt != null) _Fact(icon: LucideIcons.clock, text: relativeTimeLabel(context, n.createdAt, now)),
              ],
            ),
            if (n.imageUrl != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(context.radii.card),
                child: Image.network(
                  n.imageUrl!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
            if (n.message.isNotEmpty) ...[
              const SizedBox(height: 16),
              SelectableText(n.message, style: Theme.of(context).textTheme.bodyMedium),
            ],
            const SizedBox(height: 16),
            AppText.caption('notifications.details_no_screen'.getString(context), color: FeColors.ink2),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: AppText('notifications.details_close'.getString(context)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: FeColors.ink2),
          const SizedBox(width: 4),
          AppText.caption(text, color: FeColors.ink2),
        ],
      );
}

/// Reply to the thread message a notification is about, without leaving
/// the list. [send] posts it (offline-queued like the thread's own composer).
Future<void> showReplySheet(
  BuildContext context,
  AppNotification n, {
  required Future<PostOutcome> Function(String text) send,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: FeColors.panel,
    builder: (context) => _ReplySheet(notification: n, send: send),
  );
}

class _ReplySheet extends StatefulWidget {
  const _ReplySheet({required this.notification, required this.send});

  final AppNotification notification;
  final Future<PostOutcome> Function(String text) send;

  @override
  State<_ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends State<_ReplySheet> {
  final _text = TextEditingController();
  var _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final outcome = await widget.send(body);
      if (!mounted) return;
      final queued = outcome is PostQueued;
      // The toast lives on the root overlay, so it outlives this sheet.
      showTechPopup(
        context,
        message: (queued ? 'notifications.reply_queued' : 'notifications.reply_sent').getString(context),
        queued: queued,
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      showTechPopup(context, message: 'notifications.reply_failed'.getString(context), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.titleSmall(n.title, weight: FontWeight.w700, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (n.message.isNotEmpty) ...[
            const SizedBox(height: 6),
            AppText.bodySmall(n.message, color: FeColors.ink2, maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(hintText: 'notifications.reply_hint'.getString(context)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: const Icon(LucideIcons.reply, size: 16),
              label: AppText('notifications.reply_send'.getString(context)),
            ),
          ),
        ],
      ),
    );
  }
}

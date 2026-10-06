import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/waiting_reasons.dart';
import '../core/utils/dates.dart';
import '../state/sync_waiting_controller.dart';
import '../theme/fe_colors.dart';
import 'app_text.dart';

/// Opens the "Waiting to send" sheet: every queued write, oldest first, with
/// the plain reason it hasn't gone ([explainQueue]) and Retry / Discard.
Future<void> showWaitingToSendSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: FeColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const WaitingToSendSheet(),
    );

String waitingReasonKey(WaitingReason r) => switch (r) {
      WaitingReason.offline => 'widgets.waiting_reason_offline',
      WaitingReason.sending => 'widgets.waiting_reason_sending',
      WaitingReason.notSentYet => 'widgets.waiting_reason_not_sent',
      WaitingReason.noAnswer => 'widgets.waiting_reason_no_answer',
      WaitingReason.serverBusy => 'widgets.waiting_reason_server_busy',
      WaitingReason.serverNotReady => 'widgets.waiting_reason_not_ready',
      WaitingReason.needsCheckIn => 'widgets.waiting_reason_check_in',
      WaitingReason.needsSignIn => 'widgets.waiting_reason_sign_in',
      WaitingReason.cannotPrepare => 'widgets.waiting_reason_cannot_prepare',
      WaitingReason.behindOther => 'widgets.waiting_reason_behind',
    };

class WaitingToSendSheet extends ConsumerStatefulWidget {
  const WaitingToSendSheet({super.key});

  @override
  ConsumerState<WaitingToSendSheet> createState() => _WaitingToSendSheetState();
}

class _WaitingToSendSheetState extends ConsumerState<WaitingToSendSheet> {
  /// The row whose Retry is running, or '*' for "Send now".
  String? _busy;

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() => _busy = key);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _discard(WaitingItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: AppText('widgets.waiting_discard_title'.getString(context)),
        content: AppText('widgets.waiting_discard_body'.getString(context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: AppText('widgets.waiting_keep'.getString(context)),
          ),
          TextButton(
            key: const ValueKey('waiting-discard-confirm'),
            style: TextButton.styleFrom(foregroundColor: FeColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: AppText('widgets.waiting_discard'.getString(context)),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(waitingActionsProvider).discard(item.entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(waitingItemsProvider);
    final offline = ref.watch(deviceOfflineProvider);
    final actions = ref.watch(waitingActionsProvider);
    final maxList = MediaQuery.sizeOf(context).height * 0.6;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 12),
          AppText.titleMedium('widgets.waiting_title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodySmall('widgets.waiting_subtitle'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: AppText.bodyMedium('widgets.waiting_empty'.getString(context), align: TextAlign.center),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxList),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1, color: FeColors.line),
                itemBuilder: (context, i) => _Row(
                  item: items[i],
                  retrying: _busy == items[i].entry.id,
                  busy: _busy != null,
                  onRetry: () => _run(items[i].entry.id, () => actions.retry(items[i].entry.id)),
                  onDiscard: () => _discard(items[i]),
                ),
              ),
            ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: offline || _busy != null ? null : () => _run('*', actions.sendAll),
              child: _busy == '*'
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : AppText('widgets.waiting_send_all'.getString(context)),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.retrying,
    required this.busy,
    required this.onRetry,
    required this.onDiscard,
  });

  final WaitingItem item;
  final bool retrying;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.bodyMedium(item.entry.label, weight: FontWeight.w600, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          AppText.caption(
            context.formatString(
              'widgets.waiting_queued_at'.getString(context),
              [formatHistoryTimestamp(item.entry.createdAt)],
            ),
            color: FeColors.ink2,
          ),
          const SizedBox(height: 4),
          AppText.bodySmall(
            waitingReasonKey(item.reason).getString(context),
            color: item.needsAttention ? FeColors.ink : FeColors.ink2,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : onRetry,
                child: retrying
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : AppText('widgets.waiting_retry'.getString(context)),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: FeColors.danger),
                onPressed: busy ? null : onDiscard,
                child: AppText('widgets.waiting_discard'.getString(context)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

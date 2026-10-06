import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/offline/waiting_reasons.dart';
import '../state/sync_waiting_controller.dart';
import '../theme/fe_colors.dart';
import 'app_text.dart';
import 'waiting_to_send_sheet.dart';

/// The shell's one-line sync status. Tapping it opens the "Waiting to send"
/// sheet ([showWaitingToSendSheet]), which says per item why it hasn't gone
/// and offers Retry / Discard.
///
/// - Offline: a dark bar ("Offline — your work is saved on this device").
/// - Online: a calm pale-blue bar ("1 change waiting to send · View"), only
///   when something is really waiting — an item that needs attention, or one
///   older than 30 s ([shouldShowWaitingBanner]). A write that is sent within
///   seconds no longer flashes a bar up (owner, 2026-10-06: "something random
///   at the top of the app").
/// - Otherwise nothing.
///
/// Must sit inside the shell's status-bar inset ([TopChromeLayout]); it pads
/// nothing itself.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  /// Re-checks the 30 s grace while something is queued: nothing else
  /// rebuilds the bar when an item quietly crosses it.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && ref.read(waitingItemsProvider).isNotEmpty) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(deviceOfflineProvider);
    final items = ref.watch(waitingItemsProvider);
    final pending = items.length;

    if (!offline && !shouldShowWaitingBanner(items, now: DateTime.now())) {
      return const SizedBox.shrink();
    }

    final String text;
    if (offline) {
      text = pending > 0
          ? context.formatString('widgets.offline_message_with_queued'.getString(context), [pending])
          : 'widgets.offline_message'.getString(context);
    } else {
      text = context.formatString(
        (pending == 1 ? 'widgets.waiting_send_one' : 'widgets.waiting_send_other').getString(context),
        [pending],
      );
    }

    final fg = offline ? Colors.white : FeColors.ink;
    return Semantics(
      button: pending > 0,
      child: Material(
        key: const ValueKey('sync-banner'),
        color: offline ? FeColors.ink : FeColors.infoSoft,
        child: InkWell(
          onTap: pending > 0 ? () => showWaitingToSendSheet(context) : null,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  offline ? LucideIcons.cloudOff : LucideIcons.cloudUpload,
                  size: 16,
                  color: offline ? Colors.white : FeColors.info,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.bodySmall(text, color: fg, weight: FontWeight.w600, maxLines: 2),
                ),
                if (pending > 0) ...[
                  const SizedBox(width: 8),
                  AppText.bodySmall(
                    'widgets.waiting_view'.getString(context),
                    color: offline ? Colors.white : FeColors.primary,
                    weight: FontWeight.w700,
                  ),
                  Icon(
                    Directionality.of(context) == TextDirection.rtl
                        ? LucideIcons.chevronLeft
                        : LucideIcons.chevronRight,
                    size: 16,
                    color: offline ? Colors.white : FeColors.primary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The shell's top chrome (sync banner, conflict panel) sits under the status
/// bar / Dynamic Island, and the screen below it must not add that inset a
/// second time.
///
/// The bug this fixes (iPhone, 2026-10-06): the banner was the first child of
/// the shell's body Column with no safe area, so iOS drew the clock and
/// battery over its text; and every branch screen wraps itself in its own
/// `SafeArea`, which still saw the full status-bar inset and added it again
/// *below* the banner — the large blank gap above "Orders". Now the shell
/// owns the top inset once and hands the screens a MediaQuery with it removed.
/// With nothing in [top] the result looks exactly as before.
class TopChromeLayout extends StatelessWidget {
  const TopChromeLayout({super.key, required this.top, required this.body});

  final List<Widget> top;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          ...top,
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: body),
          ),
        ],
      ),
    );
  }
}

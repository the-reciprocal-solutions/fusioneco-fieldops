import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/offline/sync_client.dart';
import '../state/providers.dart';
import '../theme/fe_colors.dart';
import 'app_text.dart';

/// Slate bar when offline, amber bar when online with a backlog. Renders nothing
/// when online and the queue is empty.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  bool _syncing = false;

  /// Shown state. Starts online: at a cold start connectivity_plus can answer
  /// "none" before Android has registered its network callback, and a one-shot
  /// check then pinned the bar on screen with nothing re-checking it (device
  /// report 2026-09-27: "offline bar at the top by default").
  bool _offline = false;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _confirm;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _sub = Connectivity().onConnectivityChanged.listen((_) => _check(), onError: (Object _) {});
    _check();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _confirm?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  /// Online is believed at once; offline only when a second check ~2 s later
  /// agrees. While offline, re-check every 10 s: the stream can miss the
  /// offline→online edge (see SyncClient.startAutoFlush).
  Future<void> _check() async {
    final sync = ref.read(syncClientProvider);
    final offline = await sync.isOffline;
    if (!mounted) return;
    if (!offline) {
      _confirm?.cancel();
      _poll?.cancel();
      _poll = null;
      if (_offline) setState(() => _offline = false);
      return;
    }
    if (_offline) return;
    _confirm?.cancel();
    _confirm = Timer(const Duration(seconds: 2), () async {
      final still = await sync.isOffline;
      if (!mounted || !still) return;
      setState(() => _offline = true);
      _poll ??= Timer.periodic(const Duration(seconds: 10), (_) => _check());
    });
  }

  Future<void> _syncNow(SyncClient sync) async {
    setState(() => _syncing = true);
    await sync.flushQueue();
    if (mounted) setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingMutationCountProvider).valueOrNull ?? 0;
    final sync = ref.watch(syncClientProvider);

    return Builder(
      builder: (context) {
        final offline = _offline;
        if (!offline && pending == 0) return const SizedBox.shrink();

        final text = offline
            ? (pending > 0
                ? context.formatString(
                    'widgets.offline_message_with_queued'.getString(context),
                    [pending],
                  )
                : 'widgets.offline_message'.getString(context))
            : context.formatString(
                (pending == 1
                        ? 'widgets.pending_sync_one'
                        : 'widgets.pending_sync_other')
                    .getString(context),
                [pending],
              );

        return Container(
          width: double.infinity,
          color: offline ? FeColors.ink : FeColors.warningSoft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                LucideIcons.cloudOff,
                size: 16,
                color: offline ? Colors.white : FeColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.bodySmall(
                  text,
                  color: offline ? Colors.white : FeColors.warning,
                  weight: FontWeight.w600,
                ),
              ),
              if (!offline && pending > 0)
                TextButton(
                  onPressed: _syncing ? null : () => _syncNow(sync),
                  style: TextButton.styleFrom(
                    foregroundColor: FeColors.warning,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    backgroundColor: FeColors.warningSoft,
                  ),
                  child: AppText(
                    _syncing
                        ? 'widgets.syncing_label'.getString(context)
                        : 'widgets.sync_now'.getString(context),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

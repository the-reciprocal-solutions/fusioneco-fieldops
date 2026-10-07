import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/push/push_service.dart';
import '../../state/auth_controller.dart';
import '../../state/notifications_controller.dart';
import '../../state/providers.dart';
import '../../state/socket_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/motion.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/sync_conflict_panel.dart';

class _NavItem {
  const _NavItem(this.labelKey, this.icon);

  /// Translation key for the tab label — resolved at build time via
  /// [labelKey].getString(context) so it follows the active locale.
  final String labelKey;
  final IconData icon;
}

const _navItems = <_NavItem>[
  _NavItem('common.dashboard', LucideIcons.house),
  _NavItem('common.overview', LucideIcons.chartColumn),
  _NavItem('common.orders', LucideIcons.clipboardList),
  _NavItem('common.assignments', LucideIcons.clipboardCheck),
  _NavItem('common.profile', LucideIcons.user),
];

/// Owns the whole chrome: offline banner, conflict panel, 5-item bottom bar.
class TechnicianShell extends ConsumerStatefulWidget {
  const TechnicianShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<TechnicianShell> createState() => _TechnicianShellState();
}

class _TechnicianShellState extends ConsumerState<TechnicianShell>
    with WidgetsBindingObserver {
  bool _expiryShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncClientProvider).startAutoFlush();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Backstop alongside the connectivity stream + poll timer in
  // `SyncClient.startAutoFlush`: coming back to the foreground is exactly
  // when a technician expects "did that sync yet" to already be true, and
  // it's a free, reliable connectivity re-check on its own.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(syncClientProvider).flushQueue());
      // Backstop for anything the socket missed while backgrounded (agent
      // replies, schedule started/done/failed): FCM draws the tray banner,
      // but the bell and an already-open list only learn of it here.
      ref.invalidate(unseenNotificationCountProvider);
      if (ref.exists(notificationsControllerProvider)) {
        unawaited(ref.read(notificationsControllerProvider.notifier).refresh());
      }
      // Re-send the FCM token: a first attempt can miss (iOS APNs token not
      // there yet, offline at launch), and the token can rotate while the app
      // sleeps. The server upserts, so repeating is harmless.
      unawaited(ref.read(pushServiceProvider).syncToken());
    }
  }

  Future<void> _showSessionExpired() async {
    _expiryShown = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: AppText('shell.session_expired_title'.getString(context)),
        content: AppText(
          'shell.session_expired_message'.getString(context),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: AppText('common.sign_in'.getString(context)),
          ),
        ],
      ),
    );
    // Already signed out by AuthController when the server refused the
    // renewal; this only makes sure, without another server call.
    await ref.read(authControllerProvider.notifier).logout(revoke: false);
    if (mounted) context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authControllerProvider, (previous, next) {
      if (next.sessionExpired && !_expiryShown) _showSessionExpired();
    });

    // Held open here rather than on the notifications screen: a notification
    // arriving while the technician is mid-checklist still has to reach the
    // bell.
    ref.watch(socketConnectionProvider);

    return Scaffold(
      backgroundColor: FeColors.page,
      // The shell owns the status-bar inset (iPhone notch / Dynamic Island)
      // so the banner is never drawn under the clock, and the branch
      // screens' own SafeArea doesn't add a second gap below it.
      body: TopChromeLayout(
        top: const [OfflineBanner(), SyncConflictPanel()],
        body: widget.navigationShell,
      ),
      bottomNavigationBar: _BottomNav(
        currentIndex: widget.navigationShell.currentIndex,
        onTap: (index) => widget.navigationShell.goBranch(
          index,
          initialLocation: index == widget.navigationShell.currentIndex,
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    // Detached from the screen edge and floating above the content, per the
    // reference screens' bottom bar — a plain edge-to-edge strip reads as
    // chrome, a rounded floating one reads as a control.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SafeArea(
        top: false,
        minimum: EdgeInsets.zero,
        child: Container(
          height: context.metrics.bottomNavHeight,
          decoration: BoxDecoration(
            color: FeColors.panel,
            borderRadius: BorderRadius.circular(28),
            boxShadow: FeElevation.floating,
          ),
          child: Row(
            children: [
              for (var i = 0; i < _navItems.length; i++)
                Expanded(
                  child: _NavButton(
                    item: _navItems[i],
                    active: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final _NavItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: 0.9,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: context.motion.press,
              curve: context.motion.spring,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              decoration: BoxDecoration(
                color: active ? const Color(0xFFE0F2FE) : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                item.icon,
                size: 20,
                color: active ? const Color(0xFF0284C7) : FeColors.ink2,
              ),
            ),
            const SizedBox(height: 4),
            // FittedBox rather than an ellipsis: Montserrat runs noticeably
            // wider than the Inter metrics this bar was tuned against, and
            // "Assignments" no longer fits five-across without shrinking —
            // scaling the whole label down keeps it readable on one line
            // instead of truncating to "Assignm…".
            FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedDefaultTextStyle(
                duration: context.motion.press,
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                  color: active ? const Color(0xFF0284C7) : FeColors.ink2,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 0.25,
                ),
                child: AppText(item.labelKey.getString(context), maxLines: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

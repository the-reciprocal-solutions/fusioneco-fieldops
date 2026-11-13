import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app/router.dart';
import '../state/providers.dart';
import '../theme/fe_colors.dart';
import '../theme/theme_extensions.dart';
import 'app_text.dart';
import 'fe_header.dart';
import 'dir_icon.dart';

/// The shell-level header: [FeHeader] plus the calendar/notification-bell/
/// logout affordances every top-level screen shares.
class TechHeader extends ConsumerWidget implements PreferredSizeWidget {
  const TechHeader({
    super.key,
    required this.title,
    this.showBack = false,
    this.showCalendar = true,
    this.showNotifications = true,
    this.onLogout,
  });

  final String title;
  final bool showBack;
  final bool showCalendar;
  final bool showNotifications;

  /// Only the dashboard and profile offer logout.
  final VoidCallback? onLogout;

  @override
  Size get preferredSize => const Size.fromHeight(53);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final unseen = ref.watch(unseenNotificationCountProvider).valueOrNull ?? 0;

    return FeHeader(
      title: title,
      showBack: showBack,
      actions: [
        if (showCalendar && location != Routes.calendar)
          _HeaderButton(
            icon: LucideIcons.calendarDays,
            tooltip: 'common.calendar'.getString(context),
            onTap: () => context.push(Routes.calendar),
          ),
        if (showNotifications)
          _HeaderButton(
            icon: LucideIcons.bell,
            tooltip: 'common.notifications'.getString(context),
            badge: unseen,
            onTap: () => context.push(Routes.notifications),
          ),
        if (onLogout != null)
          _HeaderButton(
            icon: LucideIcons.logOut,
            tooltip: 'common.log_out'.getString(context),
            onTap: onLogout!,
          ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Unseen count. Anything past nine shows as "9+", as the web does.
  final int badge;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: DirIcon.auto(icon, size: 20),
    );

    if (badge <= 0) return button;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        PositionedDirectional(
          top: 2,
          end: 2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16),
            decoration: BoxDecoration(
              color: FeColors.danger,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: FeColors.panel),
            ),
            child: AppText(
              badge > 9 ? '9+' : '$badge',
              align: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 9,
                height: 1.2,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Confirmation the dashboard and profile show before clearing the session.
///
/// [pendingCount] is the number of checks still sitting in the offline
/// queue. Signing out never deletes them (see [AuthController.logout]) but
/// a technician handing the phone over at end of shift needs to know their
/// work is still on the device, not on the server, until someone signs
/// back in with a connection to drain it.
Future<bool> showLogoutDialog(BuildContext context, {int pendingCount = 0}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: FeColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.radii.sheet),
      ),
      title: Row(
        children: [
          Container(
            height: 40,
            width: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: FeColors.dangerSoft,
              shape: BoxShape.circle,
            ),
            child: DirIcon(LucideIcons.logOut, size: 20, color: FeColors.danger),
          ),
          const SizedBox(width: 12),
          AppText('common.sign_out_title'.getString(context)),
        ],
      ),
      content: pendingCount > 0
          ? AppText(
              '$pendingCount check${pendingCount == 1 ? '' : 's'} on this '
              "phone ${pendingCount == 1 ? "hasn't" : "haven't"} synced yet. "
              "They'll stay saved on the device and send next time someone "
              'signs in with a connection.',
            )
          : AppText('common.sign_out_message'.getString(context)),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: AppText('common.cancel'.getString(context)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: FeColors.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: AppText('common.log_out'.getString(context)),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

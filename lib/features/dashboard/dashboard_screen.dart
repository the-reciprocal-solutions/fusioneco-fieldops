import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/locale_config.dart';
import '../../app/router.dart';
import '../../state/auth_controller.dart';
import '../../state/dashboard_controller.dart';
import '../../state/locale_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../permits/widgets/permit_dashboard_card.dart';
import '../snags/widgets/snag_dashboard_card.dart';
import '../ar/widgets/ar_entry_widgets.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/order_card.dart';
import '../../widgets/progress_ring.dart';
import '../../widgets/tech_header.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  static String greetingFor(DateTime now, BuildContext context) {
    if (now.hour < 12) return 'dashboard.greeting_morning'.getString(context);
    if (now.hour < 18) return 'dashboard.greeting_afternoon'.getString(context);
    return 'dashboard.greeting_evening'.getString(context);
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final pending = await ref.read(pendingMutationCountProvider.future);
    if (!context.mounted) return;
    if (!await showLogoutDialog(context, pendingCount: pending)) return;
    await ref.read(authControllerProvider.notifier).logout();
    if (context.mounted) context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).session;
    final state = ref.watch(dashboardControllerProvider);
    final unseenCount =
        ref.watch(unseenNotificationCountProvider).valueOrNull ?? 0;
    final name = session?.name ?? 'Balaji';
    final email = session?.email ?? 'balaji@eco.com';

    return Scaffold(
      backgroundColor: FeColors.page,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: ref.read(dashboardControllerProvider.notifier).refresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Custom top dashboard header matching screenshot
              _TopBar(
                unseenNotifications: unseenCount,
                onCalendar: () => context.push(Routes.calendar),
                onNotifications: () => context.push(Routes.notifications),
                onLogout: () => _logout(context, ref),
              ),
              const SizedBox(height: 18),

              // Hero Greeting Card with soft organic light-blue wave gradient
              _HeroGreetingCard(
                name: name,
                email: email,
                greeting: greetingFor(DateTime.now(), context),
              ),
              const SizedBox(height: 16),
              const _SyncStatusCard(),

              // 3-up stat row: Progress, Overdue, Due Today
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ProgressTile(
                        completed: state.completedCount,
                        total: state.totalCount,
                        pending: !state.loaded,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatCard(
                        label: 'dashboard.stat_overdue'.getString(context),
                        icon: LucideIcons.circleAlert,
                        value: state.overdueCount,
                        pending: !state.loaded,
                        iconColor: const Color(0xFFEF4444),
                        badgeColor: const Color(0xFFFFEEF1),
                        tintColor: const Color(0xFFFFEEF1),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatCard(
                        label: 'dashboard.stat_due_today'.getString(context),
                        icon: LucideIcons.clock,
                        value: state.dueTodayCount,
                        pending: !state.loaded,
                        iconColor: const Color(0xFFF97316),
                        badgeColor: const Color(0xFFFFF4EB),
                        tintColor: const Color(0xFFFFF4EB),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Action Cards Row: Scan QR & Orders
              Row(
                children: [
                  Expanded(
                    child: _ScanQrActionCard(
                      onTap: () => context.push(Routes.scan),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _WorkOrdersActionCard(
                      onTap: () => context.go(Routes.orders),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Snag Assistant (docs/snag-assistant.md) — its own widget so
              // this screen only knows where the door is, not what's behind it.
              const SnagDashboardCard(),
              const SizedBox(height: 12),
              // Permit to Work (docs/permit-to-work.md) — same doorway pattern.
              const PermitDashboardCard(),
              const SizedBox(height: 12),
              // AR BIM overlay: scan a board, open a floor, or an install run.
              const ArDashboardCard(),
              const SizedBox(height: 22),

              // Section Title: "Today's Active Tasks"
              Text(
                'dashboard.section_active_tasks'.getString(context),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: FeColors.ink,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 12),

              // Task List or Empty State Card
              if (state.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: TechSpinner(),
                )
              else if (state.activeTasks.isEmpty)
                const _ActiveTasksEmptyCard()
              else
                for (var i = 0; i < state.activeTasks.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: StaggeredEntrance(
                      index: i,
                      child: Builder(
                        builder: (context) {
                          final record = state.activeTasks[i];
                          return OrderCard(
                            id: record.id,
                            type: record.type,
                            referenceId: record.referenceId ?? '',
                            title: record.focusTitle,
                            priority: record.displayPriority,
                            status: record.displayStatus,
                            dueDate: record.effectiveDate,
                            technician: record.technicianName,
                            onTap: () => context.push(
                              Routes.orderDetail(record.type.slug, record.id),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header with Dashboard title, subtitle, and three circular action buttons.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.unseenNotifications,
    required this.onCalendar,
    required this.onNotifications,
    required this.onLogout,
  });

  final int unseenNotifications;
  final VoidCallback onCalendar;
  final VoidCallback onNotifications;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Dashboard's top bar carries four fixed-width circular
              // buttons (language toggle, calendar, notifications, logout)
              // instead of the two that Orders/Overview leave room for, so
              // the same 26px title that fits fine on those screens can run
              // out of room here on narrower phones and wrap mid-word
              // ("Dashboar" / "d"). Same fix as `_WorkOrdersActionCard`
              // below: keep the title on one line and let it scale down
              // rather than wrap, instead of shrinking the base size (which
              // would make it read smaller than every other screen's title
              // on normal-width phones where it already fits).
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'dashboard.title'.getString(context),
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: FeColors.ink,
                    letterSpacing: -0.5,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'dashboard.subtitle'.getString(context),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: FeColors.ink2,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const _LanguageSwitcherButton(),
        const SizedBox(width: 8),
        _CircleActionButton(
          icon: LucideIcons.calendarDays,
          tooltip: 'common.calendar'.getString(context),
          onTap: onCalendar,
        ),
        const SizedBox(width: 8),
        _CircleActionButton(
          icon: LucideIcons.bell,
          tooltip: 'common.notifications'.getString(context),
          badge: unseenNotifications,
          onTap: onNotifications,
        ),
        const SizedBox(width: 8),
        _CircleActionButton(
          icon: LucideIcons.logOut,
          tooltip: 'common.log_out'.getString(context),
          onTap: onLogout,
        ),
      ],
    );
  }
}

/// EN/AR toggle placed right next to the notifications bell. A single tap
/// flips to the other language via [localeControllerProvider] — the single
/// source of truth for the active language (see state/locale_controller.dart
/// for why reading/writing through the FlutterLocalization singleton
/// directly, as this used to, let the choice silently revert to English
/// after switching bottom-nav tabs). [FlutterLocalization.translate] still
/// persists the choice itself under the hood, so it survives an app restart
/// with no extra storage code here.
class _LanguageSwitcherButton extends ConsumerWidget {
  const _LanguageSwitcherButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeControllerProvider);
    final next = current == AppLocales.english
        ? AppLocales.arabic
        : AppLocales.english;
    final label = current.toUpperCase();

    return Material(
      color: FeColors.panel,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => ref.read(localeControllerProvider.notifier).set(next),
        child: Tooltip(
          message: 'common.language'.getString(context),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: FeColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: FeColors.panel,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, size: 19, color: FeColors.ink),
        ),
      ),
    );

    if (badge <= 0) return button;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        Positioned(
          top: -2,
          right: -2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16),
            decoration: BoxDecoration(
              color: FeColors.danger,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: FeColors.panel, width: 1.5),
            ),
            child: Text(
              badge > 9 ? '9+' : '$badge',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 9,
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

/// Hero Greeting Card with soft airy blue wave gradient
class _HeroGreetingCard extends StatelessWidget {
  const _HeroGreetingCard({
    required this.name,
    required this.email,
    required this.greeting,
  });

  final String name;
  final String email;
  final String greeting;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFDBEAFE), Color(0xFFEFF6FF), Color(0xFFE0F2FE)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0284C7).withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          children: [
            // Soft curved wave accent in the card background
            Positioned(
              right: -30,
              bottom: -40,
              child: CustomPaint(
                size: const Size(200, 140),
                painter: _HeroWavePainter(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFF0284C7),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x330284C7),
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Text(
                      name.isEmpty ? '?' : name[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$greeting \u{1F44B}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF475569),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: FeColors.ink,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          email,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
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

class _HeroWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF93C5FD).withValues(alpha: 0.35),
          const Color(0xFF60A5FA).withValues(alpha: 0.15),
        ],
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(0, size.height * 0.8)
      ..quadraticBezierTo(
        size.width * 0.4,
        size.height * 0.2,
        size.width,
        size.height * 0.4,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The Home screen's own view of the offline queue — richer than the thin
/// bar every screen already carries (see widgets/offline_banner.dart): a
/// progress bar while a flush is actively running, otherwise just the
/// backlog count. Tapping it opens the Sync Center, the one place with the
/// full list and per-item control.
///
/// FR-4.10 (2026-10-08): it used to render nothing once the queue was empty,
/// which also hid the only way into the Sync Center — so an unfinished
/// check sitting on the phone could not be seen, and "nothing is left" was
/// never said. Now it also shows for unsent drafts / local-only rows, and
/// turns into a green "Nothing is left on this device" once a sync this
/// session has emptied everything.
class _SyncStatusCard extends ConsumerWidget {
  const _SyncStatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingMutationCountProvider).valueOrNull ?? 0;
    final progress = ref.watch(syncProgressProvider);
    final left = ref.watch(leftOnDeviceProvider).valueOrNull;
    final drafts = left?.drafts.length ?? 0;
    final localOnly = left?.unsentLocal ?? 0;
    final sentThisSession = ref.watch(recentlySentProvider).isNotEmpty;

    if (pending == 0 && progress == null) {
      if (drafts > 0 || localOnly > 0) {
        return _LeftOnDeviceCard(drafts: drafts, localOnly: localOnly);
      }
      // Only after a drain this session — a phone that never queued
      // anything has nothing to reassure the technician about.
      if (left != null && left.isEmpty && sentThisSession) {
        return const _NothingLeftCard();
      }
      return const SizedBox.shrink();
    }

    final syncing = progress != null;
    final value = syncing
        ? (progress.total == 0 ? 1.0 : progress.completed / progress.total)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TechCard(
        onTap: () => context.push(Routes.syncCenter),
        padding: const EdgeInsets.all(14),
        tint: FeColors.warningSoft,
        borderColor: FeColors.warning.withValues(alpha: 0.25),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  syncing ? LucideIcons.refreshCw : LucideIcons.cloudUpload,
                  size: 16,
                  color: FeColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.bodySmall(
                    syncing
                        ? 'Syncing ${progress.completed} of ${progress.total}…'
                        : '$pending item${pending == 1 ? '' : 's'} waiting to sync',
                    weight: FontWeight.w700,
                    color: FeColors.warning,
                  ),
                ),
                const Icon(
                  LucideIcons.chevronRight,
                  size: 16,
                  color: FeColors.warning,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 6,
                backgroundColor: FeColors.warning.withValues(alpha: 0.15),
                valueColor: const AlwaysStoppedAnimation(FeColors.warning),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftOnDeviceCard extends StatelessWidget {
  const _LeftOnDeviceCard({required this.drafts, required this.localOnly});

  final int drafts;
  final int localOnly;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TechCard(
      onTap: () => context.push(Routes.syncCenter),
      padding: const EdgeInsets.all(14),
      tint: FeColors.warningSoft,
      borderColor: FeColors.warning.withValues(alpha: 0.25),
      child: Row(
        children: [
          const Icon(LucideIcons.filePen, size: 16, color: FeColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: AppText.bodySmall(
              drafts > 0
                  ? context.formatString('sync.card_drafts'.getString(context), [drafts])
                  : context.formatString('sync.local_only_note'.getString(context), [localOnly]),
              weight: FontWeight.w700,
              color: FeColors.warning,
            ),
          ),
          const Icon(LucideIcons.chevronRight, size: 16, color: FeColors.warning),
        ],
      ),
    ),
  );
}

class _NothingLeftCard extends StatelessWidget {
  const _NothingLeftCard();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TechCard(
      onTap: () => context.push(Routes.syncCenter),
      padding: const EdgeInsets.all(14),
      borderColor: FeColors.success.withValues(alpha: 0.3),
      child: Row(
        children: [
          const Icon(LucideIcons.cloudCheck, size: 16, color: FeColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: AppText.bodySmall(
              'sync.nothing_left_title'.getString(context),
              weight: FontWeight.w700,
              color: FeColors.success,
            ),
          ),
          const Icon(LucideIcons.chevronRight, size: 16, color: FeColors.success),
        ],
      ),
    ),
  );
}

/// Progress Ring tile
class _ProgressTile extends StatelessWidget {
  const _ProgressTile({
    required this.completed,
    required this.total,
    this.pending = false,
  });

  final int completed;
  final int total;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? completed / total : 0.0;
    final percentage = (fraction * 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Color(0xFFE0F2FE)],
          stops: [0.0, 0.75, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ProgressRing(
              value: pending ? null : fraction,
              size: 54,
              strokeWidth: 5.5,
              colors: const [Color(0xFF0284C7), Color(0xFF38BDF8)],
              child: Text(
                pending ? '—' : '$percentage%',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: FeColors.ink,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'dashboard.stat_progress'.getString(context),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stat card for Overdue and Due Today
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.icon,
    required this.value,
    required this.iconColor,
    required this.badgeColor,
    required this.tintColor,
    this.pending = false,
  });

  final String label;
  final IconData icon;
  final int value;
  final Color iconColor;
  final Color badgeColor;
  final Color tintColor;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, tintColor],
          stops: const [0.0, 0.75, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(height: 6),
          Text(
            pending ? '—' : '$value',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: pending ? const Color(0xFF94A3B8) : FeColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scan QR Action Card with rich blue gradient and bottom arrow
class _ScanQrActionCard extends StatelessWidget {
  const _ScanQrActionCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: 0.97,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0284C7), Color(0xFF0369A1)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.qrCode, color: Colors.white, size: 26),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Flexible+FittedBox rather than a bare Text — Montserrat
                    // runs wider than the Inter metrics this card was tuned
                    // against, and "Scan QR" no longer fits next to the arrow
                    // button without shrinking slightly — same fix already
                    // applied to `_WorkOrdersActionCard`'s label below.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'dashboard.action_scan_qr'.getString(context),
                          maxLines: 1,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.arrowRight,
                        color: Colors.white,
                        size: 15,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Work Orders Action Card with clean white background and bottom arrow
class _WorkOrdersActionCard extends StatelessWidget {
  const _WorkOrdersActionCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: 0.97,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: FeColors.panel,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  LucideIcons.clipboardList,
                  color: Color(0xFF475569),
                  size: 26,
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // FittedBox rather than an ellipsis — Montserrat runs
                    // wider than the Inter metrics this card was tuned
                    // against, and "Work Orders" no longer fits next to the
                    // arrow button without shrinking slightly.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'dashboard.action_work_orders'.getString(context),
                          maxLines: 1,
                          style: const TextStyle(
                            color: FeColors.ink,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.arrowRight,
                        color: Color(0xFF475569),
                        size: 15,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom Empty State Card with radiant sparkles icon
class _ActiveTasksEmptyCard extends StatelessWidget {
  const _ActiveTasksEmptyCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Radiant Sparkle Alert Icon
          CustomPaint(
            size: const Size(80, 80),
            painter: _RadiantSparklePainter(),
            child: Center(
              child: Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  LucideIcons.circleAlert,
                  size: 26,
                  color: Color(0xFF475569),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'dashboard.empty_title'.getString(context),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF334155),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'dashboard.empty_subtitle'.getString(context),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF94A3B8),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Painter for radiating sparkle dashes around the alert icon
class _RadiantSparklePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    final center = size.center(Offset.zero);
    const radius = 34.0;
    const rayLength = 5.0;

    final angles = [
      -math.pi / 4, // top-right
      -3 * math.pi / 4, // top-left
      0.0, // right
      math.pi, // left
    ];

    for (final angle in angles) {
      final start =
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
      final end =
          center +
          Offset(
            math.cos(angle) * (radius + rayLength),
            math.sin(angle) * (radius + rayLength),
          );
      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/push/push_service.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/catalog_controller.dart';
import '../../state/socket_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/motion.dart';
import '../../../theme/app_font.dart';

/// Bottom nav: Home · Efficiency · Alerts · Operations · More.
///
/// A tab whose module is not in the catalog is hidden and the others fill
/// the space. Branch indexes stay fixed (one per [NavTab]); only the drawn
/// buttons change, so go_router's branch state is never reshuffled.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// The bottom bar, for tests.
  static const bottomNavKey = Key('admin-bottom-nav');

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

typedef _NavItem = ({NavTab tab, IconData icon, String labelKey});

const _navItems = <_NavItem>[
  (tab: NavTab.home, icon: LucideIcons.house, labelKey: 'nav.home'),
  (tab: NavTab.efficiency, icon: LucideIcons.gauge, labelKey: 'nav.efficiency'),
  (tab: NavTab.alerts, icon: LucideIcons.bell, labelKey: 'nav.alerts'),
  (tab: NavTab.operations, icon: LucideIcons.wrench, labelKey: 'nav.operations'),
  (tab: NavTab.more, icon: LucideIcons.menu, labelKey: 'nav.more'),
];

class _AdminShellState extends ConsumerState<AdminShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Signed in: hand this phone's push token to the server (and open the
    // alert a tapped push was about).
    ref.read(pushServiceProvider).init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// An admin may have switched a module off while the app was away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    ref.invalidate(catalogProvider);
    // A socket that gave up while the phone was away comes back (P-002).
    ref.read(socketProvider).ensureConnected();
  }

  @override
  Widget build(BuildContext context) {
    // Live channel (config:changed → refetch) for as long as the shell is up.
    ref.watch(socketProvider);
    final boot = ref.watch(loadedCatalogProvider);
    // Until the catalog lands, show every tab (the screens show loading).
    final visible = [
      for (var i = 0; i < _navItems.length; i++)
        if (boot == null || boot.tabVisible(_navItems[i].tab)) i,
    ];
    final current = widget.navigationShell.currentIndex;

    return Scaffold(
      body: widget.navigationShell,
      bottomNavigationBar: _BottomNav(
        items: [for (final i in visible) _navItems[i]],
        activeIndex: visible.indexOf(current),
        onTap: (i) {
          final branch = visible[i];
          widget.navigationShell.goBranch(
            branch,
            // Tapping the active tab again returns to its first screen.
            initialLocation: branch == current,
          );
        },
      ),
    );
  }
}

/// technician_portal's floating bottom bar: detached from the screen edge,
/// rounded, so it reads as a control rather than chrome.
class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.items, required this.activeIndex, required this.onTap});

  final List<_NavItem> items;
  final int activeIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SafeArea(
        top: false,
        minimum: EdgeInsets.zero,
        child: Container(
          key: AdminShell.bottomNavKey,
          height: context.metrics.bottomNavHeight,
          decoration: BoxDecoration(
            color: FeColors.panel,
            borderRadius: BorderRadius.circular(28),
            boxShadow: FeElevation.floating,
          ),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavButton(item: items[i], active: i == activeIndex, onTap: () => onTap(i)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.active, required this.onTap});

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
                gradient: active ? const LinearGradient(colors: [FeColors.primaryLight, FeColors.primary]) : null,
                borderRadius: BorderRadius.circular(16),
                boxShadow: active ? FeElevation.tinted(FeColors.primary) : null,
              ),
              child: Icon(item.icon, size: 20, color: active ? Colors.white : FeColors.ink2),
            ),
            const SizedBox(height: 4),
            // Scale the label down rather than wrap or ellipsize: "Operations"
            // must stay on one line five-across.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedDefaultTextStyle(
                duration: context.motion.press,
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                      color: active ? FeColors.primary : FeColors.ink2,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: context.letterSpacingFor(0.25),
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

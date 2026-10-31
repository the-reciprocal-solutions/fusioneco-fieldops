import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../catalog/catalog_guard.dart';
import '../domain/mobile_catalog.dart';
import '../features/alerts/alert_detail_screen.dart';
import '../features/alerts/alerts_screen.dart';
import '../features/efficiency/efficiency_screen.dart';
import '../features/home/home_screen.dart';
import '../features/module/module_screen.dart';
import '../features/modules/module_spec.dart';
import '../features/more/more_screen.dart';
import '../features/operations/operations_screen.dart';
import '../features/shell/admin_shell.dart';
import '../state/auth_controller.dart';
import '../state/catalog_controller.dart';
import '../theme/fe_colors.dart';

abstract final class Routes {
  static const login = '/login';
  static final home = tabPaths[NavTab.home]!;
  static final efficiency = tabPaths[NavTab.efficiency]!;
  static final alerts = tabPaths[NavTab.alerts]!;
  static final operations = tabPaths[NavTab.operations]!;
  static final more = tabPaths[NavTab.more]!;
  static const unavailable = unavailablePath;

  /// One module (or one of its pages): `/m/:moduleId?page=…`.
  static String module(String moduleId, {String? page}) => modulePath(moduleId, page: page);

  /// One alert (`sa:…` / `pd:…` / `ac:…` / `sl:…` key) — list taps and push deep links.
  static String alert(String key) => alertPath(key);
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authControllerProvider, (previous, next) {
    if (previous?.isAuthenticated != next.isAuthenticated) refresh.value++;
  });
  // A new catalog can hide the screen the user is on: re-run the guard.
  ref.listen(loadedCatalogProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final authed = ref.read(authControllerProvider).isAuthenticated;
      final atLogin = state.matchedLocation == Routes.login;
      if (!authed) return atLogin ? null : Routes.login;
      if (atLogin) return Routes.home;
      return catalogRedirect(ref.read(loadedCatalogProvider), state.uri);
    },
    routes: [
      // Sign-in is FieldOps' screen (lib/features/login): once the admin is
      // signed out, the root (lib/app/app_root.dart) swaps back to the
      // technician app, so this only shows for the frame in between.
      GoRoute(path: Routes.login, builder: (context, state) => const ColoredBox(color: FeColors.page)),
      GoRoute(path: Routes.unavailable, builder: (context, state) => const UnavailableScreen()),
      GoRoute(
        path: '/m/:moduleId',
        builder: (context, state) => ModuleScreen(
          moduleId: state.pathParameters['moduleId']!,
          pageId: state.uri.queryParameters['page'],
        ),
        routes: [
          // One record (Phase 3 detail); the list passes its row as `extra`.
          GoRoute(
            path: 'r/:recordId',
            builder: (context, state) => RecordScreen(
              moduleId: state.pathParameters['moduleId']!,
              recordId: state.pathParameters['recordId']!,
              pageId: state.uri.queryParameters['page'],
              initial: state.extra is Json ? state.extra as Json : null,
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/alert/:key',
        builder: (context, state) => AlertDetailScreen(alertKey: state.pathParameters['key']!),
      ),
      // Branch order = NavTab order = AdminShell._tabs order.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AdminShell(navigationShell: navigationShell),
        branches: [
          _branch(Routes.home, (_) => const HomeScreen()),
          _branch(Routes.efficiency, (_) => const EfficiencyScreen()),
          _branch(Routes.alerts, (_) => const AlertsScreen()),
          _branch(Routes.operations, (_) => const OperationsScreen()),
          _branch(Routes.more, (_) => const MoreScreen()),
        ],
      ),
    ],
  );
});

StatefulShellBranch _branch(String path, Widget Function(BuildContext) screen) => StatefulShellBranch(
      routes: [GoRoute(path: path, builder: (context, state) => screen(context))],
    );

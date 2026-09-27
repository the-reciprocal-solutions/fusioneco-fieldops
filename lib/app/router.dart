import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/ar/ar_marker_screen.dart';
import '../features/ar/ar_models_screen.dart';
import '../features/ar/ar_session_screen.dart';
import '../features/ar/ar_spare_screen.dart';
import '../features/ar/install/ar_install_guide_screen.dart';
import '../features/ar/install/ar_install_list_screen.dart';
import '../features/asset_detail/asset_detail_screen.dart';
import '../features/c2o_search/c2o_asset_search_screen.dart';
import '../features/calendar/calendar_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/field_verification/field_verification_screen.dart';
import '../features/floor_plan/floor_plan_screen.dart';
import '../features/inspection/inspection_form_screen.dart';
import '../features/inspection/inspection_list_screen.dart';
import '../features/invites/invites_screen.dart';
import '../features/login/login_screen.dart';
import '../features/nameplate_ocr/nameplate_ocr_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/order_detail/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
import '../features/overview/overview_screen.dart';
import '../core/c2o/route_pack.dart';
import '../domain/ar_handoff.dart';
import '../features/permits/permit_detail_screen.dart';
import '../features/permits/permit_resolve_screen.dart';
import '../features/permits/permits_hub_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/routes/route_detail_screen.dart';
import '../features/routes/route_list_screen.dart';
import '../features/scanner/scanner_screen.dart';
import '../features/shell/technician_shell.dart';
import '../features/snags/snag_detail_screen.dart';
import '../features/snags/snag_hub_screen.dart';
import '../features/snags/snag_raise_screen.dart';
import '../features/snags/snag_survey_screen.dart';
import '../features/snags/snag_verify_screen.dart';
import '../features/snags/snag_walk_screen.dart';
import '../features/sync/sync_center_screen.dart';
import '../features/bim_viewer/bim_viewer_screen.dart';
import '../features/twin/twin_screen.dart';
import '../features/web/web_page_screen.dart';
import '../state/auth_controller.dart';

/// Paths mirror the web routes so the notification deep-link table maps 1:1.
abstract final class Routes {
  static const login = '/login';
  static const dashboard = '/dashboard';
  static const overview = '/overview';
  static const orders = '/orders';
  static const invites = '/invites';
  static const profile = '/profile';
  static const calendar = '/calendar';
  static const notifications = '/notifications';
  static const scan = '/scan';
  static const nameplateOcr = '/nameplate-ocr';
  static const c2oSearch = '/c2o-search';
  static const c2oRoutes = '/c2o-routes';
  static const syncCenter = '/sync';

  /// FR-5.2/5.3 — the room-grouped list + progress for one downloaded route.
  static String routeDetail(RouteScope scope, String id) => '/c2o-routes/${scope.name}/$id';

  /// FR-5.4 — the scanner with an off-route check active: a resolved asset
  /// outside [assetIds] is marked off-route rather than treated as a plain
  /// resolve. Query params, not `extra` — this app never passes objects
  /// through the router, only serialisable strings.
  static String scanForRoute(RouteScope scope, String id) =>
      Uri(path: scan, queryParameters: {'routeScope': scope.name, 'routeId': id}).toString();
  static const inspections = '/inspections';

  static String orderDetail(String type, String id) => '/orders/$type/$id';
  static String inspectionDetail(String id) => '/inspections/$id';
  static String twin(String assetId) => '/twin/$assetId';

  /// The 2D/3D model viewer (docs/bim-viewer.md) for a floor, optionally
  /// opened on an asset (selected and framed). Alongside [twin], which
  /// stays the web's xeokit page.
  static String bimViewer(String floorId, {String? assetId, String? assetName}) {
    final query = {'assetId': ?assetId, 'name': ?assetName};
    return Uri(path: '/bim-viewer/$floorId', queryParameters: query.isEmpty ? null : query).toString();
  }
  static String assetDetail(String assetId) => '/asset/$assetId';

  // Snag Assistant (docs/snag-assistant.md). The server's notification link
  // `/technician/snags/<id>` maps onto [snagDetail] like every other link.
  static const snags = '/snags';
  static String snagDetail(String id) => '/snags/$id';
  static String snagWalk(String surveyId) => '/snags/walk/$surveyId';
  static String snagSurvey(String surveyId) => '/snags/survey/$surveyId';
  static String snagVerify(String buildingId) =>
      Uri(path: '/snags/verify', queryParameters: {'buildingId': buildingId}).toString();

  // Permit to Work (docs/permit-to-work.md). The server's notification/push
  // link `/technician/permits/<id>` maps onto [permitDetail] the same way
  // every other technician link does (prefix strip in notification_route.dart
  // / push_service.dart) — no special-casing needed there.
  static const permits = '/permits';
  static String permitDetail(String id) => '/permits/$id';

  /// A scanned worksite QR (`/permit-check/<token>`) lands on the resolver
  /// screen, which looks the token up and replaces itself with [permitDetail].
  static String permitByToken(String token) =>
      '/permits/by-token/${Uri.encodeComponent(token)}';

  /// UC-5 — a snag raised from context (an asset, a work order) arrives
  /// with that context pre-filled. Only strings cross the router.
  static String snagNew({
    String? buildingId,
    String? floorId,
    String? assetId,
    String? assetName,
    String? assetReferenceId,
    String? workOrderId,
    String? context,
    Map<String, String>? ar,
  }) {
    final query = {
      'buildingId': ?buildingId,
      'floorId': ?floorId,
      'assetId': ?assetId,
      'assetName': ?assetName,
      'assetRef': ?assetReferenceId,
      'workOrderId': ?workOrderId,
      'context': ?context,
      // P-006: the AR hand-off (`ArHandoff.toQuery`), when raised in AR.
      ...?ar,
    };
    return Uri(path: '/snags/new', queryParameters: query.isEmpty ? null : query).toString();
  }

  /// FR-2.8. [assetId] is a query param (not the path) so the floor plan
  /// image can stay cached under one key per floor regardless of which
  /// asset on it was opened from.
  static String floorPlan(
    String floorId, {
    required String assetId,
    String? assetName,
    String? assetReferenceId,
    String? assetType,
  }) {
    final query = {
      'assetId': assetId,
      'name': ?assetName,
      'ref': ?assetReferenceId,
      'type': ?assetType,
    };
    return Uri(path: '/floor-plan/$floorId', queryParameters: query).toString();
  }

  /// FR-3. [claimedSerial]/[claimedTag] feed the "same as claimed" shortcut
  /// (FR-3.2); [floorId] rides along purely so a submitted verification can
  /// jump straight into the floor plan afterward without a second scan.
  static String verifyAsset(
    String assetId, {
    String? assetName,
    String? claimedSerial,
    String? claimedTag,
    String? floorId,
  }) {
    final query = {
      'name': ?assetName,
      'claimedSerial': ?claimedSerial,
      'claimedTag': ?claimedTag,
      'floorId': ?floorId,
    };
    return Uri(path: '/verify/$assetId', queryParameters: query).toString();
  }

  // AR BIM overlay (docs/ar-setup-and-gamma-parity.md, ar-markers-and-qr.md
  // §5). Only strings cross the router: the session re-reads the floor pack
  // itself. The server's install push link `/technician/ar/install?floorId=`
  // maps onto [arInstall] through the usual `/technician` prefix strip.

  /// Building → floor → tick the models to show together. From an asset or
  /// a work order only [assetId] is known; the screen finds the floor.
  static String arModels({String? buildingId, String? floorId, String? assetId, String? workOrderId}) {
    final query = <String, String>{
      'buildingId': ?buildingId,
      'floorId': ?floorId,
      'assetId': ?assetId,
      'workOrderId': ?workOrderId,
    };
    return Uri(path: '/ar', queryParameters: query.isEmpty ? null : query).toString();
  }

  /// A scanned board (in-app scanner, App Link `/m/<code>`).
  static String arMarker(String code) => '/ar/marker/${Uri.encodeComponent(code)}';

  /// The AR session. [models] are the ticked lineages; [focus] is the board
  /// that opened it; [install] runs the installer's self-check for that code.
  static String arSession({
    required String floorId,
    String? method,
    String? targetGlobalId,
    String? assetId,
    String? workOrderId,
    String? focus,
    List<String>? models,
    String? space,
    String? install,
  }) {
    final query = <String, String>{
      'floorId': floorId,
      'method': ?method,
      'targetGlobalId': ?targetGlobalId,
      'assetId': ?assetId,
      'workOrderId': ?workOrderId,
      'focus': ?focus,
      if (models != null && models.isNotEmpty) 'models': models.join(','),
      'space': ?space,
      'install': ?install,
    };
    return Uri(path: '/ar/session', queryParameters: query).toString();
  }

  /// The installer's list for a floor (push link target).
  static String arInstall({String? floorId}) =>
      Uri(path: '/ar/install', queryParameters: floorId == null ? null : {'floorId': floorId}).toString();

  /// One stop: find the spot, then the self-check.
  static String arInstallGuide(String code, {String? floorId}) => Uri(
    path: '/ar/install/${Uri.encodeComponent(code)}',
    queryParameters: floorId == null ? null : {'floorId': floorId},
  ).toString();

  /// A spare board scanned outside a session: register it here.
  static String arSpare(String code, {String? floorId}) => Uri(
    path: '/ar/spare/${Uri.encodeComponent(code)}',
    queryParameters: floorId == null ? null : {'floorId': floorId},
  ).toString();

  /// The built-in browser. The address is a query parameter rather than a path
  /// segment so slashes in it survive.
  static String webPage(String url, {String? title}) {
    final query = {'url': url, 'title': ?title};
    return Uri(path: '/web', queryParameters: query).toString();
  }

  /// The five routes that live inside the bottom-bar shell. Each one owns a
  /// branch navigator, and pushing one onto the root navigator reserves that
  /// branch's key a second time — which throws
  /// `!keyReservation.contains(key)` and takes the app down. They are switched
  /// to with `go`, never pushed.
  static const shellBranches = <String>{
    dashboard,
    overview,
    orders,
    invites,
    profile,
  };

  static bool isShellBranch(String route) => shellBranches.contains(route);
}

final _rootKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authControllerProvider, (previous, next) {
    if (previous?.isAuthenticated != next.isAuthenticated) refresh.value++;
  });
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: Routes.dashboard,
    refreshListenable: refresh,
    redirect: (context, state) {
      final authed = ref.read(authControllerProvider).isAuthenticated;
      final atLogin = state.matchedLocation == Routes.login;
      if (!authed) return atLogin ? null : Routes.login;
      if (atLogin) return Routes.dashboard;
      return null;
    },
    routes: [
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            TechnicianShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.dashboard,
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.overview,
                builder: (context, state) => const OverviewScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.orders,
                builder: (context, state) => const OrdersScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.invites,
                builder: (context, state) => const InvitesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.profile,
                builder: (context, state) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/orders/:type/:id',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => OrderDetailScreen(
          orderType: state.pathParameters['type'] ?? 'work-order',
          orderId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.inspections,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const InspectionListScreen(),
      ),
      GoRoute(
        path: '/inspections/:id',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => InspectionFormScreen(
          assignmentId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.calendar,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const CalendarScreen(),
      ),
      GoRoute(
        path: Routes.notifications,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.scan,
        parentNavigatorKey: _rootKey,
        builder: (context, state) {
          final routeScopeName = state.uri.queryParameters['routeScope'];
          final routeId = state.uri.queryParameters['routeId'];
          final routeScope = routeScopeName == null
              ? null
              : RouteScope.values.asNameMap()[routeScopeName];
          return ScannerScreen(
            activeRouteScope: routeScope,
            activeRouteId: routeId,
          );
        },
      ),
      GoRoute(
        path: Routes.nameplateOcr,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const NameplateOcrScreen(),
      ),
      GoRoute(
        path: Routes.c2oSearch,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const C2oAssetSearchScreen(),
      ),
      GoRoute(
        path: Routes.c2oRoutes,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const RouteListScreen(),
      ),
      GoRoute(
        path: '/c2o-routes/:scope/:id',
        parentNavigatorKey: _rootKey,
        builder: (context, state) {
          final scope = RouteScope.values.asNameMap()[state.pathParameters['scope']] ??
              RouteScope.package;
          return RouteDetailScreen(scope: scope, id: state.pathParameters['id'] ?? '');
        },
      ),
      GoRoute(
        path: Routes.syncCenter,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const SyncCenterScreen(),
      ),
      GoRoute(
        path: '/web',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => WebPageScreen(
          url: state.uri.queryParameters['url'] ?? '',
          title: state.uri.queryParameters['title'],
        ),
      ),
      GoRoute(
        path: '/asset/:assetId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => AssetDetailScreen(
          assetId: state.pathParameters['assetId'] ?? '',
        ),
      ),
      GoRoute(
        path: '/twin/:assetId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => TwinScreen(
          assetId: state.pathParameters['assetId'] ?? '',
          assetName: state.uri.queryParameters['name'],
        ),
      ),
      GoRoute(
        path: '/verify/:assetId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => FieldVerificationScreen(
          assetId: state.pathParameters['assetId'] ?? '',
          assetName: state.uri.queryParameters['name'],
          claimedSerial: state.uri.queryParameters['claimedSerial'],
          claimedTag: state.uri.queryParameters['claimedTag'],
          floorId: state.uri.queryParameters['floorId'],
          // P-006: the AR workspace's `ar*` params (null from a scan).
          arHandoff: ArHandoff.fromQuery(state.uri.queryParameters),
        ),
      ),
      // Snag Assistant — the fixed segments must stay above `/snags/:id`.
      GoRoute(
        path: Routes.snags,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const SnagHubScreen(),
      ),
      GoRoute(
        path: '/snags/walk/:surveyId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => SnagWalkScreen(surveyId: state.pathParameters['surveyId'] ?? ''),
      ),
      GoRoute(
        path: '/snags/survey/:surveyId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => SnagSurveyScreen(surveyId: state.pathParameters['surveyId'] ?? ''),
      ),
      GoRoute(
        path: '/snags/verify',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => SnagVerifyScreen(buildingId: state.uri.queryParameters['buildingId'] ?? ''),
      ),
      GoRoute(
        path: '/snags/new',
        parentNavigatorKey: _rootKey,
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return SnagRaiseScreen(
            buildingId: q['buildingId'],
            floorId: q['floorId'],
            assetId: q['assetId'],
            assetName: q['assetName'],
            assetReferenceId: q['assetRef'],
            workOrderId: q['workOrderId'],
            contextWire: q['context'],
            arHandoff: ArHandoff.fromQuery(q),
          );
        },
      ),
      GoRoute(
        path: '/snags/:id',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => SnagDetailScreen(snagId: state.pathParameters['id'] ?? ''),
      ),
      // Permit to Work — the fixed segments must stay above `/permits/:id`.
      GoRoute(
        path: Routes.permits,
        parentNavigatorKey: _rootKey,
        builder: (context, state) => const PermitsHubScreen(),
      ),
      GoRoute(
        path: '/permits/by-token/:token',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => PermitResolveScreen(
          token: Uri.decodeComponent(state.pathParameters['token'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/permits/:id',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => PermitDetailScreen(permitId: state.pathParameters['id'] ?? ''),
      ),
      // AR BIM overlay. The fixed segments stay above the `:code` routes.
      GoRoute(
        path: '/ar',
        parentNavigatorKey: _rootKey,
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return ArModelsScreen(
            buildingId: q['buildingId'],
            floorId: q['floorId'],
            assetId: q['assetId'],
            workOrderId: q['workOrderId'],
          );
        },
      ),
      GoRoute(
        path: '/ar/session',
        parentNavigatorKey: _rootKey,
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return ArSessionScreen(
            floorId: q['floorId'] ?? '',
            method: q['method'],
            targetGlobalId: q['targetGlobalId'],
            assetId: q['assetId'],
            workOrderId: q['workOrderId'],
            focusCode: q['focus'],
            models: (q['models'] ?? '').split(',').where((m) => m.isNotEmpty).toSet(),
            spaceName: q['space'],
            installCode: q['install'],
          );
        },
      ),
      GoRoute(
        path: '/ar/install',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => ArInstallListScreen(floorId: state.uri.queryParameters['floorId']),
      ),
      GoRoute(
        path: '/ar/install/:code',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => ArInstallGuideScreen(
          code: state.pathParameters['code'] ?? '',
          floorId: state.uri.queryParameters['floorId'],
        ),
      ),
      GoRoute(
        path: '/ar/marker/:code',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => ArMarkerScreen(code: state.pathParameters['code'] ?? ''),
      ),
      GoRoute(
        path: '/ar/spare/:code',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => ArSpareScreen(
          code: state.pathParameters['code'] ?? '',
          floorId: state.uri.queryParameters['floorId'],
        ),
      ),
      GoRoute(
        path: '/bim-viewer/:floorId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => BimViewerScreen(
          floorId: state.pathParameters['floorId'] ?? '',
          assetId: state.uri.queryParameters['assetId'],
          assetName: state.uri.queryParameters['name'],
        ),
      ),
      GoRoute(
        path: '/floor-plan/:floorId',
        parentNavigatorKey: _rootKey,
        builder: (context, state) => FloorPlanScreen(
          floorId: state.pathParameters['floorId'] ?? '',
          assetId: state.uri.queryParameters['assetId'] ?? '',
          assetName: state.uri.queryParameters['name'],
          assetReferenceId: state.uri.queryParameters['ref'],
          assetType: state.uri.queryParameters['type'],
        ),
      ),
    ],
  );
});

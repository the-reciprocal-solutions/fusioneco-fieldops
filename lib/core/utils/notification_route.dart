import '../../app/router.dart';
import '../../domain/app_notification.dart';
import '../conversation/conversation_links.dart';
import '../push/push_content.dart';

/// Where tapping a notification takes a technician. A port of the web's
/// `getNotificationRoute.ts`, Technician branch only — this app has no other
/// role to serve.
///
/// Returns null when there is no screen for it; the caller then opens the
/// notification's details sheet ([Routes.notificationsFor] `open:`) — never
/// a dead tap.
String? routeForNotification(AppNotification notification) => routeForNotificationFields(
      link: notification.link,
      entityId: notification.entityId,
      entityType: notification.entityType,
      title: notification.title,
      route: notification.route,
    );

/// THE routing rule, used by every way a notification is opened: a tray tap
/// and its buttons (`PushService._handleResponse`, foreground, background
/// and cold start — Android and iOS, local and server-drawn), and the in-app
/// list. It used to be written out twice and the two copies drifted.
///
/// Order, first match wins:
/// 1. Threads, agent sessions, schedules ([conversationRouteFor]) — their
///    links are web admin pages, which rule 2 can't use.
/// 2. A `/technician/...` link that maps onto a screen this app has.
/// 3. The fixed titles of the invite chain (inbox / order list).
/// 4. The entity table ([kNoticeEntityRoutes]) — also catches an admin
///    link on a technician's copy (it used to make the tap do nothing).
/// 5. The server's `route` deep link (payload v2), if it maps to a screen.
/// 6. A digest opens the list on its group.
/// Null otherwise.
String? routeForNotificationFields({
  String? link,
  String? entityId,
  String? entityType,
  String? title,
  String? route,
  String? group,
}) {
  final conversation = conversationRouteFor(entityType: entityType, entityId: entityId, link: link);
  if (conversation != null) return conversation;

  final fromLink = appRouteForWebLink(link);
  if (fromLink != null && isKnownAppRoute(fromLink)) return fromLink;

  final id = entityId?.trim();
  final type = entityType?.trim();

  final kind = pushKindOf(PushData(title: title, entityId: id, entityType: type));
  switch (kind) {
    // The invite inbox, not the task page. `assignmentInviteService.ts` uses
    // this exact title and only this title for invites, and the detail screen
    // fires a dozen calls just to reach the accept/decline panel at the top
    // of it.
    case PushKind.invite:
      return Routes.invites;
    // The job went to someone else; its detail page would only refuse them.
    case PushKind.inviteWithdrawn:
      return Routes.orders;
    case PushKind.digest:
      return Routes.notificationsFor(group: NoticeGroup.fromWire(group)?.wire);
    default:
      break;
  }

  if (id != null && id.isNotEmpty && type != null && type.isNotEmpty) {
    final rule = kNoticeEntityRoutes[type];
    if (rule != null) return rule(id);
  }

  final fromServer = appRouteForWebLink(route);
  if (fromServer != null && isKnownAppRoute(fromServer)) return fromServer;
  return null;
}

/// The routing table: server `entityType` → this app's screen for that id.
/// Every key is a string some server service really stamps (grep
/// `entityType:` in `fusion-eco-server/src`); `test/notification_route_test.dart`
/// has one case per key with the real server strings.
///
/// Not here on purpose (no screen in this app → details sheet):
/// `c2o_finding` (C2O exception log is web-only), `FlowAgentSuggestion`
/// (an on-call page; its draft lives in the web Flow Agents workspace),
/// `C2oFieldVerification`, `conversation` (the old AI chat), and the
/// admin-only families (`purchase_order`, `room_booking`, `visitor`,
/// `service_schedule`, `storage`).
final Map<String, String Function(String id)> kNoticeEntityRoutes = {
  // Maintenance orders: PascalCase model names on most notifications,
  // snake_case `AssignableEntityType` on the invite chain.
  for (final type in const [
    'WorkOrder',
    'work_order',
    'PreventiveMaintenance',
    'preventive_maintenance',
    'ReactiveMaintenance',
    'reactive_maintenance',
    'AnnualMaintenance',
    'annual_maintenance',
  ])
    type: (id) => Routes.orderDetail(orderTypeForEntity(type)!.slug, id),
  // Inspections aren't an `OrderType` (see `maintenance_record.dart`) —
  // `/inspections/:id` takes the assignment id, which is what both the
  // inspection controller (`Inspection`) and the Flow Agents photo-check
  // flag (`InspectionAssignment`) send.
  'Inspection': Routes.inspectionDetail,
  'InspectionAssignment': Routes.inspectionDetail,
  // Snag Assistant (`snagService.ts` also sends `/technician/snags/<id>`).
  'Snag': Routes.snagDetail,
  // Permit to Work: `ptwService.ts` stamps `PermitToWork`; `Permit` is kept
  // for any older or generic path (LEARNINGS 2026-09-26).
  'PermitToWork': Routes.permitDetail,
  'Permit': Routes.permitDetail,
  // AR install requests name the floor (`installRequestService.ts`).
  'ar_install_request': (id) => Routes.arInstall(floorId: id),
  'ArInstallRequest': (id) => Routes.arInstall(floorId: id),
  // C2O route handed over / released: the route list (the link says so too).
  'c2o_route_assignment': (_) => Routes.c2oRoutes,
  'Asset': Routes.assetDetail,
  'asset': Routes.assetDetail,
  // Certification reminders name the technician themself.
  'Technician': (_) => Routes.profile,
  // Schedules without a usable link (conversationRouteFor handles the rest).
  'UserSchedule': (id) => Routes.schedules(focus: id),
  'user_schedule': (id) => Routes.schedules(focus: id),
};

/// The server sends web paths. This app's routes are the same paths without the
/// `/technician` prefix, so a technician link maps across directly — anything
/// else belongs to a different portal (null).
String? appRouteForWebLink(String? link) {
  final l = link?.trim();
  if (l == null || l.isEmpty) return null;
  const prefix = '/technician';
  if (!l.startsWith(prefix)) return null;
  final route = l.substring(prefix.length);
  if (route.isEmpty || route == '/') return Routes.dashboard;
  if (!route.startsWith('/') && !route.startsWith('?')) return null; // `/technicianfoo`
  return route.startsWith('/') ? route : '/$route';
}

/// Every path pattern registered in `router.dart` (a test reads that file
/// and fails if one here is missing there). A server link to a screen this
/// app doesn't have would otherwise open go_router's error page.
const kAppRoutePatterns = <String>[
  '/dashboard',
  '/overview',
  '/orders',
  '/invites',
  '/profile',
  '/calendar',
  '/notifications',
  '/scan',
  '/scans',
  '/nameplate-ocr',
  '/c2o-search',
  '/c2o-routes',
  '/c2o-routes/:scope/:id',
  '/sync',
  '/web',
  '/orders/:type/:id',
  '/conversations/:entity/:id',
  '/schedules',
  '/schedules/:id',
  '/inspections',
  '/inspections/:id',
  '/asset/:assetId',
  '/twin/:assetId',
  '/verify/:assetId',
  '/snags',
  '/snags/walk/:surveyId',
  '/snags/survey/:surveyId',
  '/snags/verify',
  '/snags/new',
  '/snags/:id',
  '/permits',
  '/permits/by-token/:token',
  '/permits/:id',
  '/ar',
  '/ar/session',
  '/ar/install',
  '/ar/install/:code',
  '/ar/marker/:code',
  '/ar/spare/:code',
  '/bim-viewer/:floorId',
  '/floor-plan/:floorId',
];

/// True when [route] (path + optional query) matches a registered pattern.
bool isKnownAppRoute(String route) {
  final path = Uri.tryParse(route)?.path ?? route;
  final segs = path.split('/').where((s) => s.isNotEmpty).toList();
  for (final pattern in kAppRoutePatterns) {
    final p = pattern.split('/').where((s) => s.isNotEmpty).toList();
    if (p.length != segs.length) continue;
    var ok = true;
    for (var i = 0; i < p.length && ok; i++) {
      ok = p[i].startsWith(':') ? segs[i].isNotEmpty : p[i] == segs[i];
    }
    if (ok) return true;
  }
  return false;
}

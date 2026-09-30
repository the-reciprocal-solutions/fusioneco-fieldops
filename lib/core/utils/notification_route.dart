import '../../app/router.dart';
import '../../domain/app_notification.dart';
import '../conversation/conversation_links.dart';

/// Where tapping a notification takes a technician. A port of the web's
/// `getNotificationRoute.ts`, Technician branch only — this app has no other
/// role to serve.
///
/// Returns null when there is nowhere useful to go, and the caller should leave
/// the technician on the notifications list rather than pushing a dead route.
String? routeForNotification(AppNotification notification) {
  // Conversations, agent sessions and schedules first: their links are web
  // admin pages, which the `/technician` rule below would throw away.
  final conversation = conversationRouteFor(
    entityType: notification.entityType,
    entityId: notification.entityId,
    link: notification.link,
  );
  if (conversation != null) return conversation;

  final link = notification.link?.trim();
  if (link != null && link.isNotEmpty) {
    final route = _appRouteForWebLink(link);
    if (route != null) return route;
    // A link pointing outside the technician portal — another role's page, or
    // an absolute URL. There is no screen here that can show it.
    return null;
  }

  final entityId = notification.entityId?.trim();
  final entityType = notification.entityType?.trim();
  if (entityId == null || entityId.isEmpty) return null;
  if (entityType == null || entityType.isEmpty) return null;

  // AI conversations resume in the Flow Agent workspace, which this app does
  // not have.
  if (entityType == 'conversation') return null;

  // The invite inbox, not the task page. `assignmentInviteService.ts` uses this
  // exact title and only this title for invites, and the detail screen fires a
  // dozen calls just to reach the accept/decline panel at the top of it.
  if (notification.title == 'New assignment invite') return Routes.invites;

  // Inspections aren't an `OrderType` (see `maintenance_record.dart`'s doc
  // comment) — their detail route lives at `/inspections/:id`, not
  // `/orders/:type/:id`, so this one entity type is handled before the
  // four-way order lookup below.
  if (entityType == 'Inspection') return Routes.inspectionDetail(entityId);
  // Snag Assistant — the server also sends `/technician/snags/<id>` as the
  // link, which the branch above already maps; this covers a link-less one.
  if (entityType == 'Snag') return Routes.snagDetail(entityId);
  // Permit to Work — the server also sends `/technician/permits/<id>` as the
  // link, which the branch above already maps; this covers a link-less one.
  // `ptwService.ts` stamps `entityType: "PermitToWork"`; `Permit` is kept
  // too in case an older or generic notification path ever used it. Keep in
  // step with `_routeForPushData` in push_service.dart.
  if (entityType == 'Permit' || entityType == 'PermitToWork') {
    return Routes.permitDetail(entityId);
  }
  // AR install requests send the link `/technician/ar/install?floorId=<id>`,
  // which the prefix strip above maps onto [Routes.arInstall] as it is; a
  // link-less one names the floor as its entity. The server stamps
  // `ar_install_request` (installRequestService.ts INSTALL_REQUEST_ENTITY);
  // the PascalCase spelling is kept in case it is ever normalised. Keep in
  // step with `_routeForPushData` in push_service.dart.
  if (entityType == 'ar_install_request' || entityType == 'ArInstallRequest') {
    return Routes.arInstall(floorId: entityId);
  }

  final slug = _slugForEntityType(entityType);
  return slug == null ? null : Routes.orderDetail(slug, entityId);
}

/// The four entity names the server stamps on a notification, mapped to this
/// app's route segments. Spelled out rather than derived: the server's names
/// are PascalCase and the routes are not.
String? _slugForEntityType(String entityType) => switch (entityType) {
      'WorkOrder' => 'work-order',
      'PreventiveMaintenance' => 'preventive',
      'ReactiveMaintenance' => 'reactive',
      'AnnualMaintenance' => 'annual',
      _ => null,
    };

/// The server sends web paths. This app's routes are the same paths without the
/// `/technician` prefix, so a technician link maps across directly — anything
/// else belongs to a different portal.
String? _appRouteForWebLink(String link) {
  const prefix = '/technician';
  if (!link.startsWith(prefix)) return null;
  final route = link.substring(prefix.length);
  if (route.isEmpty || route == '/') return Routes.dashboard;
  return route.startsWith('/') ? route : '/$route';
}

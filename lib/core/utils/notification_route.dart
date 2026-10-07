import '../../app/router.dart';
import '../../domain/app_notification.dart';
import '../conversation/conversation_links.dart';
import '../push/push_content.dart';

/// Where tapping a notification takes a technician. A port of the web's
/// `getNotificationRoute.ts`, Technician branch only — this app has no other
/// role to serve.
///
/// Returns null when there is nowhere useful to go, and the caller should leave
/// the technician on the notifications list rather than pushing a dead route.
String? routeForNotification(AppNotification notification) => routeForNotificationFields(
      link: notification.link,
      entityId: notification.entityId,
      entityType: notification.entityType,
      title: notification.title,
    );

/// The one routing rule for both the in-app list ([routeForNotification])
/// and a tapped push (`push_service.dart`, which only has the flat string
/// keys of the FCM payload). It used to be written out twice, and the two
/// copies had to be kept in step by hand.
String? routeForNotificationFields({
  String? link,
  String? entityId,
  String? entityType,
  String? title,
}) {
  // Conversations, agent sessions and schedules first: their links are web
  // admin pages, which the `/technician` rule below would throw away.
  final conversation = conversationRouteFor(entityType: entityType, entityId: entityId, link: link);
  if (conversation != null) return conversation;

  final trimmedLink = link?.trim();
  if (trimmedLink != null && trimmedLink.isNotEmpty) {
    final route = _appRouteForWebLink(trimmedLink);
    if (route != null) return route;
    // A link pointing outside the technician portal — another role's page, or
    // an absolute URL. There is no screen here that can show it.
    return null;
  }

  final id = entityId?.trim();
  final type = entityType?.trim();
  if (id == null || id.isEmpty) return null;
  if (type == null || type.isEmpty) return null;

  // AI conversations resume in the Flow Agent workspace, which this app does
  // not have.
  if (type == 'conversation') return null;

  final data = PushData(title: title, entityId: id, entityType: type);
  switch (pushKindOf(data)) {
    // The invite inbox, not the task page. `assignmentInviteService.ts` uses
    // this exact title and only this title for invites, and the detail screen
    // fires a dozen calls just to reach the accept/decline panel at the top
    // of it.
    case PushKind.invite:
      return Routes.invites;
    // The job went to someone else; its detail page would only refuse them.
    case PushKind.inviteWithdrawn:
      return Routes.orders;
    // Certification reminders name the technician themself.
    case PushKind.certification:
      return Routes.profile;
    default:
      break;
  }

  // Inspections aren't an `OrderType` (see `maintenance_record.dart`'s doc
  // comment) — their detail route lives at `/inspections/:id`, not
  // `/orders/:type/:id`, so this one entity type is handled before the
  // four-way order lookup below.
  if (type == 'Inspection') return Routes.inspectionDetail(id);
  // Snag Assistant — the server also sends `/technician/snags/<id>` as the
  // link, which the branch above already maps; this covers a link-less one.
  if (type == 'Snag') return Routes.snagDetail(id);
  // Permit to Work — the server also sends `/technician/permits/<id>` as the
  // link, which the branch above already maps; this covers a link-less one.
  // `ptwService.ts` stamps `entityType: "PermitToWork"`; `Permit` is kept
  // too in case an older or generic notification path ever used it.
  if (type == 'Permit' || type == 'PermitToWork') return Routes.permitDetail(id);
  // AR install requests send the link `/technician/ar/install?floorId=<id>`,
  // which the prefix strip above maps onto [Routes.arInstall] as it is; a
  // link-less one names the floor as its entity. The server stamps
  // `ar_install_request` (installRequestService.ts INSTALL_REQUEST_ENTITY);
  // the PascalCase spelling is kept in case it is ever normalised.
  if (type == 'ar_install_request' || type == 'ArInstallRequest') {
    return Routes.arInstall(floorId: id);
  }

  // The server stamps PascalCase model names on most notifications and the
  // snake_case invite-chain names on a few; both map to the same route
  // segment ([orderTypeForEntity]).
  final orderType = orderTypeForEntity(type);
  return orderType == null ? null : Routes.orderDetail(orderType.slug, id);
}

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

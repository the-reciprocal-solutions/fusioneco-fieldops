import '../../domain/maintenance_record.dart';

/// What a push is about, and what a technician can do with it straight from
/// the tray. Pure (no plugin, no Flutter widgets) so the background isolate
/// that draws the notification and the foreground app that handles its tap
/// both read the same rules, and tests can pin them without a device.
///
/// The server sends one flat, data-only FCM payload for every notification
/// (`pushToUserDevices` in `notificationService.ts`): `title`, `body`
/// (the stored `message`, since 2026-10-07 — before that the phone only ever
/// got the title), `link`, `entityId`, `entityType`, `notificationId`, `type`
/// (info | warning | success | error) and `category`. There is no "kind" key:
/// the kind is worked out here from `entityType` + `title`, the same signals
/// the routing in `notification_route.dart` already relies on, so an older
/// server that sends fewer keys still gets a sensible notification.
enum PushKind {
  /// "New assignment invite" — answer it (Accept here, Decline needs a reason).
  invite,

  /// The invite went to someone else before this technician answered.
  inviteWithdrawn,

  /// A job is now theirs: a scheduled work order, a new inspection.
  newWork,

  /// Something already theirs is late or about to be (PM overdue, SLA warning).
  atRisk,

  /// C2O route assigned / handed over / released.
  route,
  snag,
  permit,
  arInstall,

  /// Their own certification is about to lapse.
  certification,
  general,
}

/// The buttons a notification can carry. Every one opens the app
/// (`showsUserInterface` on Android, `foreground` on iOS): the work they do
/// needs the signed-in session, the offline queue and the router, none of
/// which exist in the background isolate that drew the notification.
enum PushAction {
  /// Accept the invite in place, then open the job.
  acceptInvite('invite_accept'),

  /// Decline needs a reason, so this opens the invite inbox to ask for it.
  declineInvite('invite_decline'),

  /// Open whatever the notification is about (same as tapping it).
  open('open'),

  /// The technician's order list.
  myOrders('my_orders'),

  /// Straight into the scanner (route work starts with a tag scan).
  scan('scan');

  const PushAction(this.id);

  /// The action id the plugin hands back on a button tap. Stable strings —
  /// a notification drawn by an older build is still answered by a newer one.
  final String id;

  static PushAction? fromId(String? id) {
    for (final a in values) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// How loudly to present it. Drives the accent colour and the badge label;
/// the sound and channel stay the same for all of them (a channel's sound is
/// fixed once it is created, see `local_notifications.dart`).
enum PushTone { normal, urgent, good }

/// The flat push payload, parsed tolerantly — every key is optional and
/// arrives as a string (FCM data values are always strings; empty = absent).
class PushData {
  const PushData({
    this.title,
    this.body,
    this.link,
    this.entityId,
    this.entityType,
    this.notificationId,
    this.type,
  });

  factory PushData.fromMap(Map<String, dynamic> map) {
    String? s(String key) {
      final v = map[key]?.toString().trim();
      return v == null || v.isEmpty ? null : v;
    }

    return PushData(
      title: s('title'),
      body: s('body'),
      link: s('link'),
      entityId: s('entityId'),
      entityType: s('entityType'),
      notificationId: s('notificationId'),
      type: s('type'),
    );
  }

  final String? title;
  final String? body;
  final String? link;
  final String? entityId;
  final String? entityType;

  /// The `app_notifications` row id, so a tap can mark that row read.
  final String? notificationId;

  /// info | warning | success | error.
  final String? type;
}

/// The exact titles the server uses for the invite chain
/// (`assignmentInviteService.ts`). The invite title is also what
/// `notification_route.dart` routes on, so it can't be reworded server-side
/// without breaking every build already in the field.
const kInviteTitle = 'New assignment invite';
const _withdrawnTitles = {'Assignment reassigned'};

PushKind pushKindOf(PushData d) {
  final type = d.entityType;
  final title = d.title ?? '';
  if (title == kInviteTitle) return PushKind.invite;
  if (_withdrawnTitles.contains(title)) return PushKind.inviteWithdrawn;
  switch (type) {
    case 'c2o_route_assignment':
      return PushKind.route;
    case 'Snag':
      return PushKind.snag;
    case 'Permit' || 'PermitToWork':
      return PushKind.permit;
    case 'ar_install_request' || 'ArInstallRequest':
      return PushKind.arInstall;
    case 'Technician':
      return PushKind.certification;
    case 'Inspection':
      return PushKind.newWork;
  }
  final isOrder = orderTypeForEntity(type) != null;
  if (isOrder && (d.type == 'warning' || d.type == 'error')) return PushKind.atRisk;
  if (isOrder) return PushKind.newWork;
  return PushKind.general;
}

/// The two spellings the server stamps on maintenance records: PascalCase
/// model names on most notifications, snake_case `AssignableEntityType` on
/// the invite chain. Null for anything that isn't an order.
OrderType? orderTypeForEntity(String? entityType) => switch (entityType) {
      'WorkOrder' || 'work_order' => OrderType.workOrder,
      'PreventiveMaintenance' || 'preventive_maintenance' => OrderType.preventive,
      'ReactiveMaintenance' || 'reactive_maintenance' => OrderType.reactive,
      'AnnualMaintenance' || 'annual_maintenance' => OrderType.annual,
      _ => null,
    };

/// Order types an invite can be accepted for from the tray. Annual has no
/// `/assignment/respond` route on the server, so it only gets the inbox.
const _acceptableInviteTypes = {OrderType.workOrder, OrderType.preventive, OrderType.reactive};

/// At most two buttons: Android shows three, but the third squeezes every
/// label to an ellipsis on a small phone, and two reads faster at a glance.
List<PushAction> pushActionsFor(PushData d) {
  final kind = pushKindOf(d);
  switch (kind) {
    case PushKind.invite:
      final type = orderTypeForEntity(d.entityType);
      final canAccept = d.entityId != null && _acceptableInviteTypes.contains(type);
      return canAccept
          ? const [PushAction.acceptInvite, PushAction.declineInvite]
          : const [PushAction.open];
    case PushKind.newWork:
    case PushKind.atRisk:
      return const [PushAction.open, PushAction.myOrders];
    case PushKind.route:
      return const [PushAction.open, PushAction.scan];
    case PushKind.snag:
    case PushKind.permit:
    case PushKind.arInstall:
    case PushKind.certification:
      return const [PushAction.open];
    case PushKind.inviteWithdrawn:
    case PushKind.general:
      return const [];
  }
}

PushTone pushToneFor(PushData d) {
  if (d.type == 'warning' || d.type == 'error') return PushTone.urgent;
  if (d.type == 'success') return PushTone.good;
  return switch (pushKindOf(d)) {
    PushKind.atRisk || PushKind.certification => PushTone.urgent,
    _ => PushTone.normal,
  };
}

/// One notification per thing, not one per event. The key is hashed into the
/// notification id ([pushIdFor]) and a reused id replaces the old one, so a snag that is assigned, rejected and
/// closed shows its latest state once instead of three stacked banners, and
/// an invite that is withdrawn replaces the invite (whose Accept button
/// would now only be refused). Null when there is no thing to key on.
String? pushTagFor(PushData d) {
  final id = d.entityId;
  if (id == null) return d.notificationId;
  final kind = pushKindOf(d);
  // Invites and their withdrawal share the order's key on purpose (above).
  final scope = kind == PushKind.invite || kind == PushKind.inviteWithdrawn
      ? 'order'
      : (d.entityType ?? 'x');
  return '$scope:$id';
}

/// A small, stable integer for the plugin's notification id. Dart's own
/// `String.hashCode` isn't promised to match between the background isolate
/// that draws a notification and the main one that later replaces it, so
/// this is a plain FNV-1a hash folded to 31 bits.
int pushIdFor(String key) {
  var h = 0x811c9dc5;
  for (final c in key.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// The text a notification is drawn with. The server's title and message
/// stay the substance (they name the job, the asset, the due date); this
/// only adds a short kind badge and falls back sensibly when a key is missing.
class PushDisplay {
  const PushDisplay({required this.title, required this.body, required this.badge});

  final String title;

  /// Null when the server sent no message (an older server).
  final String? body;

  /// Short kind label shown beside the app name on Android ("New job",
  /// "Action needed"). Null for a general notification.
  final String? badge;
}

PushDisplay pushDisplayFor(PushData d, {String lang = 'en'}) {
  final t = _strings(lang);
  final kind = pushKindOf(d);
  final badge = switch (kind) {
    PushKind.invite => t['badge.invite'],
    PushKind.inviteWithdrawn => t['badge.withdrawn'],
    PushKind.newWork => t['badge.new_work'],
    PushKind.atRisk => t['badge.at_risk'],
    PushKind.route => t['badge.route'],
    PushKind.snag => t['badge.snag'],
    PushKind.permit => t['badge.permit'],
    PushKind.arInstall => t['badge.ar'],
    PushKind.certification => t['badge.certification'],
    PushKind.general => null,
  };
  // An invite's server title is a fixed routing key, not a headline. The
  // message already says which job ("You have been assigned to WO-0042…"),
  // so the headline can just say what it asks for.
  final title = kind == PushKind.invite ? t['title.invite']! : (d.title ?? t['title.fallback']!);
  return PushDisplay(title: title, body: d.body, badge: badge);
}

String pushActionLabel(PushAction a, PushData d, {String lang = 'en'}) {
  final t = _strings(lang);
  return switch (a) {
    PushAction.acceptInvite => t['action.accept']!,
    PushAction.declineInvite => t['action.decline']!,
    PushAction.myOrders => t['action.my_orders']!,
    PushAction.scan => t['action.scan']!,
    PushAction.open => switch (pushKindOf(d)) {
        PushKind.invite => t['action.view_invite']!,
        PushKind.newWork || PushKind.atRisk => t['action.open_job']!,
        PushKind.route => t['action.open_route']!,
        PushKind.snag => t['action.open_snag']!,
        PushKind.permit => t['action.open_permit']!,
        PushKind.arInstall => t['action.start_install']!,
        PushKind.certification => t['action.view_profile']!,
        _ => t['action.open']!,
      },
  };
}

/// Notification text is drawn in the background isolate, outside any widget
/// tree, so it can't use `'ns.key'.getString(context)` like the screens do.
/// The handful of strings live here instead, in both shipped languages.
/// Keep the keys in step across both maps (a test checks this).
Map<String, String> _strings(String lang) => lang == 'ar' ? pushStringsAr : pushStringsEn;

const pushStringsEn = <String, String>{
  'badge.invite': 'Job offer',
  'badge.withdrawn': 'Job moved on',
  'badge.new_work': 'New job',
  'badge.at_risk': 'Action needed',
  'badge.route': 'Route',
  'badge.snag': 'Snag',
  'badge.permit': 'Permit',
  'badge.ar': 'AR install',
  'badge.certification': 'Certification',
  'title.invite': 'A new job is waiting for you',
  'title.fallback': 'Fusion Eco',
  'action.accept': 'Accept',
  'action.decline': 'Decline',
  'action.my_orders': 'My orders',
  'action.scan': 'Scan tag',
  'action.view_invite': 'View invite',
  'action.open_job': 'Open job',
  'action.open_route': 'View route',
  'action.open_snag': 'Open snag',
  'action.open_permit': 'Open permit',
  'action.start_install': 'Start install',
  'action.view_profile': 'View profile',
  'action.open': 'Open',
  'result.accepted': 'Job accepted. Opening it now.',
  'result.accepted_offline': 'Accepted offline. It will be sent when you are back online.',
  'result.accept_failed': 'That did not send. Please answer the invite here.',
};

const pushStringsAr = <String, String>{
  'badge.invite': 'عرض عمل',
  'badge.withdrawn': 'تم نقل المهمة',
  'badge.new_work': 'مهمة جديدة',
  'badge.at_risk': 'إجراء مطلوب',
  'badge.route': 'مسار',
  'badge.snag': 'ملاحظة',
  'badge.permit': 'تصريح',
  'badge.ar': 'تركيب AR',
  'badge.certification': 'شهادة',
  'title.invite': 'مهمة جديدة بانتظارك',
  'title.fallback': 'Fusion Eco',
  'action.accept': 'قبول',
  'action.decline': 'رفض',
  'action.my_orders': 'طلباتي',
  'action.scan': 'مسح الملصق',
  'action.view_invite': 'عرض الدعوة',
  'action.open_job': 'فتح المهمة',
  'action.open_route': 'عرض المسار',
  'action.open_snag': 'فتح الملاحظة',
  'action.open_permit': 'فتح التصريح',
  'action.start_install': 'بدء التركيب',
  'action.view_profile': 'عرض الملف الشخصي',
  'action.open': 'فتح',
  'result.accepted': 'تم قبول المهمة. جارٍ فتحها الآن.',
  'result.accepted_offline': 'تم القبول دون اتصال. سيتم الإرسال عند عودة الاتصال.',
  'result.accept_failed': 'لم يتم الإرسال. يرجى الرد على الدعوة هنا.',
};

/// A result message shown after a tray action ran in the app.
String pushResultText(String key, {String lang = 'en'}) => _strings(lang)[key] ?? pushStringsEn[key] ?? '';

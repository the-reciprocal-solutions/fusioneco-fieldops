import 'dart:convert';

import '../../domain/maintenance_record.dart';

/// What a push is about, and what a technician can do with it straight from
/// the tray. Pure (no plugin, no Flutter widgets) so the background isolate
/// that draws the notification and the foreground app that handles its tap
/// both read the same rules, and tests can pin them without a device.
///
/// The server sends one flat, data-only FCM payload for every notification
/// (`buildPushMessage` in the server's `services/push/pushPayload.ts`).
/// v1 keys (every server since 2026-10-07): `title`, `body`, `link`,
/// `entityId`, `entityType`, `notificationId`, `type` (info | warning |
/// success | error) and `category`. v2 keys (2026-10-10, all optional):
/// `group`, `priority`, `actions`, `threadId`, `route`, `imageUrl`, `ref`,
/// `location`, `badge`, and for a digest `kind=digest`, `count`, `lines`,
/// `notificationIds`. Every rule below works from the v1 keys alone, so an
/// older server still gets a sensible notification; a v2 key only refines it.
///
/// **Server mirror:** the group / priority / action rules here are the same
/// as `pushPayload.ts` (`noticeGroupOf`, `noticePriorityOf`,
/// `pushActionsOf`). Both test files pin the same fixtures
/// (`test/notice_catalog_test.dart`, server `pushPayload.test.ts`); change
/// both together.
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

  /// A C2O finding raised from their own field check (no screen in the app).
  finding,
  permit,
  arInstall,

  /// Their own certification is about to lapse.
  certification,

  /// Someone (or an AI teammate) wrote on a record's thread.
  message,

  /// They were @mentioned on a record's thread.
  mention,

  /// An AI teammate started / finished working on their request.
  agentSession,

  /// A schedule or reminder started / finished / failed.
  schedule,

  /// An on-call page from a Flow Agent.
  alert,

  /// Several notifications that arrived together, folded into one push.
  digest,
  general,
}

/// The tabs of the notifications screen, the Android channels and the iOS
/// thread groups. Wire names match the server's `NoticeGroup`.
enum NoticeGroup {
  work('work'),
  snags('snags'),
  permits('permits'),
  messages('messages'),
  schedules('schedules'),
  system('system');

  const NoticeGroup(this.wire);
  final String wire;

  static NoticeGroup? fromWire(String? value) {
    for (final g in values) {
      if (g.wire == value) return g;
    }
    return null;
  }
}

/// How loudly to deliver. Wire names match the server's `NoticePriority`.
enum NoticePriority {
  /// A safety stop or an on-call alarm: alarm channel, full-screen on a
  /// locked Android phone, time-sensitive on iOS.
  critical('critical'),

  /// Needs an answer soon (invite, overdue, mention): heads-up, time-sensitive.
  high('high'),
  normal('normal'),

  /// FYI (a job moved on, a schedule started): quiet channel, iOS passive.
  low('low');

  const NoticePriority(this.wire);
  final String wire;

  static NoticePriority? fromWire(String? value) {
    for (final p in values) {
      if (p.wire == value) return p;
    }
    return null;
  }
}

/// The buttons a notification can carry. [markRead] runs without opening
/// the app (it is parked for the app to send, see `pending_push_actions.dart`);
/// every other one opens the app (`showsUserInterface` on Android,
/// `foreground` on iOS): the work it does needs the signed-in session, the
/// offline queue and the router.
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
  scan('scan'),

  /// Type a reply to a thread message right in the notification.
  reply('reply'),

  /// Mark it read and clear it, without opening the app.
  markRead('mark_read');

  const PushAction(this.id);

  /// The action id the plugin hands back on a button tap. Stable strings —
  /// a notification drawn by an older build is still answered by a newer one,
  /// and the server names them in `actions` / the APNs `category`.
  final String id;

  static PushAction? fromId(String? id) {
    for (final a in values) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// True for the one button that never opens the app.
  bool get runsInBackground => this == PushAction.markRead;
}

/// How loudly to present it. Drives the accent colour and the badge label.
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
    this.category,
    this.group,
    this.priority,
    this.actions,
    this.threadId,
    this.route,
    this.imageUrl,
    this.ref,
    this.location,
    this.badge,
    this.kind,
    this.count,
    this.lines = const [],
    this.notificationIds = const [],
  });

  factory PushData.fromMap(Map<String, dynamic> map) {
    String? s(String key) {
      final v = map[key]?.toString().trim();
      return v == null || v.isEmpty ? null : v;
    }

    List<String> csv(String key) =>
        (s(key) ?? '').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    List<String> lines() {
      final raw = s('lines');
      if (raw == null) return const [];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
      return const [];
    }

    final image = s('imageUrl');
    return PushData(
      title: s('title'),
      body: s('body'),
      link: s('link'),
      entityId: s('entityId'),
      entityType: s('entityType'),
      notificationId: s('notificationId'),
      type: s('type'),
      category: s('category'),
      group: NoticeGroup.fromWire(s('group')),
      priority: NoticePriority.fromWire(s('priority')),
      // Null (absent, an older server) means "use the app's own rules"; an
      // empty list is the server saying "no buttons".
      actions: map.containsKey('actions') && map.containsKey('v') ? csv('actions') : null,
      threadId: s('threadId'),
      route: s('route'),
      // Only http(s): the picture is downloaded in the background isolate.
      imageUrl: image != null && RegExp(r'^https?://', caseSensitive: false).hasMatch(image) ? image : null,
      ref: s('ref'),
      location: s('location'),
      badge: int.tryParse(s('badge') ?? ''),
      kind: s('kind'),
      count: int.tryParse(s('count') ?? ''),
      lines: lines(),
      notificationIds: csv('notificationIds'),
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

  /// The stored server category (system | asset | work_order | …).
  final String? category;

  // v2 — null on an older server.
  final NoticeGroup? group;
  final NoticePriority? priority;

  /// Action ids the server suggests; the app keeps only the ones it supports
  /// for this kind ([pushActionsFor]).
  final List<String>? actions;
  final String? threadId;

  /// A `/technician/...` deep link for a type the app has no rule for.
  final String? route;
  final String? imageUrl;
  final String? ref;
  final String? location;

  /// The bell's unseen count after this one arrived (app icon badge).
  final int? badge;

  /// `digest` for a folded burst, else null.
  final String? kind;
  final int? count;
  final List<String> lines;
  final List<String> notificationIds;

  bool get isDigest => kind == 'digest' || entityType == 'digest';
}

/// The exact titles the server uses for the invite chain
/// (`assignmentInviteService.ts`). The invite title is also what
/// `notification_route.dart` routes on, so it can't be reworded server-side
/// without breaking every build already in the field.
const kInviteTitle = 'New assignment invite';
const _withdrawnTitles = {'Assignment reassigned'};

/// Record kinds a reply can be posted to (`ConvEntity` wires).
const kReplyableEntities = {'snag', 'work_order', 'service_request', 'pm_plan', 'inspection_response', 'permit', 'asset'};

PushKind pushKindOf(PushData d) {
  if (d.isDigest) return PushKind.digest;
  final type = d.entityType ?? '';
  final title = d.title ?? '';
  if (title == kInviteTitle) return PushKind.invite;
  if (_withdrawnTitles.contains(title)) return PushKind.inviteWithdrawn;
  if (type.startsWith('conversation:')) {
    return type.endsWith(':mention') ? PushKind.mention : PushKind.message;
  }
  if (type.startsWith('session:') || type == 'agent_session') return PushKind.agentSession;
  if (type == 'schedule' || type.startsWith('schedule:') || type == 'user_schedule' || type == 'UserSchedule') {
    return PushKind.schedule;
  }
  switch (type) {
    case 'c2o_route_assignment':
      return PushKind.route;
    case 'Snag':
      return PushKind.snag;
    case 'c2o_finding' || 'C2oFinding':
      return PushKind.finding;
    case 'Permit' || 'PermitToWork':
      return PushKind.permit;
    case 'ar_install_request' || 'ArInstallRequest':
      return PushKind.arInstall;
    case 'Technician':
      return PushKind.certification;
    case 'Inspection' || 'InspectionAssignment':
      return PushKind.newWork;
    case 'FlowAgentSuggestion':
      return PushKind.alert;
  }
  final isOrder = orderTypeForEntity(type) != null;
  if (isOrder && (d.type == 'warning' || d.type == 'error')) return PushKind.atRisk;
  if (isOrder) return PushKind.newWork;
  return PushKind.general;
}

/// Same rules as the server's `noticeGroupOf`. The server's `group` key wins.
NoticeGroup pushGroupOf(PushData d) =>
    d.group ?? noticeGroupFor(entityType: d.entityType, category: d.category);

/// The group of a stored notification or a push, from the v1 keys only.
NoticeGroup noticeGroupFor({String? entityType, String? category}) {
  final t = entityType?.trim() ?? '';
  if (t.startsWith('conversation:') || t.startsWith('session:') || t == 'conversation' || t == 'agent_session') {
    return NoticeGroup.messages;
  }
  if (t == 'schedule' || t.startsWith('schedule:') || t == 'user_schedule' || t == 'UserSchedule') {
    return NoticeGroup.schedules;
  }
  switch (t) {
    case 'Snag' || 'c2o_finding' || 'C2oFinding':
      return NoticeGroup.snags;
    case 'Permit' || 'PermitToWork':
      return NoticeGroup.permits;
    case 'Inspection' ||
          'InspectionAssignment' ||
          'c2o_route_assignment' ||
          'ar_install_request' ||
          'ArInstallRequest' ||
          'C2oFieldVerification' ||
          'FlowAgentSuggestion':
      return NoticeGroup.work;
    case 'Technician':
      return NoticeGroup.system;
  }
  if (orderTypeForEntity(t) != null) return NoticeGroup.work;
  return switch (category) {
    'ai_conversation' => NoticeGroup.messages,
    'work_order' || 'maintenance' => NoticeGroup.work,
    _ => NoticeGroup.system,
  };
}

/// Same rules as the server's `noticePriorityOf`. The server's `priority` wins.
NoticePriority pushPriorityOf(PushData d) {
  if (d.priority != null) return d.priority!;
  final t = d.entityType ?? '';
  final type = d.type ?? '';
  final title = d.title ?? '';
  if ((t == 'Permit' || t == 'PermitToWork') && type == 'error') return NoticePriority.critical;
  if (title == kInviteTitle) return NoticePriority.high;
  if (_withdrawnTitles.contains(title)) return NoticePriority.low;
  if (t.startsWith('conversation:')) return t.endsWith(':mention') ? NoticePriority.high : NoticePriority.normal;
  if (t.startsWith('schedule:') || t.startsWith('session:')) {
    if (t.endsWith(':failed')) return NoticePriority.high;
    if (t.endsWith(':started')) return NoticePriority.low;
    return NoticePriority.normal;
  }
  if (type == 'warning' || type == 'error') return NoticePriority.high;
  return NoticePriority.normal;
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

/// The record a thread message belongs to, when a reply can be posted to it:
/// `conversation:<entity>:<kind>` + the record id.
({String entity, String id})? replyTargetOf(PushData d) {
  final t = d.entityType ?? '';
  final id = d.entityId;
  if (!t.startsWith('conversation:') || id == null) return null;
  final parts = t.split(':');
  final entity = parts.length > 1 ? parts[1] : '';
  return kReplyableEntities.contains(entity) ? (entity: entity, id: id) : null;
}

/// The app's own button rules (what an older server, which names no
/// actions, gets). Mirrors the server's `pushActionsOf`. At most two: a third
/// squeezes every label to an ellipsis on a small phone.
List<PushAction> _defaultActions(PushData d) {
  switch (pushKindOf(d)) {
    case PushKind.invite:
      final type = orderTypeForEntity(d.entityType);
      final canAccept = d.entityId != null && _acceptableInviteTypes.contains(type);
      return canAccept
          ? const [PushAction.acceptInvite, PushAction.declineInvite]
          : const [PushAction.open];
    case PushKind.route:
      return const [PushAction.open, PushAction.scan];
    case PushKind.message:
    case PushKind.mention:
      return replyTargetOf(d) != null ? const [PushAction.reply, PushAction.markRead] : const [PushAction.markRead];
    case PushKind.newWork:
    case PushKind.atRisk:
    case PushKind.snag:
    case PushKind.finding:
    case PushKind.permit:
    case PushKind.arInstall:
    case PushKind.certification:
    case PushKind.agentSession:
    case PushKind.schedule:
      return const [PushAction.open, PushAction.markRead];
    case PushKind.alert:
    case PushKind.general:
      return const [PushAction.markRead];
    case PushKind.inviteWithdrawn:
    case PushKind.digest:
      return const [];
  }
}

/// The buttons to draw. A v2 server names them (`actions`); the app keeps
/// only ones that make sense for this kind, so a server can't conjure an
/// Accept on a snag or a Reply where there is no thread.
List<PushAction> pushActionsFor(PushData d) {
  final suggested = d.actions;
  if (suggested == null) return _defaultActions(d);
  final kind = pushKindOf(d);
  bool supported(PushAction a) => switch (a) {
        PushAction.acceptInvite || PushAction.declineInvite =>
          kind == PushKind.invite && _defaultActions(d).contains(PushAction.acceptInvite),
        PushAction.reply => replyTargetOf(d) != null,
        PushAction.scan => kind == PushKind.route,
        PushAction.myOrders => kind == PushKind.newWork || kind == PushKind.atRisk || kind == PushKind.invite,
        PushAction.markRead => d.notificationId != null || !d.isDigest,
        PushAction.open => kind != PushKind.digest,
      };
  final out = <PushAction>[];
  for (final id in suggested) {
    final a = PushAction.fromId(id);
    if (a != null && supported(a) && !out.contains(a)) out.add(a);
    if (out.length == 2) break;
  }
  return out;
}

PushTone pushToneFor(PushData d) {
  if (d.type == 'warning' || d.type == 'error') return PushTone.urgent;
  if (d.type == 'success') return PushTone.good;
  final p = pushPriorityOf(d);
  if (p == NoticePriority.critical) return PushTone.urgent;
  return switch (pushKindOf(d)) {
    PushKind.atRisk || PushKind.certification || PushKind.alert => PushTone.urgent,
    _ => PushTone.normal,
  };
}

/// One notification per thing, not one per event. The key is hashed into the
/// notification id ([pushIdFor]) and a reused id replaces the old one, so a snag that is assigned, rejected and
/// closed shows its latest state once instead of three stacked banners, and
/// an invite that is withdrawn replaces the invite (whose Accept button
/// would now only be refused). Thread messages are the exception: each
/// message is its own entry (they stack in the record's group instead), so a
/// second reply never silently replaces an unread first one.
String? pushTagFor(PushData d) {
  final kind = pushKindOf(d);
  if (kind == PushKind.digest) return 'digest:${d.group?.wire ?? 'all'}';
  final id = d.entityId;
  if (kind == PushKind.message || kind == PushKind.mention) {
    return d.notificationId ?? (id == null ? null : '${d.entityType}:$id');
  }
  if (id == null) return d.notificationId;
  // Invites and their withdrawal share the order's key on purpose (above).
  final scope = kind == PushKind.invite || kind == PushKind.inviteWithdrawn
      ? 'order'
      : (d.entityType ?? 'x');
  return '$scope:$id';
}

/// The group a notification stacks in (Android `groupKey`, iOS
/// `threadIdentifier`): one record's updates together, else the tab.
String pushThreadFor(PushData d) {
  if (d.threadId != null) return d.threadId!;
  final t = d.entityType ?? '';
  final id = d.entityId;
  final group = pushGroupOf(d).wire;
  if (id == null) return group;
  if (t.startsWith('conversation:')) return 'conversation:${t.split(':')[1]}:$id';
  return '$group:${t.isEmpty ? 'x' : t}:$id';
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
    PushKind.finding => t['badge.snag'],
    PushKind.permit => t['badge.permit'],
    PushKind.arInstall => t['badge.ar'],
    PushKind.certification => t['badge.certification'],
    PushKind.message => t['badge.message'],
    PushKind.mention => t['badge.mention'],
    PushKind.agentSession => t['badge.agent'],
    PushKind.schedule => t['badge.schedule'],
    PushKind.alert => t['badge.alert'],
    PushKind.digest || PushKind.general => null,
  };
  // An invite's server title is a fixed routing key, not a headline. The
  // message already says which job ("You have been assigned to WO-0042…"),
  // so the headline can just say what it asks for.
  final String title;
  if (kind == PushKind.invite) {
    title = t['title.invite']!;
  } else if (kind == PushKind.digest) {
    title = (t['title.digest'] ?? '%n').replaceAll('%n', '${d.count ?? d.lines.length}');
  } else {
    title = d.title ?? t['title.fallback']!;
  }
  final badgeText = [?badge, ?d.ref].join(' · ');
  return PushDisplay(title: title, body: d.body, badge: badgeText.isEmpty ? null : badgeText);
}

String pushActionLabel(PushAction a, PushData d, {String lang = 'en'}) {
  final t = _strings(lang);
  return switch (a) {
    PushAction.acceptInvite => t['action.accept']!,
    PushAction.declineInvite => t['action.decline']!,
    PushAction.myOrders => t['action.my_orders']!,
    PushAction.scan => t['action.scan']!,
    PushAction.reply => t['action.reply']!,
    PushAction.markRead => t['action.mark_read']!,
    PushAction.open => switch (pushKindOf(d)) {
        PushKind.invite => t['action.view_invite']!,
        PushKind.newWork || PushKind.atRisk => t['action.open_job']!,
        PushKind.route => t['action.open_route']!,
        PushKind.snag || PushKind.finding => t['action.open_snag']!,
        PushKind.permit => t['action.open_permit']!,
        PushKind.arInstall => t['action.start_install']!,
        PushKind.certification => t['action.view_profile']!,
        _ => t['action.open']!,
      },
  };
}

/// The localised name of a group (Android channel name, summary line).
String noticeGroupLabel(NoticeGroup g, {String lang = 'en'}) => _strings(lang)['group.${g.wire}']!;

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
  'badge.message': 'Message',
  'badge.mention': 'Mentioned you',
  'badge.agent': 'AI teammate',
  'badge.schedule': 'Reminder',
  'badge.alert': 'On-call alert',
  'title.invite': 'A new job is waiting for you',
  'title.fallback': 'Fusion Eco',
  'title.digest': '%n new updates',
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
  'action.reply': 'Reply',
  'action.mark_read': 'Mark read',
  'reply.placeholder': 'Write a reply',
  'reply.send': 'Send',
  'group.work': 'Work',
  'group.snags': 'Snags',
  'group.permits': 'Permits',
  'group.messages': 'Messages and AI teammates',
  'group.schedules': 'Schedules and reminders',
  'group.system': 'Other updates',
  'channel.critical': 'Urgent alarms',
  'channel.critical_desc': 'Safety stops and on-call alarms. These ring even in Do Not Disturb.',
  'channel.work_desc': 'Job offers, new jobs, late jobs and routes.',
  'channel.snags_desc': 'Snags assigned to you and their updates.',
  'channel.permits_desc': 'Permit approvals, changes and stops.',
  'channel.messages_desc': 'Replies, mentions and AI teammates.',
  'channel.schedules_desc': 'Your reminders and scheduled checks.',
  'channel.system_desc': 'Certification reminders and everything else.',
  'summary.more': '+%n more',
  'result.accepted': 'Job accepted. Opening it now.',
  'result.accepted_offline': 'Accepted offline. It will be sent when you are back online.',
  'result.accept_failed': 'That did not send. Please answer the invite here.',
  'result.reply_sent': 'Reply sent.',
  'result.reply_queued': 'Reply saved. It will be sent when you are back online.',
  'result.reply_failed': 'That reply did not send. Please try again here.',
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
  'badge.message': 'رسالة',
  'badge.mention': 'أشار إليك',
  'badge.agent': 'زميل ذكاء اصطناعي',
  'badge.schedule': 'تذكير',
  'badge.alert': 'تنبيه مناوبة',
  'title.invite': 'مهمة جديدة بانتظارك',
  'title.fallback': 'Fusion Eco',
  'title.digest': '%n تحديثات جديدة',
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
  'action.reply': 'رد',
  'action.mark_read': 'تعليم كمقروء',
  'reply.placeholder': 'اكتب ردًا',
  'reply.send': 'إرسال',
  'group.work': 'العمل',
  'group.snags': 'الملاحظات',
  'group.permits': 'التصاريح',
  'group.messages': 'الرسائل وزملاء الذكاء الاصطناعي',
  'group.schedules': 'الجداول والتذكيرات',
  'group.system': 'تحديثات أخرى',
  'channel.critical': 'إنذارات عاجلة',
  'channel.critical_desc': 'إيقافات السلامة وإنذارات المناوبة. ترن حتى في وضع عدم الإزعاج.',
  'channel.work_desc': 'عروض العمل والمهام الجديدة والمتأخرة والمسارات.',
  'channel.snags_desc': 'الملاحظات المسندة إليك وتحديثاتها.',
  'channel.permits_desc': 'موافقات التصاريح وتغييراتها وإيقافها.',
  'channel.messages_desc': 'الردود والإشارات وزملاء الذكاء الاصطناعي.',
  'channel.schedules_desc': 'تذكيراتك وفحوصاتك المجدولة.',
  'channel.system_desc': 'تذكيرات الشهادات وكل ما عدا ذلك.',
  'summary.more': '+%n أخرى',
  'result.accepted': 'تم قبول المهمة. جارٍ فتحها الآن.',
  'result.accepted_offline': 'تم القبول دون اتصال. سيتم الإرسال عند عودة الاتصال.',
  'result.accept_failed': 'لم يتم الإرسال. يرجى الرد على الدعوة هنا.',
  'result.reply_sent': 'تم إرسال الرد.',
  'result.reply_queued': 'تم حفظ الرد. سيتم إرساله عند عودة الاتصال.',
  'result.reply_failed': 'لم يتم إرسال الرد. يرجى المحاولة مرة أخرى هنا.',
};

/// A localised push string by key (falls back to English, then empty).
String pushText(String key, {String lang = 'en'}) => _strings(lang)[key] ?? pushStringsEn[key] ?? '';

/// A result message shown after a tray action ran in the app.
String pushResultText(String key, {String lang = 'en'}) => pushText(key, lang: lang);

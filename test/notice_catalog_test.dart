import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/app/router.dart';
import 'package:technician_portal/core/push/local_notifications.dart';
import 'package:technician_portal/core/push/push_content.dart';
import 'package:technician_portal/core/push/push_service.dart';
import 'package:technician_portal/core/utils/notification_route.dart';

/// Every notification type the server creates for a technician, with the
/// REAL strings each service sends (grep `createNotification(` / `notifyRaw(`
/// in fusion-eco-server/src). The group / priority / actions columns are the
/// same fixtures as the server's `services/push/__tests__/pushPayload.test.ts`
/// — the two sides must agree, or a tray button and an iOS category drift.
const _id = '8b0c5c1e-2f8a-4a57-9d1e-3c2b1a0f9e77';

class _Case {
  const _Case(this.name, this.data, {required this.group, required this.priority, required this.actions, required this.route});

  final String name;
  final Map<String, String> data;
  final NoticeGroup group;
  final NoticePriority priority;
  final List<PushAction> actions;

  /// Where a tap goes; null = the details sheet.
  final String? route;
}

final _cases = <_Case>[
  const _Case('invite (assignmentInviteService)',
      {'title': 'New assignment invite', 'body': 'WO WO-0042 is waiting for you.', 'entityId': _id, 'entityType': 'work_order', 'type': 'info', 'category': 'work_order'},
      group: NoticeGroup.work, priority: NoticePriority.high, actions: [PushAction.acceptInvite, PushAction.declineInvite], route: '/invites'),
  const _Case('annual invite has no Accept',
      {'title': 'New assignment invite', 'entityId': _id, 'entityType': 'annual_maintenance', 'type': 'info', 'category': 'maintenance'},
      group: NoticeGroup.work, priority: NoticePriority.high, actions: [PushAction.open], route: '/invites'),
  const _Case('invite withdrawn',
      {'title': 'Assignment reassigned', 'entityId': _id, 'entityType': 'preventive_maintenance', 'type': 'info', 'category': 'maintenance'},
      group: NoticeGroup.work, priority: NoticePriority.low, actions: [], route: '/orders'),
  const _Case('PM-generated WO (pmWorkOrderGenerationService)',
      {'title': 'Scheduled job assigned to you', 'entityId': _id, 'entityType': 'WorkOrder', 'link': '/technician/orders/work-order/$_id', 'type': 'info', 'category': 'work_order'},
      group: NoticeGroup.work, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/orders/work-order/$_id'),
  const _Case('SLA warning (slaNotifyService, no link)',
      {'title': 'WO-0042: 30 min left to stay on time', 'entityId': _id, 'entityType': 'WorkOrder', 'type': 'warning', 'category': 'work_order'},
      group: NoticeGroup.work, priority: NoticePriority.high, actions: [PushAction.open, PushAction.markRead], route: '/orders/work-order/$_id'),
  const _Case('PM overdue (pmEscalationService)',
      {'title': 'Preventive maintenance overdue', 'entityId': _id, 'entityType': 'PreventiveMaintenance', 'type': 'warning', 'category': 'maintenance'},
      group: NoticeGroup.work, priority: NoticePriority.high, actions: [PushAction.open, PushAction.markRead], route: '/orders/preventive/$_id'),
  const _Case('inspection assigned (inspectionController)',
      {'title': 'New Inspection Assigned', 'entityId': _id, 'entityType': 'Inspection', 'link': '/technician/inspections/$_id', 'type': 'info', 'category': 'maintenance'},
      group: NoticeGroup.work, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/inspections/$_id'),
  const _Case('C2O route (routeAssignmentService)',
      {'title': 'Route assigned to you', 'entityId': _id, 'entityType': 'c2o_route_assignment', 'link': '/technician/c2o-routes', 'type': 'info', 'category': 'asset'},
      group: NoticeGroup.work, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.scan], route: '/c2o-routes'),
  const _Case('AR install (installRequestService)',
      {'title': 'Put up 3 AR boards', 'entityId': _id, 'entityType': 'ar_install_request', 'link': '/technician/ar/install?floorId=$_id', 'type': 'info', 'category': 'asset'},
      group: NoticeGroup.work, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/ar/install?floorId=$_id'),
  const _Case('snag (snagService)',
      {'title': 'Snag assigned to you', 'entityId': _id, 'entityType': 'Snag', 'link': '/technician/snags/$_id', 'type': 'info', 'category': 'maintenance'},
      group: NoticeGroup.snags, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/snags/$_id'),
  const _Case('own C2O finding (fieldVerificationService, web-only link)',
      {'title': 'Finding raised from your check', 'entityId': _id, 'entityType': 'c2o_finding', 'link': '/c2o/findings/$_id', 'type': 'warning', 'category': 'asset'},
      group: NoticeGroup.snags, priority: NoticePriority.high, actions: [PushAction.open, PushAction.markRead], route: null),
  const _Case('permit approved (ptwService)',
      {'title': 'Permit approved', 'entityId': _id, 'entityType': 'PermitToWork', 'link': '/technician/permits/$_id', 'type': 'success', 'category': 'maintenance'},
      group: NoticeGroup.permits, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/permits/$_id'),
  const _Case('permit suspended (ptwService error tone)',
      {'title': 'Permit suspended', 'entityId': _id, 'entityType': 'PermitToWork', 'link': '/technician/permits/$_id', 'type': 'error', 'category': 'maintenance'},
      group: NoticeGroup.permits, priority: NoticePriority.critical, actions: [PushAction.open, PushAction.markRead], route: '/permits/$_id'),
  const _Case('permit, admin link on a technician copy → entity rule',
      {'title': 'Permit changed', 'entityId': _id, 'entityType': 'PermitToWork', 'link': '/facility-management/permits/$_id', 'type': 'info', 'category': 'maintenance'},
      group: NoticeGroup.permits, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/permits/$_id'),
  const _Case('mention (conversations/notify.ts)',
      {'title': 'Asha mentioned you on SN-00006', 'entityId': _id, 'entityType': 'conversation:snag:mention', 'link': '/facility-management/snags?snag=$_id&message=m1', 'type': 'info', 'category': 'user'},
      group: NoticeGroup.messages, priority: NoticePriority.high, actions: [PushAction.reply, PushAction.markRead], route: '/conversations/snag/$_id?message=m1'),
  const _Case('agent reply on a WO',
      {'title': 'Flow Agent replied to you on WO-161', 'entityId': _id, 'entityType': 'conversation:work_order:reply', 'link': '/facility-management/work-order/view/$_id?tab=comments&message=m2', 'type': 'info', 'category': 'ai_conversation'},
      group: NoticeGroup.messages, priority: NoticePriority.normal, actions: [PushAction.reply, PushAction.markRead], route: '/orders/work-order/$_id?tab=comments&message=m2'),
  const _Case('session done (live.ts, technician link)',
      {'title': 'Flow Agent finished on WO-161', 'entityId': _id, 'entityType': 'session:done', 'link': '/technician/orders/work-order/$_id', 'type': 'success', 'category': 'ai_conversation'},
      group: NoticeGroup.messages, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/orders/work-order/$_id'),
  const _Case('schedule reminder (schedules/execute.ts)',
      {'title': 'Reminder: Check pump', 'entityId': _id, 'entityType': 'schedule:done', 'link': '/technician/schedules/$_id', 'type': 'success', 'category': 'ops'},
      group: NoticeGroup.schedules, priority: NoticePriority.normal, actions: [PushAction.open, PushAction.markRead], route: '/schedules/$_id'),
  const _Case('schedule failed',
      {'title': "Couldn't finish: Check pump", 'entityId': _id, 'entityType': 'schedule:failed', 'link': '/technician/schedules/$_id', 'type': 'error', 'category': 'ops'},
      group: NoticeGroup.schedules, priority: NoticePriority.high, actions: [PushAction.open, PushAction.markRead], route: '/schedules/$_id'),
  const _Case('certification (certificationExpiryService)',
      {'title': 'Certification expiring soon', 'entityId': _id, 'entityType': 'Technician', 'type': 'warning', 'category': 'user'},
      group: NoticeGroup.system, priority: NoticePriority.high, actions: [PushAction.open, PushAction.markRead], route: '/profile'),
  const _Case('on-call page (flowAgents notify.oncall, critical, web-only link)',
      {'title': 'On-call: Chiller trip', 'entityId': _id, 'entityType': 'FlowAgentSuggestion', 'link': '/flow-agents/drafts?item=$_id', 'type': 'warning', 'category': 'ops', 'priority': 'critical'},
      group: NoticeGroup.work, priority: NoticePriority.critical, actions: [PushAction.markRead], route: null),
  const _Case('photo-check flag on an inspection (flowAgents evidence)',
      {'title': 'Photo check: INS-0007', 'entityId': _id, 'entityType': 'InspectionAssignment', 'link': '/facility-management/inspections/x/responses/$_id', 'type': 'warning', 'category': 'maintenance'},
      group: NoticeGroup.work, priority: NoticePriority.high, actions: [PushAction.open, PushAction.markRead], route: '/inspections/$_id'),
  const _Case('unknown admin-only type → details sheet',
      {'title': 'Storage almost full', 'entityType': 'storage', 'link': '/settings', 'type': 'warning', 'category': 'system'},
      group: NoticeGroup.system, priority: NoticePriority.high, actions: [PushAction.markRead], route: null),
];

String? _routeOf(PushData d) => routeForNotificationFields(
      link: d.link,
      entityId: d.entityId,
      entityType: d.entityType,
      title: d.title,
      route: d.route,
      group: d.group?.wire,
    );

void main() {
  group('every server notification type (shared fixtures with the server)', () {
    for (final c in _cases) {
      test(c.name, () {
        final d = PushData.fromMap(c.data);
        expect(pushGroupOf(d), c.group, reason: 'group');
        expect(pushPriorityOf(d), c.priority, reason: 'priority');
        expect(pushActionsFor(d), c.actions, reason: 'actions');
        expect(_routeOf(d), c.route, reason: 'route');
        if (c.route != null) expect(isKnownAppRoute(c.route!), isTrue, reason: 'route must exist in router.dart');
      });
    }
  });

  group('one routing function for every entry point', () {
    test('a tap with no screen opens the details sheet for that notification, never nothing', () {
      final d = PushData.fromMap({'title': 'Finding raised', 'entityType': 'c2o_finding', 'entityId': _id, 'notificationId': 'n9'});
      expect(PushService.targetFor(d), '/notifications?open=n9');
      expect(PushService.targetFor(const PushData(title: 'x')), '/notifications');
    });

    test('a digest opens the list on its tab', () {
      final d = PushData.fromMap({'v': '2', 'kind': 'digest', 'entityType': 'digest', 'group': 'snags', 'count': '3'});
      expect(PushService.targetFor(d), '/notifications?group=snags');
    });

    test('a technician link to a screen this app lacks falls through to the entity rule', () {
      expect(
        routeForNotificationFields(link: '/technician/no-such-page/1', entityType: 'Snag', entityId: 's1'),
        '/snags/s1',
      );
      expect(routeForNotificationFields(link: '/technician/no-such-page/1'), isNull);
    });

    test("the server's v2 route key is used when nothing else matches", () {
      expect(routeForNotificationFields(entityType: 'brand_new_type', entityId: 'x', route: '/technician/permits/p1'), '/permits/p1');
      expect(routeForNotificationFields(entityType: 'brand_new_type', entityId: 'x', route: '/facility-management/x'), isNull);
    });

    test('every entity rule lands on a registered route', () {
      for (final e in kNoticeEntityRoutes.entries) {
        expect(isKnownAppRoute(e.value('id-1')), isTrue, reason: e.key);
      }
    });

    test('kAppRoutePatterns matches router.dart exactly (no stale or missing screen)', () {
      final src = File('lib/app/router.dart').readAsStringSync();
      final consts = {
        for (final m in RegExp(r"static const (\w+) = '([^']+)';").allMatches(src)) m.group(1)!: m.group(2)!,
      };
      final registered = <String>{
        for (final m in RegExp(r"GoRoute\(\s*path: '([^']+)'").allMatches(src)) m.group(1)!,
        for (final m in RegExp(r'GoRoute\(\s*path: Routes\.(\w+),').allMatches(src)) ?consts[m.group(1)!],
      }..remove('/login');
      expect(kAppRoutePatterns.toSet(), registered);
    });

    test('Routes.notificationsFor builds the query', () {
      expect(Routes.notificationsFor(), '/notifications');
      expect(Routes.notificationsFor(group: 'work', open: 'n1'), '/notifications?group=work&open=n1');
    });
  });

  group('payload v2 parsing', () {
    test('reads the rich keys; drops a non-http image', () {
      final d = PushData.fromMap({
        'title': 'Snag assigned', 'v': '2', 'group': 'snags', 'priority': 'high', 'actions': 'open,mark_read',
        'threadId': 'snags:Snag:1', 'route': '/technician/snags/1', 'imageUrl': 'https://x.example.com/a.jpg',
        'ref': 'SN-00006', 'location': 'Tower A', 'badge': '7',
      });
      expect(d.group, NoticeGroup.snags);
      expect(d.priority, NoticePriority.high);
      expect(d.actions, ['open', 'mark_read']);
      expect(d.threadId, 'snags:Snag:1');
      expect(d.imageUrl, 'https://x.example.com/a.jpg');
      expect(d.ref, 'SN-00006');
      expect(d.badge, 7);
      expect(PushData.fromMap({'imageUrl': 'file:///etc/passwd'}).imageUrl, isNull);
    });

    test('an older server (no v) → the app picks the buttons itself', () {
      final d = PushData.fromMap({'title': 'x', 'entityType': 'Snag', 'entityId': 's', 'actions': 'reply'});
      expect(d.actions, isNull);
      expect(pushActionsFor(d), [PushAction.open, PushAction.markRead]);
    });

    test('the server cannot conjure a button that makes no sense for the kind', () {
      final snag = PushData.fromMap({'v': '2', 'entityType': 'Snag', 'entityId': 's', 'actions': 'invite_accept,reply,scan,open', 'notificationId': 'n'});
      expect(pushActionsFor(snag), [PushAction.open]);
      final none = PushData.fromMap({'v': '2', 'entityType': 'WorkOrder', 'entityId': 'w', 'actions': ''});
      expect(pushActionsFor(none), isEmpty);
    });

    test('a digest: count, lines, ids, headline', () {
      final d = PushData.fromMap({
        'v': '2', 'kind': 'digest', 'entityType': 'digest', 'title': '3 new updates', 'count': '3',
        'lines': '["A","B","C"]', 'notificationIds': 'n1,n2,n3', 'group': 'work',
      });
      expect(pushKindOf(d), PushKind.digest);
      expect(d.lines, ['A', 'B', 'C']);
      expect(d.notificationIds, ['n1', 'n2', 'n3']);
      expect(pushDisplayFor(d).title, '3 new updates');
      expect(pushDisplayFor(d, lang: 'ar').title, contains('3'));
      expect(pushTagFor(d), 'digest:work');
    });

    test('thread messages each get their own tray entry; a record update replaces its last one', () {
      final m1 = PushData.fromMap({'entityType': 'conversation:snag:message', 'entityId': 's', 'notificationId': 'n1'});
      final m2 = PushData.fromMap({'entityType': 'conversation:snag:message', 'entityId': 's', 'notificationId': 'n2'});
      expect(pushTagFor(m1), isNot(pushTagFor(m2)));
      expect(pushThreadFor(m1), pushThreadFor(m2));
      final s1 = PushData.fromMap({'entityType': 'Snag', 'entityId': 's', 'notificationId': 'n3'});
      final s2 = PushData.fromMap({'entityType': 'Snag', 'entityId': 's', 'notificationId': 'n4'});
      expect(pushTagFor(s1), pushTagFor(s2));
    });

    test('the badge line carries the record ref', () {
      final d = PushData.fromMap({'title': 'Permit approved', 'entityType': 'PermitToWork', 'entityId': 'p', 'ref': 'PTW-0009', 'v': '2'});
      expect(pushDisplayFor(d).badge, 'Permit · PTW-0009');
    });
  });

  group('tray buttons on both platforms', () {
    test('every button set a fixture produces has a registered iOS category (server sends its id)', () {
      final registered = LocalNotifications.darwinActionSets.map(LocalNotifications.darwinCategoryId).toSet();
      for (final c in _cases) {
        final actions = pushActionsFor(PushData.fromMap(c.data));
        if (actions.isEmpty) continue;
        expect(registered, contains(LocalNotifications.darwinCategoryId(actions)), reason: c.name);
      }
      // The id format the server computes (pushPayload.ts darwinCategoryFor).
      expect(LocalNotifications.darwinCategoryId([PushAction.reply, PushAction.markRead]), 'fe_reply_mark_read');
    });

    test('only Mark read stays in the background', () {
      expect([for (final a in PushAction.values) if (a.runsInBackground) a], [PushAction.markRead]);
    });

    test('a reply target only for records the conversation API knows', () {
      expect(replyTargetOf(PushData.fromMap({'entityType': 'conversation:permit:reply', 'entityId': 'p'})), (entity: 'permit', id: 'p'));
      expect(replyTargetOf(PushData.fromMap({'entityType': 'conversation:unknown:reply', 'entityId': 'p'})), isNull);
      expect(replyTargetOf(PushData.fromMap({'entityType': 'conversation:snag:reply'})), isNull);
    });

    test('a channel per group, plus the alarm and quiet channels', () {
      final ids = {
        for (final g in NoticeGroup.values)
          for (final p in NoticePriority.values) LocalNotifications.channelIdFor(g, p),
      };
      expect(ids, {'fe_work', 'fe_snags', 'fe_permits', 'fe_messages', 'fe_schedules', 'fcm_default_channel', 'fe_critical', 'fe_quiet'});
      expect(LocalNotifications.channelIdFor(NoticeGroup.permits, NoticePriority.critical), 'fe_critical');
      expect(LocalNotifications.channelIdFor(NoticeGroup.work, NoticePriority.low), 'fe_quiet');
    });

    test('every push string exists in both languages', () {
      expect(pushStringsAr.keys.toSet(), pushStringsEn.keys.toSet());
      for (final g in NoticeGroup.values) {
        expect(pushStringsEn['group.${g.wire}'], isNotNull);
        expect(pushStringsEn['channel.${g.wire}_desc'], isNotNull);
      }
    });
  });
}

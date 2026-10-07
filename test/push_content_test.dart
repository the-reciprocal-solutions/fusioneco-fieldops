import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/push/push_content.dart';
import 'package:technician_portal/core/utils/notification_route.dart';
import 'package:technician_portal/domain/maintenance_record.dart';

PushData _push({
  String? title,
  String? body,
  String? entityType,
  String? entityId,
  String? type,
  String? link,
}) =>
    PushData.fromMap({
      'title': ?title,
      'body': ?body,
      'entityType': ?entityType,
      'entityId': ?entityId,
      'type': ?type,
      'link': ?link,
    });

void main() {
  group('PushData.fromMap', () {
    test('treats empty strings as absent (the server sends "" for no value)', () {
      final d = PushData.fromMap({'title': 'Hi', 'body': '', 'entityId': '  ', 'notificationId': 'n1'});
      expect(d.title, 'Hi');
      expect(d.body, isNull);
      expect(d.entityId, isNull);
      expect(d.notificationId, 'n1');
    });
  });

  group('kind', () {
    test('invite is recognised by its fixed server title, whatever the entity spelling', () {
      expect(pushKindOf(_push(title: kInviteTitle, entityType: 'work_order', entityId: 'w')), PushKind.invite);
      expect(pushKindOf(_push(title: kInviteTitle, entityType: 'WorkOrder', entityId: 'w')), PushKind.invite);
    });

    test('a warning on an order is at risk, an info one is new work', () {
      expect(pushKindOf(_push(entityType: 'WorkOrder', entityId: 'w', type: 'warning')), PushKind.atRisk);
      expect(pushKindOf(_push(entityType: 'PreventiveMaintenance', entityId: 'p', type: 'info')), PushKind.newWork);
      expect(pushKindOf(_push(entityType: 'Inspection', entityId: 'i')), PushKind.newWork);
    });

    test('feature entities map to their own kinds', () {
      expect(pushKindOf(_push(entityType: 'c2o_route_assignment')), PushKind.route);
      expect(pushKindOf(_push(entityType: 'Snag')), PushKind.snag);
      expect(pushKindOf(_push(entityType: 'PermitToWork')), PushKind.permit);
      expect(pushKindOf(_push(entityType: 'ar_install_request')), PushKind.arInstall);
      expect(pushKindOf(_push(entityType: 'Technician')), PushKind.certification);
      expect(pushKindOf(_push(entityType: 'room_booking')), PushKind.general);
    });

    test('a withdrawn invite is its own kind', () {
      expect(pushKindOf(_push(title: 'Assignment reassigned', entityType: 'work_order', entityId: 'w')), PushKind.inviteWithdrawn);
    });
  });

  group('actions', () {
    test('an invite on a respondable type offers Accept and Decline', () {
      for (final t in ['work_order', 'preventive_maintenance', 'reactive_maintenance']) {
        expect(
          pushActionsFor(_push(title: kInviteTitle, entityType: t, entityId: 'x')),
          [PushAction.acceptInvite, PushAction.declineInvite],
          reason: t,
        );
      }
    });

    test('an annual invite has no respond route, so it only opens the inbox', () {
      expect(pushActionsFor(_push(title: kInviteTitle, entityType: 'annual_maintenance', entityId: 'a')), [PushAction.open]);
    });

    test('an invite without an id cannot be accepted from the tray', () {
      expect(pushActionsFor(_push(title: kInviteTitle, entityType: 'work_order')), [PushAction.open]);
    });

    test('new work and at-risk work offer the job and the order list', () {
      expect(pushActionsFor(_push(entityType: 'WorkOrder', entityId: 'w')), [PushAction.open, PushAction.myOrders]);
      expect(pushActionsFor(_push(entityType: 'WorkOrder', entityId: 'w', type: 'warning')), [PushAction.open, PushAction.myOrders]);
    });

    test('routes offer the scanner; general and withdrawn offer nothing', () {
      expect(pushActionsFor(_push(entityType: 'c2o_route_assignment', entityId: 'r')), [PushAction.open, PushAction.scan]);
      expect(pushActionsFor(_push(entityType: 'room_booking')), isEmpty);
      expect(pushActionsFor(_push(title: 'Assignment reassigned', entityType: 'work_order', entityId: 'w')), isEmpty);
    });

    test('no kind gets more than two buttons', () {
      for (final kind in PushKind.values) {
        final sample = switch (kind) {
          PushKind.invite => _push(title: kInviteTitle, entityType: 'work_order', entityId: 'x'),
          PushKind.inviteWithdrawn => _push(title: 'Assignment reassigned', entityType: 'work_order', entityId: 'x'),
          PushKind.newWork => _push(entityType: 'WorkOrder', entityId: 'x'),
          PushKind.atRisk => _push(entityType: 'WorkOrder', entityId: 'x', type: 'warning'),
          PushKind.route => _push(entityType: 'c2o_route_assignment', entityId: 'x'),
          PushKind.snag => _push(entityType: 'Snag', entityId: 'x'),
          PushKind.permit => _push(entityType: 'PermitToWork', entityId: 'x'),
          PushKind.arInstall => _push(entityType: 'ar_install_request', entityId: 'x'),
          PushKind.certification => _push(entityType: 'Technician', entityId: 'x'),
          PushKind.general => _push(),
        };
        expect(pushKindOf(sample), kind);
        expect(pushActionsFor(sample).length, lessThanOrEqualTo(2), reason: kind.name);
      }
    });

    test('action ids round-trip, unknown ids are a plain tap', () {
      for (final a in PushAction.values) {
        expect(PushAction.fromId(a.id), a);
      }
      expect(PushAction.fromId(null), isNull);
      expect(PushAction.fromId('gone'), isNull);
    });
  });

  group('display', () {
    test('the server message becomes the body; an invite gets a real headline', () {
      final d = pushDisplayFor(_push(title: kInviteTitle, body: 'Work Order WO-1 is waiting for you.', entityType: 'work_order', entityId: 'w'));
      expect(d.title, isNot(kInviteTitle));
      expect(d.body, 'Work Order WO-1 is waiting for you.');
      expect(d.badge, isNotNull);
    });

    test('other kinds keep the server title; a missing title falls back to the brand', () {
      expect(pushDisplayFor(_push(title: 'Snag closed', entityType: 'Snag')).title, 'Snag closed');
      expect(pushDisplayFor(_push()).title, 'Fusion Eco');
      expect(pushDisplayFor(_push()).badge, isNull);
    });

    test('Arabic labels are used when the app is in Arabic', () {
      final d = _push(title: kInviteTitle, entityType: 'work_order', entityId: 'w');
      expect(pushActionLabel(PushAction.acceptInvite, d, lang: 'ar'), pushStringsAr['action.accept']);
      expect(pushDisplayFor(d, lang: 'ar').title, pushStringsAr['title.invite']);
    });

    test('both languages define every key', () {
      expect(pushStringsAr.keys.toSet(), pushStringsEn.keys.toSet());
    });

    test('urgent tone for warnings and at-risk kinds', () {
      expect(pushToneFor(_push(entityType: 'WorkOrder', entityId: 'w', type: 'warning')), PushTone.urgent);
      expect(pushToneFor(_push(entityType: 'Technician')), PushTone.urgent);
      expect(pushToneFor(_push(entityType: 'Snag', type: 'success')), PushTone.good);
      expect(pushToneFor(_push(entityType: 'Snag')), PushTone.normal);
    });
  });

  group('tag and id', () {
    test('an invite and its withdrawal share a slot, so the withdrawal replaces it', () {
      final invite = pushTagFor(_push(title: kInviteTitle, entityType: 'work_order', entityId: 'w1'));
      final gone = pushTagFor(_push(title: 'Assignment reassigned', entityType: 'work_order', entityId: 'w1'));
      expect(invite, gone);
    });

    test('different records never share a slot', () {
      expect(pushTagFor(_push(entityType: 'Snag', entityId: 'a')), isNot(pushTagFor(_push(entityType: 'Snag', entityId: 'b'))));
    });

    test('the id hash is stable and fits a 31-bit int', () {
      expect(pushIdFor('Snag:abc'), pushIdFor('Snag:abc'));
      expect(pushIdFor('Snag:abc'), isNot(pushIdFor('Snag:abd')));
      expect(pushIdFor('Snag:abc'), inInclusiveRange(0, 0x7fffffff));
    });
  });

  group('order entity spellings', () {
    test('PascalCase and snake_case both resolve', () {
      expect(orderTypeForEntity('WorkOrder'), OrderType.workOrder);
      expect(orderTypeForEntity('work_order'), OrderType.workOrder);
      expect(orderTypeForEntity('preventive_maintenance'), OrderType.preventive);
      expect(orderTypeForEntity('Snag'), isNull);
    });
  });

  group('shared routing (push and bell list)', () {
    test('a withdrawn invite opens the order list, not the job it lost', () {
      expect(
        routeForNotificationFields(title: 'Assignment reassigned', entityType: 'work_order', entityId: 'w'),
        '/orders',
      );
    });

    test('a certification reminder opens the profile', () {
      expect(routeForNotificationFields(entityType: 'Technician', entityId: 't1'), '/profile');
    });

    test('snake_case order entities open the job', () {
      expect(routeForNotificationFields(entityType: 'preventive_maintenance', entityId: 'p1'), '/orders/preventive/p1');
    });

    test('the technician PM work-order link maps straight across', () {
      expect(routeForNotificationFields(link: '/technician/orders/work-order/w9', entityType: 'WorkOrder', entityId: 'w9'), '/orders/work-order/w9');
    });
  });
}

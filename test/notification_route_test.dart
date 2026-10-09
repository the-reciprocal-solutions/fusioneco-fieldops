import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/app/router.dart';
import 'package:technician_portal/core/utils/notification_route.dart';
import 'package:technician_portal/domain/app_notification.dart';

AppNotification _notification({
  String title = 'Update',
  String? entityId,
  String? entityType,
  String? link,
}) =>
    AppNotification(
      id: 'n1',
      title: title,
      message: '',
      type: 'info',
      entityId: entityId,
      entityType: entityType,
      link: link,
    );

void main() {
  group('notification routing', () {
    test('each entity type opens its own detail route', () {
      expect(
        routeForNotification(
          _notification(entityType: 'WorkOrder', entityId: 'wo-1'),
        ),
        '/orders/work-order/wo-1',
      );
      expect(
        routeForNotification(
          _notification(entityType: 'ReactiveMaintenance', entityId: 'rm-1'),
        ),
        '/orders/reactive/rm-1',
      );
      expect(
        routeForNotification(
          _notification(entityType: 'PreventiveMaintenance', entityId: 'pm-1'),
        ),
        '/orders/preventive/pm-1',
      );
      expect(
        routeForNotification(
          _notification(entityType: 'AnnualMaintenance', entityId: 'amc-1'),
        ),
        '/orders/annual/amc-1',
      );
    });

    test('an assignment invite goes to the inbox, not the task page', () {
      // The exact and only title assignmentInviteService.ts uses.
      expect(
        routeForNotification(
          _notification(
            title: 'New assignment invite',
            entityType: 'WorkOrder',
            entityId: 'wo-1',
          ),
        ),
        '/invites',
      );
    });

    test('a link wins over the entity, with the portal prefix dropped', () {
      expect(
        routeForNotification(
          _notification(
            link: '/technician/orders/annual/amc-9',
            entityType: 'WorkOrder',
            entityId: 'wo-1',
          ),
        ),
        '/orders/annual/amc-9',
      );
    });

    test('a link into another portal has nowhere to go here', () {
      expect(
        routeForNotification(
          _notification(link: '/facility-management/work-order/view/wo-1'),
        ),
        isNull,
      );
    });

    test('an AI conversation has no screen in this app', () {
      expect(
        routeForNotification(
          _notification(entityType: 'conversation', entityId: 'sess-1'),
        ),
        isNull,
      );
    });

    test('the invite inbox is a shell tab, so it is switched to not pushed', () {
      // Pushing a branch route onto the root navigator reserves that branch's
      // navigator key twice, which throws inside Navigator and kills the app.
      expect(Routes.isShellBranch(Routes.invites), isTrue);
      expect(Routes.isShellBranch(Routes.orders), isTrue);
      expect(Routes.isShellBranch(Routes.orderDetail('work-order', 'wo-1')),
          isFalse);
      expect(Routes.isShellBranch(Routes.notifications), isFalse);
    });

    test('an unknown or incomplete notification stays put', () {
      expect(routeForNotification(_notification()), isNull);
      expect(
        routeForNotification(_notification(entityType: 'WorkOrder')),
        isNull,
      );
      // A type the app has no screen for (here a C2O finding) → null, and
      // the caller shows its details sheet instead.
      expect(
        routeForNotification(
          _notification(entityType: 'c2o_finding', entityId: 'f-1'),
        ),
        isNull,
      );
    });
  });
}

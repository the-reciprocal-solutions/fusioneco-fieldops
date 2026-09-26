import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/app/router.dart';
import 'package:technician_portal/core/permit/permit_gas.dart';
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
  group('Permit to Work route builders', () {
    test('permits hub and detail paths', () {
      expect(Routes.permits, '/permits');
      expect(Routes.permitDetail('p1'), '/permits/p1');
    });

    test('permitByToken percent-encodes the token', () {
      // Base64url tokens don't normally need `/` or `+`, but the encoder
      // must not assume that — anything the server ever hands back should
      // survive the round trip through the URL.
      expect(Routes.permitByToken('tok123'), '/permits/by-token/tok123');
      expect(
        Routes.permitByToken('a/b+c'),
        '/permits/by-token/${Uri.encodeComponent('a/b+c')}',
      );
      // And the encoded form actually round-trips back to the raw token.
      final built = Routes.permitByToken('a/b+c');
      final encodedSegment = built.substring('/permits/by-token/'.length);
      expect(Uri.decodeComponent(encodedSegment), 'a/b+c');
    });

    test('permit routes are not bottom-nav shell branches — push is fine', () {
      expect(Routes.isShellBranch(Routes.permits), isFalse);
      expect(Routes.isShellBranch(Routes.permitDetail('p1')), isFalse);
    });
  });

  group('Notification/push routing for Permit to Work', () {
    test('the server link /technician/permits/<id> maps onto permitDetail', () {
      expect(
        routeForNotification(_notification(link: '/technician/permits/p1')),
        Routes.permitDetail('p1'),
      );
    });

    test('entityType "PermitToWork" (the server\'s actual stamp) opens the detail route', () {
      expect(
        routeForNotification(_notification(entityType: 'PermitToWork', entityId: 'p1')),
        Routes.permitDetail('p1'),
      );
    });

    test('entityType "Permit" is kept working too, in case anything still sends it', () {
      expect(
        routeForNotification(_notification(entityType: 'Permit', entityId: 'p1')),
        Routes.permitDetail('p1'),
      );
    });

    test('a link always wins over the entityType fallback', () {
      expect(
        routeForNotification(
          _notification(link: '/technician/permits/p1', entityType: 'PermitToWork', entityId: 'p2'),
        ),
        Routes.permitDetail('p1'),
      );
    });

    test('a permit with no id and no link goes nowhere, not to a broken route', () {
      expect(routeForNotification(_notification(entityType: 'PermitToWork')), isNull);
    });
  });

  group('Scan payload detection for the worksite QR', () {
    test('a scanned /permit-check/<token> URL resolves to the by-token route', () {
      const raw = 'https://fusioneco.app/permit-check/tok123';
      final token = permitCheckTokenFromScan(raw);
      expect(token, isNotNull);
      expect(Routes.permitByToken(token!), '/permits/by-token/tok123');
    });

    test('a non-permit scan (an AR board or the general asset scheme) yields no token', () {
      expect(permitCheckTokenFromScan('HTTPS://fusioneco.app/M/7K3QX9R'), isNull);
      expect(permitCheckTokenFromScan('{"type":"Asset","id":"a1"}'), isNull);
      expect(permitCheckTokenFromScan('WO-00042'), isNull);
    });

    test('the by-token path has a fixed extra segment, distinct from a plain detail path', () {
      // Documents why `router.dart` registers `/permits/by-token/:token` above
      // the generic `/permits/:id`: without that ordering, a token that
      // happened to read "by-token" would be ambiguous with the fixed segment.
      final byTokenPath = Routes.permitByToken('tok123');
      expect(byTokenPath, isNot(equals(Routes.permitDetail('tok123'))));
      expect(byTokenPath.startsWith('/permits/by-token/'), isTrue);
    });
  });
}

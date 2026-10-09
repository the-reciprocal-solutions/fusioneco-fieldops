// FR-5.4 — off-route used to live only on the phone (2026-10-08 review). The
// route a check started from now rides the router as query parameters and
// goes to the server as `routeContext`.
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/app/router.dart';
import 'package:technician_portal/core/c2o/route_pack.dart';
import 'package:technician_portal/core/c2o/route_walk_context.dart';
import 'package:technician_portal/data/field_verification_repository.dart';

void main() {
  const offRoute = RouteWalkContext(scope: RouteScope.level, id: 'L02', offRoute: true);
  const onRoute = RouteWalkContext(scope: RouteScope.package, id: 'pkg-1', offRoute: false);

  test('survives the trip through asset detail and verify URLs', () {
    for (final ctx in [offRoute, onRoute]) {
      final detail = Uri.parse(Routes.assetDetail('a-1', route: ctx));
      expect(detail.path, '/asset/a-1');
      final back = RouteWalkContext.fromQuery(detail.queryParameters)!;
      expect((back.scope, back.id, back.offRoute), (ctx.scope, ctx.id, ctx.offRoute));

      final verify = Uri.parse(Routes.verifyAsset('a-1', assetName: 'Pump', route: ctx));
      expect(verify.queryParameters['name'], 'Pump');
      expect(RouteWalkContext.fromQuery(verify.queryParameters)!.offRoute, ctx.offRoute);
    }
  });

  test('no route means a plain URL and no context', () {
    expect(Routes.assetDetail('a-1'), '/asset/a-1');
    expect(RouteWalkContext.fromQuery(Uri.parse(Routes.verifyAsset('a-1')).queryParameters), isNull);
    expect(RouteWalkContext.fromQuery(const {'routeScope': 'planet', 'routeId': 'x'}), isNull);
    expect(RouteWalkContext.fromQuery(const {'routeScope': 'level'}), isNull);
  });

  test('is sent with the check in the server shape, and only when set', () {
    final json = const FieldVerificationRequest(result: VerificationResult.verified, routeContext: offRoute).toJson();
    expect(json['routeContext'], {'scope': 'level', 'id': 'L02', 'offRoute': true});
    expect(const FieldVerificationRequest(result: VerificationResult.verified).toJson().containsKey('routeContext'), isFalse);
  });

  test("a draft's copy reads back; junk does not", () {
    final back = RouteWalkContext.fromJson(onRoute.toJson())!;
    expect((back.scope, back.id, back.offRoute), (RouteScope.package, 'pkg-1', false));
    expect(RouteWalkContext.fromJson(null), isNull);
    expect(RouteWalkContext.fromJson({'scope': 'level', 'id': 'L1', 'offRoute': 'yes'}), isNull);
  });
}

import 'route_pack.dart';

/// FR-5.4 — the route a check was started from, and whether the asset was on
/// it. Off-route used to exist only on the phone (the scanner's flash and
/// the scan history), so the admin never learned that a route walk strayed
/// (2026-10-08 review). It now rides through asset detail → verify as plain
/// query parameters (this app never passes objects through the router) and
/// is sent with the check as `routeContext`, stored by the server as-is.
class RouteWalkContext {
  const RouteWalkContext({required this.scope, required this.id, required this.offRoute});

  final RouteScope scope;
  final String id;
  final bool offRoute;

  static const _scopeKey = 'routeScope';
  static const _idKey = 'routeId';
  static const _offRouteKey = 'offRoute';

  Map<String, String> toQuery() => {
    _scopeKey: scope.name,
    _idKey: id,
    if (offRoute) _offRouteKey: '1',
  };

  /// Null unless both the scope and the id are there and the scope is real.
  static RouteWalkContext? fromQuery(Map<String, String> query) {
    final scope = RouteScope.values.where((s) => s.name == query[_scopeKey]).firstOrNull;
    final id = query[_idKey];
    if (scope == null || id == null || id.isEmpty) return null;
    return RouteWalkContext(scope: scope, id: id, offRoute: query[_offRouteKey] == '1');
  }

  /// The server's `routeContext` shape (`normaliseRouteContext`).
  Map<String, dynamic> toJson() => {'scope': scope.name, 'id': id, 'offRoute': offRoute};

  /// A draft's copy of [toJson], read back when the form is resumed from
  /// the Sync Center (which knows nothing about routes).
  static RouteWalkContext? fromJson(Object? json) {
    if (json is! Map) return null;
    final scope = RouteScope.values.where((s) => s.name == json['scope']).firstOrNull;
    final id = json['id'];
    final offRoute = json['offRoute'];
    if (scope == null || id is! String || id.isEmpty || offRoute is! bool) return null;
    return RouteWalkContext(scope: scope, id: id, offRoute: offRoute);
  }
}

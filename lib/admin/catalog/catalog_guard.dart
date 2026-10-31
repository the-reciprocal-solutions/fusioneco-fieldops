import '../domain/mobile_catalog.dart';

/// Tab paths, in bottom-nav order. Index = StatefulShellRoute branch index.
const tabPaths = <NavTab, String>{
  NavTab.home: '/home',
  NavTab.efficiency: '/efficiency',
  NavTab.alerts: '/alerts',
  NavTab.operations: '/operations',
  NavTab.more: '/more',
};

const unavailablePath = '/unavailable';

/// One alert's detail (list taps and push deep links). Needs module `alerts`.
String alertPath(String key) => '/alert/${Uri.encodeComponent(key)}';

/// Path of one module's screen. Push deep links land here too.
String modulePath(String moduleId, {String? page}) =>
    Uri(path: '/m/$moduleId', queryParameters: page == null ? null : {'page': page}).toString();

/// One record of a module (Phase 3 detail). Same module check as [modulePath].
String recordPath(String moduleId, String recordId, {String? page}) =>
    Uri(path: '/m/$moduleId/r/${Uri.encodeComponent(recordId)}', queryParameters: page == null ? null : {'page': page}).toString();

/// The catalog half of the router's redirect (FE-mobile.md "Catalog guard").
///
/// Returns where to send the user instead, or null to let them through.
/// While the catalog is still loading ([boot] null) nothing is blocked: the
/// screens show their own loading state, and this runs again once it lands.
String? catalogRedirect(MobileBootstrap? boot, Uri location) {
  if (boot == null) return null;
  final path = location.path;

  for (final entry in tabPaths.entries) {
    if (path == entry.value || path.startsWith('${entry.value}/')) {
      return boot.tabVisible(entry.key) ? null : tabPaths[NavTab.home];
    }
  }

  final segments = location.pathSegments;
  if (segments.isNotEmpty && segments.first == 'alert') {
    return boot.has('alerts') ? null : unavailablePath;
  }
  if (segments.length >= 2 && segments.first == 'm') {
    final module = boot.module(segments[1]);
    if (module == null) return unavailablePath;
    // A page the user may not see (e.g. one Efficiency page switched off).
    final page = location.queryParameters['page'];
    if (page != null && module.pages.isNotEmpty && !module.pages.any((p) => p.id == page)) {
      return unavailablePath;
    }
  }
  return null;
}

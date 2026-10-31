import 'package:technician_portal/admin/catalog/catalog_guard.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

MobileBootstrap _boot(List<MobileModule> modules) => MobileBootstrap(
      role: 'Admin',
      isSuperAdmin: false,
      accessScope: 'all',
      buildings: const [],
      language: 'en',
      license: const LicenseInfo(state: 'active', access: 'full'),
      modules: modules,
      webOnly: const [],
      catalogVersion: 1,
    );

const _eff = MobileModule(
  id: 'efficiency',
  label: 'Building Efficiency',
  group: 'Building Efficiency',
  icon: 'gauge',
  webPath: '/hvac/efficiency',
  navTab: NavTab.efficiency,
  pages: [ModulePage(id: 'overview', label: 'Building health', group: 'Today')],
);
const _plant = MobileModule(id: 'plant_room', label: 'Plant Room', group: 'Building Performance', icon: 'factory', webPath: '/x');

void main() {
  final boot = _boot([_eff, _plant]);
  String? guard(String location, [MobileBootstrap? b]) => catalogRedirect(b, Uri.parse(location));

  test('catalog still loading: nothing is blocked', () {
    expect(guard('/m/anything'), isNull);
    expect(guard('/alerts'), isNull);
  });

  test('module in the catalog: allowed', () {
    expect(guard('/m/plant_room', boot), isNull);
    expect(guard('/m/efficiency?page=overview', boot), isNull);
  });

  test('module not in the catalog: not-available screen', () {
    expect(guard('/m/alerts', boot), unavailablePath);
  });

  test('page switched off inside a visible module: not-available screen', () {
    expect(guard('/m/efficiency?page=savings', boot), unavailablePath);
  });

  test('tabs: Home and More always open, empty tabs go home', () {
    expect(guard('/home', boot), isNull);
    expect(guard('/more', boot), isNull);
    expect(guard('/efficiency', boot), isNull);
    expect(guard('/alerts', boot), '/home');
    expect(guard('/operations', boot), '/home');
  });

  test('bootstrap JSON parses tolerant of missing fields', () {
    final b = MobileBootstrap.fromJson({
      'modules': [
        {'id': 'alerts', 'navTab': 'alerts'},
        {'id': 'x', 'navTab': 'unknown-tab'},
      ],
    });
    expect(b.license.isLocked, isFalse);
    expect(b.forTab(NavTab.alerts).map((m) => m.id), ['alerts']);
    expect(b.forTab(NavTab.more).map((m) => m.id), ['x']);
  });
}

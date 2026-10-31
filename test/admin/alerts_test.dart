import 'package:technician_portal/admin/catalog/catalog_guard.dart';
import 'package:technician_portal/admin/domain/alert.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AlertItem.fromJson', () {
    test('reads the server shape, formats the reading, tolerates gaps', () {
      final a = AlertItem.fromJson({
        'key': 'sa:9',
        'title': 'Chiller 2 supply temp high',
        'severity': 'critical',
        'status': 'active',
        'buildingName': 'Tower A',
        'location': 'Plant room',
        'reading': {'value': 12.4, 'unit': '°C', 'condition': 'above 9 °C'},
        'assignee': {'id': 'u1', 'name': 'Dana'},
        'ackDueAt': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
      });
      expect(a.readingText, '12.4 °C · above 9 °C');
      expect(a.where, 'Tower A · Plant room');
      expect(a.assigneeName, 'Dana');
      expect(a.ackOverdue, isTrue);
      expect(a.isOpen, isTrue);

      // Access alarms repeat the zone as building and location: show it once.
      expect(AlertItem.fromJson({'key': 'ac:1', 'buildingName': 'L2 Office West', 'location': 'L2 Office West'}).where, 'L2 Office West');

      final bare = AlertItem.fromJson({'key': 'pd:1'});
      expect(bare.severity, 'low');
      expect(bare.readingText, isNull);
      expect(bare.ackOverdue, isFalse);
    });

    test('acknowledged alerts are not "acknowledge overdue"', () {
      final a = AlertItem.fromJson({
        'key': 'sa:1',
        'status': 'acknowledged',
        'ackDueAt': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      });
      expect(a.ackOverdue, isFalse);
    });
  });

  test('filters → query the server understands (comma lists, worst first)', () {
    const f = AlertFilters(severity: {'critical', 'high'}, mineOnly: true);
    final q = f.toQuery();
    expect(q['severity'], anyOf('critical,high', 'high,critical'));
    expect(q['status'], anyOf('active,acknowledged', 'acknowledged,active'));
    expect(q['assignee'], 'me');
    expect(q['sort'], '-severity');
    expect(const AlertFilters().toQuery().containsKey('severity'), isFalse);
  });

  test('alert detail path is guarded by the alerts module', () {
    MobileBootstrap boot(List<String> ids) => MobileBootstrap(
          role: 'Admin',
          isSuperAdmin: false,
          accessScope: 'all',
          buildings: const [],
          language: 'en',
          license: const LicenseInfo(state: 'active', access: 'full'),
          modules: [for (final id in ids) MobileModule(id: id, label: id, group: 'g', icon: 'bell', webPath: '/x')],
          webOnly: const [],
          catalogVersion: 1,
        );
    final path = Uri.parse(alertPath('sa:42'));
    expect(path.pathSegments, ['alert', 'sa:42']);
    expect(catalogRedirect(boot(['alerts']), path), isNull);
    expect(catalogRedirect(boot(['plant_room']), path), unavailablePath);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/app/router.dart';
import 'package:technician_portal/core/day/process_guides.dart';
import 'package:technician_portal/core/utils/notification_route.dart';

/// "How do I…?" guides (docs/day-brief.md §Guides): every "Open this screen"
/// must land on a route router.dart really registers (kAppRoutePatterns is
/// itself checked against router.dart in notice_catalog_test.dart), and every
/// string must exist in both languages.
void main() {
  final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
  final ar = jsonDecode(File('assets/i18n/ar.json').readAsStringSync()) as Map<String, dynamic>;

  test('the seven processes the owner listed are covered', () {
    expect(kProcessGuides.map((g) => g.id), ['work_order', 'inspection', 'snag', 'permit', 'checkin', 'scan', 'agent']);
  });

  for (final g in kProcessGuides) {
    test('${g.id}: routes exist in router.dart, with and without a next job', () {
      for (final route in [g.route(), g.route(nextJobId: 'wo-123')]) {
        expect(isKnownAppRoute(route), isTrue, reason: '${g.id} → $route');
      }
    });

    test('${g.id}: every string is in en.json and ar.json, with no stray placeholder', () {
      for (final key in [g.titleKey, g.askKey, ...g.stepKeys]) {
        expect(en[key], isA<String>(), reason: 'en $key');
        expect(ar[key], isA<String>(), reason: 'ar $key');
        expect((en[key] as String).contains('%a'), isFalse, reason: key);
      }
      expect(en.containsKey('day.guide.${g.id}.step${g.stepCount + 1}'), isFalse, reason: 'stepCount is too low');
    });
  }

  test('bottom-nav targets are switched to, not pushed (router.dart key trap)', () {
    final wo = kProcessGuides.firstWhere((g) => g.id == 'work_order');
    expect(Routes.isShellBranch(wo.route()), isTrue);
    expect(Routes.isShellBranch(wo.route(nextJobId: 'x')), isFalse);
  });

  test('server step routes (/technician/...) map onto registered screens', () {
    for (final web in [
      '/technician/orders/work-order/abc',
      '/technician/inspections/abc',
      '/technician/snags/abc',
      '/technician/invites',
      '/technician/schedules/abc',
      '/technician/permits/abc',
    ]) {
      final app = appRouteForWebLink(web);
      expect(app, isNotNull, reason: web);
      expect(isKnownAppRoute(app!), isTrue, reason: web);
    }
  });

  test('every day.* key exists in both languages with the same placeholders', () {
    final keys = en.keys.where((k) => k.startsWith('day.'));
    expect(keys.length, greaterThan(100));
    for (final k in keys) {
      expect(ar[k], isA<String>(), reason: 'ar missing $k');
      expect('%a'.allMatches(ar[k] as String).length, '%a'.allMatches(en[k] as String).length, reason: k);
    }
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/i18n/server_text.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/module_spec.dart';

Map<String, dynamic> _read(String code) => jsonDecode(File('assets/i18n/$code.json').readAsStringSync()) as Map<String, dynamic>;

const _workOrders = MobileModule(id: 'work_orders', label: 'Work Orders', group: 'Facility Management', icon: 'wrench', webPath: '/x');

/// Words the server sends in English (catalog names, status words) follow the
/// language; a word with no entry stays readable. Found on the phone 2026-11-04.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
  });

  test('en and ar have the same keys', () {
    expect(_read('ar').keys.toSet().difference(_read('en').keys.toSet()), isEmpty);
    expect(_read('en').keys.toSet().difference(_read('ar').keys.toSet()), isEmpty);
  });

  testWidgets('Arabic: catalog names and status words translate; unknown ones stay', (tester) async {
    final l = FlutterLocalization.instance;
    l.init(mapLocales: [MapLocale('en', _read('en')), MapLocale('ar', _read('ar'))], initLanguageCode: 'ar');
    await tester.pumpWidget(MaterialApp(locale: const Locale('ar'), supportedLocales: l.supportedLocales, localizationsDelegates: l.localizationsDelegates, home: const SizedBox()));
    await tester.pumpAndSettle();

    expect(_workOrders.label, 'أوامر العمل');
    expect(_workOrders.group, 'Facility Management'); // still the grouping key
    expect(catalogGroup(_workOrders.group), 'إدارة المرافق');
    expect(chipLabel('In Progress'), 'قيد التنفيذ');
    expect(chipLabel('in_progress'), 'قيد التنفيذ');
    expect(statusWord('Fusion Eco Tower A'), 'Fusion Eco Tower A');
    expect(const MobileModule(id: 'brand_new', label: 'Brand New', group: 'G', icon: 'x', webPath: '/x').label, 'Brand New');
  });
}

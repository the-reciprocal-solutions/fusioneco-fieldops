import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/features/order_detail/detail_widgets.dart';

/// Total Hours is the checklist tasks' tracked time. A job closed with no task
/// timer read "0.0 hrs" next to a two-day start → finish (WO-762, 2026-11-02).
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  Future<void> pump(WidgetTester tester, double hours) async {
    final l = FlutterLocalization.instance;
    await tester.pumpWidget(MaterialApp(
      supportedLocales: l.supportedLocales,
      localizationsDelegates: l.localizationsDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: TimeTrackerCard(
            startedDate: DateTime(2026, 10, 31, 11),
            completedDate: DateTime(2026, 11, 2, 15),
            actualHours: hours,
            queuedComplete: false,
          ),
        ),
      ),
    ));
    // The translations load after the first frame.
    await tester.pumpAndSettle();
  }

  testWidgets('no task time tracked: says so, not "0.0 hrs"', (tester) async {
    await pump(tester, 0);
    expect(find.text('No task time tracked'), findsOneWidget);
    expect(find.textContaining('0.0 hrs'), findsNothing);
  });

  testWidgets('tracked time: shown in hours', (tester) async {
    await pump(tester, 2.5);
    expect(find.text('2.5 hrs'), findsOneWidget);
  });
}

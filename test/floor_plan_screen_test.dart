import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/data/floor_plan_repository.dart';
import 'package:technician_portal/features/floor_plan/floor_plan_screen.dart';
import 'package:technician_portal/state/providers.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// FR-2.8 — what the floor plan screen says when it cannot show a plan.
/// Real `floorPlan.*` strings, so a renamed key shows here.
Map<String, dynamic> _strings() {
  final all = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('floorPlan.') || e.key.startsWith('common.')) e.key: e.value,
  };
}

class _FakeFloorPlans implements FloorPlanRepository {
  _FakeFloorPlans(this._answer);

  final Future<FloorPlanRecord?> Function() _answer;

  @override
  Future<FloorPlanRecord?> get(String floorId, {Duration? ttl}) => _answer();
}

Future<void> _pump(WidgetTester tester, FloorPlanRepository repository) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [floorPlanRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      theme: AppTheme.build(),
      supportedLocales: FlutterLocalization.instance.supportedLocales,
      localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
      home: const FloorPlanScreen(floorId: 'floor-1', assetId: 'asset-1', assetName: 'VLV-02'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(mapLocales: [MapLocale('en', _strings())], initLanguageCode: 'en');
  });

  testWidgets('offline with the floor never downloaded says so — not "no plan"', (tester) async {
    // Caught on device: this read as "No floor plan available", which tells
    // a technician the floor has no plan when it may well have one.
    await _pump(tester, _FakeFloorPlans(() async => throw const NetworkFailure()));

    expect(find.text('Not downloaded yet'), findsOneWidget);
    expect(find.text('No floor plan available'), findsNothing);
  });

  testWidgets('a floor the server says has no plan still says "no plan"', (tester) async {
    await _pump(
      tester,
      _FakeFloorPlans(() async => const FloorPlanRecord(floorId: 'floor-1', floorName: 'Level 01')),
    );

    expect(find.text('No floor plan available'), findsOneWidget);
    expect(find.text('Not downloaded yet'), findsNothing);
  });

  testWidgets('any other failure is not passed off as "no plan" either', (tester) async {
    await _pump(tester, _FakeFloorPlans(() async => throw StateError('corrupt cache')));

    expect(find.text('No floor plan available'), findsNothing);
    expect(find.text('Not downloaded yet'), findsNothing);
  });
}

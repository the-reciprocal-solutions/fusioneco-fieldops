import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/data/snag_repository.dart';
import 'package:technician_portal/domain/snag.dart';
import 'package:technician_portal/features/snags/snag_detail_screen.dart';
import 'package:technician_portal/features/snags/snag_hub_screen.dart';
import 'package:technician_portal/features/snags/snag_survey_screen.dart';
import 'package:technician_portal/state/snag_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// Screen-level render tests with every data provider overridden, so they
/// exercise layout and wiring, not the network or SQLCipher.

Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('snags.') || e.key.startsWith('common.')) e.key: e.value,
  };
}

class _FixedBuilding extends SnagBuildingIdController {
  @override
  String? build() => 'b1';
  @override
  Future<void> select(String id) async => state = id;
}

class _IdleSync extends SnagSyncController {
  @override
  SnagSyncState build() => const SnagSyncState(online: true);
  @override
  Future<void> refresh(String buildingId) async {}
}

final _t = DateTime(2026, 9, 1);

Snag _s(String id, SnagStatus status, {SnagPriority p = SnagPriority.major, String? readyBy, String? surveyId, List<SnagEvidence> evidence = const []}) => Snag(
  id: id,
  context: SnagContext.fmTakeover,
  issueType: 'defect',
  trade: 'plumbing',
  priority: p,
  title: 'Leak under basin $id',
  status: status,
  buildingId: 'b1',
  floorId: 'f1',
  spaceId: 'r1',
  locationLabel: 'Tower A › L1 › Room 101',
  surveyId: surveyId,
  readyBy: readyBy,
  readyAt: readyBy == null ? null : _t,
  raisedBy: 'someone',
  raisedByName: 'Sam',
  evidence: evidence,
  activity: [SnagActivity(id: 'a-$id', at: _t, type: 'raised', byName: 'Sam')],
  createdAt: _t,
  updatedAt: _t,
);

final _snags = [
  _s('a', SnagStatus.open, p: SnagPriority.critical, surveyId: 'w1'),
  _s('b', SnagStatus.ready, readyBy: 'fixer', surveyId: 'w1'),
  _s('c', SnagStatus.closed),
];

const _tree = SnagLocationTree(
  id: 'b1',
  name: 'Tower A',
  floors: [
    SnagFloor(id: 'f1', name: 'L1', spaces: [SnagSpace(id: 'r1', name: 'Room 101'), SnagSpace(id: 'r2', name: 'Room 102')]),
  ],
);

final _survey = SnagSurvey(
  id: 'w1',
  name: 'Tower A takeover walk',
  context: SnagContext.fmTakeover,
  buildingId: 'b1',
  buildingName: 'Tower A',
  startedAt: _t,
  startedByName: 'Me',
  inspectedSpaces: [SpaceSweep(spaceId: 'r1', floorId: 'f1', clear: false, snagCount: 2, at: _t)],
);

List<Override> _overrides() => [
  snagActorProvider.overrideWithValue(const SnagActor(id: 'me', name: 'Me')),
  snagBuildingIdProvider.overrideWith(_FixedBuilding.new),
  snagSyncProvider.overrideWith(_IdleSync.new),
  snagQueueFlushingProvider.overrideWithValue(false),
  snagBuildingsProvider.overrideWith((ref) async => const [SnagBuilding(id: 'b1', name: 'Tower A')]),
  snagsProvider.overrideWith((ref, buildingId) async => _snags),
  snagSurveysProvider.overrideWith((ref, buildingId) async => [_survey]),
  snagSurveyProvider.overrideWith((ref, id) async => _survey),
  snagTreeProvider.overrideWith((ref, id) async => _tree),
  pendingSnagIdsProvider.overrideWith((ref) async => <String>{'a'}),
  snagByIdProvider.overrideWith((ref, id) async => _snags.firstWhere((s) => s.id == id)),
];

Future<void> _pump(WidgetTester tester, String lang, Widget screen) async {
  FlutterLocalization.instance.translate(lang);
  tester.view.physicalSize = const Size(360 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
        locale: Locale(lang),
        home: screen,
      ),
    ),
  );
  // Let the FutureProviders resolve and the entrance/ring animations run.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Fails with the full Flutter diagnostic (widget and source line), not
/// just the one-line summary, so a layout regression names its culprit.
void _expectClean(WidgetTester tester) {
  final err = tester.takeException();
  if (err is FlutterError) fail(err.toStringDeep());
  expect(err, isNull);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(
      mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))],
      initLanguageCode: 'en',
    );
  });

  for (final lang in ['en', 'ar']) {
    testWidgets('hub: readiness, waiting-on-you, surveys and list ($lang)', (tester) async {
      await _pump(tester, lang, const SnagHubScreen());
      _expectClean(tester);
      expect(find.text('Tower A'), findsWidgets);
      // The ready snag someone else fixed is waiting on "me" to verify.
      expect(find.text('Leak under basin b'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Tower A takeover walk'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Tower A takeover walk'), findsOneWidget);
      // ...and all the way down the list, still without a layout error.
      await tester.scrollUntilVisible(find.text('Leak under basin a'), 300, scrollable: find.byType(Scrollable).first);
      _expectClean(tester);
      expect(find.textContaining('snags.'), findsNothing, reason: 'a raw i18n key leaked');
    });

    testWidgets('detail: ready snag fixed by someone else offers accept/reject ($lang)', (tester) async {
      await _pump(tester, lang, const SnagDetailScreen(snagId: 'b'));
      _expectClean(tester);
      expect(find.text(lang == 'en' ? 'Accept' : 'قبول'), findsOneWidget);
      expect(find.text(lang == 'en' ? 'Reject' : 'رفض'), findsOneWidget);
      expect(find.textContaining('snags.'), findsNothing);
    });

    testWidgets('survey: coverage and breakdowns ($lang)', (tester) async {
      await _pump(tester, lang, const SnagSurveyScreen(surveyId: 'w1'));
      _expectClean(tester);
      expect(find.text('1/2'), findsWidgets);
      expect(find.textContaining('snags.'), findsNothing);
    });
  }
}

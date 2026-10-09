import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/data/snag_estimate_repository.dart';
import 'package:technician_portal/domain/snag.dart';
import 'package:technician_portal/domain/snag_estimate.dart';
import 'package:technician_portal/features/snags/widgets/snag_ai_panel.dart';
import 'package:technician_portal/features/snags/widgets/snag_estimate_card.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The snag estimate & quote help (server snag-assistant.md §4c): the model
/// parses the server's answer without inventing values, the card shows
/// "Price needed" instead of a price, and the quote sheet won't send until
/// every included line has a price — and then sends exactly what the
/// technician reviewed. Also: the photo check is a quiet chip until asked.

Map<String, dynamic> _estimateJson({bool scope = true}) => {
      'snagId': 's1',
      'reference': 'SN-00012',
      'ai': {'status': scope ? 'ok' : 'skipped', 'message': null, 'removed': 0},
      'scope': {
        'summary': scope ? 'Replace two cracked tiles' : null,
        'steps': scope ? ['Remove cracked tiles', 'Lay new tiles', 'Grout'] : [],
        'trades': ['finishes', 'not-a-trade'],
        'crewSize': scope ? 1 : null,
        'durationHours': scope ? {'low': 2, 'high': 4} : null,
        'fromAi': scope,
      },
      'materials': scope
          ? [
              {
                'id': 'L1',
                'name': 'Floor tile 600x600',
                'quantity': 2,
                'unit': 'pcs',
                'match': 'catalogue',
                'material': {'id': 'm-tile', 'name': 'Ceramic floor tile 600x600', 'partNumber': 'FT-600'},
                'stock': {'onHand': '4', 'reserved': 1, 'available': 3},
                'shortBy': 0,
                'unitPrice': '35.00',
                'priceSource': 'catalogue',
                'priceNote': 'Catalogue price',
                'lineCost': {'low': 70, 'high': 70},
              },
              {
                'id': 'L2',
                'name': 'Expansion joint strip',
                'quantity': 1,
                'unit': 'm',
                'match': 'not-in-catalogue',
                'material': null,
                'stock': null,
                'unitPrice': null,
                'priceSource': 'none',
                'priceNote': 'Not in catalogue — price needed',
                'lineCost': null,
              },
              {'id': 'L3', 'name': '', 'quantity': 1}, // dropped: no name
            ]
          : [],
      'cost': {
        'currency': 'AED',
        'labour': scope ? {'rate': 60, 'rateBasis': 'default', 'crewSize': 1, 'personHours': {'low': 2, 'high': 4}, 'low': 120, 'high': 240} : null,
        'materials': {'low': 70, 'high': 70, 'pricedLines': 1, 'unpricedLines': 1},
        'contingencyPct': 15,
        'contingency': 46.5,
        'total': scope ? {'low': 190, 'high': 356.5} : {'low': 0, 'high': 0},
        'complete': false,
      },
      'assumptions': ['Labour at AED 60.00 per person-hour (a default rate — change it to your own).'],
      'responsibility': {'kind': 'warranty', 'party': 'Finishes contractor (DLP)', 'backCharge': true, 'basis': ['Raised within the 12-month defects liability period.']},
      'warranty': {'status': 'in-dlp', 'until': '2027-03-01T00:00:00.000Z', 'basis': 'DLP'},
      'priority': {'current': 'minor', 'suggested': 'major', 'reason': 'Trip risk', 'changed': true, 'slaDue': '2026-10-08T00:00:00.000Z', 'slaBasis': 'Usual fix-by target'},
      'benchmark': {'count': 4, 'medianDaysToClose': 3.5, 'costRange': {'low': 200, 'high': 400}, 'note': '4 closed snags'},
      'vendors': [
        {'id': 'v1', 'name': 'TileCo', 'reasons': ['Service: Finishes', 'Serves this building']},
      ],
      'linked': {'workOrderId': null, 'records': []},
    };

class _FakeGateway implements SnagEstimateGateway {
  final calls = <String>[];
  List<QuoteLineDraft>? sentLines;
  final requestIds = <String>[];

  @override
  Future<SnagEstimate> estimate(String snagId, {bool ai = false, bool fresh = false, Map<String, num>? assumptions}) async {
    calls.add('estimate:ai=$ai');
    return SnagEstimate.fromJson(_estimateJson(scope: ai))!;
  }

  @override
  Future<({String quoteNumber, String quoteId, double grandTotal, String currency, bool replayed})> draftQuote(
    String snagId, {
    required String requestId,
    required List<QuoteLineDraft> lines,
    double? contingencyPct,
    String? subject,
    String? scope,
    List<String> assumptions = const [],
  }) async {
    calls.add('quote');
    requestIds.add(requestId);
    sentLines = lines;
    return (quoteNumber: 'QT-2026-00042', quoteId: 'q1', grandTotal: 341.0, currency: 'AED', replayed: false);
  }

  @override
  Future<List<({String name, bool ok, String message})>> materials(String snagId, {required String requestId, required List<({String materialId, int quantity, String action, String? vendorId})> lines}) async =>
      const [];

  @override
  Future<({String workOrderId, String id, bool alreadyLinked})> workOrder(String snagId, {required String requestId, DateTime? dueDate, double? estimatedHours}) async =>
      (workOrderId: 'WO-0001', id: 'w1', alreadyLinked: false);

  @override
  Future<void> applySuggestion(String snagId, {SnagPriority? priority, DateTime? dueDate}) async => calls.add('apply');
}

Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('snags.') || e.key.startsWith('common.')) e.key: e.value,
  };
}

Snag _snag() => Snag(
      id: 's1',
      context: SnagContext.operations,
      issueType: 'damage',
      trade: 'finishes',
      priority: SnagPriority.minor,
      title: 'Cracked floor tiles at the lift lobby',
      status: SnagStatus.open,
      locationLabel: 'Tower A › L1 › Lift lobby',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );

Future<void> _pump(WidgetTester tester, String lang, Widget child, {SnagEstimateGateway? gateway}) async {
  FlutterLocalization.instance.translate(lang);
  tester.view.physicalSize = const Size(360 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [if (gateway != null) snagEstimateRepositoryProvider.overrideWithValue(gateway)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
        locale: Locale(lang),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('SnagEstimate.fromJson', () {
    test('parses the server answer tolerantly and never fills a missing price', () {
      final e = SnagEstimate.fromJson(_estimateJson())!;
      expect(e.hasScope, isTrue);
      expect(e.trades, ['finishes'], reason: 'unknown trades are dropped');
      expect(e.materials, hasLength(2), reason: 'a line without a name is dropped');
      expect(e.materials[0].unitPrice, 35);
      expect(e.materials[0].available, 3);
      expect(e.materials[0].inCatalogue, isTrue);
      expect(e.materials[1].needsPrice, isTrue);
      expect(e.materials[1].unitPrice, isNull);
      expect(e.unpricedCount, 1);
      expect(e.total.low, 190);
      expect(e.total.high, 356.5);
      expect(e.complete, isFalse);
      expect(e.suggestedPriority, SnagPriority.major);
      expect(e.backCharge, isTrue);
      expect(e.vendors.single.name, 'TileCo');
    });

    test('rejects an answer without a snag or cost', () {
      expect(SnagEstimate.fromJson({'snagId': 's1'}), isNull);
      expect(SnagEstimate.fromJson({'cost': {}}), isNull);
    });

    test('quote lines: catalogue price, unpriced stays null, labour at the rate', () {
      final lines = quoteLinesFrom(SnagEstimate.fromJson(_estimateJson())!);
      expect(lines.map((l) => l.name), ['Ceramic floor tile 600x600', 'Expansion joint strip', 'Labour']);
      expect(lines[0].unitPrice, 35);
      expect(lines[0].sourceType, 'material');
      expect(lines[0].sourceId, 'm-tile');
      expect(lines[1].unitPrice, isNull);
      expect(lines[1].sourceType, 'custom');
      expect(lines[2].quantity, 4);
      expect(lines[2].unitPrice, 60);
      expect(lines[2].sourceType, 'labor');
      expect(lines[2].toJson()['unit'], 'h');
    });
  });

  group('widgets', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      final l = FlutterLocalization.instance;
      await l.ensureInitialized();
      l.init(mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))], initLanguageCode: 'en');
    });

    for (final lang in ['en', 'ar']) {
      testWidgets('photo check is a quiet chip until asked ($lang)', (tester) async {
        var runs = 0;
        await _pump(
          tester,
          lang,
          SnagAiPanel(running: false, result: null, applied: const {}, onRun: () => runs++, onApply: (_) {}, onApplyAll: () {}),
        );
        expect(find.byKey(const ValueKey('snag-check-photo')), findsOneWidget);
        expect(find.text(lang == 'en' ? 'AI assist' : 'مساعد الذكاء الاصطناعي'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('snag-check-photo')));
        expect(runs, 1);
        expect(find.textContaining('snags.'), findsNothing, reason: 'a raw i18n key leaked');

        await _pump(
          tester,
          lang,
          SnagAiPanel(running: false, result: null, applied: const {}, hasPhoto: false, onRun: () {}, onApply: (_) {}, onApplyAll: () {}),
        );
        expect(find.byKey(const ValueKey('snag-check-photo')), findsNothing);
      });

      testWidgets('estimate card: price needed, then a reviewed draft quote ($lang)', (tester) async {
        final fake = _FakeGateway();
        await _pump(tester, lang, SnagEstimateCard(snag: _snag()), gateway: fake);
        await tester.pumpAndSettle();
        expect(fake.calls, ['estimate:ai=false'], reason: 'opening never waits on the AI');
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('snag-estimate-run')));
        await tester.pumpAndSettle();
        expect(fake.calls.last, 'estimate:ai=true');
        expect(find.text(lang == 'en' ? 'Price needed' : 'يلزم سعر'), findsOneWidget);
        expect(find.textContaining('snags.'), findsNothing, reason: 'a raw i18n key leaked');

        await tester.ensureVisible(find.byKey(const ValueKey('snag-estimate-quote')));
        await tester.tap(find.byKey(const ValueKey('snag-estimate-quote')));
        await tester.pumpAndSettle();

        final create = find.byKey(const ValueKey('snag-quote-create'));
        expect(tester.widget<ButtonStyleButton>(create).onPressed, isNull, reason: 'an unpriced line blocks the quote');

        await tester.enterText(find.byKey(const ValueKey('snag-quote-price-1')), '12.5');
        await tester.pump();
        await tester.tap(create);
        await tester.pumpAndSettle();

        expect(fake.calls, contains('quote'));
        expect(fake.sentLines!.map((l) => l.unitPrice), [35, 12.5, 60]);
        expect(fake.requestIds.single, hasLength(36));
        expect(tester.takeException(), isNull);
      });
    }
  });
}

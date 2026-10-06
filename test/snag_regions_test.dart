import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/domain/snag.dart';
import 'package:technician_portal/domain/snag_ai.dart';
import 'package:technician_portal/features/snags/widgets/snag_region_overlay.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// AI defect highlights (2026-10-06): the grounding mirrors the server's
/// snagRules.ts `normaliseRegions`, the mapping puts a normalised box on the
/// right pixels for `cover` and `contain`, and Arabic (RTL) never mirrors it.
Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {for (final e in all.entries) if (e.key.startsWith('snags.')) e.key: e.value};
}

const _box = SnagRegion(x: 0.25, y: 0.5, w: 0.5, h: 0.25, label: 'damage', severity: SnagPriority.major);

void main() {
  group('SnagRegion grounding (mirrors the server)', () {
    test('clamps to the photo and keeps a usable box', () {
      final r = SnagRegion.tryParse({'x': -0.2, 'y': 0.5, 'w': 0.5, 'h': 0.8, 'label': 'Defect', 'severity': 'MINOR'})!;
      expect([r.x, r.y, r.w, r.h], [0, 0.5, 0.3, 0.5]);
      expect(r.label, 'defect');
      expect(r.severity, SnagPriority.minor);
    });

    test('fails closed: strings, slivers, whole-photo boxes and unknown labels are dropped', () {
      expect(SnagRegion.tryParse({'x': '0.1', 'y': 0.1, 'w': 0.2, 'h': 0.2, 'label': 'defect'}), isNull);
      expect(SnagRegion.tryParse({'x': 0.1, 'y': 0.1, 'w': 0.005, 'h': 0.4, 'label': 'defect'}), isNull);
      expect(SnagRegion.tryParse({'x': 0, 'y': 0, 'w': 1, 'h': 1, 'label': 'defect'}), isNull);
      expect(SnagRegion.tryParse({'x': 0.1, 'y': 0.1, 'w': 0.2, 'h': 0.2, 'label': 'crack'}), isNull);
      expect(SnagRegion.tryParse('nope'), isNull);
    });

    test('at most five, near-duplicates dropped, severity falls back', () {
      final list = SnagRegion.listFrom([
        {'x': 0.1, 'y': 0.1, 'w': 0.2, 'h': 0.2, 'label': 'defect', 'severity': 'urgent'},
        {'x': 0.1, 'y': 0.1, 'w': 0.2, 'h': 0.21, 'label': 'defect'},
        for (var i = 0; i < 8; i++) {'x': 0.4 + i * 0.07, 'y': 0.6, 'w': 0.05, 'h': 0.05, 'label': 'damage'},
      ], fallbackSeverity: SnagPriority.critical);
      expect(list, hasLength(SnagRegion.maxCount));
      expect(list.first.severity, SnagPriority.critical);
      expect(list.where((r) => r.x == 0.1), hasLength(1));
    });

    test('AI answer: regions only from a real answer; an older server sends none', () {
      final ok = SnagAiResult.fromJson({
        'available': true,
        'suggestions': {'priority': 'major'},
        'regions': [
          {'x': 0.2, 'y': 0.2, 'w': 0.3, 'h': 0.3, 'label': 'damage'},
        ],
      });
      expect(ok.regions.single.severity, SnagPriority.major, reason: 'falls back to the answer severity');
      expect(SnagAiResult.fromJson({'available': true, 'suggestions': {}}).regions, isEmpty);
      expect(
        SnagAiResult.fromJson({
          'available': false,
          'regions': [
            {'x': 0.2, 'y': 0.2, 'w': 0.3, 'h': 0.3, 'label': 'damage'},
          ],
        }).regions,
        isEmpty,
      );
    });

    test('evidence keeps regions on photos only, and round-trips', () {
      final photo = SnagEvidence.fromJson({
        'id': 'e1',
        'kind': 'photo',
        'url': 'https://x/a.jpg',
        'capturedAt': '2026-10-06T10:00:00Z',
        'regions': [_box.toJson()],
      });
      expect(photo.regions, [_box]);
      expect(SnagEvidence.fromJson(photo.toJson()).regions, [_box]);
      expect(photo.withLocalPath('/tmp/a.jpg').regions, [_box]);
      final audio = SnagEvidence.fromJson({'id': 'e2', 'kind': 'audio', 'regions': [_box.toJson()]});
      expect(audio.regions, isEmpty);
      final bare = SnagEvidence.fromJson({'id': 'e3', 'kind': 'photo'});
      expect(bare.toJson().containsKey('regions'), isFalse, reason: 'older readers see the old shape');
    });
  });

  group('normalised → pixel mapping', () {
    test('contain letterboxes: a 4:3 photo in a 400×400 box', () {
      // Drawn 400×300, centred → 50 px bars top and bottom.
      final rect = snagRegionRect(_box, imageSize: const Size(800, 600), boxSize: const Size(400, 400), fit: BoxFit.contain);
      expect(rect, const Rect.fromLTWH(100, 50 + 150, 200, 75));
    });

    test('cover crops: a 4:3 photo in a 300×400 box', () {
      // Scaled to 533.3×400, centred → 116.7 px cut off each side.
      final rect = snagRegionRect(_box, imageSize: const Size(800, 600), boxSize: const Size(300, 400));
      const drawnW = 800 * 400 / 600;
      const left = (300 - drawnW) / 2;
      expect(rect.left, closeTo(left + 0.25 * drawnW, 1e-9));
      expect(rect.top, closeTo(200, 1e-9));
      expect(rect.width, closeTo(0.5 * drawnW, 1e-9));
      expect(rect.height, closeTo(100, 1e-9));
    });

    test('an empty size draws nothing', () {
      expect(snagRegionRect(_box, imageSize: Size.zero, boxSize: const Size(10, 10)), Rect.zero);
    });
  });

  group('SnagRegionLayer', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      final l = FlutterLocalization.instance;
      await l.ensureInitialized();
      l.init(mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))], initLanguageCode: 'en');
    });

    Future<Rect> pumpLayer(WidgetTester tester, String lang, {ValueChanged<int>? onDelete}) async {
      FlutterLocalization.instance.translate(lang);
      tester.view.physicalSize = const Size(320 * 3, 568 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
          locale: Locale(lang),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 300,
                child: SnagRegionLayer(
                  image: MemoryImage(Uint8List(4)),
                  imageSize: const Size(600, 600),
                  regions: const [_box],
                  fit: BoxFit.cover,
                  onDelete: onDelete,
                  child: const ColoredBox(color: Colors.grey),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2)); // past the first-show pulse
      expect(tester.takeException(), isNull);
      return tester.getRect(find.byKey(const ValueKey('region-0')));
    }

    testWidgets('draws the box on the same pixels in English and Arabic (RTL never mirrors photo space)', (tester) async {
      final en = await pumpLayer(tester, 'en');
      expect(en, const Rect.fromLTWH(75, 150, 150, 75));
      expect(find.textContaining('snags.'), findsNothing, reason: 'a raw i18n key leaked');
      final ar = await pumpLayer(tester, 'ar');
      expect(ar, en);
    });

    testWidgets('the chip names the defect and its × removes the box', (tester) async {
      int? removed;
      await pumpLayer(tester, 'en', onDelete: (i) => removed = i);
      expect(find.text('Damage · Major'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Remove this highlight'));
      expect(removed, 0);
    });
  });
}

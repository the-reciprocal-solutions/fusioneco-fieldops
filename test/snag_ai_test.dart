import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:technician_portal/core/snag/snag_photo_quality.dart';
import 'package:technician_portal/domain/snag.dart';
import 'package:technician_portal/domain/snag_ai.dart';

void main() {
  group('SnagAiResult.fromJson — grounded in the app vocabulary', () {
    test('keeps valid suggestions, drops invented values and unknown codes', () {
      final r = SnagAiResult.fromJson({
        'available': true,
        'suggestions': {
          'title': 'Ceiling tile stained — water ingress',
          'trade': 'hvac',
          'priority': 'major',
          'issueType': 'damage',
          'likelyCause': 'Condensate drip',
          'recommendedFix': 'Clear the drain line',
          'responsibleTrade': 'carpentry',
        },
        'confidence': 3,
        'captureTips': [
          {'code': 'add_wide_shot', 'message': 'x'},
          {'code': 'make_it_pretty'},
        ],
        'duplicates': [
          {'id': 'd1', 'reference': 'SN-00012', 'status': 'open', 'trade': 'hvac', 'score': 0.8, 'coverUrl': 'file:///x'},
          {'title': 'no id'},
        ],
        'missing': ['location', 'bogus'],
      }, deviceTips: ['too_dark']);
      expect(r.status, SnagAiStatus.ok);
      expect(r.trade, 'hvac');
      expect(r.priority, SnagPriority.major);
      expect(r.responsibleTrade, isNull, reason: 'not in kSnagTrades');
      expect(r.confidence, 1);
      expect(r.captureTips, ['too_dark', 'add_wide_shot']);
      expect(r.duplicates.single.displayRef, 'SN-00012');
      expect(r.duplicates.single.coverUrl, isNull, reason: 'only http(s) images load');
      expect(r.missing, ['location']);
    });

    test('available:false → unavailable, no suggestions, device tips kept', () {
      final r = SnagAiResult.fromJson({'available': false, 'suggestions': {}}, deviceTips: ['blurry']);
      expect(r.status, SnagAiStatus.unavailable);
      expect(r.hasSuggestions, isFalse);
      expect(r.captureTips, ['blurry']);
    });
  });

  group('photo quality (on device, works offline)', () {
    img.Image solid(int v) => img.Image(width: 200, height: 150)..clear(img.ColorRgb8(v, v, v));

    test('a black frame is too dark (and flat)', () {
      final (b, s) = measureLumaQuality(solid(10));
      expect(b, lessThan(kTooDarkBelow));
      expect(snagQualityTips(brightness: b, sharpness: s), containsAll(['too_dark', 'blurry']));
    });

    test('a high-detail frame is neither dark nor blurry', () {
      final im = img.Image(width: 200, height: 150);
      for (var y = 0; y < im.height; y++) {
        for (var x = 0; x < im.width; x++) {
          final v = ((x ~/ 2) + (y ~/ 2)).isEven ? 230 : 40;
          im.setPixelRgb(x, y, v, v, v);
        }
      }
      final (b, s) = measureLumaQuality(im);
      expect(snagQualityTips(brightness: b, sharpness: s), isEmpty);
    });

    test('prepareSnagPhotoForAi downsizes to the AI edge and returns metrics', () {
      final big = img.Image(width: 2000, height: 1000)..clear(img.ColorRgb8(128, 128, 128));
      final prep = prepareSnagPhotoForAi(Uint8List.fromList(img.encodeJpg(big)))!;
      final back = img.decodeJpg(prep.jpeg)!;
      expect(back.width, kAiPhotoEdge);
      expect(prep.brightness, closeTo(0.5, 0.05));
      expect(prepareSnagPhotoForAi(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:technician_portal/features/field_verification/photo_annotation_screen.dart';

/// FR-3.5 — an annotated photo used to be a screenshot of the screen: ~720px
/// wide on a 720px phone instead of the 1600px capture, and PNG bytes under
/// the photo's `.jpg` name (uploaded as image/jpeg). Caught reading the code
/// for FR-3; these pin the fix.
Future<ui.Image> _solidPhoto(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF203040),
  );
  return recorder.endRecording().toImage(width, height);
}

void main() {
  testWidgets('keeps the photo at its own resolution, not the screen size', (tester) async {
    await tester.runAsync(() async {
      final photo = await _solidPhoto(1600, 1200);

      final bytes = await flattenAnnotatedPhoto(
        photo,
        const Size(360, 270), // drawn on a phone-width view
        (canvas, size) => canvas.drawLine(
          Offset.zero,
          Offset(size.width, size.height),
          Paint()
            ..color = const Color(0xFFFF0000)
            ..strokeWidth = 6,
        ),
      );

      final decoded = img.decodeJpg(bytes);
      expect(decoded, isNotNull, reason: 'must be real JPEG bytes');
      expect(decoded!.width, 1600);
      expect(decoded.height, 1200);
    });
  });

  testWidgets('a mark lands where it was drawn, scaled up to the photo', (tester) async {
    await tester.runAsync(() async {
      final photo = await _solidPhoto(1600, 1200);

      // A red dot drawn at the centre of a 400x300 view.
      final bytes = await flattenAnnotatedPhoto(
        photo,
        const Size(400, 300),
        (canvas, size) => canvas.drawCircle(
          const Offset(200, 150),
          10,
          Paint()..color = const Color(0xFFFF0000),
        ),
      );

      final decoded = img.decodeJpg(bytes)!;
      final centre = decoded.getPixel(800, 600);
      final corner = decoded.getPixel(40, 40);
      expect(centre.r, greaterThan(200), reason: 'the dot is at the photo centre');
      expect(corner.r, lessThan(80), reason: 'and nowhere near the corner');
    });
  });

  test('the saved name always says .jpg, matching the bytes', () {
    expect(annotatedFileName('IMG_0001.jpg'), 'IMG_0001.jpg');
    expect(annotatedFileName('screenshot.png'), 'screenshot.jpg');
    expect(annotatedFileName('photo'), 'photo.jpg');
  });
}

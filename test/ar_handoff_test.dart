import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/data/field_verification_repository.dart';
import 'package:technician_portal/domain/ar_handoff.dart';

/// P-006: the AR context crosses the router as `ar*` strings and becomes the
/// §8 `arContext` block on the verification request.
void main() {
  const h = ArHandoff(
    check: 'offset',
    offsetM: 1.234,
    toleranceM: 0.35,
    tagMatches: true,
    buildId: 'b-7',
    globalId: '2O2Fr\$t4X7Zf8NOew3FLOH',
    featureId: 18234,
    elementName: 'CHW supply 150',
    fitMethod: 'positions',
    maxResidualMm: 11,
    quality: 'locked',
    mappingConfirmed: false,
    photoPath: '/tmp/ar-1.jpg',
    cameraTile: [12.41, 1.52, -8.07],
    cameraDirTile: [0.71, -0.1, -0.7],
  );

  test('round-trips through query parameters (and a real URI)', () {
    final uri = Uri(path: '/verify/a1', queryParameters: {'name': 'Chiller', ...h.toQuery()});
    final back = ArHandoff.fromQuery(Uri.parse(uri.toString()).queryParameters)!;
    expect(back.check, 'offset');
    expect(back.offsetM, 1.23);
    expect(back.toleranceM, 0.35);
    expect(back.tagMatches, isTrue);
    expect(back.globalId, h.globalId);
    expect(back.featureId, 18234);
    expect(back.elementName, 'CHW supply 150');
    expect(back.maxResidualMm, 11);
    expect(back.quality, 'locked');
    expect(back.mappingConfirmed, isFalse);
    expect(back.photoPath, '/tmp/ar-1.jpg');
    expect(back.cameraTile, [12.41, 1.52, -8.07]);
    expect(back.cameraDirTile, [0.71, -0.1, -0.7]);
  });

  test('no ar* params → no hand-off (a form opened from a scan)', () {
    expect(ArHandoff.fromQuery(const {'name': 'Chiller', 'floorId': 'f1'}), isNull);
    expect(ArHandoff.fromQuery(const {'arCheck': 'unchecked'}), isNull);
    expect(ArHandoff.fromQuery(const {'arCam': 'garbage'}), isNull);
  });

  test('arContext has the §8 shape', () {
    final c = h.toArContext();
    expect(c['globalId'], h.globalId);
    expect(c['featureId'], 18234);
    expect(c['maxResidualMm'], 11);
    expect(c['cameraTile'], [12.41, 1.52, -8.07]);
    expect(c['locationCheck'], {'result': 'offset', 'offsetM': 1.234, 'toleranceM': 0.35, 'tagMatches': true});
    expect(c['mappingConfirmed'], isFalse);
    expect(const ArHandoff(globalId: 'g').toArContext().containsKey('fitMethod'), isFalse);
  });

  test('the verification request carries arContext only when given', () {
    final with_ = FieldVerificationRequest(result: VerificationResult.verified, arContext: h.toArContext()).toJson();
    expect((with_['arContext'] as Map)['globalId'], h.globalId);
    final without = FieldVerificationRequest(
      result: VerificationResult.verified,
      photos: [VerificationPhoto(bytes: Uint8List(1), fileName: 'a.jpg', contentType: 'image/jpeg')],
    ).toJson();
    expect(without.containsKey('arContext'), isFalse);
  });

  test('summary line for a snag', () {
    expect(h.summaryLine(), 'Model element CHW supply 150 · GlobalId ${h.globalId} · AR locked ±11 mm');
    expect(const ArHandoff().summaryLine(), '');
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/data/field_verification_repository.dart';

void main() {
  group('FR-3 — FieldVerificationRequest.toJson', () {
    test('a bare result with nothing else observed sends only what was set', () {
      final json = const FieldVerificationRequest(result: VerificationResult.verified).toJson();
      expect(json['result'], 'verified');
      expect(json.containsKey('observedSerial'), isFalse);
      expect(json.containsKey('observedTag'), isFalse);
      expect(json.containsKey('observedCondition'), isFalse);
      expect(json.containsKey('notes'), isFalse);
      expect(json.containsKey('photos'), isFalse);
      expect(json.containsKey('geo'), isFalse);
    });

    test('every field maps to the server enum names exactly', () {
      final json = const FieldVerificationRequest(
        result: VerificationResult.mismatch,
        observedSerial: 'SN-123',
        observedTag: 'AST-9',
        observedCondition: ObservedCondition.poor,
        notes: 'Cracked housing',
      ).toJson();

      expect(json['result'], 'mismatch');
      expect(json['observedSerial'], 'SN-123');
      expect(json['observedTag'], 'AST-9');
      expect(json['observedCondition'], 'poor');
      expect(json['notes'], 'Cracked housing');
    });

    test('the fifth result value is "inaccessible", not "needs-follow-up"', () {
      final json = const FieldVerificationRequest(result: VerificationResult.inaccessible).toJson();
      expect(json['result'], 'inaccessible');
    });

    test('photos serialize as {url, name, contentType} placeholders — FR-4.7 uploads them separately', () {
      final request = FieldVerificationRequest(
        result: VerificationResult.verified,
        photos: [
          VerificationPhoto(bytes: Uint8List.fromList([1, 2, 3]), fileName: 'a.jpg', contentType: 'image/jpeg'),
        ],
      );
      final json = request.toJson();

      final photos = json['photos'] as List;
      expect(photos, hasLength(1));
      expect(photos.single, {
        'url': '__pending_photo_0__',
        'name': 'a.jpg',
        'contentType': 'image/jpeg',
      });

      // The placeholder above must match the attachment SyncClient uploads.
      final attachments = request.toAttachments();
      expect(attachments, hasLength(1));
      expect(attachments.single.placeholder, '__pending_photo_0__');
      expect(attachments.single.field, 'image');
    });

    test('lat/lng only appear together, with accuracy folded into geo', () {
      final json = const FieldVerificationRequest(
        result: VerificationResult.verified,
        latitude: 25.2,
        longitude: 55.3,
        gpsAccuracy: 12.5,
      ).toJson();

      expect(json['geo'], {'lat': 25.2, 'lng': 55.3, 'accuracy': 12.5});
    });

    test('no latitude means no geo key at all, not a half-filled one', () {
      final json = const FieldVerificationRequest(result: VerificationResult.verified).toJson();
      expect(json.containsKey('geo'), isFalse);
    });
  });

  group('FR-4.8 — capture claims widened past serial + tag', () {
    test('captureClaimsFrom keeps only the compared keys the cache actually had', () {
      final claims = captureClaimsFrom({
        'manufacturer': 'Belimo',
        'model': 'BV-100',
        'floorID': 'f-1',
        'location': null, // shown as empty: still compared
        'assetName': 'VLV-03', // not a compared field
        // no spaceID: an older cached pack, so the room is not compared
      });
      expect(claims, {'manufacturer': 'Belimo', 'model': 'BV-100', 'floorID': 'f-1', 'location': null});
      expect(captureClaimsFrom(null), isEmpty);
    });

    test('the request sends them alongside the claimed serial and tag', () {
      final json = const FieldVerificationRequest(
        result: VerificationResult.verified,
        claimedSerial: 'SN-1',
        shownRegister: {'manufacturer': 'Belimo', 'spaceID': 's-1'},
      ).toJson();
      expect(json['captureClaims'], {'manufacturer': 'Belimo', 'spaceID': 's-1', 'serialNumber': 'SN-1'});
    });

    test('with nothing shown there is no captureClaims at all', () {
      final json = const FieldVerificationRequest(result: VerificationResult.verified).toJson();
      expect(json.containsKey('captureClaims'), isFalse);
    });
  });
}

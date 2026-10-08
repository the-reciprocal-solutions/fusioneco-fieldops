import 'dart:typed_data';

import '../core/offline/sync_client.dart';

/// FR-3.1 — one of five outcomes. Matches the server's enum exactly
/// (`C2oFieldVerification.result`, `fieldVerificationService.ts`); there is
/// no "needs follow-up" value on the server — [inaccessible] is that case
/// ("could not reach/verify it right now").
enum VerificationResult { verified, mismatch, missing, damaged, inaccessible }

/// FR-3.3 — matches the server's `observedCondition` enum exactly.
enum ObservedCondition { good, fair, poor, damaged }

/// A photo already captured and downscaled on-device (see
/// `PhotoCapture.takeJobPhoto`). FR-4.7 — carried as raw bytes rather than a
/// base64 data URL: [FieldVerificationRequest] uploads each one separately
/// through [SyncClient]'s attachment queue instead of inlining it into the
/// verify request's JSON body, so one large photo cannot block (or have to
/// be fully resent with) the rest of the check.
class VerificationPhoto {
  const VerificationPhoto({
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final Uint8List bytes;
  final String fileName;
  final String contentType;
}

/// FR-4.8 — the register fields the server compares at arrival, picked out
/// of a cached `claims['asset']` map (single scan or route pack: same keys).
const kCaptureClaimKeys = ['manufacturer', 'model', 'floorID', 'spaceID', 'location'];

Map<String, Object?> captureClaimsFrom(Map<String, dynamic>? asset) => {
  if (asset != null)
    for (final k in kCaptureClaimKeys)
      if (asset.containsKey(k) && (asset[k] == null || asset[k] is String)) k: asset[k],
};

/// Pure request-shaping, separated from the network call below so it can be
/// unit tested without a fake [SyncClient] — same split already used by
/// `FloorPlanRecord.fromJson` for the read side.
class FieldVerificationRequest {
  const FieldVerificationRequest({
    required this.result,
    this.observedSerial,
    this.observedTag,
    this.observedCondition,
    this.notes,
    this.photos = const [],
    this.latitude,
    this.longitude,
    this.gpsAccuracy,
    this.flagForReinspection = false,
    this.flagReason,
    this.claimedSerial,
    this.claimedTag,
    this.shownRegister = const {},
    this.arContext,
  });

  final VerificationResult result;
  final String? observedSerial;
  final String? observedTag;
  final ObservedCondition? observedCondition;
  final String? notes;

  /// FR-4.8 — the serial/tag the technician was shown as "Claimed" when they
  /// opened this form (from whatever cached scan or route pack the screen
  /// was reached from). Sent alongside the observation so the server can
  /// tell "the register changed since capture" apart from "the crew's
  /// observation disagrees with the register" — two different things that
  /// happen to use the same two fields.
  final String? claimedSerial;
  final String? claimedTag;

  /// FR-4.8 (widened 2026-10-08) — the other register values the
  /// technician was shown for this asset (manufacturer, model, floor, room,
  /// location), from the phone's cached copy. Only keys the cache actually
  /// had are sent; a `null` value means "shown as empty", which the server
  /// does compare. See [captureClaimsFrom].
  final Map<String, Object?> shownRegister;

  /// FR-3.11 — the crew could not finish this check (blocked access, missing
  /// tool, etc.) and wants the asset requeued for a return visit, regardless
  /// of what [result] itself says.
  final bool flagForReinspection;
  final String? flagReason;

  /// docs/ar-bim-overlay.md §8: where the AR workspace put the asset, how
  /// well it was aligned and the location check (`ArHandoff.toArContext`),
  /// when the check was started in AR (P-006). The server ignores unknown
  /// keys until AR-24 stores it.
  final Map<String, dynamic>? arContext;

  /// Capped at 8 client-side (FR-3.4) — the server has no explicit limit.
  final List<VerificationPhoto> photos;

  // FR-3.9 — GPS fix. Floor comes from the scan route context instead
  // (`AssetDetail.floorId`), not from this request — the server's verify
  // endpoint has no floor field of its own to attach it to.
  final double? latitude;
  final double? longitude;
  final double? gpsAccuracy;

  /// FR-4.7 — each photo rides as a placeholder handed to [SyncClient],
  /// substituted for the real upload URL once that photo lands (see
  /// [toAttachments]), rather than inlining its bytes here.
  static String _photoPlaceholder(int index) => '__pending_photo_${index}__';

  Map<String, dynamic> toJson() => {
    'result': result.name,
    'observedSerial': ?observedSerial,
    'observedTag': ?observedTag,
    'observedCondition': ?observedCondition?.name,
    'notes': ?notes,
    if (photos.isNotEmpty)
      'photos': [
        for (var i = 0; i < photos.length; i++)
          {
            'url': _photoPlaceholder(i),
            'name': photos[i].fileName,
            'contentType': photos[i].contentType,
          },
      ],
    if (latitude != null && longitude != null)
      'geo': {'lat': latitude, 'lng': longitude, 'accuracy': ?gpsAccuracy},
    if (flagForReinspection) 'flagForReinspection': true,
    if (flagForReinspection) 'flagReason': ?flagReason,
    if (claimedSerial != null || claimedTag != null || shownRegister.isNotEmpty)
      'captureClaims': {
        ...shownRegister,
        'serialNumber': ?claimedSerial,
        'assetReferenceId': ?claimedTag,
      },
    'arContext': ?arContext,
  };

  /// The queued upload for each entry in [photos], keyed to the same
  /// placeholders [toJson] wrote into the request body.
  List<QueuedAttachment> toAttachments() => [
    for (var i = 0; i < photos.length; i++)
      QueuedAttachment(
        bytes: photos[i].bytes,
        fileName: photos[i].fileName,
        placeholder: _photoPlaceholder(i),
        field: 'image',
      ),
  ];
}

/// Submits FR-3's capture form. Goes through [SyncClient] rather than the
/// raw API client so a verification recorded with no signal (a plant room,
/// a basement) queues like any other mutation and replays once the
/// technician is back online, instead of being lost.
class FieldVerificationRepository {
  FieldVerificationRepository(this._sync);

  final SyncClient _sync;

  Future<SyncedWrite> submit(String assetId, FieldVerificationRequest request) =>
      _sync.syncRequest(
        'post',
        '/api/c2o/assets/$assetId/verify',
        data: request.toJson(),
        label: 'Submit asset verification',
        entityType: 'Asset',
        entityId: assetId,
        attachments: request.toAttachments(),
      );
}

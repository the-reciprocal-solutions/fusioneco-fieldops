/// FR-4.10 — what is still only on this phone.
///
/// The Sync Center used to say "All caught up" whenever the queue was empty.
/// The queue is not the only place unsent work lives: a half-filled capture
/// form sits in `verification_drafts`, and a snag or AR mark the server has
/// not accepted stays behind as `local_only`/`pending`. A technician reading
/// "All caught up" before handing the phone over could still lose those.
/// "Nothing is left on this device" is only claimed when all of them are
/// empty.
///
/// "Unsent" is not redefined here: it is exactly what the sign-out wipe
/// refuses to delete ([kSignOutWipe]'s filtered steps), so the two can never
/// disagree about what counts as work the server does not have.
library;

import 'sign_out_wipe.dart';

/// One unfinished FR-3 capture form, enough to list it and reopen it.
class DraftSummary {
  const DraftSummary({
    required this.assetId,
    required this.updatedAt,
    this.assetName,
    this.claimedSerial,
    this.claimedTag,
    this.floorId,
    this.photoCount = 0,
  });

  /// Reads the screen-owned draft payload. Drafts saved before the name was
  /// stored in them simply come back without one.
  factory DraftSummary.fromPayload(
    String assetId,
    DateTime updatedAt,
    Map<String, dynamic> payload,
  ) {
    String? text(String key) {
      final v = payload[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final photos = payload['photos'];
    return DraftSummary(
      assetId: assetId,
      updatedAt: updatedAt,
      assetName: text('assetName'),
      claimedSerial: text('claimedSerial'),
      claimedTag: text('claimedTag'),
      floorId: text('floorId'),
      photoCount: photos is List ? photos.length : 0,
    );
  }

  /// One row of `OfflineDb`'s summary query (JSON fields pulled out by
  /// SQLite, so the photos are never decoded just to be counted).
  factory DraftSummary.fromSummaryRow(Map<String, Object?> row) {
    String? text(String key) {
      final v = row[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final count = row['photo_count'];
    return DraftSummary(
      assetId: row['asset_id']! as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
      assetName: text('asset_name'),
      claimedSerial: text('claimed_serial'),
      claimedTag: text('claimed_tag'),
      floorId: text('floor_id'),
      photoCount: count is int ? count : 0,
    );
  }

  final String assetId;
  final DateTime updatedAt;
  final String? assetName;
  final String? claimedSerial;
  final String? claimedTag;
  final String? floorId;
  final int photoCount;
}

class LeftOnDevice {
  const LeftOnDevice({
    required this.queued,
    required this.drafts,
    required this.unsentLocal,
  });

  static const empty = LeftOnDevice(queued: 0, drafts: [], unsentLocal: 0);

  /// Writes waiting in the offline queue.
  final int queued;

  /// Unfinished capture forms, newest first.
  final List<DraftSummary> drafts;

  /// Snags / AR marks the server does not have yet. May overlap [queued]
  /// (a local-only snag usually also has its create queued), so it is shown
  /// as its own line, never added to it.
  final int unsentLocal;

  bool get isEmpty => queued == 0 && drafts.isEmpty && unsentLocal == 0;
}

/// One `COUNT(*)` per filtered sign-out step, counting the rows that step
/// deliberately keeps (`NOT (where)`) — the unsent rows.
List<String> unsentLocalCountQueries([List<SignOutWipeStep> steps = kSignOutWipe]) => [
  for (final s in steps)
    if (s.where != null) 'SELECT COUNT(*) FROM ${s.table} WHERE NOT (${s.where})',
];

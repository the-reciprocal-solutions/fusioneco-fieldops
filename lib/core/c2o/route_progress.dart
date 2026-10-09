import '../offline/offline_db.dart';
import 'asset_detail.dart';

/// FR-5.2 (room-grouped list) / FR-5.3 (verified/outstanding/flagged
/// progress) — pure logic over a downloaded route's cached assets, kept
/// separate from `route_detail_screen.dart` for the same reason
/// `asset_detail.dart` is separate from its screen: testable without
/// Riverpod or a `BuildContext`.

/// One asset in a route's list — a lighter read than [AssetDetail], which
/// also carries twin/OCR fields this view has no use for, built from the
/// same `claims['asset']` shape.
class RouteAssetRow {
  const RouteAssetRow({
    required this.id,
    required this.name,
    required this.roomLabel,
    required this.status,
    this.levelLabel,
    this.queued = false,
  });

  final String id;
  final String? name;

  /// Null when the asset carries no Room step in its location walk — the
  /// caller decides what to call that bucket (localization lives with the
  /// widget, not here).
  final String? roomLabel;

  /// The Level step (code, else name) — rooms are walked floor by floor, so
  /// a building or system route must not interleave B-101 with G-101.
  final String? levelLabel;

  /// "pending" | "verified" | "mismatch" | "missing" — the server's
  /// `assets.c2oVerificationStatus` enum, read straight off the cached claim.
  final String status;

  /// A check for this asset is still in this phone's offline queue — counted
  /// already (FR-5.3 "live and offline"), but the server does not have it yet.
  final bool queued;

  RouteAssetRow withQueuedCheck(String queuedStatus) =>
      RouteAssetRow(
        id: id,
        name: name,
        roomLabel: roomLabel,
        levelLabel: levelLabel,
        status: queuedStatus,
        queued: true,
      );

  bool get isVerified => status == 'verified';
  bool get isFlagged => status == 'mismatch' || status == 'missing';
  bool get isOutstanding => !isVerified && !isFlagged;
}

/// Builds a [RouteAssetRow] from a cached c2o asset's `claims` — the same
/// wrapper shape `resolveScan()`/`RouteDownloadService.download` both write,
/// so this reads a scanned-in and a bulk-downloaded asset identically.
RouteAssetRow routeAssetRowFromClaims({
  required String assetId,
  String? assetReferenceId,
  required Map<String, dynamic> claims,
}) {
  final detail = AssetDetail.fromClaims(claims);
  String? step(String level) => detail?.locationPath
      .where((s) => s.level == level)
      .map((s) => s.code ?? s.label)
      .whereType<String>()
      .firstOrNull;
  final asset = claims['asset'];
  final status = asset is Map ? asset['verificationStatus']?.toString() : null;
  return RouteAssetRow(
    id: assetId,
    name: detail?.assetName ?? assetReferenceId,
    roomLabel: step('Room'),
    levelLabel: step('Level'),
    status: status ?? 'pending',
  );
}

/// The asset status the server sets for a check [result] — mirrors
/// `fieldVerificationService.ts` (verified → verified, missing → missing,
/// anything else → mismatch), so the phone's count agrees with the next
/// pack download instead of jumping when it arrives.
String verificationStatusForResult(String result) => switch (result) {
  'verified' => 'verified',
  'missing' => 'missing',
  _ => 'mismatch',
};

/// FR-5.3 offline — the cached claim with [status] written in, so the route
/// count moves the moment a check is submitted (queued or sent) and stays
/// moved after a force-quit. The cached status used to change only on the
/// next pack download, so a walk done underground read "0 verified"
/// throughout (found in the 2026-10-08 FR-5 review).
CachedC2oAsset withLocalVerificationStatus(CachedC2oAsset cached, String status) {
  final asset = cached.claims['asset'];
  return CachedC2oAsset(
    assetId: cached.assetId,
    assetReferenceId: cached.assetReferenceId,
    scanToken: cached.scanToken,
    claims: {
      ...cached.claims,
      'asset': {if (asset is Map) ...Map<String, dynamic>.from(asset), 'verificationStatus': status},
    },
    cachedAt: cached.cachedAt,
    packStamp: cached.packStamp,
  );
}

/// FR-5.3 offline — a check still waiting in the queue wins over the cached
/// status: re-downloading the route while it waits brings back the server's
/// older answer ("pending"), and that must not un-count work the technician
/// has done. The newest queued check per asset wins (the queue is oldest
/// first). Matched the same way as [queuedChecksForRoute].
List<RouteAssetRow> applyQueuedChecks(List<RouteAssetRow> rows, Iterable<PendingMutation> queue) {
  final queuedStatus = <String, String>{};
  for (final m in queue) {
    if (m.entityType != 'Asset' || m.entityId == null || !m.url.endsWith('/verify')) continue;
    final body = m.body;
    final result = body is Map ? body['result'] : null;
    if (result is String) queuedStatus[m.entityId!] = verificationStatusForResult(result);
  }
  if (queuedStatus.isEmpty) return rows;
  return [
    for (final r in rows)
      if (queuedStatus[r.id] case final status?) r.withQueuedCheck(status) else r,
  ];
}

/// FR-5.3 — verified/outstanding/flagged tallies for one route.
class RouteProgress {
  const RouteProgress({
    required this.verified,
    required this.outstanding,
    required this.flagged,
  });

  final int verified;
  final int outstanding;
  final int flagged;

  int get total => verified + outstanding + flagged;

  factory RouteProgress.from(List<RouteAssetRow> rows) => RouteProgress(
    verified: rows.where((r) => r.isVerified).length,
    outstanding: rows.where((r) => r.isOutstanding).length,
    flagged: rows.where((r) => r.isFlagged).length,
  );
}

/// FR-5.2 — one stop on the walk: a room on a level, and its assets.
class RouteRoomGroup {
  const RouteRoomGroup({required this.level, required this.room, required this.rows});

  /// Null when the assets carry no Level / Room step; the widget names that.
  final String? level;
  final String? room;
  final List<RouteAssetRow> rows;
}

/// FR-5.2 — the route as a walk: level by level, room by room, each in
/// natural order ("L2" before "L10", "Room 9" before "Room 10"), assets in
/// a room by name. Anything with no level or room comes after the known
/// ones — it isn't a real stop, so it shouldn't look like the first.
///
/// There are no room coordinates to plan a true shortest path with, so this
/// is the order signage is walked in. It replaced plain alphabetical rooms
/// (2026-10-08 review), which mixed floors on a building route and put
/// "Room 10" before "Room 9".
List<RouteRoomGroup> groupRouteForWalk(List<RouteAssetRow> rows) {
  final byStop = <(String?, String?), List<RouteAssetRow>>{};
  for (final row in rows) {
    byStop.putIfAbsent((row.levelLabel, row.roomLabel), () => []).add(row);
  }
  final stops = byStop.keys.toList()
    ..sort((a, b) {
      final level = _nullsLast(a.$1, b.$1);
      return level != 0 ? level : _nullsLast(a.$2, b.$2);
    });
  return [
    for (final stop in stops)
      RouteRoomGroup(
        level: stop.$1,
        room: stop.$2,
        rows: byStop[stop]!..sort((a, b) => naturalCompare(a.name ?? a.id, b.name ?? b.id)),
      ),
  ];
}

int _nullsLast(String? a, String? b) {
  if (a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return naturalCompare(a, b);
}

final _chunk = RegExp(r'\d+|\D+');

/// Compares runs of digits as numbers and everything else case-blind, so
/// "Room 9" < "Room 10" and "l2" < "L10".
int naturalCompare(String a, String b) {
  final x = _chunk.allMatches(a).map((m) => m[0]!).toList();
  final y = _chunk.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final nx = int.tryParse(x[i]);
    final ny = int.tryParse(y[i]);
    final c = nx != null && ny != null
        ? nx.compareTo(ny)
        : x[i].toLowerCase().compareTo(y[i].toLowerCase());
    if (c != 0) return c;
  }
  final byLength = x.length.compareTo(y.length);
  return byLength != 0 ? byLength : a.compareTo(b);
}

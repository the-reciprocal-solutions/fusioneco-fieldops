import 'dart:convert';

import '../c2o/asset_detail.dart';
import '../c2o/c2o_asset_resolver.dart';
import '../utils/qr_payload.dart';

/// Every scan the technician makes, kept on the phone (owner, 2026-10-06:
/// "When a scan finishes it is added to a queue, but I can't view the whole
/// queue. It only shows two scanned items … keep all past scans in local
/// storage so I can get to them with one tap").
///
/// Before this the scanner kept only an in-memory session list, drawn as a
/// strip of dots that showed about two entries on a phone and vanished
/// when the screen closed. Now each scan is written to the local DB as it
/// happens (offline-first: no network involved), listed in full on the
/// Scans page, and pruned to [ScanHistoryPolicy].
///
/// Pure Dart: the store is a seam ([ScanHistoryStore], implemented by
/// `OfflineDb`), so the rules here are tested without SQLCipher.

/// What the code turned out to be.
enum ScanKind {
  /// A C2O field-verification tag (resolved against the register).
  c2oAsset,

  /// A general asset label (opens the public asset sheet).
  asset,
  workOrder,
  material,

  /// Another of our `/public/*` pages.
  record,

  /// An AR board.
  marker,

  /// A Permit to Work worksite QR.
  permit,

  /// Someone else's link (opened in the browser).
  link,

  /// Plain text that is none of the above.
  text,
}

/// Where the scan stands. "Waiting" is the queued case: a C2O tag that
/// wasn't in the downloaded route and needs signal once to resolve; the
/// Scans page retries those.
enum ScanStatus {
  /// Resolved with the server.
  found,

  /// Resolved from what is already on the phone (no signal needed).
  foundOffline,

  /// Needs signal to resolve; retried later.
  waiting,

  /// Resolved to a problem (tag doesn't match, not in the register). See
  /// [ScanRecord.reasonKey].
  failed,

  /// Handed on (a board, a permit, a link): nothing to resolve here.
  opened,
}

class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.userId,
    required this.at,
    required this.kind,
    required this.status,
    required this.raw,
    required this.code,
    this.title,
    this.place,
    this.reasonKey,
    this.assetId,
    this.target,
    this.offRoute = false,
  });

  final String id;

  /// Whose scan. Rows are kept across sign-outs (a 24 h session expiry must
  /// not wipe a shift's history), so every read filters on the user signed in.
  final String userId;
  final DateTime at;
  final ScanKind kind;
  final ScanStatus status;

  /// Exactly what the camera read. Needed to retry a waiting C2O tag.
  final String raw;

  /// The short code to show: asset reference, board code, permit code, host.
  final String code;

  /// The resolved name ("CHW pump P-01"), when there is one.
  final String? title;

  /// Where: the asset's location walk ("Tower A › L3 › Plant room").
  final String? place;

  /// i18n key of the plain reason for [ScanStatus.failed] / waiting.
  final String? reasonKey;
  final String? assetId;

  /// What a tap opens: an in-app route, or an `http(s)` URL for [ScanKind.link].
  final String? target;

  /// FR-5.4: resolved, but not on the route being walked.
  final bool offRoute;

  ScanRecord copyWith({
    ScanStatus? status,
    String? title,
    String? place,
    String? reasonKey,
    bool clearReason = false,
    String? assetId,
    String? target,
  }) =>
      ScanRecord(
        id: id,
        userId: userId,
        at: at,
        kind: kind,
        status: status ?? this.status,
        raw: raw,
        code: code,
        title: title ?? this.title,
        place: place ?? this.place,
        reasonKey: clearReason ? null : (reasonKey ?? this.reasonKey),
        assetId: assetId ?? this.assetId,
        target: target ?? this.target,
        offRoute: offRoute,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'userId': userId,
        'at': at.millisecondsSinceEpoch,
        'kind': kind.name,
        'status': status.name,
        'raw': raw,
        'code': code,
        'title': ?title,
        'place': ?place,
        'reasonKey': ?reasonKey,
        'assetId': ?assetId,
        'target': ?target,
        if (offRoute) 'offRoute': true,
      };

  /// Tolerant: an unknown kind/status (a newer app wrote it) reads as
  /// text/opened rather than dropping the row.
  static ScanRecord? fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    final at = j['at'];
    if (id == null || at is! int) return null;
    String? s(String k) {
      final v = j[k]?.toString();
      return v == null || v.isEmpty ? null : v;
    }

    return ScanRecord(
      id: id,
      userId: j['userId']?.toString() ?? '',
      at: DateTime.fromMillisecondsSinceEpoch(at),
      kind: ScanKind.values.asNameMap()[j['kind']] ?? ScanKind.text,
      status: ScanStatus.values.asNameMap()[j['status']] ?? ScanStatus.opened,
      raw: j['raw']?.toString() ?? '',
      code: j['code']?.toString() ?? '',
      title: s('title'),
      place: s('place'),
      reasonKey: s('reasonKey'),
      assetId: s('assetId'),
      target: s('target'),
      offRoute: j['offRoute'] == true,
    );
  }

  String encode() => jsonEncode(toJson());
  static ScanRecord? decode(String text) {
    try {
      final j = jsonDecode(text);
      return j is Map ? fromJson(Map<String, dynamic>.from(j)) : null;
    } catch (_) {
      return null;
    }
  }

  /// For the search box: everything a technician might type.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [code, title, place, raw].any((v) => v != null && v.toLowerCase().contains(q));
  }
}

/// The local DB side. `OfflineDb` implements it (table `scan_history`).
abstract interface class ScanHistoryStore {
  /// Insert or replace (same [ScanRecord.id]).
  Future<void> putScan(ScanRecord record);

  /// Newest first, this user's only.
  Future<List<ScanRecord>> listScans(String userId, {int limit});

  /// Removes every row (all users) older than [cutoff].
  Future<void> deleteScansBefore(DateTime cutoff);

  /// Keeps this user's newest [keep] rows, removes the rest.
  Future<void> trimScans(String userId, int keep);

  Future<void> clearScans(String userId);
}

/// How much history the phone keeps: enough for weeks of rounds, small
/// enough that the list and the DB never grow without bound.
abstract final class ScanHistoryPolicy {
  static const maxEntries = 500;
  static const maxAge = Duration(days: 90);
}

/// The Scans page's filter chips.
enum ScanFilter { all, waiting, problems, assets, other }

extension ScanFilterTest on ScanFilter {
  bool accepts(ScanRecord r) => switch (this) {
        ScanFilter.all => true,
        ScanFilter.waiting => r.status == ScanStatus.waiting,
        ScanFilter.problems => r.status == ScanStatus.failed || r.offRoute,
        ScanFilter.assets => r.kind == ScanKind.c2oAsset || r.kind == ScanKind.asset,
        ScanFilter.other => r.kind != ScanKind.c2oAsset && r.kind != ScanKind.asset,
      };
}

/// Records, lists and prunes. Recording never throws: a full disk must not
/// stop a technician scanning.
class ScanHistory {
  ScanHistory(this._store, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ScanHistoryStore _store;
  final DateTime Function() _clock;
  var _seq = 0;

  DateTime now() => _clock();

  /// A unique, sortable id without a uuid package: time + a per-run counter.
  String newId() => '${_clock().microsecondsSinceEpoch}-${_seq++}';

  Future<bool> record(ScanRecord r) async {
    try {
      await _store.putScan(r);
      await prune(r.userId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> update(ScanRecord r) async {
    try {
      await _store.putScan(r);
    } catch (_) {}
  }

  Future<void> prune(String userId) async {
    await _store.deleteScansBefore(_clock().subtract(ScanHistoryPolicy.maxAge));
    await _store.trimScans(userId, ScanHistoryPolicy.maxEntries);
  }

  Future<List<ScanRecord>> list(String userId) =>
      _store.listScans(userId, limit: ScanHistoryPolicy.maxEntries);

  Future<void> clear(String userId) => _store.clearScans(userId);
}

// ------------------------------------------------------------- builders

/// The record for a C2O tag scan (FR-1.1 outcome → history row).
ScanRecord scanRecordForC2o({
  required String id,
  required String userId,
  required DateTime at,
  required String raw,
  required C2oResolution outcome,
  bool offRoute = false,
}) {
  switch (outcome) {
    case C2oResolved(:final assetId, :final claims, :final fromCache):
      final detail = AssetDetail.fromClaims(claims);
      return ScanRecord(
        id: id,
        userId: userId,
        at: at,
        kind: ScanKind.c2oAsset,
        status: fromCache ? ScanStatus.foundOffline : ScanStatus.found,
        raw: raw,
        code: detail?.assetReferenceId ?? assetId,
        title: detail?.assetName,
        place: placeOf(detail),
        assetId: assetId,
        target: '/asset/$assetId',
        offRoute: offRoute,
      );
    case C2oTokenMismatch(:final assetId):
      return ScanRecord(
        id: id,
        userId: userId,
        at: at,
        kind: ScanKind.c2oAsset,
        status: ScanStatus.failed,
        raw: raw,
        code: assetId,
        reasonKey: 'scans.reason_mismatch',
        assetId: assetId,
      );
    case C2oNotFound(:final assetId):
      return ScanRecord(
        id: id,
        userId: userId,
        at: at,
        kind: ScanKind.c2oAsset,
        status: ScanStatus.failed,
        raw: raw,
        code: assetId,
        reasonKey: 'scans.reason_not_found',
        assetId: assetId,
      );
    case C2oNeedsSignal(:final assetId):
      return ScanRecord(
        id: id,
        userId: userId,
        at: at,
        kind: ScanKind.c2oAsset,
        status: ScanStatus.waiting,
        raw: raw,
        code: assetId,
        reasonKey: 'scans.reason_waiting',
        assetId: assetId,
      );
  }
}

/// A waiting/failed C2O row updated with a fresh resolution (the Scans
/// page's retry). Keeps the original id, time and raw value.
ScanRecord rescanned(ScanRecord old, C2oResolution outcome) {
  final fresh = scanRecordForC2o(id: old.id, userId: old.userId, at: old.at, raw: old.raw, outcome: outcome);
  return ScanRecord(
    id: old.id,
    userId: old.userId,
    at: old.at,
    kind: old.kind,
    status: fresh.status,
    raw: old.raw,
    code: fresh.code,
    title: fresh.title ?? old.title,
    place: fresh.place ?? old.place,
    reasonKey: fresh.reasonKey,
    assetId: fresh.assetId ?? old.assetId,
    target: fresh.target ?? old.target,
    offRoute: old.offRoute,
  );
}

/// The record for one of our general QR labels (asset, work order, …).
ScanRecord scanRecordForLabel({
  required String id,
  required String userId,
  required DateTime at,
  required String raw,
  required ScannedRecord record,
  required String webBaseUrl,
}) {
  final path = record.path;
  final kind = path.startsWith('/public/assets/')
      ? ScanKind.asset
      : path.startsWith('/public/materials/')
          ? ScanKind.material
          : path.startsWith('/orders/work-order/')
              ? ScanKind.workOrder
              : ScanKind.record;
  final segs = Uri.parse(path).pathSegments;
  final idPart = segs.isEmpty ? path : segs.last;
  return ScanRecord(
    id: id,
    userId: userId,
    at: at,
    kind: kind,
    status: ScanStatus.found,
    raw: raw,
    code: idPart,
    // `/public/*` pages are web pages: stored as the full URL, which the
    // Scans page opens in the in-app browser, like the scanner's own
    // "Open" button does. Anything else is an in-app route.
    target: record.isPublic ? '$webBaseUrl$path' : path,
  );
}

/// The record for a board, a permit, a link or plain text.
ScanRecord scanRecordForOther({
  required String id,
  required String userId,
  required DateTime at,
  required String raw,
  required ScanKind kind,
  required String code,
  String? target,
}) =>
    ScanRecord(
      id: id,
      userId: userId,
      at: at,
      kind: kind,
      status: kind == ScanKind.text ? ScanStatus.found : ScanStatus.opened,
      raw: raw,
      code: code,
      target: target,
    );

/// "Tower A › L3 › Plant room", or the register's free-text location.
String? placeOf(AssetDetail? d) {
  if (d == null) return null;
  final steps = [
    for (final s in d.locationPath)
      if ((s.label ?? s.code) case final v? when v.trim().isNotEmpty) v.trim(),
  ];
  if (steps.isNotEmpty) return steps.join(' › ');
  return d.flatLocation;
}

/// A permit worksite token is long and opaque; show its start only.
String shortCode(String value, {int keep = 8}) =>
    value.length <= keep ? value : '${value.substring(0, keep)}…';

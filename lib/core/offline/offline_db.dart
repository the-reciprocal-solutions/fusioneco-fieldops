import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
// FR-4.1/NFR-1 — SQLCipher build of sqflite, same API surface, so this is
// the only file in the app that needs to know the store is encrypted.
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../c2o/route_pack.dart' show RouteScope;
import 'flush_policy.dart' show SyncLease;
import 'sign_out_wipe.dart';

/// One queued upload inside a [PendingMutation] — a photo, a voice note, a
/// face capture. Uploaded independently on flush and its own [placeholder]
/// in the mutation body substituted with the resulting URL; [uploadedUrl] is
/// persisted back to the row the moment that upload succeeds (FR-4.7), so a
/// later retry on the same mutation — another attachment failing, a 5xx on
/// the request itself, the app getting killed mid-flush — does not re-upload
/// bytes that already landed.
class PendingAttachment {
  const PendingAttachment({
    required this.bytes,
    required this.fileName,
    required this.field,
    required this.placeholder,
    this.uploadedUrl,
  });

  final Uint8List bytes;
  final String fileName;

  /// `file` (POST /api/upload/file) or `image` (POST /api/upload/image).
  final String field;

  /// Token inside the mutation body replaced by the uploaded URL.
  final String placeholder;

  final String? uploadedUrl;

  factory PendingAttachment.fromJson(Map<String, dynamic> json) =>
      PendingAttachment(
        bytes: base64Decode(json['bytesBase64'] as String),
        fileName: json['fileName'] as String,
        field: json['field'] as String,
        placeholder: json['placeholder'] as String,
        uploadedUrl: json['uploadedUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'bytesBase64': base64Encode(bytes),
    'fileName': fileName,
    'field': field,
    'placeholder': placeholder,
    'uploadedUrl': ?uploadedUrl,
  };

  PendingAttachment withUploadedUrl(String url) => PendingAttachment(
    bytes: bytes,
    fileName: fileName,
    field: field,
    placeholder: placeholder,
    uploadedUrl: url,
  );
}

/// Mirrors the web portal's IndexedDB stores: a mutation queue, a GET cache, a
/// meta table and a capped conflict log.
class PendingMutation {
  const PendingMutation({
    required this.clientMutationId,
    required this.method,
    required this.url,
    required this.body,
    required this.label,
    required this.attempts,
    required this.createdAt,
    this.attachments = const [],
    this.entityType,
    this.entityId,
  });

  final String clientMutationId;
  final String method;
  final String url;
  final dynamic body;
  final String label;
  final int attempts;
  final DateTime createdAt;

  /// FR-4.7 — zero or more queued uploads this mutation's body references by
  /// placeholder. Most mutations have none; a field verification can have up
  /// to 8 (one per photo), each uploaded and resolved independently.
  final List<PendingAttachment> attachments;

  /// The order this write belongs to — an [OrderType.name], not its slug —
  /// and its record id. Stamped by the repository at enqueue time rather than
  /// parsed back out of [url]: the URL shape differs per endpoint (downtime's
  /// path puts a fixed segment before the record's own vocabulary), so it is
  /// not reliably reversible. Null for a request that never went through a
  /// [PendingMutation]-aware repository call. Used only to group and label
  /// the Sync Center list — never sent to the server.
  final String? entityType;
  final String? entityId;

  bool get hasAttachments => attachments.isNotEmpty;

  factory PendingMutation.fromRow(Map<String, Object?> row) {
    final attachmentsJson = row['attachments_json'] as String?;
    List<PendingAttachment> attachments;
    if (attachmentsJson != null && attachmentsJson.isNotEmpty) {
      attachments = (jsonDecode(attachmentsJson) as List)
          .map((e) => PendingAttachment.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      // A row queued before the FR-4.7 migration — its one attachment (if
      // any) still lives in the old singular columns rather than
      // `attachments_json`. Read it back the same way so an in-flight queue
      // survives the app update instead of silently dropping its photo.
      final legacyBytes = row['attachment'] as Uint8List?;
      final legacyField = row['attachment_field'] as String?;
      attachments = legacyBytes != null && legacyField != null
          ? [
              PendingAttachment(
                bytes: legacyBytes,
                fileName: row['attachment_name'] as String? ?? 'attachment',
                field: legacyField,
                placeholder: row['placeholder'] as String? ?? '',
              ),
            ]
          : const [];
    }
    return PendingMutation(
      clientMutationId: row['client_mutation_id'] as String,
      method: row['method'] as String,
      url: row['url'] as String,
      body: row['body'] == null ? null : jsonDecode(row['body'] as String),
      label: row['label'] as String? ?? 'Change',
      attempts: row['attempts'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      attachments: attachments,
      entityType: row['entity_type'] as String?,
      entityId: row['entity_id'] as String?,
    );
  }

  Map<String, Object?> toRow() => {
    'client_mutation_id': clientMutationId,
    'method': method,
    'url': url,
    'body': body == null ? null : jsonEncode(body),
    'label': label,
    'attempts': attempts,
    'created_at': createdAt.millisecondsSinceEpoch,
    'attachments_json': attachments.isEmpty
        ? null
        : jsonEncode(attachments.map((a) => a.toJson()).toList()),
    'entity_type': entityType,
    'entity_id': entityId,
  };
}

class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.label,
    required this.url,
    required this.reason,
    required this.at,
    required this.dropped,
  });

  final int id;
  final String label;
  final String url;
  final String reason;
  final DateTime at;
  final bool dropped;

  factory SyncConflict.fromRow(Map<String, Object?> row) => SyncConflict(
    id: row['id'] as int,
    label: row['label'] as String? ?? 'Change',
    url: row['url'] as String? ?? '',
    reason: row['reason'] as String? ?? '',
    at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
    dropped: (row['dropped'] as int? ?? 1) == 1,
  );
}

class CachedEntity {
  const CachedEntity({
    required this.body,
    required this.cachedAt,
    required this.ttlMs,
  });

  final dynamic body;
  final DateTime cachedAt;
  final int ttlMs;

  bool get isExpired =>
      DateTime.now().difference(cachedAt).inMilliseconds > ttlMs;
}

/// A resolved c2o asset, cached offline so a later scan of the same tag
/// answers from the local store — see FR-1.1. Keyed by `assetId`, but also
/// carries `assetReferenceId` because the tokenless general Asset label
/// (`AssetLabel.tsx`) bakes that human-readable id into its QR instead of the
/// real uuid, and a lookup needs to match either one.
class CachedC2oAsset {
  const CachedC2oAsset({
    required this.assetId,
    required this.claims,
    required this.cachedAt,
    this.assetReferenceId,
    this.scanToken,
    this.packStamp,
  });

  final String assetId;
  final String? assetReferenceId;

  /// Null for an asset cached from the tokenless general label.
  final String? scanToken;

  /// The full `resolveScan()` response body, unpacked lazily by FR-2's
  /// display screen rather than re-shaped here.
  final Map<String, dynamic> claims;
  final DateTime cachedAt;

  /// The route pack's "as-of" stamp (SR-2), once FR-5 downloads packs in
  /// bulk. Null for an asset cached one-at-a-time via a live scan.
  final String? packStamp;

  factory CachedC2oAsset.fromRow(Map<String, Object?> row) => CachedC2oAsset(
    assetId: row['asset_id'] as String,
    assetReferenceId: row['asset_reference_id'] as String?,
    scanToken: row['scan_token'] as String?,
    claims: Map<String, dynamic>.from(
      jsonDecode(row['claims'] as String) as Map,
    ),
    cachedAt: DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int),
    packStamp: row['pack_stamp'] as String?,
  );

  Map<String, Object?> toRow() => {
    'asset_id': assetId,
    'asset_reference_id': assetReferenceId,
    'scan_token': scanToken,
    'claims': jsonEncode(claims),
    'cached_at': cachedAt.millisecondsSinceEpoch,
    'pack_stamp': packStamp,
  };
}

/// The c2o-cache operations `C2oAssetResolver` and the FR-1.6 manual search
/// need, pulled out of [OfflineDb] so a test can fake them without touching
/// sqflite.
abstract interface class C2oAssetCache {
  Future<CachedC2oAsset?> getC2oAsset(String idOrReference);
  Future<void> upsertC2oAsset(CachedC2oAsset asset);

  /// Every asset in today's downloaded route — FR-1.6 searches this list
  /// entirely on-device, never the network, since a technician reaching for
  /// manual search has usually already established there is no tag to scan.
  Future<List<CachedC2oAsset>> listC2oAssets();
}

/// A structured, countable "tag missing/unreadable" report (FR-1.7),
/// captured against an asset found via manual search (FR-1.6) rather than
/// scanned. Local-only for now: the server has no field for this yet
/// (SR-6) and there is no submission flow to send it through (FR-3/FR-4)
/// — this table is what makes the report real and countable on-device in
/// the meantime, instead of it disappearing into a notes field.
enum TagIssueReason { missing, unreadable }

class TagIssueReport {
  const TagIssueReport({
    this.id,
    required this.assetId,
    this.assetReferenceId,
    this.assetName,
    required this.reason,
    this.note,
    required this.reportedAt,
  });

  final int? id;
  final String assetId;
  final String? assetReferenceId;
  final String? assetName;
  final TagIssueReason reason;
  final String? note;
  final DateTime reportedAt;

  factory TagIssueReport.fromRow(Map<String, Object?> row) => TagIssueReport(
    id: row['id'] as int?,
    assetId: row['asset_id'] as String,
    assetReferenceId: row['asset_reference_id'] as String?,
    assetName: row['asset_name'] as String?,
    reason: TagIssueReason.values.byName(row['reason'] as String),
    note: row['note'] as String?,
    reportedAt: DateTime.fromMillisecondsSinceEpoch(row['reported_at'] as int),
  );

  Map<String, Object?> toRow() => {
    'asset_id': assetId,
    'asset_reference_id': assetReferenceId,
    'asset_name': assetName,
    'reason': reason.name,
    'note': note,
    'reported_at': reportedAt.millisecondsSinceEpoch,
  };
}

abstract interface class TagIssueLog {
  Future<void> reportTagIssue(TagIssueReport report);
  Future<List<TagIssueReport>> listTagIssueReports();
}

/// FR-4.2 — the in-progress FR-3 capture form, autosaved continuously so a
/// force-quit or an OS kill (a phone call, low memory, a crash) never costs
/// the technician a half-filled check. One draft per asset; a fresh
/// [saveDraft] for the same [assetId] replaces the last one rather than
/// accumulating history — this is a save slot, not a log.
class VerificationDraft {
  const VerificationDraft({
    required this.assetId,
    required this.payload,
    required this.updatedAt,
  });

  final String assetId;

  /// Opaque to this layer — the screen owns the shape (result, observed
  /// fields, photos as base64, notes, the reinspection flag/reason, the GPS
  /// fix). Keeping it schemaless here means a new FR-3 field never needs a
  /// migration just to survive a crash.
  final Map<String, dynamic> payload;
  final DateTime updatedAt;

  factory VerificationDraft.fromRow(Map<String, Object?> row) =>
      VerificationDraft(
        assetId: row['asset_id'] as String,
        payload: Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map,
        ),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          row['updated_at'] as int,
        ),
      );

  Map<String, Object?> toRow() => {
    'asset_id': assetId,
    'payload': jsonEncode(payload),
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };
}

abstract interface class VerificationDraftStore {
  Future<void> saveDraft(String assetId, Map<String, dynamic> payload);
  Future<VerificationDraft?> getDraft(String assetId);
  Future<void> deleteDraft(String assetId);
}

/// FR-5.1/SR-2 — a downloaded route's identity and freshness stamp. Its
/// assets are NOT duplicated here: each one is upserted into the shared
/// `c2o_assets` cache (same table FR-1.1's single-scan resolve already
/// writes to), and [assetIds] is just the list needed to pull this route's
/// own assets back out of that shared table for a progress/list view.
class DownloadedRoutePack {
  const DownloadedRoutePack({
    required this.scope,
    required this.id,
    required this.asOf,
    required this.versionTag,
    required this.assetIds,
    required this.downloadedAt,
    this.packageId,
    this.projectId,
  });

  final RouteScope scope;
  final String id;

  /// SR-2's pack timestamp — FR-5.7's "stamp the pack, show its age" starts
  /// here, not [downloadedAt] (a slow download could finish well after the
  /// server assembled the data).
  final DateTime asOf;
  final String versionTag;
  final List<String> assetIds;
  final DateTime downloadedAt;

  /// The anchor this route was downloaded with — needed again for a
  /// conditional-refresh call against a non-package scope (SR-1's building/
  /// level/system scopes require the same anchor on every request).
  final String? packageId;
  final String? projectId;

  int get assetCount => assetIds.length;

  /// FR-5.7 — how stale this download is. The actual "too old to verify
  /// against" THRESHOLD is a product/UI decision, not baked in here.
  Duration get age => DateTime.now().difference(asOf);

  factory DownloadedRoutePack.fromRow(Map<String, Object?> row) =>
      DownloadedRoutePack(
        scope: RouteScope.values.byName(row['scope'] as String),
        id: row['scope_id'] as String,
        asOf: DateTime.fromMillisecondsSinceEpoch(row['as_of'] as int),
        versionTag: row['version_tag'] as String,
        assetIds: List<String>.from(
          jsonDecode(row['asset_ids'] as String) as List,
        ),
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(
          row['downloaded_at'] as int,
        ),
        packageId: row['package_id'] as String?,
        projectId: row['project_id'] as String?,
      );

  Map<String, Object?> toRow() => {
    'scope': scope.name,
    'scope_id': id,
    'as_of': asOf.millisecondsSinceEpoch,
    'version_tag': versionTag,
    'asset_ids': jsonEncode(assetIds),
    'downloaded_at': downloadedAt.millisecondsSinceEpoch,
    'package_id': packageId,
    'project_id': projectId,
  };
}

abstract interface class RoutePackStore {
  Future<void> saveRoutePack(DownloadedRoutePack pack);
  Future<List<DownloadedRoutePack>> listRoutePacks();
  Future<void> deleteRoutePack(RouteScope scope, String id);
}

/// Snag Assistant's local store (docs/snag-assistant.md §6). A snag is
/// written here *first*, so the UI never waits on the network; the server
/// write is queued separately through [SyncClient]. The row holds the whole
/// snag as JSON — the columns beside it exist only to filter without
/// decoding every row.
class StoredSnagRow {
  const StoredSnagRow({required this.id, required this.json, required this.localOnly});
  final String id;
  final Map<String, dynamic> json;
  final bool localOnly;
}

/// One row for [SnagStore.upsertSnags].
class SnagRowWrite {
  const SnagRowWrite({
    required this.id,
    required this.json,
    required this.status,
    required this.localOnly,
    required this.updatedAt,
    this.buildingId,
    this.surveyId,
  });
  final String id;
  final Map<String, dynamic> json;
  final String? buildingId;
  final String? surveyId;
  final String status;
  final bool localOnly;
  final DateTime updatedAt;
}

abstract interface class SnagStore {
  /// Many rows in one batch — a building refresh used to write its snags
  /// one transaction each (hundreds of SQLCipher round trips per pull).
  Future<void> upsertSnags(List<SnagRowWrite> rows);

  Future<void> upsertSnag({
    required String id,
    required Map<String, dynamic> json,
    String? buildingId,
    String? surveyId,
    required String status,
    required bool localOnly,
    required DateTime updatedAt,
  });
  Future<StoredSnagRow?> getSnag(String id);

  /// All snags, or one building's when [buildingId] is set.
  Future<List<StoredSnagRow>> listSnags({String? buildingId});

  /// Removes server-known rows for [buildingId] that are not in [keepIds] —
  /// a snag deleted or moved on the server. Never touches local-only rows.
  Future<void> pruneSnags({required String buildingId, required Set<String> keepIds});

  Future<void> upsertSurvey({
    required String id,
    required Map<String, dynamic> json,
    String? buildingId,
    required bool localOnly,
    required DateTime updatedAt,
  });
  Future<Map<String, dynamic>?> getSurvey(String id);
  Future<List<Map<String, dynamic>>> listSurveys({String? buildingId});

  /// Entity ids with a write still waiting in the queue, for one entity type.
  /// A snag in this set is *ahead* of the server, so a fetch must not
  /// overwrite it.
  Future<Set<String>> pendingEntityIds(String entityType);
}

/// An AR floor pack's manifest as stored (docs/ar-bim-overlay.md §6.8,
/// CONTRACT C8). [json] is the manifest exactly as the server sent it, so a
/// read-back parses what was received; [etag] is sent back as
/// `If-None-Match` so an unchanged floor costs one 304.
class StoredArManifest {
  const StoredArManifest({
    required this.scopeId,
    required this.json,
    required this.savedAt,
    this.scope = 'floor',
    this.buildingId,
    this.etag,
    this.tileHashes = const [],
    this.meta = const {},
  });

  /// `floor` today; the route-pack scopes (`package`, `system`, …) later.
  final String scope;
  final String scopeId;
  final String? buildingId;
  final String? etag;
  final Map<String, dynamic> json;

  /// Local context the manifest doesn't carry (building name, the focus
  /// board), so an offline resolve can still say "Tower A · Level 3".
  final Map<String, dynamic> meta;

  /// Every tile hash the manifest references — what tile GC keeps.
  final List<String> tileHashes;
  final DateTime savedAt;

  factory StoredArManifest.fromRow(Map<String, Object?> row) => StoredArManifest(
    scope: row['scope'] as String,
    scopeId: row['scope_id'] as String,
    buildingId: row['building_id'] as String?,
    etag: row['etag'] as String?,
    tileHashes: List<String>.from(jsonDecode(row['tile_hashes'] as String) as List),
    json: Map<String, dynamic>.from(jsonDecode(row['json'] as String) as Map),
    meta: row['meta'] == null
        ? const {}
        : Map<String, dynamic>.from(jsonDecode(row['meta'] as String) as Map),
    savedAt: DateTime.fromMillisecondsSinceEpoch(row['saved_at'] as int),
  );

  Map<String, Object?> toRow() => {
    'scope': scope,
    'scope_id': scopeId,
    'building_id': buildingId,
    'etag': etag,
    'tile_hashes': jsonEncode(tileHashes),
    'json': jsonEncode(json),
    'meta': jsonEncode(meta),
    'saved_at': savedAt.millisecondsSinceEpoch,
  };
}

/// A tile file on disk. The GLB lives at [path], never in a row (a 2 MB
/// base64 blob per row is what already costs the Sync Center an O(n²)
/// decode, improvements.md #12). Tiles are content-addressed and shared
/// across manifests: two floors that reference one tile store it once.
class StoredArTile {
  const StoredArTile({
    required this.hash,
    required this.path,
    required this.bytes,
    required this.lastUsedAt,
  });

  final String hash;
  final String path;
  final int bytes;

  /// For least-recently-used GC when the tile store is over its cap.
  final DateTime lastUsedAt;

  factory StoredArTile.fromRow(Map<String, Object?> row) => StoredArTile(
    hash: row['hash'] as String,
    path: row['path'] as String,
    bytes: row['bytes'] as int? ?? 0,
    lastUsedAt: DateTime.fromMillisecondsSinceEpoch(row['last_used_at'] as int),
  );

  Map<String, Object?> toRow() => {
    'hash': hash,
    'path': path,
    'bytes': bytes,
    'last_used_at': lastUsedAt.millisecondsSinceEpoch,
  };
}

/// The AR floor-pack store (schema v10), pulled out of [OfflineDb] so
/// `ArRepository` can be tested with an in-memory fake. Rows are JSON maps
/// in the server's shapes; `lib/domain/ar_models.dart` parses them.
abstract interface class ArPackStore {
  /// Saves a floor's manifest together with its markers, corners and grid
  /// lines, replacing what the floor had, in one transaction. Markers bound
  /// on this phone and not yet known to the server (`localOnly`) survive.
  Future<void> saveArManifest(
    StoredArManifest manifest, {
    List<Map<String, dynamic>> markers = const [],
    List<Map<String, dynamic>> corners = const [],
    List<Map<String, dynamic>> gridLines = const [],
  });
  Future<StoredArManifest?> getArManifest(String scopeId, {String scope = 'floor'});
  Future<List<StoredArManifest>> listArManifests();

  /// Removes the manifest and its markers, corners, grid lines and
  /// progress. Tile files are left for [ArPackStore.deleteArTiles] via GC,
  /// because another floor may share them.
  Future<void> deleteArManifest(String scopeId, {String scope = 'floor'});

  Future<StoredArTile?> getArTile(String hash);
  Future<List<StoredArTile>> listArTiles();
  Future<void> upsertArTile(StoredArTile tile);
  Future<void> touchArTiles(List<String> hashes, DateTime at);
  Future<void> deleteArTiles(List<String> hashes);

  Future<void> upsertArFeatures(String buildId, List<Map<String, dynamic>> features);
  Future<List<Map<String, dynamic>>> listArFeatures(String buildId);

  /// Features by GlobalId or register asset, across every stored build —
  /// "Show in AR" from an asset or a work order starts here.
  Future<List<Map<String, dynamic>>> findArFeatures({String? globalId, String? assetId});

  /// Keyed by the marker's canonical `code`; `floorId`, `buildingId`,
  /// `label` and `status` are read from the map for the index columns.
  Future<void> upsertArMarker(Map<String, dynamic> marker, {bool localOnly = false});
  Future<Map<String, dynamic>?> getArMarker(String code);
  Future<List<Map<String, dynamic>>> listArMarkers({String? floorId, String? buildingId});

  /// Drops a board bound on this phone that the server refused (bound
  /// elsewhere first).
  Future<void> deleteArMarker(String code);

  Future<List<Map<String, dynamic>>> listArCorners(String floorId);
  Future<List<Map<String, dynamic>>> listArGridLines(String floorId);

  /// A local status change, written before the network (local-first, like
  /// snags); [pending] marks it as ahead of the server.
  Future<void> upsertArProgress(
    String floorId,
    List<Map<String, dynamic>> rows, {
    required bool pending,
  });

  /// The server's statuses for a floor. With [keepPending], rows this phone
  /// changed and hasn't synced yet are kept instead of overwritten.
  Future<void> replaceArProgress(
    String floorId,
    List<Map<String, dynamic>> rows, {
    bool keepPending = true,
  });
  Future<List<Map<String, dynamic>>> listArProgress(String floorId);

  /// Small per-device AR settings ("remember my method for this floor").
  /// A null [value] removes the key.
  Future<String?> getArPref(String key);
  Future<void> setArPref(String key, String? value);
}

class OfflineDb
    implements
        C2oAssetCache,
        TagIssueLog,
        VerificationDraftStore,
        RoutePackStore,
        SnagStore,
        ArPackStore,
        WipeExecutor {
  OfflineDb._(this._db);

  static const _fileName = 'fusion_eco_offline.db';
  static const _conflictCap = 50;

  final Database _db;

  static Future<OfflineDb> open({required String passphrase}) async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, _fileName),
      password: passphrase,
      version: 10,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE pending_mutations (
            client_mutation_id TEXT PRIMARY KEY,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            body TEXT,
            label TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            attachments_json TEXT,
            entity_type TEXT,
            entity_id TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_pending_created_at ON pending_mutations (created_at)',
        );
        await db.execute(
          'CREATE INDEX idx_pending_entity ON pending_mutations (entity_type, entity_id)',
        );
        await db.execute('''
          CREATE TABLE cached_entities (
            url TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            cached_at INTEGER NOT NULL,
            ttl_ms INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_meta (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE conflicts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            label TEXT,
            url TEXT,
            reason TEXT,
            at INTEGER NOT NULL,
            dropped INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute(_createC2oAssetsSql);
        await db.execute(
          'CREATE INDEX idx_c2o_assets_reference ON c2o_assets (asset_reference_id)',
        );
        await db.execute(_createTagIssueReportsSql);
        await db.execute(_createDraftsSql);
        await db.execute(_createRoutePacksSql);
        await _createSnagTables(db);
        await _createArTables(db);
      },
      // v1 → v2: which order a queued write belongs to, for the Sync Center
      // list. Existing rows just come back with both columns null — they
      // still show up in the list, minus the order grouping.
      // v2 → v3: the c2o field-verification asset cache (FR-1.1).
      // v3 → v4: local tag-missing/unreadable reports (FR-1.7).
      // v4 → v5: FR-3 capture-form drafts (FR-4.2).
      // v5 → v6: multi-attachment queue rows, one upload per photo (FR-4.7).
      // v6 → v7: index the Sync Center's per-entity grouping (FR-4.9 — also
      // the first migration exercised live against a populated queue).
      // v7 → v8: downloaded route packs (FR-5.1/SR-1).
      // v8 → v9: Snag Assistant local store (snags, snag_surveys).
      // v9 → v10: AR floor packs (ar_manifests, ar_tiles, ar_features,
      // ar_markers, ar_corners, ar_grid_lines, ar_progress, ar_prefs).
      // New tables only, so every existing row reads back unchanged.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE pending_mutations ADD COLUMN entity_type TEXT',
          );
          await db.execute(
            'ALTER TABLE pending_mutations ADD COLUMN entity_id TEXT',
          );
        }
        if (oldVersion < 3) {
          await db.execute(_createC2oAssetsSql);
          await db.execute(
            'CREATE INDEX idx_c2o_assets_reference ON c2o_assets (asset_reference_id)',
          );
        }
        if (oldVersion < 4) {
          await db.execute(_createTagIssueReportsSql);
        }
        if (oldVersion < 5) {
          await db.execute(_createDraftsSql);
        }
        if (oldVersion < 6) {
          await db.execute(
            'ALTER TABLE pending_mutations ADD COLUMN attachments_json TEXT',
          );
        }
        if (oldVersion < 7) {
          await db.execute(
            'CREATE INDEX idx_pending_entity ON pending_mutations (entity_type, entity_id)',
          );
        }
        if (oldVersion < 8) {
          await db.execute(_createRoutePacksSql);
        }
        if (oldVersion < 9) {
          await _createSnagTables(db);
        }
        if (oldVersion < 10) {
          await _createArTables(db);
        }
      },
    );
    return OfflineDb._(db);
  }

  static const _createC2oAssetsSql = '''
    CREATE TABLE c2o_assets (
      asset_id TEXT PRIMARY KEY,
      asset_reference_id TEXT,
      scan_token TEXT,
      claims TEXT NOT NULL,
      cached_at INTEGER NOT NULL,
      pack_stamp TEXT
    )
  ''';

  static const _createTagIssueReportsSql = '''
    CREATE TABLE tag_issue_reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      asset_id TEXT NOT NULL,
      asset_reference_id TEXT,
      asset_name TEXT,
      reason TEXT NOT NULL,
      note TEXT,
      reported_at INTEGER NOT NULL
    )
  ''';

  static const _createDraftsSql = '''
    CREATE TABLE verification_drafts (
      asset_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''';

  static const _createRoutePacksSql = '''
    CREATE TABLE route_packs (
      scope TEXT NOT NULL,
      scope_id TEXT NOT NULL,
      as_of INTEGER NOT NULL,
      version_tag TEXT NOT NULL,
      asset_ids TEXT NOT NULL,
      downloaded_at INTEGER NOT NULL,
      package_id TEXT,
      project_id TEXT,
      PRIMARY KEY (scope, scope_id)
    )
  ''';

  static Future<void> _createSnagTables(Database db) async {
    await db.execute('''
      CREATE TABLE snags (
        id TEXT PRIMARY KEY,
        building_id TEXT,
        survey_id TEXT,
        status TEXT NOT NULL,
        local_only INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        json TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_snags_building ON snags (building_id)');
    await db.execute('''
      CREATE TABLE snag_surveys (
        id TEXT PRIMARY KEY,
        building_id TEXT,
        local_only INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        json TEXT NOT NULL
      )
    ''');
  }

  /// AR floor packs (schema v10, docs/ar-bim-overlay.md §6.8). Tile bytes are
  /// files on disk (`<appSupport>/ar/tiles/<hash>.glb`); `ar_tiles` only
  /// indexes them.
  static Future<void> _createArTables(Database db) async {
    await db.execute('''
      CREATE TABLE ar_manifests (
        scope TEXT NOT NULL,
        scope_id TEXT NOT NULL,
        building_id TEXT,
        etag TEXT,
        tile_hashes TEXT NOT NULL,
        json TEXT NOT NULL,
        meta TEXT,
        saved_at INTEGER NOT NULL,
        PRIMARY KEY (scope, scope_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE ar_tiles (
        hash TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        last_used_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE ar_features (
        build_id TEXT NOT NULL,
        feature_id INTEGER NOT NULL,
        global_id TEXT NOT NULL,
        asset_id TEXT,
        floor_id TEXT,
        json TEXT NOT NULL,
        PRIMARY KEY (build_id, feature_id)
      )
    ''');
    await db.execute('CREATE INDEX idx_ar_features_global ON ar_features (global_id)');
    await db.execute('CREATE INDEX idx_ar_features_asset ON ar_features (asset_id)');
    await db.execute('''
      CREATE TABLE ar_markers (
        code TEXT PRIMARY KEY,
        building_id TEXT,
        floor_id TEXT,
        label TEXT,
        status TEXT,
        local_only INTEGER NOT NULL DEFAULT 0,
        json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_ar_markers_floor ON ar_markers (floor_id)');
    await db.execute('''
      CREATE TABLE ar_corners (
        floor_id TEXT NOT NULL,
        id TEXT NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY (floor_id, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE ar_grid_lines (
        floor_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        name TEXT,
        json TEXT NOT NULL,
        PRIMARY KEY (floor_id, seq)
      )
    ''');
    await db.execute('''
      CREATE TABLE ar_progress (
        floor_id TEXT NOT NULL,
        global_id TEXT NOT NULL,
        status TEXT NOT NULL,
        pending INTEGER NOT NULL DEFAULT 0,
        json TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (floor_id, global_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE ar_prefs (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  Future<void> enqueue(PendingMutation mutation) async {
    await _db.insert(
      'pending_mutations',
      mutation.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Oldest first — replay order is what keeps RCA → downtime → complete correct.
  Future<List<PendingMutation>> listMutations() async {
    final rows = await _db.query(
      'pending_mutations',
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingMutation.fromRow).toList();
  }

  Future<int> countMutations() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery('SELECT COUNT(*) FROM pending_mutations'),
      ) ??
      0;

  Future<void> deleteMutation(String id) => _db.delete(
    'pending_mutations',
    where: 'client_mutation_id = ?',
    whereArgs: [id],
  );

  Future<void> bumpAttempts(String id, int attempts) => _db.update(
    'pending_mutations',
    {'attempts': attempts},
    where: 'client_mutation_id = ?',
    whereArgs: [id],
  );

  /// FR-4.7 — called right after each individual attachment upload succeeds
  /// during a flush, so a photo that already landed is never re-sent by a
  /// later retry on the same mutation.
  Future<void> updateMutationAttachments(
    String id,
    List<PendingAttachment> attachments,
  ) => _db.update(
    'pending_mutations',
    {
      'attachments_json': attachments.isEmpty
          ? null
          : jsonEncode(attachments.map((a) => a.toJson()).toList()),
    },
    where: 'client_mutation_id = ?',
    whereArgs: [id],
  );

  Future<CachedEntity?> readCache(String url) async {
    final rows = await _db.query(
      'cached_entities',
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return CachedEntity(
      body: jsonDecode(row['body'] as String),
      cachedAt: DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int),
      ttlMs: row['ttl_ms'] as int,
    );
  }

  Future<void> writeCache(String url, dynamic body, Duration ttl) =>
      _db.insert('cached_entities', {
        'url': url,
        'body': jsonEncode(body),
        'cached_at': DateTime.now().millisecondsSinceEpoch,
        'ttl_ms': ttl.inMilliseconds,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String?> readMeta(String key) async {
    final rows = await _db.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> writeMeta(String key, String value) => _db.insert('sync_meta', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static const _flushLeaseKey = 'flush_lease';

  /// FR-4.4 — take or renew the queue-drain lease (see [SyncLease]). Read and
  /// write happen in one transaction, so the app and a background run racing
  /// for it can't both win.
  Future<bool> tryAcquireFlushLease(String owner) =>
      _db.transaction((txn) async {
        final rows = await txn.query(
          'sync_meta',
          where: 'key = ?',
          whereArgs: [_flushLeaseKey],
          limit: 1,
        );
        final current = SyncLease.decode(
          rows.isEmpty ? null : rows.first['value'] as String?,
        );
        final now = DateTime.now();
        if (!SyncLease.canTake(current, owner, now)) return false;
        await txn.insert('sync_meta', {
          'key': _flushLeaseKey,
          'value': SyncLease(
            owner: owner,
            expiresAt: now.add(SyncLease.ttl),
          ).encode(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return true;
      });

  /// Gives the lease up, but only if [owner] still holds it.
  Future<void> releaseFlushLease(String owner) => _db.transaction((txn) async {
    final rows = await txn.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [_flushLeaseKey],
      limit: 1,
    );
    final current = SyncLease.decode(
      rows.isEmpty ? null : rows.first['value'] as String?,
    );
    if (current?.owner == owner) {
      await txn.delete(
        'sync_meta',
        where: 'key = ?',
        whereArgs: [_flushLeaseKey],
      );
    }
  });

  Future<void> addConflict({
    required String label,
    required String url,
    required String reason,
    bool dropped = true,
  }) async {
    await _db.insert('conflicts', {
      'label': label,
      'url': url,
      'reason': reason,
      'at': DateTime.now().millisecondsSinceEpoch,
      'dropped': dropped ? 1 : 0,
    });
    await _db.rawDelete(
      'DELETE FROM conflicts WHERE id NOT IN '
      '(SELECT id FROM conflicts ORDER BY at DESC LIMIT $_conflictCap)',
    );
  }

  Future<List<SyncConflict>> listConflicts() async {
    final rows = await _db.query('conflicts', orderBy: 'at DESC');
    return rows.map(SyncConflict.fromRow).toList();
  }

  Future<void> deleteConflict(int id) =>
      _db.delete('conflicts', where: 'id = ?', whereArgs: [id]);

  Future<void> clearConflicts() => _db.delete('conflicts');

  @override
  Future<void> upsertC2oAsset(CachedC2oAsset asset) => _db.insert(
    'c2o_assets',
    asset.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  /// Matches on either the real asset id or the `assetReferenceId` baked
  /// into a tokenless general-label scan — see [CachedC2oAsset].
  @override
  Future<CachedC2oAsset?> getC2oAsset(String idOrReference) async {
    final rows = await _db.query(
      'c2o_assets',
      where: 'asset_id = ? OR asset_reference_id = ?',
      whereArgs: [idOrReference, idOrReference],
      limit: 1,
    );
    return rows.isEmpty ? null : CachedC2oAsset.fromRow(rows.first);
  }

  @override
  Future<List<CachedC2oAsset>> listC2oAssets() async {
    final rows = await _db.query('c2o_assets', orderBy: 'cached_at DESC');
    return rows.map(CachedC2oAsset.fromRow).toList();
  }

  @override
  Future<void> reportTagIssue(TagIssueReport report) =>
      _db.insert('tag_issue_reports', report.toRow());

  @override
  Future<List<TagIssueReport>> listTagIssueReports() async {
    final rows = await _db.query(
      'tag_issue_reports',
      orderBy: 'reported_at DESC',
    );
    return rows.map(TagIssueReport.fromRow).toList();
  }

  @override
  Future<void> saveDraft(String assetId, Map<String, dynamic> payload) =>
      _db.insert(
        'verification_drafts',
        VerificationDraft(
          assetId: assetId,
          payload: payload,
          updatedAt: DateTime.now(),
        ).toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  @override
  Future<VerificationDraft?> getDraft(String assetId) async {
    final rows = await _db.query(
      'verification_drafts',
      where: 'asset_id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isEmpty ? null : VerificationDraft.fromRow(rows.first);
  }

  @override
  Future<void> deleteDraft(String assetId) => _db.delete(
    'verification_drafts',
    where: 'asset_id = ?',
    whereArgs: [assetId],
  );

  @override
  Future<void> saveRoutePack(DownloadedRoutePack pack) => _db.insert(
    'route_packs',
    pack.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<List<DownloadedRoutePack>> listRoutePacks() async {
    final rows = await _db.query('route_packs', orderBy: 'downloaded_at DESC');
    return rows.map(DownloadedRoutePack.fromRow).toList();
  }

  @override
  Future<void> deleteRoutePack(RouteScope scope, String id) => _db.delete(
    'route_packs',
    where: 'scope = ? AND scope_id = ?',
    whereArgs: [scope.name, id],
  );

  @override
  Future<void> upsertSnag({
    required String id,
    required Map<String, dynamic> json,
    String? buildingId,
    String? surveyId,
    required String status,
    required bool localOnly,
    required DateTime updatedAt,
  }) => _db.insert('snags', {
    'id': id,
    'building_id': buildingId,
    'survey_id': surveyId,
    'status': status,
    'local_only': localOnly ? 1 : 0,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'json': jsonEncode(json),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> upsertSnags(List<SnagRowWrite> rows) async {
    if (rows.isEmpty) return;
    final batch = _db.batch();
    for (final r in rows) {
      batch.insert('snags', {
        'id': r.id,
        'building_id': r.buildingId,
        'survey_id': r.surveyId,
        'status': r.status,
        'local_only': r.localOnly ? 1 : 0,
        'updated_at': r.updatedAt.millisecondsSinceEpoch,
        'json': jsonEncode(r.json),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static StoredSnagRow _snagRow(Map<String, Object?> row) => StoredSnagRow(
    id: row['id'] as String,
    json: Map<String, dynamic>.from(jsonDecode(row['json'] as String) as Map),
    localOnly: (row['local_only'] as int? ?? 0) == 1,
  );

  @override
  Future<StoredSnagRow?> getSnag(String id) async {
    final rows = await _db.query('snags', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _snagRow(rows.first);
  }

  @override
  Future<List<StoredSnagRow>> listSnags({String? buildingId}) async {
    final rows = buildingId == null
        ? await _db.query('snags', orderBy: 'updated_at DESC')
        : await _db.query(
            'snags',
            where: 'building_id = ?',
            whereArgs: [buildingId],
            orderBy: 'updated_at DESC',
          );
    return rows.map(_snagRow).toList();
  }

  @override
  Future<void> pruneSnags({required String buildingId, required Set<String> keepIds}) async {
    final rows = await _db.query(
      'snags',
      columns: ['id'],
      where: 'building_id = ? AND local_only = 0',
      whereArgs: [buildingId],
    );
    final stale = rows.map((r) => r['id'] as String).where((id) => !keepIds.contains(id)).toList();
    for (final id in stale) {
      await _db.delete('snags', where: 'id = ?', whereArgs: [id]);
    }
  }

  @override
  Future<void> upsertSurvey({
    required String id,
    required Map<String, dynamic> json,
    String? buildingId,
    required bool localOnly,
    required DateTime updatedAt,
  }) => _db.insert('snag_surveys', {
    'id': id,
    'building_id': buildingId,
    'local_only': localOnly ? 1 : 0,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'json': jsonEncode(json),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<Map<String, dynamic>?> getSurvey(String id) async {
    final rows = await _db.query('snag_surveys', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(jsonDecode(rows.first['json'] as String) as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> listSurveys({String? buildingId}) async {
    final rows = buildingId == null
        ? await _db.query('snag_surveys', orderBy: 'updated_at DESC')
        : await _db.query(
            'snag_surveys',
            where: 'building_id = ?',
            whereArgs: [buildingId],
            orderBy: 'updated_at DESC',
          );
    return rows
        .map((r) => Map<String, dynamic>.from(jsonDecode(r['json'] as String) as Map))
        .toList();
  }

  @override
  Future<Set<String>> pendingEntityIds(String entityType) async {
    final rows = await _db.query(
      'pending_mutations',
      columns: ['entity_id'],
      where: 'entity_type = ? AND entity_id IS NOT NULL',
      whereArgs: [entityType],
    );
    return rows.map((r) => r['entity_id'] as String).toSet();
  }

  // ---------------------------------------------------------------- AR packs

  static Map<String, dynamic> _jsonColumn(Map<String, Object?> row) =>
      Map<String, dynamic>.from(jsonDecode(row['json'] as String) as Map);

  @override
  Future<void> saveArManifest(
    StoredArManifest manifest, {
    List<Map<String, dynamic>> markers = const [],
    List<Map<String, dynamic>> corners = const [],
    List<Map<String, dynamic>> gridLines = const [],
  }) => _db.transaction((txn) async {
    final floorId = manifest.scopeId;
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.insert(
      'ar_manifests',
      manifest.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // Only a floor pack owns the floor's corners, grid lines and boards. A
    // second pack on the same floor id (the model viewer's `viewer` scope,
    // docs/bim-viewer.md) must not wipe them — mirrors deleteArManifest.
    if (manifest.scope != 'floor') return;

    await txn.delete('ar_corners', where: 'floor_id = ?', whereArgs: [floorId]);
    for (final c in corners) {
      final id = c['id']?.toString();
      if (id == null || id.isEmpty) continue;
      await txn.insert('ar_corners', {
        'floor_id': floorId,
        'id': id,
        'json': jsonEncode(c),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await txn.delete('ar_grid_lines', where: 'floor_id = ?', whereArgs: [floorId]);
    for (var i = 0; i < gridLines.length; i++) {
      await txn.insert('ar_grid_lines', {
        'floor_id': floorId,
        'seq': i,
        'name': gridLines[i]['name']?.toString(),
        'json': jsonEncode(gridLines[i]),
      });
    }

    // Server-known boards on this floor are replaced wholesale (a retired
    // one disappears); a spare bound on this phone and still queued stays.
    await txn.delete(
      'ar_markers',
      where: 'floor_id = ? AND local_only = 0',
      whereArgs: [floorId],
    );
    for (final m in markers) {
      final code = m['code']?.toString();
      if (code == null || code.isEmpty) continue;
      final json = {
        ...m,
        'floorId': m['floorId'] ?? floorId,
        'buildingId': m['buildingId'] ?? manifest.buildingId,
      };
      await txn.insert('ar_markers', {
        'code': code,
        'building_id': json['buildingId']?.toString(),
        'floor_id': json['floorId']?.toString(),
        'label': m['label']?.toString(),
        'status': m['status']?.toString(),
        'local_only': 0,
        'json': jsonEncode(json),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  });

  @override
  Future<StoredArManifest?> getArManifest(String scopeId, {String scope = 'floor'}) async {
    final rows = await _db.query(
      'ar_manifests',
      where: 'scope = ? AND scope_id = ?',
      whereArgs: [scope, scopeId],
      limit: 1,
    );
    return rows.isEmpty ? null : StoredArManifest.fromRow(rows.first);
  }

  @override
  Future<List<StoredArManifest>> listArManifests() async {
    final rows = await _db.query('ar_manifests', orderBy: 'saved_at DESC');
    return rows.map(StoredArManifest.fromRow).toList();
  }

  @override
  Future<void> deleteArManifest(String scopeId, {String scope = 'floor'}) =>
      _db.transaction((txn) async {
        await txn.delete(
          'ar_manifests',
          where: 'scope = ? AND scope_id = ?',
          whereArgs: [scope, scopeId],
        );
        if (scope != 'floor') return;
        await txn.delete('ar_corners', where: 'floor_id = ?', whereArgs: [scopeId]);
        await txn.delete('ar_grid_lines', where: 'floor_id = ?', whereArgs: [scopeId]);
        await txn.delete(
          'ar_markers',
          where: 'floor_id = ? AND local_only = 0',
          whereArgs: [scopeId],
        );
        await txn.delete(
          'ar_progress',
          where: 'floor_id = ? AND pending = 0',
          whereArgs: [scopeId],
        );
      });

  @override
  Future<StoredArTile?> getArTile(String hash) async {
    final rows = await _db.query('ar_tiles', where: 'hash = ?', whereArgs: [hash], limit: 1);
    return rows.isEmpty ? null : StoredArTile.fromRow(rows.first);
  }

  @override
  Future<List<StoredArTile>> listArTiles() async {
    final rows = await _db.query('ar_tiles', orderBy: 'last_used_at ASC');
    return rows.map(StoredArTile.fromRow).toList();
  }

  @override
  Future<void> upsertArTile(StoredArTile tile) => _db.insert(
    'ar_tiles',
    tile.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<void> touchArTiles(List<String> hashes, DateTime at) async {
    if (hashes.isEmpty) return;
    final batch = _db.batch();
    for (final h in hashes) {
      batch.update(
        'ar_tiles',
        {'last_used_at': at.millisecondsSinceEpoch},
        where: 'hash = ?',
        whereArgs: [h],
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> deleteArTiles(List<String> hashes) async {
    if (hashes.isEmpty) return;
    final batch = _db.batch();
    for (final h in hashes) {
      batch.delete('ar_tiles', where: 'hash = ?', whereArgs: [h]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> upsertArFeatures(String buildId, List<Map<String, dynamic>> features) async {
    if (features.isEmpty) return;
    final batch = _db.batch();
    for (final f in features) {
      final featureId = f['featureId'];
      final globalId = f['globalId']?.toString();
      final id = featureId is num ? featureId.toInt() : int.tryParse('$featureId');
      if (id == null || globalId == null || globalId.isEmpty) continue;
      batch.insert('ar_features', {
        'build_id': buildId,
        'feature_id': id,
        'global_id': globalId,
        'asset_id': f['assetId']?.toString(),
        'floor_id': f['floorId']?.toString(),
        'json': jsonEncode({...f, 'buildId': buildId}),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<Map<String, dynamic>>> listArFeatures(String buildId) async {
    final rows = await _db.query(
      'ar_features',
      where: 'build_id = ?',
      whereArgs: [buildId],
      orderBy: 'feature_id ASC',
    );
    return rows.map(_jsonColumn).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> findArFeatures({String? globalId, String? assetId}) async {
    if (globalId == null && assetId == null) return const [];
    final rows = await _db.query(
      'ar_features',
      where: globalId != null ? 'global_id = ?' : 'asset_id = ?',
      whereArgs: [globalId ?? assetId],
    );
    return rows.map(_jsonColumn).toList();
  }

  @override
  Future<void> upsertArMarker(Map<String, dynamic> marker, {bool localOnly = false}) async {
    final code = marker['code']?.toString();
    if (code == null || code.isEmpty) return;
    await _db.insert('ar_markers', {
      'code': code,
      'building_id': marker['buildingId']?.toString(),
      'floor_id': marker['floorId']?.toString(),
      'label': marker['label']?.toString(),
      'status': marker['status']?.toString(),
      'local_only': localOnly ? 1 : 0,
      'json': jsonEncode(marker),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<Map<String, dynamic>?> getArMarker(String code) async {
    final rows = await _db.query('ar_markers', where: 'code = ?', whereArgs: [code], limit: 1);
    return rows.isEmpty ? null : _jsonColumn(rows.first);
  }

  @override
  Future<List<Map<String, dynamic>>> listArMarkers({String? floorId, String? buildingId}) async {
    final rows = floorId != null
        ? await _db.query('ar_markers', where: 'floor_id = ?', whereArgs: [floorId], orderBy: 'label ASC')
        : buildingId != null
            ? await _db.query('ar_markers', where: 'building_id = ?', whereArgs: [buildingId], orderBy: 'label ASC')
            : await _db.query('ar_markers', orderBy: 'label ASC');
    return rows.map(_jsonColumn).toList();
  }

  @override
  Future<void> deleteArMarker(String code) =>
      _db.delete('ar_markers', where: 'code = ?', whereArgs: [code]);

  @override
  Future<List<Map<String, dynamic>>> listArCorners(String floorId) async {
    final rows = await _db.query('ar_corners', where: 'floor_id = ?', whereArgs: [floorId]);
    return rows.map(_jsonColumn).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> listArGridLines(String floorId) async {
    final rows = await _db.query(
      'ar_grid_lines',
      where: 'floor_id = ?',
      whereArgs: [floorId],
      orderBy: 'seq ASC',
    );
    return rows.map(_jsonColumn).toList();
  }

  @override
  Future<void> upsertArProgress(
    String floorId,
    List<Map<String, dynamic>> rows, {
    required bool pending,
  }) async {
    if (rows.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final r in rows) {
      final globalId = r['globalId']?.toString();
      if (globalId == null || globalId.isEmpty) continue;
      batch.insert('ar_progress', {
        'floor_id': floorId,
        'global_id': globalId,
        'status': r['status']?.toString() ?? 'not_started',
        'pending': pending ? 1 : 0,
        'json': jsonEncode({...r, 'pending': pending}),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> replaceArProgress(
    String floorId,
    List<Map<String, dynamic>> rows, {
    bool keepPending = true,
  }) => _db.transaction((txn) async {
    await txn.delete(
      'ar_progress',
      where: keepPending ? 'floor_id = ? AND pending = 0' : 'floor_id = ?',
      whereArgs: [floorId],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final r in rows) {
      final globalId = r['globalId']?.toString();
      if (globalId == null || globalId.isEmpty) continue;
      // `ignore`: a pending local row with the same key is ahead of the
      // server and wins until its write has synced.
      await txn.insert('ar_progress', {
        'floor_id': floorId,
        'global_id': globalId,
        'status': r['status']?.toString() ?? 'not_started',
        'pending': 0,
        'json': jsonEncode({...r, 'pending': false}),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  });

  @override
  Future<List<Map<String, dynamic>>> listArProgress(String floorId) async {
    final rows = await _db.query('ar_progress', where: 'floor_id = ?', whereArgs: [floorId]);
    return rows.map(_jsonColumn).toList();
  }

  @override
  Future<String?> getArPref(String key) async {
    final rows = await _db.query('ar_prefs', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> setArPref(String key, String? value) async {
    if (value == null) {
      await _db.delete('ar_prefs', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _db.insert('ar_prefs', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Sign-out wipe (PENDING P-002): clears server copies, keeps unsent work
  /// — see `sign_out_wipe.dart` for the table-by-table rule.
  Future<void> wipeForSignOut() => runSignOutWipe(this);

  @override
  Future<void> deleteRows(String table, {String? where}) =>
      _db.delete(table, where: where);

  /// Deletes EVERYTHING, unsent work included (local-only snags, drafts, the
  /// conflict log). Not for sign-out — use [wipeForSignOut].
  Future<void> wipe() async {
    await _db.delete('pending_mutations');
    await _db.delete('cached_entities');
    await _db.delete('sync_meta'); // includes the FR-4.4 flush lease
    await _db.delete('conflicts');
    await _db.delete('c2o_assets');
    await _db.delete('tag_issue_reports');
    await _db.delete('verification_drafts');
    await _db.delete('route_packs');
    await _db.delete('snags');
    await _db.delete('snag_surveys');
    // AR packs: tile *files* stay on disk; the next download re-adopts any
    // whose bytes still hash to their name instead of fetching them again.
    await _db.delete('ar_manifests');
    await _db.delete('ar_tiles');
    await _db.delete('ar_features');
    await _db.delete('ar_markers');
    await _db.delete('ar_corners');
    await _db.delete('ar_grid_lines');
    await _db.delete('ar_progress');
    await _db.delete('ar_prefs');
  }
}

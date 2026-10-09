/// FR-2 — shapes the same `resolveScan()` payload FR-1.1 already fetches and
/// caches (`CachedC2oAsset.claims`) into something a detail screen can just
/// read off, instead of every widget dotting into a raw `Map`. Pure parsing,
/// no I/O: the network/cache work is already done by the time this runs.
class AssetDetail {
  const AssetDetail({
    required this.id,
    this.assetReferenceId,
    this.assetName,
    this.type,
    this.category,
    this.imageUrl,
    this.locationPath = const [],
    this.manufacturer,
    this.model,
    this.serialNumber,
    this.supplierTagNumber,
    this.barcode,
    this.warrantyExpiryDate,
    this.systemCode,
    this.isMaintainable,
    this.physicalTagStatus,
    this.condition,
    this.history = const [],
    this.description,
    this.flatLocation,
    this.openFindings = const [],
    this.floorId,
  });

  // FR-2.1 — identity.
  final String id;
  final String? assetReferenceId;
  final String? assetName;
  final String? type;
  final String? category;
  final String? imageUrl;
  final String? description;

  /// A single free-text location line — used when [locationPath] is empty
  /// (the full asset record has no structured site/building/level/room
  /// walk, only this) so the screen still says *something* about where the
  /// thing is rather than omitting location entirely.
  final String? flatLocation;

  // FR-2.2 — location walk. Rungs with neither a name nor a code are already
  // dropped server-side (see `buildLocationPath` in fieldVerificationService).
  final List<LocationStep> locationPath;

  // FR-2.3 — nameplate claims.
  final String? manufacturer;
  final String? model;
  final String? serialNumber;
  final String? supplierTagNumber;
  final String? barcode;

  // FR-2.4 — warranty (raw date; see `warrantyVerdict` for the display text).
  final DateTime? warrantyExpiryDate;

  // FR-2.5 — status chips.
  final String? systemCode;
  final bool? isMaintainable;
  final String? physicalTagStatus;
  final String? condition;

  // FR-2.6 — last check is history.first (server already orders newest-first).
  final List<VerificationHistoryEntry> history;

  // FR-2.7 — open findings already raised against this asset. Only ever
  // populated on the c2o scan path (`fromClaims`) — the full-asset-record
  // fallback (`fromAssetRecord`) has no equivalent endpoint to read this
  // from, same as `history` above.
  final List<AssetFinding> openFindings;

  /// FR-2.8 — the floor this asset sits on, used to fetch the cached floor
  /// plan image + this asset's pinned position. Present on both entry
  /// paths (the c2o scan payload now carries the raw `floorID` column
  /// alongside the display-only `floor` name; the full asset record always
  /// had it).
  final String? floorId;

  VerificationHistoryEntry? get lastCheck => history.isEmpty ? null : history.first;

  static AssetDetail? fromClaims(Map<String, dynamic> claims) {
    final asset = claims['asset'];
    if (asset is! Map) return null;
    final a = Map<String, dynamic>.from(asset);

    final rawHistory = claims['history'];
    final history = rawHistory is List
        ? rawHistory
            .whereType<Map>()
            .map((h) => VerificationHistoryEntry.fromJson(Map<String, dynamic>.from(h)))
            .toList()
        : const <VerificationHistoryEntry>[];

    final rawFindings = claims['openFindings'];
    final openFindings = rawFindings is List
        ? rawFindings
            .whereType<Map>()
            .map((f) => AssetFinding.fromJson(Map<String, dynamic>.from(f)))
            .toList()
        : const <AssetFinding>[];

    final rawPath = a['locationPath'];
    final locationPath = rawPath is List
        ? rawPath
            .whereType<Map>()
            .map((s) => LocationStep.fromJson(Map<String, dynamic>.from(s)))
            .toList()
        : const <LocationStep>[];

    final id = a['id']?.toString();
    if (id == null || id.isEmpty) return null;

    return AssetDetail(
      id: id,
      assetReferenceId: a['assetReferenceId']?.toString(),
      assetName: a['assetName']?.toString(),
      type: a['type']?.toString(),
      category: a['category']?.toString(),
      imageUrl: referencePhotoUrl(a['imageUrl']),
      locationPath: locationPath,
      manufacturer: a['manufacturer']?.toString(),
      model: a['model']?.toString(),
      serialNumber: a['serialNumber']?.toString(),
      supplierTagNumber: a['supplierTagNumber']?.toString(),
      barcode: a['barcode']?.toString(),
      warrantyExpiryDate: _parseDate(a['warrantyExpiryDate']),
      systemCode: a['systemCode']?.toString(),
      isMaintainable: a['isMaintainable'] is bool ? a['isMaintainable'] as bool : null,
      physicalTagStatus: a['physicalTagStatus']?.toString(),
      condition: a['condition']?.toString(),
      history: history,
      description: _nonEmpty(a['description']),
      flatLocation: _nonEmpty(a['location']),
      openFindings: openFindings,
      floorId: _nonEmpty(a['floorID']),
    );
  }

  /// FR-2's fallback source when there is no c2o scan cache entry to read
  /// from (search rather than a scan — see [AssetRepository]). This is the
  /// plain `GET /api/fm/assets/:id` shape: flat, no `asset` wrapper, no
  /// `locationPath` walk (that is a c2o-only construct) — just [location]
  /// as free text, and `maintainability` as a string enum rather than
  /// [isMaintainable]'s bool.
  static AssetDetail? fromAssetRecord(Map<String, dynamic> a) {
    final id = a['id']?.toString();
    if (id == null || id.isEmpty) return null;

    final maintainability = a['maintainability']?.toString();

    return AssetDetail(
      id: id,
      assetReferenceId: _nonEmpty(a['assetReferenceId']),
      assetName: _nonEmpty(a['assetName']) ?? _nonEmpty(a['name']),
      type: _nonEmpty(a['type']),
      category: _nonEmpty(a['category']),
      imageUrl: referencePhotoUrl(a['imageUrl']),
      manufacturer: _nonEmpty(a['manufacturer']),
      model: _nonEmpty(a['model']),
      serialNumber: _nonEmpty(a['serialNumber']),
      supplierTagNumber: _nonEmpty(a['supplierTagNumber']),
      barcode: _nonEmpty(a['qrCode']),
      warrantyExpiryDate: _parseDate(a['warrantyExpiryDate'] ?? a['warrantyExpiry']),
      isMaintainable: maintainability == null ? null : maintainability == 'maintainable',
      condition: _nonEmpty(a['condition']),
      description: _nonEmpty(a['description']),
      flatLocation: _nonEmpty(a['location']),
      floorId: _nonEmpty(a['floorID']),
    );
  }
}

/// FR-2.7 — one open finding already raised against this asset.
class AssetFinding {
  const AssetFinding({
    required this.id,
    required this.severity,
    required this.message,
    this.fixHint,
    this.ruleName,
    this.createdAt,
  });

  final String id;

  /// "blocker" | "warning" | "info" — the server's own enum, shown as-is
  /// rather than re-modeled, same choice already made for [AssetDetail.condition].
  final String severity;
  final String message;
  final String? fixHint;
  final String? ruleName;
  final DateTime? createdAt;

  factory AssetFinding.fromJson(Map<String, dynamic> json) => AssetFinding(
    id: json['id']?.toString() ?? '',
    severity: json['severity']?.toString() ?? 'info',
    message: json['message']?.toString() ?? '',
    fixHint: _nonEmpty(json['fixHint']),
    ruleName: _nonEmpty(json['ruleName']),
    createdAt: _parseDate(json['createdAt']),
  );
}

class LocationStep {
  const LocationStep({required this.level, this.label, this.code});

  final String level;
  final String? label;
  final String? code;

  factory LocationStep.fromJson(Map<String, dynamic> json) => LocationStep(
    level: json['level']?.toString() ?? '',
    label: _nonEmpty(json['label']),
    code: _nonEmpty(json['code']),
  );
}

class VerificationHistoryEntry {
  const VerificationHistoryEntry({
    required this.result,
    this.verifiedAt,
    this.verifiedByName,
    this.discrepancies = const [],
  });

  final String result;
  final DateTime? verifiedAt;
  final String? verifiedByName;
  final List<String> discrepancies;

  factory VerificationHistoryEntry.fromJson(Map<String, dynamic> json) => VerificationHistoryEntry(
    result: json['result']?.toString() ?? 'unknown',
    verifiedAt: _parseDate(json['verifiedAt']),
    verifiedByName: _nonEmpty(json['verifiedByName']),
    discrepancies: (json['discrepancies'] is List)
        ? (json['discrepancies'] as List).map((d) => d.toString()).toList()
        : const [],
  );
}

enum WarrantyStatus {
  /// No `warrantyExpiryDate` on the register at all.
  none,
  expired,
  expiresToday,
  active,
}

/// FR-2.4's verdict, structured rather than pre-worded — the screen still
/// has to run this through the app's own i18n strings (this app supports
/// Arabic), so a hardcoded English sentence here would just be thrown away.
class WarrantyVerdict {
  const WarrantyVerdict.none() : status = WarrantyStatus.none, formattedDate = null, daysRemaining = null;

  const WarrantyVerdict.expired(this.formattedDate) : status = WarrantyStatus.expired, daysRemaining = null;

  const WarrantyVerdict.expiresToday() : status = WarrantyStatus.expiresToday, formattedDate = null, daysRemaining = null;

  const WarrantyVerdict.active(this.daysRemaining) : status = WarrantyStatus.active, formattedDate = null;

  final WarrantyStatus status;

  /// "12/06/2025" — set only when [status] is [WarrantyStatus.expired].
  final String? formattedDate;

  /// Set only when [status] is [WarrantyStatus.active].
  final int? daysRemaining;
}

/// Turns a raw date into what the plan calls for — "expired 12/06/2025" or
/// "ends in 43 days" — as data, not a pre-worded English string. [now] is
/// injectable so tests do not depend on the clock.
WarrantyVerdict warrantyVerdict(DateTime? expiry, {DateTime? now}) {
  if (expiry == null) return const WarrantyVerdict.none();
  final today = now ?? DateTime.now();
  final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  final days = expiryDay.difference(todayDay).inDays;
  if (days < 0) {
    final formatted =
        '${expiry.day.toString().padLeft(2, '0')}/${expiry.month.toString().padLeft(2, '0')}/${expiry.year}';
    return WarrantyVerdict.expired(formatted);
  }
  if (days == 0) return const WarrantyVerdict.expiresToday();
  return WarrantyVerdict.active(days);
}

String? _nonEmpty(dynamic v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

/// FR-2.1 — an asset's `imageUrl` when it is a real http(s) link, else
/// null. Seed data carries bare paths that were never uploaded anywhere;
/// those would only ever fail, so they count as "no photo".
String? referencePhotoUrl(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) return null;
  return trimmed;
}

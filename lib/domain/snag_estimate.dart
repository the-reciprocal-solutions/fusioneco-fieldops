import '../core/network/envelope.dart';
import 'snag.dart';

/// The snag estimate (`POST /api/snags/:id/ai/estimate`, server
/// documentation/snag-assistant.md §4c) — the main AI help on a snag since
/// 2026-10-10: scope of work, materials matched to the catalogue with stock,
/// and an approximate cost as a range with every assumption listed.
///
/// Every money figure here is the SERVER's: the AI only proposes words and
/// quantities, the server prices them from the tenant's catalogue and past
/// quotes and does the sums. A material it can't price arrives with
/// `lineCost == null` and must show "Price needed" — never a guess. Parsing
/// is tolerant (Sequelize decimals arrive as strings) and drops anything it
/// doesn't recognise rather than inventing a value.
enum SnagEstimateAiStatus {
  ok,
  cached,
  offline,
  error,
  skipped;

  static SnagEstimateAiStatus parse(dynamic v) => switch (v?.toString()) {
        'ok' => ok,
        'cached' => cached,
        'offline' => offline,
        'error' => error,
        _ => skipped,
      };
}

class MoneyRange {
  const MoneyRange(this.low, this.high);
  final double low;
  final double high;

  static MoneyRange? tryParse(dynamic j) {
    if (j is! Map) return null;
    final lo = asDouble(j['low']);
    final hi = asDouble(j['high']);
    if (lo == null || hi == null) return null;
    return MoneyRange(lo, hi);
  }
}

class EstimateMaterial {
  const EstimateMaterial({
    required this.id,
    required this.name,
    required this.quantity,
    required this.inCatalogue,
    required this.priceSource,
    required this.priceNote,
    this.unit,
    this.purpose,
    this.materialId,
    this.catalogueName,
    this.partNumber,
    this.available,
    this.onHand,
    this.shortBy,
    this.unitPrice,
    this.priceRange,
    this.lineCost,
    this.vendorId,
    this.vendorName,
    this.unitMismatch = false,
  });

  final String id;
  final String name;
  final double quantity;
  final String? unit;
  final String? purpose;
  final bool inCatalogue;
  final String? materialId;
  final String? catalogueName;
  final String? partNumber;
  final double? available;
  final double? onHand;
  final double? shortBy;
  final double? unitPrice;
  final MoneyRange? priceRange;
  final MoneyRange? lineCost;

  /// `catalogue`, `past-quote` or `none`.
  final String priceSource;
  final String priceNote;
  final String? vendorId;
  final String? vendorName;
  final bool unitMismatch;

  bool get needsPrice => lineCost == null;
  String get displayName => catalogueName ?? name;

  static EstimateMaterial? fromJson(Map<String, dynamic> j) {
    final name = firstNonEmpty([j['name']]);
    final qty = asDouble(j['quantity']);
    if (name == null || qty == null || qty <= 0) return null;
    final m = j['material'] is Map ? Map<String, dynamic>.from(j['material'] as Map) : null;
    final stock = j['stock'] is Map ? Map<String, dynamic>.from(j['stock'] as Map) : null;
    final vendor = j['vendor'] is Map ? Map<String, dynamic>.from(j['vendor'] as Map) : null;
    final src = j['priceSource']?.toString();
    return EstimateMaterial(
      id: firstNonEmpty([j['id']]) ?? name,
      name: name,
      quantity: qty,
      unit: firstNonEmpty([j['unit']]),
      purpose: firstNonEmpty([j['purpose']]),
      inCatalogue: m != null && firstNonEmpty([m['id']]) != null,
      materialId: m == null ? null : firstNonEmpty([m['id']]),
      catalogueName: m == null ? null : firstNonEmpty([m['name']]),
      partNumber: m == null ? null : firstNonEmpty([m['partNumber']]),
      available: stock == null ? null : asDouble(stock['available']),
      onHand: stock == null ? null : asDouble(stock['onHand']),
      shortBy: asDouble(j['shortBy']),
      unitPrice: asDouble(j['unitPrice']),
      priceRange: MoneyRange.tryParse(j['priceRange']),
      lineCost: MoneyRange.tryParse(j['lineCost']),
      priceSource: src == 'catalogue' || src == 'past-quote' ? src! : 'none',
      priceNote: firstNonEmpty([j['priceNote']]) ?? '',
      vendorId: vendor == null ? null : firstNonEmpty([vendor['id']]),
      vendorName: vendor == null ? null : firstNonEmpty([vendor['name']]),
      unitMismatch: asBool(j['unitMismatch']) ?? false,
    );
  }
}

class EstimateLinked {
  const EstimateLinked({required this.kind, required this.at, this.id, this.number, this.note});
  final String kind;
  final String? id;
  final String? number;
  final DateTime at;
  final String? note;
}

class SnagEstimate {
  const SnagEstimate({
    required this.snagId,
    required this.aiStatus,
    required this.currency,
    required this.steps,
    required this.trades,
    required this.materials,
    required this.total,
    required this.labour,
    required this.materialsCost,
    required this.contingencyPct,
    required this.contingency,
    required this.complete,
    required this.assumptions,
    required this.responsibleParty,
    required this.responsibleKind,
    required this.backCharge,
    required this.responsibilityBasis,
    required this.warrantyStatus,
    required this.warrantyBasis,
    required this.benchmarkCount,
    required this.benchmarkNote,
    required this.vendors,
    required this.linked,
    this.reference,
    this.aiMessage,
    this.summary,
    this.crewSize,
    this.durationLow,
    this.durationHigh,
    this.labourRate,
    this.personHoursHigh,
    this.warrantyUntil,
    this.suggestedPriority,
    this.priorityChanged = false,
    this.priorityReason,
    this.slaDue,
    this.slaBasis,
    this.benchmarkDays,
    this.benchmarkCost,
    this.workOrderId,
  });

  final String snagId;
  final String? reference;
  final SnagEstimateAiStatus aiStatus;
  final String? aiMessage;
  final String currency;

  // scope
  final String? summary;
  final List<String> steps;
  final List<String> trades;
  final int? crewSize;
  final double? durationLow;
  final double? durationHigh;

  // materials + cost
  final List<EstimateMaterial> materials;
  final MoneyRange total;
  final MoneyRange? labour;
  final double? labourRate;
  final double? personHoursHigh;
  final MoneyRange materialsCost;
  final double contingencyPct;
  final double contingency;
  final bool complete;
  final List<String> assumptions;

  // grounded facts
  final String responsibleParty;
  final String responsibleKind;
  final bool backCharge;
  final List<String> responsibilityBasis;
  final String warrantyStatus;
  final String warrantyBasis;
  final DateTime? warrantyUntil;
  final SnagPriority? suggestedPriority;
  final bool priorityChanged;
  final String? priorityReason;
  final DateTime? slaDue;
  final String? slaBasis;
  final int benchmarkCount;
  final double? benchmarkDays;
  final MoneyRange? benchmarkCost;
  final String benchmarkNote;
  final List<({String id, String name, String reasons})> vendors;
  final String? workOrderId;
  final List<EstimateLinked> linked;

  /// The AI's scope is in (fresh or from an earlier answer).
  bool get hasScope => aiStatus == SnagEstimateAiStatus.ok || aiStatus == SnagEstimateAiStatus.cached;
  bool get aiFailed => aiStatus == SnagEstimateAiStatus.offline || aiStatus == SnagEstimateAiStatus.error;
  int get unpricedCount => materials.where((m) => m.needsPrice).length;
  bool get hasCatalogueItems => materials.any((m) => m.inCatalogue);

  static SnagEstimate? fromJson(Map<String, dynamic> j) {
    final snagId = firstNonEmpty([j['snagId']]);
    final cost = j['cost'] is Map ? Map<String, dynamic>.from(j['cost'] as Map) : null;
    if (snagId == null || cost == null) return null;
    final ai = j['ai'] is Map ? Map<String, dynamic>.from(j['ai'] as Map) : const <String, dynamic>{};
    final scope = j['scope'] is Map ? Map<String, dynamic>.from(j['scope'] as Map) : const <String, dynamic>{};
    final dur = scope['durationHours'] is Map ? Map<String, dynamic>.from(scope['durationHours'] as Map) : null;
    final lab = cost['labour'] is Map ? Map<String, dynamic>.from(cost['labour'] as Map) : null;
    final mats = cost['materials'] is Map ? Map<String, dynamic>.from(cost['materials'] as Map) : const <String, dynamic>{};
    final resp = j['responsibility'] is Map ? Map<String, dynamic>.from(j['responsibility'] as Map) : const <String, dynamic>{};
    final war = j['warranty'] is Map ? Map<String, dynamic>.from(j['warranty'] as Map) : const <String, dynamic>{};
    final pr = j['priority'] is Map ? Map<String, dynamic>.from(j['priority'] as Map) : const <String, dynamic>{};
    final bm = j['benchmark'] is Map ? Map<String, dynamic>.from(j['benchmark'] as Map) : const <String, dynamic>{};
    final linked = j['linked'] is Map ? Map<String, dynamic>.from(j['linked'] as Map) : const <String, dynamic>{};
    final ph = lab?['personHours'] is Map ? Map<String, dynamic>.from(lab!['personHours'] as Map) : null;
    List<String> strings(dynamic v) => v is List ? v.map((e) => firstNonEmpty([e])).whereType<String>().toList() : const [];
    return SnagEstimate(
      snagId: snagId,
      reference: firstNonEmpty([j['reference']]),
      aiStatus: SnagEstimateAiStatus.parse(ai['status']),
      aiMessage: firstNonEmpty([ai['message']]),
      currency: firstNonEmpty([cost['currency']]) ?? 'AED',
      summary: firstNonEmpty([scope['summary']]),
      steps: strings(scope['steps']),
      trades: strings(scope['trades']).where(kSnagTrades.contains).toList(),
      crewSize: asInt(scope['crewSize']),
      durationLow: dur == null ? null : asDouble(dur['low']),
      durationHigh: dur == null ? null : asDouble(dur['high']),
      materials: (j['materials'] is List ? j['materials'] as List : const [])
          .whereType<Map>()
          .map((m) => EstimateMaterial.fromJson(Map<String, dynamic>.from(m)))
          .whereType<EstimateMaterial>()
          .toList(),
      total: MoneyRange.tryParse(cost['total']) ?? const MoneyRange(0, 0),
      labour: lab == null ? null : MoneyRange.tryParse(lab),
      labourRate: lab == null ? null : asDouble(lab['rate']),
      personHoursHigh: ph == null ? null : asDouble(ph['high']),
      materialsCost: MoneyRange.tryParse(mats) ?? const MoneyRange(0, 0),
      contingencyPct: asDouble(cost['contingencyPct']) ?? 0,
      contingency: asDouble(cost['contingency']) ?? 0,
      complete: asBool(cost['complete']) ?? false,
      assumptions: strings(j['assumptions']),
      responsibleParty: firstNonEmpty([resp['party']]) ?? '—',
      responsibleKind: firstNonEmpty([resp['kind']]) ?? 'fm',
      backCharge: asBool(resp['backCharge']) ?? false,
      responsibilityBasis: strings(resp['basis']),
      warrantyStatus: firstNonEmpty([war['status']]) ?? 'unknown',
      warrantyBasis: firstNonEmpty([war['basis']]) ?? '',
      warrantyUntil: asDate(war['until']),
      suggestedPriority: SnagPriority.tryParse(pr['suggested']),
      priorityChanged: asBool(pr['changed']) ?? false,
      priorityReason: firstNonEmpty([pr['reason']]),
      slaDue: asDate(pr['slaDue']),
      slaBasis: firstNonEmpty([pr['slaBasis']]),
      benchmarkCount: asInt(bm['count']) ?? 0,
      benchmarkDays: asDouble(bm['medianDaysToClose']),
      benchmarkCost: MoneyRange.tryParse(bm['costRange']) ??
          (asDouble(bm['medianCost']) == null ? null : MoneyRange(asDouble(bm['medianCost'])!, asDouble(bm['medianCost'])!)),
      benchmarkNote: firstNonEmpty([bm['note']]) ?? '',
      vendors: (j['vendors'] is List ? j['vendors'] as List : const [])
          .whereType<Map>()
          .map((v) => (
                id: v['id']?.toString() ?? '',
                name: v['name']?.toString() ?? '',
                reasons: v['reasons'] is List ? (v['reasons'] as List).join(' · ') : '',
              ))
          .where((v) => v.id.isNotEmpty && v.name.isNotEmpty)
          .toList(),
      workOrderId: firstNonEmpty([linked['workOrderId']]),
      linked: (linked['records'] is List ? linked['records'] as List : const [])
          .whereType<Map>()
          .map((r) {
            final at = asDate(r['at']);
            final kind = r['kind']?.toString();
            if (at == null || kind == null) return null;
            return EstimateLinked(kind: kind, at: at, id: firstNonEmpty([r['id']]), number: firstNonEmpty([r['number']]), note: firstNonEmpty([r['note']]));
          })
          .whereType<EstimateLinked>()
          .toList(),
    );
  }
}

/// A draft-quote line the technician reviewed. `unitPrice == null` = still
/// needs a price; the server refuses those (422 PRICE_NEEDED), so the sheet
/// won't send until every included line has one.
class QuoteLineDraft {
  QuoteLineDraft({
    required this.name,
    required this.quantity,
    required this.sourceType,
    this.unit,
    this.unitPrice,
    this.sourceId,
    this.description,
    this.include = true,
  });

  final String name;
  double quantity;
  final String? unit;
  double? unitPrice;
  final String sourceType;
  final String? sourceId;
  final String? description;
  bool include;

  Map<String, dynamic> toJson() => {
        'name': name,
        'quantity': quantity,
        'unit': ?unit,
        'unitPrice': unitPrice,
        'sourceType': sourceType,
        'sourceId': ?sourceId,
        'description': ?description,
      };
}

/// Catalogue / priced materials first, then one labour line (person-hours,
/// upper figure, at the estimate's rate). A past-quote range offers its
/// upper price; an unpriced line stays null for the technician to fill in.
List<QuoteLineDraft> quoteLinesFrom(SnagEstimate e) => [
      for (final m in e.materials)
        QuoteLineDraft(
          name: m.displayName,
          quantity: m.quantity,
          unit: m.unit,
          unitPrice: m.unitPrice ?? m.priceRange?.high,
          sourceType: m.inCatalogue ? 'material' : 'custom',
          sourceId: m.materialId,
          description: m.purpose,
        ),
      if (e.labour != null && e.labourRate != null && (e.personHoursHigh ?? 0) > 0)
        QuoteLineDraft(
          name: 'Labour',
          quantity: e.personHoursHigh!,
          unit: 'h',
          unitPrice: e.labourRate,
          sourceType: 'labor',
          description: e.crewSize == null ? null : '${e.crewSize} × ${_h(e.durationLow)}–${_h(e.durationHigh)} h',
        ),
    ];

String _h(double? v) => v == null ? '?' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1));

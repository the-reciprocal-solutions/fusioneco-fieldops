import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../../core/network/api_client.dart';
import '../../domain/mobile_catalog.dart';

/// Phase 3 summary screens (FE-mobile.md): every module is "summary tiles +
/// a recent list + light actions". A [ModuleSpec] says where those come from
/// for one catalog module id; [ModuleSummaryScreen] and [RecordDetailScreen]
/// draw any spec. Response parsing is tolerant: the FM endpoints use four
/// envelope shapes (`{data:[..]}`, `{data:{items}}`, `{documents}`, bare).
typedef Json = Map<String, dynamic>;

enum Tone { neutral, good, warn, bad, info }

/// One summary tile. [label] is an i18n key.
class Kpi {
  const Kpi(this.label, this.value, {this.tone = Tone.neutral});
  final String label;
  final String value;
  final Tone tone;
}

/// One summary request and how to read tiles from its body.
class SummarySpec {
  const SummarySpec(this.path, this.kpis, {this.query = const {}, this.liveQuery});
  final String path;
  final Map<String, dynamic> query;

  /// Params computed at request time (a time window ending now).
  final Map<String, dynamic> Function()? liveQuery;
  final List<Kpi> Function(Json data) kpis;

  Map<String, dynamic> get params => {...query, ...?liveQuery?.call()};
}

/// What a list row shows.
class RecordRow {
  const RecordRow({required this.id, required this.title, this.ref, this.subtitle, this.status, this.priority, this.date, this.refInHeader = true});
  final String id;
  final String title;

  /// Short human reference (WO-762, PTW-0002), shown in the header too.
  final String? ref;

  /// False when [ref] is not a record number (PM Compliance's percentage):
  /// the detail header then shows [title].
  final bool refInHeader;
  final String? subtitle;
  final String? status;
  final String? priority;
  final DateTime? date;
}

class ListSpec {
  const ListSpec({
    required this.path,
    required this.row,
    this.pageQuery,
    this.query = const {},
    this.searchParam,
    this.detailPath,
    this.detailExtras = const {},
    this.scanId,
    this.liveQuery,
    this.items,
  });

  final String path;

  /// Params computed at request time (see [SummarySpec.liveQuery]).
  final Map<String, dynamic> Function()? liveQuery;

  /// Where the rows sit when not in a standard envelope (e.g. `data.floors`).
  final List<Json> Function(Object? body)? items;

  /// Paging params for page [page] of [size]; null = the endpoint returns
  /// everything (only used where that list is small).
  final Map<String, dynamic> Function(int page, int size)? pageQuery;
  final Map<String, dynamic> query;

  /// Query param for the search box; null = no search box.
  final String? searchParam;
  final RecordRow Function(Json r) row;

  /// `GET` for one record (deep links, refresh after an action); null = the
  /// list row is the whole record.
  final String Function(String id)? detailPath;

  /// More `GET`s fetched with [detailPath], each one's list stored on the
  /// record under its key (e.g. a work order's `/work-log` as `_log`). A
  /// failed one is left out; the record still shows.
  final Map<String, String Function(String id)> detailExtras;

  /// Set = a scan button by the search box. Returns the record id a scanned
  /// code points at, or null: the code is searched for instead (and opened
  /// when exactly one record matches).
  final String? Function(String raw)? scanId;
}

/// When an action asks for text first.
enum TextAsk { none, optional, required }

class RecordAction {
  const RecordAction({
    required this.label,
    required this.icon,
    this.run,
    this.photoRun,
    this.ask = TextAsk.none,
    this.choices = const [],
    this.primary = false,
    this.danger = false,
  });

  /// i18n key; the same key + `_done` is the success message.
  final String label;
  final IconData icon;
  final TextAsk ask;

  /// Set when the server takes one of a fixed list (a work order's
  /// `holdReason`): the detail screen asks the user to pick one, and passes
  /// its value to [run] as the text. Each entry is (value sent, i18n key).
  final List<(String, String)> choices;
  final bool primary;
  final bool danger;
  final Future<void> Function(ApiClient api, Json record, String? text)? run;

  /// Set instead of [run] for an action that needs a photo (a snag's "after"
  /// photo): the detail screen takes it, uploads it, then passes its URL.
  final Future<void> Function(ApiClient api, Json record, String? text, String photoUrl)? photoRun;
}

class ModuleSpec {
  const ModuleSpec({
    required this.moduleId,
    this.summaries = const [],
    this.list,
    this.facts,
    this.actions,
    this.open,
    this.screen,
    this.extra,
    this.headerActions,
    this.desktopNote,
  });

  final String moduleId;

  /// i18n key of a [DesktopNote] on the summary screen, for a module whose
  /// web page has more than the phone (3D, running reports).
  final String? desktopNote;

  /// Extra header buttons on the summary screen (AMC's calendar).
  final List<Widget> Function(BuildContext context, MobileModule module)? headerActions;

  /// A screen of its own instead of tiles + list (utilities: devices ×
  /// readings). Still opened through the catalog guard.
  final Widget Function(MobileModule module)? screen;
  final List<SummarySpec> summaries;
  final ListSpec? list;

  /// Detail facts: (i18n label key, value). Empty values are dropped.
  final List<(String, String?)> Function(Json r)? facts;

  /// Light actions for a record in its current state. The record carries
  /// `_me: {id, role}` (the signed-in user) for rules that depend on who asks.
  final List<RecordAction> Function(Json r)? actions;

  /// A URL to open (documents); null = nothing to open.
  final String? Function(Json r)? open;

  /// More detail sections under the facts (a snag's photos and thread).
  final List<Widget> Function(BuildContext context, Json r)? extra;
}

// ── tolerant readers ─────────────────────────────────────────────────────────

/// The list inside any of the FM envelope shapes.
List<Json> rowsOf(Object? body) {
  Object? v = body;
  if (v is Map) {
    final d = v['data'];
    v = d is List ? d : d is Map && d['items'] is List ? d['items'] : v['documents'] ?? v['items'] ?? v['rows'] ?? d;
  }
  return v is List ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : const [];
}

/// Total row count when the endpoint pages (`pagination.total` / `data.total` / `total`).
int? totalOf(Object? body) {
  if (body is! Map) return null;
  final p = body['pagination'];
  final d = body['data'];
  final t = p is Map ? p['total'] : d is Map ? d['total'] : body['total'];
  return t is num ? t.toInt() : null;
}

/// A summary body: `{data:{..}}` or the bare object.
Json dataOf(Object? body) {
  if (body is Map) {
    final d = body['data'];
    if (d is Map) return Map<String, dynamic>.from(d);
    return Map<String, dynamic>.from(body);
  }
  return const {};
}

/// Single record from `GET /:id` (`{data:{..}}` or bare).
Json recordOf(Object? body) => dataOf(body);

String? s(Object? v) {
  if (v == null) return null;
  final t = '$v'.trim();
  return t.isEmpty || t == 'null' ? null : t;
}

DateTime? d(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

num? n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');

/// Nested `a.b.c` read.
Object? at(Object? m, String path) {
  Object? v = m;
  for (final k in path.split('.')) {
    if (v is! Map) return null;
    v = v[k];
  }
  return v;
}

/// 1234 → "1,234"; 1234567 → "1.2M"; nulls → "–".
String fmtNum(Object? v, {int decimals = 0}) {
  final x = n(v);
  if (x == null) return '–';
  final a = x.abs();
  if (a >= 1e9) return '${(x / 1e9).toStringAsFixed(1)}B';
  if (a >= 1e6) return '${(x / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e5) return '${(x / 1e3).toStringAsFixed(0)}k';
  final fixed = x.toStringAsFixed(x is int || x == x.roundToDouble() ? 0 : decimals);
  final parts = fixed.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return parts.length > 1 ? '$whole.${parts[1]}' : whole;
}

String fmtPct(Object? v) {
  final x = n(v);
  return x == null ? '–' : '${x.round()}%';
}

String? fmtMoney(Object? amount, Object? currency) {
  final x = n(amount);
  if (x == null) return null;
  return '${s(currency) ?? ''} ${fmtNum(x, decimals: 2)}'.trim();
}

/// A server word shown in the user's language: [prefix] + [raw] is looked up
/// when the fact is drawn (`snags.trade.` + `finishes` → "Finishes"), and the
/// raw word made readable is the fallback. Facts are built without a
/// BuildContext, so the lookup waits for [factText].
String? word(String prefix, Object? raw) {
  final v = s(raw);
  return v == null ? null : '$_wordMark$prefix$_wordMark$v';
}

const _wordMark = '\u{E000}';

/// A fact's text as shown: [word] values translated, others unchanged.
String factText(BuildContext context, String value) {
  if (!value.startsWith(_wordMark)) return value;
  final parts = value.substring(1).split(_wordMark);
  if (parts.length != 2) return value;
  final key = '${parts[0]}${parts[1]}';
  final t = key.getString(context);
  // flutter_localization answers the key itself (or "<key> not found") when missing.
  return t == key || t.endsWith(' not found') ? chipLabel(parts[1]) : t;
}

/// Locale-neutral `2026-10-30`.
String? fmtDate(Object? v) {
  final t = v is DateTime ? v : d(v);
  if (t == null) return null;
  String two(int i) => i.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// Value of `{status: n}` list entries — `[{status:'open',count:3}]` → 3.
num countIn(Object? list, String keyField, String key, {String countField = 'count'}) {
  if (list is! List) return 0;
  for (final e in list) {
    if (e is Map && '${e[keyField]}'.toLowerCase() == key.toLowerCase()) return n(e[countField]) ?? 0;
  }
  return 0;
}

/// Server status words as chip text: `checked_in` / `in-progress` → `checked in` / `in progress`.
String chipLabel(String raw) => raw.replaceAll(RegExp('[_-]+'), ' ');

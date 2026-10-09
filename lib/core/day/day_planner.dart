import '../../domain/day_brief.dart';
import '../../domain/maintenance_record.dart';

/// The phone's own day plan, for when the server brief can't be reached
/// (docs/day-brief.md §Offline). A port of the server's `dayBrief/rules.ts`
/// ordering over the work orders this phone already has cached — no model,
/// no network:
///
///   tier 0  safety: Critical priority, or a clear safety word in the text
///   tier ½  pending invites
///   tier 1  SLA risk (`slaState` breached / at_risk, resolve-by ≤ 2 h)
///   tier 2  overdue · tier 3 in progress · tier 4 due later today
///   tier 5  on hold
///
/// Inside a tier: permit-blocked last (only known from a cached server
/// brief), then priority, then due time; tiers 2–5 grouped by place.
/// What the phone can't know offline — permits, reserved parts, inspections,
/// snags — comes only from the last saved server brief (see [mergeCached]).
/// Change the server rules and this together.
abstract final class DayPlanner {
  static const _priorityRank = {'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3};

  /// The strongest of the server classifier's safety words
  /// (`intelligence/classify.ts` CRITICAL_WORDS). Routine names such as
  /// "Fire Safety — Extinguisher Check" are removed first, as the server does.
  static const _safetyWords = [
    'burning smell', 'gas leak', 'stuck in lift', 'stuck in the lift', 'people stuck', 'electric shock',
    'trapped', 'smoke', 'fire', 'flood', 'flooding', 'sparking', 'sparks', 'explosion', 'electrocution', 'burst',
  ];
  static const _routinePhrases = [
    'fire safety', 'fire extinguisher', 'fire alarm system', 'fire pump', 'fire door', 'fire panel', 'fire fighting',
    'fire hose', 'smoke detector', 'gas detector', 'flood light', 'floodlight',
  ];

  static String normalisePriority(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'critical':
      case 'urgent':
      case 'emergency':
        return 'Critical';
      case 'high':
        return 'High';
      case 'low':
        return 'Low';
      default:
        return 'Medium';
    }
  }

  static bool isDone(MaintenanceRecord r) {
    final s = (r.status ?? '').toLowerCase();
    return s == 'completed' || s == 'expired';
  }

  static bool isSafety(MaintenanceRecord r) {
    if (normalisePriority(r.priority) == 'Critical') return true;
    var text = ' ${[r.titleField, r.description, r.taskDescription].whereType<String>().join(' ').toLowerCase()} ';
    for (final p in _routinePhrases) {
      text = text.replaceAll(p, ' ');
    }
    return _safetyWords.any((w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(text));
  }

  static String? _placeKey(MaintenanceRecord r) {
    final building = firstNonEmptyString([r.raw['buildingId'], (r.raw['relatedAsset'] is Map ? (r.raw['relatedAsset'] as Map)['buildingID'] : null)]);
    final floor = r.raw['relatedAsset'] is Map ? (r.raw['relatedAsset'] as Map)['floorID']?.toString() : null;
    if (building != null) return '$building|${floor ?? ''}';
    final loc = r.location?.trim();
    return (loc == null || loc.isEmpty) ? null : 'loc|${loc.toLowerCase()}';
  }

  static String? firstNonEmptyString(List<Object?> xs) {
    for (final x in xs) {
      final s = x?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  /// Today's plan from cached work orders. [blockedIds] are steps a saved
  /// server brief said were waiting on a permit.
  static List<DayStep> plan(List<MaintenanceRecord> records, DateTime now, {Set<String> blockedIds = const {}}) {
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final picked = <_Item>[];
    for (final r in records) {
      if (r.id.isEmpty || (r.status ?? '') == 'Cancelled') continue;
      final done = isDone(r);
      final due = r.effectiveDate;
      final invite = r.isAssignmentPending && !done;
      final inProgress = !done && r.normalizedStatus.contains('progress');
      final onHold = !done && r.normalizedStatus.contains('hold');
      if (done) {
        final at = r.completedDate;
        if (at == null || at.isBefore(today) || !at.isBefore(tomorrow)) continue;
      } else if (!(invite || inProgress || (due != null && due.isBefore(tomorrow)))) {
        continue;
      }
      final slaState = r.raw['slaState']?.toString();
      final resolveBy = DateTime.tryParse(r.raw['slaResolveDueAt']?.toString() ?? '')?.toLocal();
      final slaRisk = !done &&
          (slaState == 'breached' || slaState == 'at_risk' || (resolveBy != null && resolveBy.difference(now) <= const Duration(hours: 2)));
      final overdue = !done && due != null && due.isBefore(now);
      final safety = !done && !invite && isSafety(r);
      final (double tier, String code) = done
          ? (9.0, 'done')
          : invite
              ? (0.5, 'invite')
              : safety
                  ? (0.0, 'safety')
                  : slaRisk
                      ? (1.0, slaState == 'breached' ? 'sla_breached' : 'sla_risk')
                      : onHold
                          ? (5.0, 'on_hold')
                          : overdue
                              ? (2.0, 'overdue')
                              : inProgress
                                  ? (3.0, 'in_progress')
                                  : (4.0, 'due_today');
      picked.add(_Item(r, tier, code, blockedIds.contains(r.id), overdue, inProgress, safety, resolveBy));
    }

    final tiers = picked.map((i) => i.tier).toSet().toList()..sort();
    final ordered = <_Item>[];
    for (final t in tiers) {
      var items = picked.where((i) => i.tier == t).toList();
      if (t == 9) {
        items.sort((a, b) => (b.r.completedDate ?? now).compareTo(a.r.completedDate ?? now));
      } else {
        items.sort(_cmp);
        if (t >= 2) {
          final last = ordered.lastWhere((i) => i.tier != 0.5, orElse: () => _Item.none);
          items = _groupByPlace(items, identical(last, _Item.none) ? null : _placeKey(last.r));
        }
      }
      ordered.addAll(items);
    }

    final steps = <DayStep>[];
    String? prevKey;
    for (final it in ordered.take(25)) {
      final r = it.r;
      final key = _placeKey(r);
      final job = it.code != 'done' && it.code != 'invite';
      final same = job && key != null && key == prevKey;
      if (job) prevKey = key;
      steps.add(DayStep(
        order: steps.length + 1,
        kind: it.code == 'invite' ? 'invite' : (r.raw['sourcePmId'] != null ? 'pm' : (r.raw['sourceRmId'] != null ? 'rm' : 'wo')),
        id: r.id,
        ref: r.referenceId,
        title: r.focusTitle,
        location: r.location,
        due: r.effectiveDate,
        status: r.displayStatus,
        priority: normalisePriority(r.priority),
        done: it.code == 'done',
        reasonCode: it.code,
        reasonParams: {if (it.code == 'on_hold') 'holdReason': r.raw['holdReason']?.toString() ?? ''},
        samePlaceAsPrevious: same,
        route: it.code == 'invite' ? '/technician/invites' : '/technician/orders/${r.type.slug}/${r.id}',
        safety: it.safety,
        overdue: it.overdue,
        inProgress: it.inProgress,
        permitBlocked: it.blocked,
        items: [
          if (r.checklists.where((c) => !c.isSignature).isNotEmpty)
            DayItem(code: 'checklist', params: {
              'done': '${r.checklists.where((c) => !c.isSignature && c.isCompleted).length}',
              'total': '${r.checklists.where((c) => !c.isSignature).length}',
            }, text: ''),
          if (job && r.requireFaceCapture) const DayItem(code: 'face_capture', text: ''),
          if (job && r.requireLocation) const DayItem(code: 'location', text: ''),
          if (job) const DayItem(code: 'signature', text: ''),
        ],
      ));
    }
    return steps;
  }

  static int _cmp(_Item a, _Item b) {
    if (a.blocked != b.blocked) return a.blocked ? 1 : -1;
    final pr = (_priorityRank[normalisePriority(a.r.priority)] ?? 2) - (_priorityRank[normalisePriority(b.r.priority)] ?? 2);
    if (pr != 0) return pr;
    final ad = a.r.effectiveDate?.millisecondsSinceEpoch ?? 1 << 52;
    final bd = b.r.effectiveDate?.millisecondsSinceEpoch ?? 1 << 52;
    if (ad != bd) return ad.compareTo(bd);
    return a.r.focusTitle.compareTo(b.r.focusTitle);
  }

  static List<_Item> _groupByPlace(List<_Item> items, String? continueFrom) {
    final free = items.where((i) => !i.blocked).toList();
    final blocked = items.where((i) => i.blocked).toList();
    final groups = <List<_Item>>[];
    final byKey = <String, List<_Item>>{};
    for (final it in free) {
      final k = _placeKey(it.r);
      if (k == null) {
        groups.add([it]);
        continue;
      }
      final g = byKey.putIfAbsent(k, () {
        final list = <_Item>[];
        groups.add(list);
        return list;
      });
      g.add(it);
    }
    if (continueFrom != null) {
      final idx = groups.indexWhere((g) => _placeKey(g.first.r) == continueFrom);
      if (idx > 0) groups.insert(0, groups.removeAt(idx));
    }
    return [...groups.expand((g) => g), ...blocked];
  }

  /// Lays what only the server knew (permit state, parts, inspections,
  /// snags, its rules items) from a saved brief over the phone's plan.
  /// Order and `done` stay the phone's: they come from fresher cached jobs.
  /// Saved non-work-order steps (inspections, snags) that are still open are
  /// kept, after the phone's steps.
  static List<DayStep> mergeCached(List<DayStep> local, DayBrief? cached) {
    if (cached == null) return local;
    final byId = {for (final s in cached.steps) s.id: s};
    final merged = [
      for (final s in local)
        if (byId[s.id] case final saved?)
          s.copyWith(
            permit: saved.permit,
            items: saved.items.where((i) => i.source == TextSource.rules).isNotEmpty
                ? saved.items.where((i) => i.source == TextSource.rules).toList()
                : s.items,
          )
        else
          s,
    ];
    final localIds = local.map((s) => s.id).toSet();
    final extra = cached.steps.where((s) => !localIds.contains(s.id) && !s.done && (s.kind == 'inspection' || s.kind == 'snag'));
    var order = merged.length;
    return [
      ...merged,
      for (final s in extra)
        DayStep(
          order: ++order,
          kind: s.kind,
          id: s.id,
          ref: s.ref,
          title: s.title,
          location: s.location,
          due: s.due,
          status: s.status,
          priority: s.priority,
          reasonCode: s.reasonCode,
          reasonParams: s.reasonParams,
          items: s.items.where((i) => i.source == TextSource.rules).toList(),
          route: s.route,
          permit: s.permit,
          safety: s.safety,
          overdue: s.overdue,
          inProgress: s.inProgress,
          permitBlocked: s.permitBlocked,
        ),
    ];
  }

  /// Ticks a server step done when the phone's fresher copy of the job says
  /// it is finished. Never the other way round, and never from the model.
  static List<DayStep> overlayDone(List<DayStep> steps, List<MaintenanceRecord> records) {
    final done = {for (final r in records) if (isDone(r)) r.id};
    return [for (final s in steps) (!s.done && done.contains(s.id)) ? s.copyWith(done: true) : s];
  }
}

class _Item {
  const _Item(this.r, this.tier, this.code, this.blocked, this.overdue, this.inProgress, this.safety, this.resolveBy);
  static final none = _Item(MaintenanceRecord.fromJson(const {}), -1, '', false, false, false, false, null);

  final MaintenanceRecord r;
  final double tier;
  final String code;
  final bool blocked;
  final bool overdue;
  final bool inProgress;
  final bool safety;
  final DateTime? resolveBy;
}

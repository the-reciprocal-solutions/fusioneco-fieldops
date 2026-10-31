import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../photo_twin/snag_actions.dart';
import 'module_spec.dart';

/// Phase 3a — Facility Management summary screens (FE-mobile.md). Endpoint
/// shapes checked against the live server 2026-10-30; field names are the
/// server's. Module ids are the catalog's (src/mobile/moduleCatalog.ts).
///
/// Paging: `page`+`limit` everywhere it works. Reactive and Assets ignored
/// paging until the server got optionalPage() (utils/optionalPaging.ts);
/// Preventive pages only when both are sent.

Map<String, dynamic> _pages(int page, int size) => {'page': '$page', 'limit': '$size'};

String? _join(Iterable<Object?> parts) {
  final v = parts.map(s).whereType<String>().toList();
  return v.isEmpty ? null : v.join(' · ');
}

// ── Work orders ─────────────────────────────────────────────────────────────

RecordAction _woStatus(String label, String status, IconData icon, {bool primary = false, TextAsk ask = TextAsk.none}) =>
    RecordAction(
      label: label,
      icon: icon,
      primary: primary,
      ask: ask,
      run: (api, r, text) => api.post('/api/fm/work-order/${r['id']}/status', body: {
        'status': status,
        if (status == 'On Hold' && text != null) 'holdReason': text,
      }),
    );

final _comment = RecordAction(
  label: 'act.comment',
  icon: LucideIcons.messageSquarePlus,
  ask: TextAsk.required,
  run: (api, r, text) => api.post('/api/fm/work-order/${r['id']}/comments', body: {'text': text}),
);

final workOrdersSpec = ModuleSpec(
  moduleId: 'work_orders',
  summaries: [
    SummarySpec('/api/fm/work-order/analytics', (j) => [
          Kpi('kpi.open', fmtNum(at(j, 'summary.openWorkOrders'))),
          Kpi('kpi.in_progress', fmtNum(at(j, 'summary.inProgressWorkOrders')), tone: Tone.info),
          Kpi('kpi.overdue', fmtNum(at(j, 'summary.overdueWorkOrders')), tone: Tone.bad),
          Kpi('kpi.on_time', fmtPct(at(j, 'summary.onTimeCompletionRate')), tone: Tone.good),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/work-order',
    pageQuery: _pages,
    searchParam: 'search',
    detailPath: (id) => '/api/fm/work-order/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['workOrderId']),
      title: s(r['title']) ?? '–',
      subtitle: _join([r['location'], r['technicianName']]),
      status: s(r['status']),
      priority: s(r['priority']),
      date: d(r['dueDate']),
    ),
  ),
  facts: (r) => [
    ('fact.category', s(r['category'])),
    ('fact.location', s(r['location'])),
    ('fact.asset', s(at(r, 'relatedAsset.name'))),
    ('fact.technician', s(r['technicianName']) ?? s(at(r, 'workOrderTechnician.name'))),
    ('fact.requested_by', s(r['requestedBy'])),
    ('fact.due', fmtDate(r['dueDate'])),
    ('fact.sla', s(r['slaState'])),
    ('fact.cost', fmtMoney(r['cost'], r['currency'])),
    ('fact.description', s(r['description'])),
  ],
  actions: (r) {
    final st = s(r['status']) ?? '';
    return [
      if (st == 'Open' || st == 'On Hold') _woStatus('act.start', 'In Progress', LucideIcons.play, primary: true),
      if (st == 'In Progress') _woStatus('act.complete', 'Completed', LucideIcons.check, primary: true),
      if (st == 'Open' || st == 'In Progress') _woStatus('act.hold', 'On Hold', LucideIcons.pause, ask: TextAsk.required),
      _comment,
    ];
  },
);

// ── Permit to Work ──────────────────────────────────────────────────────────

RecordAction _permit(String label, String action, IconData icon, {bool primary = false, bool danger = false, TextAsk ask = TextAsk.none}) =>
    RecordAction(
      label: label,
      icon: icon,
      primary: primary,
      danger: danger,
      ask: ask,
      run: (api, r, text) => api.post('/api/fm/permits/${r['id']}/transition', body: {
        'action': action,
        'reason': ?text,
      }),
    );

final permitsSpec = ModuleSpec(
  moduleId: 'permits',
  summaries: [
    SummarySpec('/api/fm/permits/summary', (j) => [
          Kpi('kpi.live', fmtNum(j['live']), tone: Tone.info),
          Kpi('kpi.awaiting_approval', fmtNum(j['awaitingApproval']), tone: Tone.warn),
          Kpi('kpi.my_approvals', fmtNum(j['myApprovals'])),
          Kpi('kpi.expiring_soon', fmtNum(j['expiringSoon']), tone: Tone.bad),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/permits',
    pageQuery: _pages,
    detailPath: (id) => '/api/fm/permits/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['permitNo']),
      title: s(r['title']) ?? '–',
      subtitle: _join([r['buildingName'], r['spaceName']]),
      status: s(r['status']),
      priority: s(r['riskLevel']),
      date: d(r['plannedStart']),
    ),
  ),
  facts: (r) => [
    ('fact.type', s(r['type'])),
    ('fact.building', s(r['buildingName'])),
    ('fact.location', _join([r['floorName'], r['spaceName']])),
    ('fact.requested_by', s(r['requestedByName'])),
    ('fact.contractor', s(r['contractorCompany'])),
    ('fact.planned', _join([fmtDate(r['plannedStart']), fmtDate(r['plannedEnd'])])),
    ('fact.risk', _join([r['riskLevel'], r['riskScore']])),
    ('fact.crew', s(r['crewOnSite'])),
  ],
  // Approve / reject a submitted permit. The server enforces approver role
  // and four-eyes (no self-approval) and answers 403 with the reason.
  actions: (r) => s(r['status']) == 'submitted'
      ? [
          _permit('act.approve', 'approve', LucideIcons.check, primary: true),
          _permit('act.reject', 'reject', LucideIcons.x, danger: true, ask: TextAsk.required),
        ]
      : const [],
);

// ── Attendance ──────────────────────────────────────────────────────────────

final attendanceSpec = ModuleSpec(
  moduleId: 'attendance',
  summaries: [
    SummarySpec('/api/fm/attendance/daily/board', (j) {
      final by = j['byStatus'] is Map ? j['byStatus'] as Map : const {};
      return [
        Kpi('kpi.expected', fmtNum(j['expected'])),
        for (final k in ['present', 'late', 'absent', 'on_leave'])
          if (by[k] != null) Kpi('kpi.att_$k', fmtNum(by[k]), tone: k == 'present' ? Tone.good : k == 'absent' ? Tone.bad : Tone.warn),
        Kpi('kpi.pending_review', fmtNum(j['pendingReview']), tone: Tone.warn),
        Kpi('kpi.no_shift', fmtNum(j['noShift'])),
      ];
    }),
  ],
);

// ── Snags ───────────────────────────────────────────────────────────────────

final snagsSpec = ModuleSpec(
  moduleId: 'snags',
  summaries: [
    SummarySpec('/api/snags/summary', (j) => [
          Kpi('kpi.open', fmtNum(at(j, 'byStatus.open'))),
          Kpi('kpi.in_progress', fmtNum(at(j, 'byStatus.in-progress')), tone: Tone.info),
          Kpi('kpi.overdue', fmtNum(j['overdue']), tone: Tone.bad),
          Kpi('kpi.critical_open', fmtNum(j['criticalOpen']), tone: Tone.bad),
        ]),
  ],
  list: ListSpec(
    path: '/api/snags',
    // The list leaves out each snag's thread; the detail fetches it.
    query: const {'view': 'list'},
    pageQuery: _pages,
    detailPath: (id) => '/api/snags/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['reference']),
      title: s(r['title']) ?? '–',
      subtitle: _join([r['locationLabel'] ?? r['locationText'], r['assigneeName']]),
      status: s(r['status']),
      priority: s(r['priority']),
      date: d(r['dueDate']),
    ),
  ),
  facts: (r) => [
    ('fact.trade', s(r['trade'])),
    ('fact.location', s(r['locationLabel']) ?? s(r['locationText'])),
    ('fact.asset', s(r['assetName'])),
    ('fact.assignee', s(r['assigneeName'])),
    ('fact.raised_by', s(r['raisedByName'])),
    ('fact.due', fmtDate(r['dueDate'])),
    ('fact.description', s(r['description'])),
  ],
  actions: snagActions,
  extra: snagSections,
);

// ── Maintenance ─────────────────────────────────────────────────────────────

final preventiveSpec = ModuleSpec(
  moduleId: 'preventive',
  summaries: [
    SummarySpec('/api/fm/preventive-maintenance/analytics', (j) => [
          Kpi('kpi.overdue', fmtNum(j['overdueMaintenance']), tone: Tone.bad),
          Kpi('kpi.upcoming', fmtNum(j['upcomingMaintenance']), tone: Tone.info),
          Kpi('kpi.pending', fmtNum(countIn(j['statusCounts'], 'status', 'pending')), tone: Tone.warn),
          Kpi('kpi.adherence', fmtPct(j['overallAdherence']), tone: Tone.good),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/preventive-maintenance',
    pageQuery: _pages,
    detailPath: (id) => '/api/fm/preventive-maintenance/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['pmScheduleId']),
      title: s(r['assetName']) ?? s(r['description']) ?? '–',
      subtitle: _join([r['frequency'], r['category']]),
      status: s(r['status']),
      priority: s(r['priority']),
      date: d(r['nextDueDate']),
    ),
  ),
  facts: _maintenanceFacts,
);

List<(String, String?)> _maintenanceFacts(Json r) => [
      ('fact.asset', s(r['assetName']) ?? s(at(r, 'asset.name'))),
      ('fact.frequency', s(r['frequency'])),
      ('fact.category', s(r['category'])),
      ('fact.location', s(r['location'])),
      ('fact.technician', s(r['technicianName'])),
      ('fact.vendor', s(r['vendorName'])),
      ('fact.planned', fmtDate(r['plannedDate'])),
      ('fact.next_due', fmtDate(r['nextDueDate'])),
      ('fact.description', s(r['description'])),
    ];

final reactiveSpec = ModuleSpec(
  moduleId: 'reactive',
  summaries: [
    SummarySpec('/api/fm/reactive-maintenance/analytics', (j) => [
          Kpi('kpi.total', fmtNum(at(j, 'summary.totalRequests'))),
          Kpi('kpi.urgent', fmtNum(at(j, 'summary.urgentRequests')), tone: Tone.bad),
          Kpi('kpi.completed_today', fmtNum(at(j, 'summary.completedToday')), tone: Tone.good),
          Kpi('kpi.sla_breached', fmtNum(at(j, 'sla.breached')), tone: Tone.warn),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/reactive-maintenance',
    pageQuery: _pages,
    detailPath: (id) => '/api/fm/reactive-maintenance/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['ticketId']),
      title: s(r['subRequest']) ?? s(r['type']) ?? '–',
      subtitle: _join([r['location'], r['technicianName']]),
      status: s(r['status']),
      priority: s(r['priority']),
      date: d(r['dateTime']),
    ),
  ),
  facts: (r) => [
    ('fact.type', s(r['type'])),
    ('fact.category', s(r['category'])),
    ('fact.location', s(r['location'])),
    ('fact.requested_by', s(r['requestedBy'])),
    ('fact.technician', s(r['technicianName'])),
    ('fact.work_order', s(at(r, 'generatedWorkOrder.workOrderId'))),
    ('fact.due', fmtDate(r['dueDate'])),
    ('fact.description', s(r['description'])),
  ],
);

final annualSpec = ModuleSpec(
  moduleId: 'annual',
  summaries: [
    SummarySpec('/api/fm/annual-maintenance/analytics', (j) => [
          Kpi('kpi.active_plans', fmtNum(at(j, 'summary.activeTemplates'))),
          Kpi('kpi.overdue', fmtNum(j['overdueMaintenance']), tone: Tone.bad),
          Kpi('kpi.done_this_month', fmtNum(at(j, 'summary.completedThisMonth')), tone: Tone.good),
          Kpi('kpi.compliance', fmtPct(j['overallCompliance']), tone: Tone.info),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/annual-maintenance',
    pageQuery: _pages,
    detailPath: (id) => '/api/fm/annual-maintenance/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['pmScheduleId']),
      title: s(r['assetName']) ?? s(r['description']) ?? '–',
      subtitle: _join([r['category'], r['technicianName']]),
      status: s(r['status']),
      priority: s(r['priority']),
      date: d(r['nextDueDate']),
    ),
  ),
  facts: _maintenanceFacts,
);

final inspectionsSpec = ModuleSpec(
  moduleId: 'inspections',
  list: ListSpec(
    path: '/api/fm/inspections/templates',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['referenceId']),
      title: s(r['name']) ?? '–',
      subtitle: _join([r['category'], r['location']]),
      status: s(r['status']),
      date: d(r['updatedAt']),
    ),
  ),
  facts: (r) => [
    ('fact.category', s(r['category'])),
    ('fact.location', s(r['location'])),
    ('fact.frequency', s(r['frequency'])),
    ('fact.description', s(r['description'])),
  ],
);

final pmComplianceSpec = ModuleSpec(
  moduleId: 'pm_compliance',
  summaries: [
    SummarySpec('/api/fm/preventive-maintenance/analytics', (j) {
      final trend = j['complianceTrend'] is List ? (j['complianceTrend'] as List).whereType<Map>().toList() : const <Map>[];
      return [
        Kpi('kpi.compliance', fmtPct(j['overallCompliance']), tone: Tone.info),
        Kpi('kpi.adherence', fmtPct(j['overallAdherence']), tone: Tone.good),
        Kpi('kpi.overdue', fmtNum(j['overdueMaintenance']), tone: Tone.bad),
        Kpi('kpi.avg_completion_h', fmtNum(j['avgCompletionTime'], decimals: 1)),
        // Last months, oldest first, as on the web chart.
        for (final m in trend.reversed.take(6).toList().reversed)
          Kpi('${m['month'] ?? m['m']}', fmtPct(m['compliance'] ?? m['pct'])),
      ];
    }),
  ],
);

// ── Assets, documents ───────────────────────────────────────────────────────

final assetsSpec = ModuleSpec(
  moduleId: 'assets',
  summaries: [
    SummarySpec('/api/fm/assets/analytics/dashboard', (j) => [
          Kpi('kpi.total', fmtNum(j['totalAssets'])),
          Kpi('kpi.active', fmtNum(j['activeAssets']), tone: Tone.good),
          Kpi('kpi.in_maintenance', fmtNum(j['maintenanceAssets']), tone: Tone.warn),
          Kpi('kpi.poor_critical', fmtNum((n(at(j, 'assetsByCondition.poor')) ?? 0) + (n(at(j, 'assetsByCondition.critical')) ?? 0)), tone: Tone.bad),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/assets',
    pageQuery: _pages,
    searchParam: 'search',
    detailPath: (id) => '/api/fm/assets/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['assetReferenceId']),
      title: s(r['name']) ?? s(r['assetName']) ?? '–',
      subtitle: _join([r['category'], r['location']]),
      status: s(r['status']),
      priority: s(r['condition']),
      date: d(r['nextMaintenance']),
    ),
  ),
  // Never shown: cameraUsername / cameraPassword come back on this endpoint.
  facts: (r) => [
    ('fact.type', s(r['type'])),
    ('fact.category', s(r['category'])),
    ('fact.location', s(r['location'])),
    ('fact.condition', s(r['condition'])),
    ('fact.make_model', _join([r['manufacturer'], r['model']])),
    ('fact.serial', s(r['serialNumber'])),
    ('fact.assigned_to', s(r['assignedTo'])),
    ('fact.last_maintenance', fmtDate(r['lastMaintenance'])),
    ('fact.next_maintenance', fmtDate(r['nextMaintenance'])),
    ('fact.warranty', fmtDate(r['warrantyExpiry'])),
    ('fact.value', fmtMoney(r['currentValue'], r['currency'])),
  ],
);

final documentsSpec = ModuleSpec(
  moduleId: 'documents',
  summaries: [
    SummarySpec('/api/fm/document/analytics', (j) => [
          Kpi('kpi.total', fmtNum(j['totalDocuments'])),
          Kpi('kpi.expiring_certs', fmtNum((j['certificatesExpiringSoon'] as List?)?.length ?? 0), tone: Tone.warn),
          Kpi('kpi.categories', fmtNum((j['documentsByCategory'] as List?)?.length ?? 0)),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/document',
    searchParam: 'search',
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['name']) ?? s(r['originalName']) ?? '–',
      subtitle: _join([r['categoryName'] ?? at(r, 'category.name'), r['type']]),
      status: s(r['complianceStatus']),
      date: d(r['expiryDate']) ?? d(r['createdAt']),
    ),
  ),
  facts: (r) => [
    ('fact.category', s(r['categoryName']) ?? s(at(r, 'category.name'))),
    ('fact.file', _join([r['originalName'], r['type']])),
    ('fact.department', s(r['department'])),
    ('fact.expiry', fmtDate(r['expiryDate'])),
    ('fact.uploaded', fmtDate(r['createdAt'])),
    ('fact.description', s(r['description'])),
  ],
  open: (r) => s(r['path']),
);

// ── Quotes, invoices ────────────────────────────────────────────────────────

RecordAction _money(String path, String label, String status, IconData icon, {bool primary = false, bool danger = false, TextAsk ask = TextAsk.none}) =>
    RecordAction(
      label: label,
      icon: icon,
      primary: primary,
      danger: danger,
      ask: ask,
      run: (api, r, text) => api.post('$path/${r['id']}/status', body: {'status': status, 'reason': ?text}),
    );

final quotesSpec = ModuleSpec(
  moduleId: 'quotes',
  list: ListSpec(
    path: '/api/fm/quotes',
    detailPath: (id) => '/api/fm/quotes/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['quoteNumber']),
      title: s(r['subject']) ?? '–',
      subtitle: _join([r['contactName'], fmtMoney(r['grandTotal'], r['currency'])]),
      status: s(r['status']),
      date: d(r['expiryDate']),
    ),
  ),
  facts: (r) => [
    ('fact.type', s(r['quoteType'])),
    ('fact.contact', _join([r['contactName'], r['contactEmail']])),
    ('fact.site', s(r['site'])),
    ('fact.total', fmtMoney(r['grandTotal'], r['currency'])),
    ('fact.issued', fmtDate(r['billDate'])),
    ('fact.expiry', fmtDate(r['expiryDate'])),
    ('fact.description', s(r['description'])),
  ],
  // The web's allowed moves (quoteController changeStatus): Sent → Accepted / Rejected.
  actions: (r) => s(r['status']) == 'Sent'
      ? [
          _money('/api/fm/quotes', 'act.accept', 'Accepted', LucideIcons.check, primary: true),
          _money('/api/fm/quotes', 'act.reject', 'Rejected', LucideIcons.x, danger: true, ask: TextAsk.optional),
        ]
      : const [],
);

final invoicesSpec = ModuleSpec(
  moduleId: 'invoices',
  summaries: [
    SummarySpec('/api/fm/invoices/summary', (j) {
      num count(String st) {
        var t = 0 as num;
        for (final e in (j['byStatus'] as List? ?? const [])) {
          if (e is Map && e['status'] == st) t += n(e['count']) ?? 0;
        }
        return t;
      }

      return [
        Kpi('kpi.awaiting_approval', fmtNum(count('Pending Approval') + count('Draft')), tone: Tone.warn),
        Kpi('kpi.sent', fmtNum(count('Sent')), tone: Tone.info),
        Kpi('kpi.overdue', fmtNum(count('Overdue')), tone: Tone.bad),
        Kpi('kpi.paid', fmtNum(count('Paid')), tone: Tone.good),
      ];
    }),
  ],
  list: ListSpec(
    path: '/api/fm/invoices',
    detailPath: (id) => '/api/fm/invoices/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['invoiceNumber']),
      title: s(r['subject']) ?? '–',
      subtitle: _join([r['contactName'], fmtMoney(r['balanceDue'] ?? r['grandTotal'], r['currency'])]),
      status: s(r['status']),
      date: d(r['dueDate']),
    ),
  ),
  facts: (r) => [
    ('fact.type', s(r['invoiceType'])),
    ('fact.total', fmtMoney(r['grandTotal'], r['currency'])),
    ('fact.paid', fmtMoney(r['amountPaid'], r['currency'])),
    ('fact.balance', fmtMoney(r['balanceDue'], r['currency'])),
    ('fact.issued', fmtDate(r['issueDate'])),
    ('fact.due', fmtDate(r['dueDate'])),
    ('fact.terms', s(r['paymentTerms'])),
  ],
  // Approve where the web allows it (invoiceController changeStatus).
  actions: (r) {
    final st = s(r['status']);
    return st == 'Draft' || st == 'Pending Approval'
        ? [_money('/api/fm/invoices', 'act.approve', 'Approved', LucideIcons.check, primary: true)]
        : const [];
  },
);

// ── Reporting, audit ────────────────────────────────────────────────────────

final reportingSpec = ModuleSpec(
  moduleId: 'reporting',
  summaries: [
    SummarySpec('/api/fm/work-order/analytics', (j) => [
          Kpi('kpi.wo_total', fmtNum(at(j, 'summary.totalWorkOrders'))),
          Kpi('kpi.wo_completed', fmtNum(at(j, 'summary.completedWorkOrders')), tone: Tone.good),
          Kpi('kpi.avg_completion_d', fmtNum(at(j, 'summary.avgCompletionTime'), decimals: 1)),
          Kpi('kpi.sla_compliance', fmtPct(at(j, 'sla.compliancePct')), tone: Tone.info),
        ]),
    SummarySpec('/api/fm/preventive-maintenance/analytics', (j) => [
          Kpi('kpi.pm_compliance', fmtPct(j['overallCompliance']), tone: Tone.info),
          Kpi('kpi.pm_overdue', fmtNum(j['overdueMaintenance']), tone: Tone.bad),
        ]),
    SummarySpec('/api/fm/reactive-maintenance/analytics', (j) => [
          Kpi('kpi.rm_total', fmtNum(at(j, 'summary.totalRequests'))),
          Kpi('kpi.rm_avg_response', fmtNum(at(j, 'summary.avgResponseTime'), decimals: 1)),
        ]),
  ],
);

final auditLogSpec = ModuleSpec(
  moduleId: 'audit_log',
  summaries: [
    SummarySpec('/api/audit-logs/summary', (j) => [
          Kpi('kpi.events_30d', fmtNum(j['total'])),
          Kpi('kpi.failed_logins', fmtNum(countIn(j['byAction'], 'action', 'login_failed')), tone: Tone.bad),
          Kpi('kpi.deletes', fmtNum(countIn(j['byAction'], 'action', 'delete')), tone: Tone.warn),
        ]),
  ],
  list: ListSpec(
    path: '/api/audit-logs',
    pageQuery: _pages,
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: _join([r['action'], r['entityLabel'] ?? r['entityType']]) ?? '–',
      subtitle: _join([r['actorName'], r['actorRole']]),
      status: s(r['action']),
      date: d(r['createdAt']),
    ),
  ),
  facts: (r) => [
    ('fact.action', s(r['action'])),
    ('fact.entity', _join([r['entityType'], r['entityLabel']])),
    ('fact.actor', _join([r['actorName'], r['actorRole']])),
    ('fact.when', fmtDate(r['createdAt'])),
    ('fact.request', _join([r['method'], r['path']])),
  ],
);

/// Every Phase 3a spec by catalog module id.
final fmSpecs = <String, ModuleSpec>{
  for (final spec in [
    workOrdersSpec,
    permitsSpec,
    attendanceSpec,
    snagsSpec,
    preventiveSpec,
    reactiveSpec,
    annualSpec,
    inspectionsSpec,
    pmComplianceSpec,
    assetsSpec,
    documentsSpec,
    quotesSpec,
    invoicesSpec,
    reportingSpec,
    auditLogSpec,
  ])
    spec.moduleId: spec,
};

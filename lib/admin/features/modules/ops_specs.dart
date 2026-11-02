import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'amc_calendar_screen.dart';
import 'chat_screen.dart';
import 'module_spec.dart';
import 'simple_screens.dart';
import 'timeline_summary_screen.dart';

/// Phase 3c — everything else (FE-mobile.md). Endpoints checked against the
/// live server 2026-10-30. Where the web has more (3D, running a report),
/// the phone shows the summary and a note that the full view is on a desktop.

Map<String, dynamic> _pages(int page, int size) => {'page': '$page', 'limit': '$size'};
Map<String, dynamic> _offset(int page, int size) => {'limit': '$size', 'offset': '${(page - 1) * size}'};

String? _join(Iterable<Object?> parts) {
  final v = parts.map(s).whereType<String>().toList();
  return v.isEmpty ? null : v.join(' · ');
}

int _len(Object? v) => v is List ? v.length : 0;

// ── Facility Ops (a module of five pages) ───────────────────────────────────

final facilityOpsSpec = ModuleSpec(moduleId: 'facility_ops', screen: (m) => ModulePagesScreen(module: m));

final bookingsSpec = ModuleSpec(
  moduleId: 'facility_ops:bookings',
  list: ListSpec(
    path: '/api/ops/bookings',
    pageQuery: _pages,
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['title']) ?? s(at(r, 'target.name')) ?? '–',
      subtitle: _join([at(r, 'target.name'), at(r, 'user.name')]),
      status: s(r['status']),
      date: d(r['startAt']),
    ),
  ),
  facts: (r) => [
    ('fact.space', s(at(r, 'target.name'))),
    ('fact.booked_by', _join([at(r, 'user.name'), at(r, 'user.email')])),
    ('fact.starts', _join([fmtDate(r['startAt']), _time(r['startAt'])])),
    ('fact.ends', _join([fmtDate(r['endAt']), _time(r['endAt'])])),
    ('fact.attendees', _len(r['attendees']) == 0 ? null : '${_len(r['attendees'])}'),
    ('fact.repeats_rule', s(r['recurrenceRule'])),
  ],
);

String? _time(Object? v) {
  final t = d(v);
  return t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Check-in / check-out (the photo the web can attach is optional on the server).
RecordAction _visitor(String label, String path, IconData icon) => RecordAction(
      label: label,
      icon: icon,
      primary: true,
      run: (api, r, _) => api.post('/api/ops/visitors/${r['id']}/$path'),
    );

final visitorsSpec = ModuleSpec(
  moduleId: 'facility_ops:visitors',
  summaries: [
    SummarySpec('/api/ops/visitors/reception/dashboard', (j) => [
          Kpi('kpi.visitors_today', fmtNum(_len(j['todaysVisitors']))),
          Kpi('kpi.awaiting_checkin', fmtNum(_len(j['awaiting_checkin'])), tone: Tone.warn),
          Kpi('kpi.checked_in', fmtNum(_len(j['checked_in'])), tone: Tone.good),
          Kpi('kpi.pending_approval', fmtNum(_len(j['pending_approval'])), tone: Tone.info),
        ]),
  ],
  list: ListSpec(
    path: '/api/ops/visitors',
    pageQuery: _pages,
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['badgeNo']),
      title: s(r['name']) ?? '–',
      subtitle: _join([r['purpose'], r['phone'] ?? r['email']]),
      status: s(r['status']),
      date: d(r['checkInAt']) ?? d(r['createdAt']),
    ),
  ),
  facts: (r) => [
    ('fact.purpose', s(r['purpose'])),
    ('fact.contact', _join([r['phone'], r['email']])),
    ('fact.badge', s(r['badgeNo'])),
    ('fact.checked_in', _join([fmtDate(r['checkInAt']), _time(r['checkInAt'])])),
    ('fact.checked_out', _join([fmtDate(r['checkOutAt']), _time(r['checkOutAt'])])),
    ('fact.host_approved', _join([fmtDate(r['hostApprovedAt']), _time(r['hostApprovedAt'])])),
    ('fact.notes', s(r['notes'])),
  ],
  actions: (r) => [
    // A walk-in waits for the host. The web's Approve (facility-ops/visitors
    // handleApprove) calls the same endpoint as pre-registering: it stamps
    // hostApprovedAt, and the visitor shows as checked in (P-015).
    if (r['status'] == 'pending_host_approval')
      RecordAction(
        label: 'act.approve',
        icon: LucideIcons.userCheck,
        primary: true,
        run: (api, r, text) => api.post('/api/ops/visitors/${r['id']}/pre-register', body: const <String, dynamic>{}),
      ),
    if (r['checkInAt'] == null) _visitor('act.check_in', 'check-in', LucideIcons.logIn),
    if (r['checkInAt'] != null && r['checkOutAt'] == null) _visitor('act.check_out', 'check-out', LucideIcons.logOut),
  ],
);

final serviceSchedulesSpec = ModuleSpec(
  moduleId: 'facility_ops:service_schedules',
  list: ListSpec(
    path: '/api/ops/service-schedules',
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['name']) ?? '–',
      subtitle: _join([r['type'], at(r, 'target.name'), r['frequency']]),
      status: r['active'] == false ? 'paused' : 'active',
      date: d(r['nextInstanceAt']),
    ),
  ),
  facts: (r) => [
    ('fact.type', s(r['type'])),
    ('fact.location', s(at(r, 'target.name'))),
    ('fact.frequency', s(r['frequency'])),
    ('fact.next_due', fmtDate(r['nextInstanceAt'])),
  ],
);

final rfqsSpec = ModuleSpec(
  moduleId: 'facility_ops:rfqs',
  list: ListSpec(
    path: '/api/fm/rfqs',
    detailPath: (id) => '/api/fm/rfqs/$id',
    row: (r) => RecordRow(id: '${r['id']}', ref: s(r['rfqNumber']), title: s(r['subject']) ?? '–', status: s(r['status']), date: d(r['sentAt']) ?? d(r['createdAt'])),
  ),
  facts: (r) => [
    ('fact.description', s(r['description'])),
    ('fact.sent', fmtDate(r['sentAt'])),
    ('fact.closed', fmtDate(r['closedAt'])),
    ('fact.notes', s(r['notes'])),
  ],
);

final purchaseOrdersSpec = ModuleSpec(
  moduleId: 'facility_ops:purchase_orders',
  list: ListSpec(
    path: '/api/fm/purchase-orders',
    detailPath: (id) => '/api/fm/purchase-orders/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['poNumber']),
      title: fmtMoney(r['totalValue'], r['currency']) ?? s(r['poNumber']) ?? '–',
      // The vendor; its reply is in the facts (a bare "pending" under CLOSED read as the PO's state).
      subtitle: s(at(r, 'vendor.name')),
      status: s(r['status']),
      priority: r['isEmergency'] == true ? 'critical' : null,
      date: d(r['expectedDate']) ?? d(r['createdAt']),
    ),
  ),
  facts: (r) => [
    ('fact.total', fmtMoney(r['totalValue'], r['currency'])),
    ('fact.vendor', s(at(r, 'vendor.name'))),
    ('fact.vendor_response', s(r['vendorResponse'])),
    ('fact.expected', fmtDate(r['expectedDate'])),
    ('fact.approved', fmtDate(r['approvedAt'])),
    ('fact.sent', fmtDate(r['sentAt'])),
    ('fact.notes', s(r['notes'])),
  ],
);

// ── AMC (scheduled maintenance; the web's calendar is 341 KB) ───────────────

final amcSpec = ModuleSpec(
  moduleId: 'amc',
  headerActions: (context, m) => [
    IconButton(
      icon: const Icon(LucideIcons.calendarDays, size: 20),
      tooltip: 'amc.calendar'.getString(context),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AmcCalendarScreen(module: m))),
    ),
  ],
  summaries: [
    SummarySpec('/api/fm/schedule-management/analytics', (j) => [
          Kpi('kpi.scheduled', fmtNum(at(j, 'summary.totalScheduled'))),
          Kpi('kpi.in_progress', fmtNum(at(j, 'summary.inProgressTasks')), tone: Tone.info),
          Kpi('kpi.completed', fmtNum(at(j, 'summary.completedTasks')), tone: Tone.good),
          Kpi('kpi.overdue', fmtNum(at(j, 'summary.overdueTasks')), tone: Tone.bad),
        ]),
  ],
  list: ListSpec(
    path: '/api/fm/schedule-management',
    pageQuery: _pages,
    detailPath: (id) => '/api/fm/schedule-management/$id',
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['title']) ?? s(r['assetName']) ?? s(r['description']) ?? '–',
      subtitle: _join([r['type'], r['technicianName']]),
      status: s(r['status']),
      priority: s(r['priority']),
      date: d(r['requestedDate']),
    ),
  ),
  facts: (r) => [
    ('fact.type', s(r['type'])),
    ('fact.asset', s(r['assetName'])),
    ('fact.location', s(r['location'])),
    ('fact.technician', s(r['technicianName'])),
    ('fact.planned', fmtDate(r['requestedDate'])),
    ('fact.description', s(r['description'])),
  ],
);

// ── Digital Twin, Construction ──────────────────────────────────────────────

final digitalTwinSpec = ModuleSpec(
  moduleId: 'digital_twin',
  // The buildings that carry the twin; the 3D view is on the desktop.
  desktopNote: 'desktop.twin',
  list: ListSpec(
    path: '/api/fm/bs/building-systems',
    pageQuery: _pages,
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['name']) ?? '–',
      subtitle: _join([r['location'], n(r['area']) == null ? null : '${fmtNum(r['area'])} m²']),
      status: s(r['status']),
      priority: s(r['condition']),
    ),
  ),
  facts: (r) => [
    ('fact.location', s(r['location'])),
    ('fact.area', n(r['area']) == null ? null : '${fmtNum(r['area'])} m²'),
    ('fact.condition', s(r['condition'])),
    ('fact.lifecycle', s(r['lifecycleState'])),
    ('fact.description', s(r['description'])),
  ],
);

final timelineSpec = ModuleSpec(moduleId: 'timeline_revisit', screen: (m) => TimelineSummaryScreen(module: m));

final handoverSpec = ModuleSpec(
  moduleId: 'handover',
  list: ListSpec(
    path: '/api/c2o/projects',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['projectCode']),
      title: s(r['name']) ?? '–',
      status: s(r['status']),
      date: d(r['updatedAt']),
    ),
  ),
  facts: (r) => [
    ('fact.code', s(r['projectCode'])),
    ('fact.packages', '${_len(r['packages'])}'),
    ('fact.description', s(r['description'])),
    ('fact.updated', fmtDate(r['updatedAt'])),
  ],
);

final constructionProgressSpec = ModuleSpec(
  moduleId: 'construction_progress',
  list: ListSpec(
    path: '/api/construction/schedules',
    row: (r) => RecordRow(id: '${r['id']}', title: s(r['name']) ?? s(r['title']) ?? '–', status: s(r['status']), date: d(r['updatedAt'])),
  ),
  facts: (r) => [('fact.description', s(r['description'])), ('fact.updated', fmtDate(r['updatedAt']))],
);

// ── Analytics ───────────────────────────────────────────────────────────────

final reportsSpec = ModuleSpec(
  moduleId: 'reports',
  desktopNote: 'desktop.reports',
  list: ListSpec(
    path: '/api/reports/definitions',
    items: (body) => rowsOf({'data': body is Map ? body['reports'] : null}),
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['name']) ?? '–',
      subtitle: _join([r['ownerName'], r['visibility']]),
      date: d(r['lastRunAt']) ?? d(r['updatedAt']),
    ),
  ),
  facts: (r) => [
    ('fact.description', s(r['description'])),
    ('fact.owner', s(r['ownerName'])),
    ('fact.runs', s(r['runCount'])),
    ('fact.last_run', fmtDate(r['lastRunAt'])),
    ('fact.schedules', '${_len(r['schedules'])}'),
  ],
);

/// Intelligence: the 11 capability headlines (`/intelligence/overview`, ~8 s on the live server).
final intelligenceSpec = ModuleSpec(
  moduleId: 'intelligence',
  list: ListSpec(
    path: '/api/intelligence/overview',
    items: (body) => rowsOf({'data': dataOf(body)['capabilities']}),
    row: (r) => RecordRow(
      id: '${r['id']}',
      // `name` added to the overview 2026-10-30; older servers send only the id.
      title: s(r['name']) ?? s(r['id']) ?? '–',
      subtitle: s(r['headline']),
      status: s(r['tone']),
      date: d(at(r, 'lineage.computedAt')),
    ),
  ),
  facts: (r) => [
    ('fact.value', r['value'] == null ? null : '${fmtNum(r['value'])} ${s(r['unit']) ?? ''}'.trim()),
    ('fact.source', s(at(r, 'lineage.source'))),
    ('fact.method', s(at(r, 'lineage.method'))),
    ('fact.window', s(at(r, 'lineage.window'))),
    ('fact.confidence', s(at(r, 'lineage.confidence'))),
    ('fact.agent_status', s(at(r, 'workflow.status'))),
  ],
);

final carbonSpec = ModuleSpec(
  moduleId: 'carbon',
  summaries: [
    SummarySpec('/api/ghg/dashboard', (j) {
      String v(String path, String unitPath) => '${fmtNum(at(j, path), decimals: 1)} ${s(at(j, unitPath)) ?? ''}'.trim();
      String pct(String path) => at(j, path) == null ? '' : ' (${fmtPct(at(j, path))})';
      return [
        Kpi('kpi.total_emissions', v('totalEmissions.value', 'totalEmissions.unit'), tone: Tone.warn),
        Kpi('kpi.energy', v('energyConsumption.value', 'energyConsumption.unit')),
        Kpi('kpi.scope1', '${fmtNum(at(j, 'scopeBreakdown.scope1.value'), decimals: 1)}${pct('scopeBreakdown.scope1.percentage')}'),
        Kpi('kpi.scope2', '${fmtNum(at(j, 'scopeBreakdown.scope2.value'), decimals: 1)}${pct('scopeBreakdown.scope2.percentage')}'),
        Kpi('kpi.scope3', '${fmtNum(at(j, 'scopeBreakdown.scope3.value'), decimals: 1)}${pct('scopeBreakdown.scope3.percentage')}'),
        Kpi('kpi.emissions_change', at(j, 'totalEmissions.change') == null ? '–' : '${fmtNum(at(j, 'totalEmissions.change'), decimals: 1)}%'),
      ];
    }),
  ],
);

// ── AI ──────────────────────────────────────────────────────────────────────

final askFlowAiSpec = ModuleSpec(moduleId: 'ask_flowai', screen: (m) => ChatSessionsScreen(module: m));

final flowAgentsSpec = ModuleSpec(
  moduleId: 'flow_agents',
  summaries: [
    SummarySpec('/api/flow-agents/overview', (j) => [
          Kpi('kpi.agents_active', '${fmtNum(at(j, 'agents.active'))} / ${fmtNum(at(j, 'agents.total'))}', tone: Tone.good),
          Kpi('kpi.running_now', fmtNum(j['runningNow']), tone: Tone.info),
          Kpi('kpi.runs_today', fmtNum(j['runsToday'])),
          Kpi('kpi.failed_today', fmtNum(j['failedToday']), tone: Tone.bad),
          Kpi('kpi.drafts_pending', fmtNum(j['draftsPending']), tone: Tone.warn),
          Kpi('kpi.llm', at(j, 'llm.ok') == true ? 'OK' : 'Down', tone: at(j, 'llm.ok') == true ? Tone.good : Tone.bad),
        ]),
  ],
  list: ListSpec(
    path: '/api/flow-agents/agents',
    row: (r) => RecordRow(
      id: '${r['id']}',
      ref: s(r['templateId']),
      title: s(r['name']) ?? '–',
      subtitle: s(r['role']),
      status: s(r['status']),
      date: d(r['lastRunAt']),
    ),
  ),
  facts: (r) => [
    ('fact.role', s(r['role'])),
    ('fact.line', s(r['line'])),
    ('fact.runs', s(r['runCount'])),
    ('fact.last_run', fmtDate(r['lastRunAt'])),
    ('fact.next_run', fmtDate(r['nextRunAt'])),
    ('fact.on_call', r['onCall'] == true ? '✓' : null),
  ],
);

// ── Notifications ───────────────────────────────────────────────────────────

final notificationsSpec = ModuleSpec(
  moduleId: 'notifications',
  summaries: [
    SummarySpec('/api/notifications', query: const {'limit': '1'}, (j) => [
          Kpi('kpi.unread', fmtNum(j['unreadCount']), tone: Tone.info),
          Kpi('kpi.total', fmtNum(j['total'])),
        ]),
  ],
  list: ListSpec(
    path: '/api/notifications',
    pageQuery: _offset,
    items: (body) => rowsOf({'data': dataOf(body)['notifications']}),
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['title']) ?? '–',
      subtitle: s(r['message']),
      status: r['isRead'] == true ? null : 'unread',
      date: d(r['createdAt']),
    ),
  ),
  facts: (r) => [
    ('fact.message', s(r['message'])),
    ('fact.category', s(r['category'])),
    ('fact.when', _join([fmtDate(r['createdAt']), _time(r['createdAt'])])),
  ],
  actions: (r) => [
    if (r['isRead'] != true)
      RecordAction(
        label: 'act.mark_read',
        icon: LucideIcons.check,
        primary: true,
        run: (api, rec, _) => api.post('/api/notifications/mark-read/${rec['id']}'),
      ),
  ],
);

final opsSpecs = <String, ModuleSpec>{
  for (final spec in [
    facilityOpsSpec,
    bookingsSpec,
    visitorsSpec,
    serviceSchedulesSpec,
    rfqsSpec,
    purchaseOrdersSpec,
    amcSpec,
    digitalTwinSpec,
    timelineSpec,
    handoverSpec,
    constructionProgressSpec,
    reportsSpec,
    intelligenceSpec,
    carbonSpec,
    askFlowAiSpec,
    flowAgentsSpec,
    notificationsSpec,
  ])
    spec.moduleId: spec,
};

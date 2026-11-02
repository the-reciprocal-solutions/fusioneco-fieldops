import 'floor_plan_screen.dart';
import 'module_spec.dart';
import 'utility_screens.dart';

/// Phase 3b — Building Performance (FE-mobile.md). Endpoints checked against
/// the live server 2026-10-30. Floor Plan: floor_plan_screen.dart (2026-11-01).

/// Utility module id → its Dashboard tab switch, as the web reads it
/// (`permissions?.isDg_Dashboard` in DGMscPage). HVAC types have none.
const _dashboardTab = <String, String>{
  'energy': 'isEnergy_Dashboard',
  'dg': 'isDg_Dashboard',
  'ups': 'isUps_Dashboard',
  'solar_panel': 'isSolarPanel_Dashboard',
  'water_meter': 'isWaterMeter_Dashboard',
  'tank_level': 'isTankLevel_Dashboard',
  'pump': 'isPump_Dashboard',
  'feel_temperature': 'isFeelTemperature_Dashboard',
  'co2': 'isCo2_Dashboard',
  'fire': 'isFire_Dashboard',
  'intrusion': 'isIntrusion_Dashboard',
  'cctv': 'isCctv_Dashboard',
  'lift': 'isLift_Dashboard',
  'it_rack': 'isItRack_Dashboard',
};

/// Utilities whose web page has a Trends tab, and its switch (the MSC pages:
/// DGMscPage `permissions?.isDg_Trends`, …). Solar, Intrusion, CCTV and IT
/// rack have none there. HVAC pages always have Trends.
const _trendsTab = <String, String>{
  'energy': 'isEnergy_Trends',
  'dg': 'isDg_Trends',
  'ups': 'isUps_Trends',
  'water_meter': 'isWaterMeter_Trends',
  'tank_level': 'isTankLevel_Trends',
  'pump': 'isPump_Trends',
  'feel_temperature': 'isFeelTemperature_Trends',
  'co2': 'isCo2_Trends',
  'fire': 'isFire_Trends',
  'lift': 'isLift_Trends',
};

final _utilitySpecs = [
  for (final e in utilityTags.entries)
    ModuleSpec(
      moduleId: e.key,
      screen: (m) => UtilityScreen(
        module: m,
        tag: e.value,
        dashboardTab: _dashboardTab[e.key],
        trendsTab: _trendsTab[e.key],
        alwaysTrends: e.key.startsWith('hvac_'),
      ),
    ),
  ModuleSpec(moduleId: 'facility_utilities', screen: (m) => UtilitiesOverviewScreen(module: m)),
  ModuleSpec(moduleId: 'utility_explorer', screen: (m) => UtilityExplorerScreen(module: m)),
  ModuleSpec(moduleId: 'floor_plan', screen: (m) => FloorPlanScreen(module: m)),
];

// ── Energy (telemetry): Building Energy + Energy Analytics ──────────────────

final _energyStatus = SummarySpec('/api/fm/energy/status', (j) {
  final lagging = (j['lagging'] as List?)?.length ?? 0;
  return [
    Kpi('kpi.meters', fmtNum(j['meterCount'])),
    Kpi('kpi.meters_active', fmtNum(j['activeMeterCount']), tone: Tone.good),
    Kpi('kpi.meters_lagging', fmtNum(lagging), tone: lagging > 0 ? Tone.warn : Tone.neutral),
    Kpi('kpi.last_reading', fmtDate(j['lastTickAt']) ?? '–'),
  ];
});

/// One building's last 7 days (`/fm/energy/summary`, the web's default range).
final _energyBuildings = ListSpec(
  path: '/api/fm/energy/buildings',
  detailPath: (id) => '/api/fm/energy/summary?buildingId=$id',
  row: (r) => RecordRow(
    id: '${r['buildingId']}',
    title: s(r['name']) ?? '–',
    // Meter counts are in the detail facts (no words here: rows have no locale).
    subtitle: n(r['area']) == null ? null : '${fmtNum(r['area'])} m²',
    status: s(r['status']),
  ),
);

List<(String, String?)> _energyFacts(Json r) => [
      ('fact.energy_7d', r['kwh'] == null ? null : '${fmtNum(r['kwh'])} kWh'),
      ('fact.change', r['changePct'] == null ? null : '${fmtNum(r['changePct'], decimals: 1)}%'),
      ('fact.peak_demand', r['peakDemandKw'] == null ? null : '${fmtNum(r['peakDemandKw'])} kW'),
      ('fact.eui', r['euiKwhPerM2'] == null ? null : '${fmtNum(r['euiKwhPerM2'], decimals: 2)} kWh/m²'),
      ('fact.completeness', _ratioPct(r['completeness'])),
      ('fact.meters', s(r['meterCount'])),
      ('fact.main_meters', s(r['mainMeterCount'])),
      // The status is the header badge (a raw code here read as `no_main_meter`).
    ];

/// Completeness arrives as 0–1; shown as a percentage.
String? _ratioPct(Object? v) {
  final x = n(v);
  if (x == null) return null;
  return fmtPct(x <= 1 ? x * 100 : x);
}

final buildingEnergySpec = ModuleSpec(moduleId: 'building_energy', summaries: [_energyStatus], list: _energyBuildings, facts: _energyFacts);
final energyAnalyticsSpec = ModuleSpec(moduleId: 'energy_analytics', summaries: [_energyStatus], list: _energyBuildings, facts: _energyFacts);

// ── Access Control ──────────────────────────────────────────────────────────

final accessControlSpec = ModuleSpec(
  moduleId: 'access_control',
  summaries: [
    SummarySpec('/api/fm/access-control/overview', (j) => [
          Kpi('kpi.doors_online', '${fmtNum(at(j, 'doors.online'))} / ${fmtNum(at(j, 'doors.total'))}', tone: Tone.good),
          Kpi('kpi.doors_offline', fmtNum(at(j, 'doors.offline')), tone: Tone.bad),
          Kpi('kpi.alarms_open', fmtNum(at(j, 'alarms.open')), tone: Tone.warn),
          Kpi('kpi.alarms_critical', fmtNum(at(j, 'alarms.critical')), tone: Tone.bad),
          Kpi('kpi.denied_24h', fmtNum(at(j, 'events24h.denied'))),
          Kpi('kpi.on_site', fmtNum(j['onSite']), tone: Tone.info),
        ]),
  ],
  // The open door alarms, newest first (alarmsController: limit + offset).
  list: ListSpec(
    path: '/api/fm/access-control/alarms',
    query: const {'status': 'open'},
    pageQuery: (page, size) => {'limit': '$size', 'offset': '${(page - 1) * size}'},
    row: (r) => RecordRow(
      id: '${r['id']}',
      title: s(r['title']) ?? '–',
      subtitle: [s(r['doorName']), if ((n(r['count']) ?? 1) > 1) '×${fmtNum(r['count'])}'].whereType<String>().join(' · '),
      status: s(r['status']),
      priority: s(r['severity']),
      date: d(r['lastAt']),
    ),
  ),
  facts: (r) => [
    ('fact.door', s(r['doorName'])),
    ('fact.kind', s(r['kind'])),
    ('fact.cardholder', s(r['cardholderName'])),
    ('fact.repeats', s(r['count'])),
    ('fact.first_seen', fmtDate(r['firstAt'])),
    ('fact.last_seen', fmtDate(r['lastAt'])),
    ('fact.building', s(r['buildingName'])),
  ],
);

// ── Occupancy Intelligence ──────────────────────────────────────────────────

/// The last 24 h, ending now (the web's default window).
Map<String, dynamic> _last24h() {
  final now = DateTime.now().toUtc();
  return {
    'from': now.subtract(const Duration(days: 1)).toIso8601String(),
    'to': now.toIso8601String(),
    'cursor': now.toIso8601String(),
  };
}

final occupancySpec = ModuleSpec(
  moduleId: 'occupancy',
  summaries: [
    SummarySpec('/api/timeline/occupancy/rollup', liveQuery: _last24h, (j) => [
          Kpi('kpi.occupancy_now', '${fmtNum(j['cursorOccupancy'])} / ${fmtNum(j['capacity'])}', tone: Tone.info),
          Kpi('kpi.peak_24h', fmtNum(at(j, 'peak.value')), tone: Tone.warn),
          Kpi('kpi.footfall_24h', fmtNum(j['footfallTotal'])),
          Kpi('kpi.footfall_change', j['footfallVsPrevPct'] == null ? '–' : '${fmtNum(j['footfallVsPrevPct'], decimals: 1)}%'),
        ]),
  ],
  // Floors from the same rollup (one more ~65 KB call; the floors list sits in `data.floors`).
  list: ListSpec(
    path: '/api/timeline/occupancy/rollup',
    liveQuery: _last24h,
    items: (body) => rowsOf({'data': dataOf(body)['floors']}),
    row: (r) => RecordRow(
      id: '${r['level'] ?? r['storey']}',
      title: s(r['storey']) ?? '–',
      subtitle: '${fmtNum(r['occupancy'])} / ${fmtNum(r['capacity'])}',
      status: (n(r['breachedRooms']) ?? 0) > 0 ? 'over capacity' : null,
      priority: fmtPct(r['pct']),
    ),
  ),
  facts: (r) => [
    ('fact.occupancy', '${fmtNum(r['occupancy'])} / ${fmtNum(r['capacity'])}'),
    ('fact.load', fmtPct(r['pct'])),
    ('fact.rooms', s(r['rooms'])),
    ('fact.busy_rooms', s(r['highRooms'])),
    ('fact.over_capacity_rooms', s(r['breachedRooms'])),
  ],
);

final performanceSpecs = <String, ModuleSpec>{
  for (final spec in [..._utilitySpecs, buildingEnergySpec, energyAnalyticsSpec, accessControlSpec, occupancySpec]) spec.moduleId: spec,
};

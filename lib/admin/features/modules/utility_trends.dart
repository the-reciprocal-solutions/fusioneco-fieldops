import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import 'module_spec.dart';
import 'module_summary_screen.dart' show KpiTile;
import 'utility_screens.dart';
import '../../../theme/app_font.dart';

/// The utility pages' **Trends** tab on the phone (web: MscTrends →
/// TrendStudio): one device, one point, a time window, a line of the
/// bucket averages with the window's low / average / high / latest.
///
///   GET /api/proxy/bacnet/api/timeseries/readings
///       `?point=Device/Point`&res=15m|1h&from=…&to=…&order=asc&limit&offset
///   → {readings: [{time, avg, min, max, last, value}], paging: {has_more}}
///
/// On/off points come back with `last` true/false → 1 / 0, as the web does.

/// A window the phone offers: label key, length, bucket.
typedef TrendWindow = ({String key, Duration span, String res});

const trendWindows = <TrendWindow>[
  (key: 'trend.6h', span: Duration(hours: 6), res: '15m'),
  (key: 'trend.24h', span: Duration(hours: 24), res: '1h'),
  (key: 'trend.7d', span: Duration(days: 7), res: '1h'),
  (key: 'trend.30d', span: Duration(days: 30), res: '1h'),
];

/// One bucket.
typedef TrendSample = ({DateTime t, double v});

double? _sampleValue(Map row) {
  double? asNum(Object? x) => x is num ? x.toDouble() : x is bool ? (x ? 1 : 0) : null;
  return asNum(row['avg']) ?? asNum(row['value']) ?? asNum(row['last']);
}

/// The readings of [point] in [from]…[to], all pages (capped at [cap] rows).
Future<List<TrendSample>> loadTrend(ApiClient api, String point, String res, DateTime from, DateTime to, {int cap = 1000}) async {
  final out = <TrendSample>[];
  for (var offset = 0; out.length < cap;) {
    final body = await api.get('/api/proxy/bacnet/api/timeseries/readings', query: {
      'point': point,
      'res': res,
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      'order': 'asc',
      'limit': '${cap - out.length}',
      'offset': '$offset',
    });
    final page = body is Map && body['readings'] is List ? (body['readings'] as List).whereType<Map>().toList() : const <Map>[];
    for (final r in page) {
      if (r['object_name'] != null && r['object_name'] != point) continue;
      final t = DateTime.tryParse('${r['time']}');
      final v = _sampleValue(r);
      if (t != null && v != null && v.isFinite) out.add((t: t.toLocal(), v: v));
    }
    final more = body is Map && body['paging'] is Map && body['paging']['has_more'] == true;
    if (!more || page.isEmpty) break;
    offset += page.length;
  }
  return out;
}

/// Points worth charting: numbers first, then on/off, by readable name.
List<String> chartablePoints(MscDevice d) {
  final names = [for (final e in d.raw.entries) if (e.value is num || e.value is bool) e.key];
  names.sort((a, b) {
    final ab = d.raw[a] is bool ? 1 : 0;
    final bb = d.raw[b] is bool ? 1 : 0;
    return ab != bb ? ab - bb : d.labelOf(a).compareTo(d.labelOf(b));
  });
  return names;
}

class UtilityTrendsView extends ConsumerStatefulWidget {
  const UtilityTrendsView({super.key, required this.devices});
  final List<MscDevice> devices;

  @override
  ConsumerState<UtilityTrendsView> createState() => _UtilityTrendsViewState();
}

class _UtilityTrendsViewState extends ConsumerState<UtilityTrendsView> {
  String? _deviceId;
  String? _point;
  TrendWindow _window = trendWindows[1];
  List<TrendSample>? _samples;
  Object? _error;
  bool _loading = false;
  int _req = 0;

  MscDevice? get _device =>
      widget.devices.where((d) => d.id == _deviceId).firstOrNull ?? widget.devices.where((d) => chartablePoints(d).isNotEmpty).firstOrNull ?? widget.devices.firstOrNull;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final d = _device;
    final points = d == null ? const <String>[] : chartablePoints(d);
    final point = points.contains(_point) ? _point : points.firstOrNull;
    if (d == null || point == null) {
      setState(() => (_samples = const [], _point = null));
      return;
    }
    final req = ++_req;
    setState(() => (_loading = true, _point = point, _error = null));
    final to = DateTime.now();
    try {
      final rows = await loadTrend(ref.read(apiClientProvider), point, _window.res, to.subtract(_window.span), to);
      if (mounted && req == _req) setState(() => _samples = rows);
    } catch (e) {
      if (mounted && req == _req) setState(() => (_error = e, _samples = null));
    } finally {
      if (mounted && req == _req) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _device;
    if (d == null) return const SizedBox.shrink();
    final points = chartablePoints(d);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: d.id,
          isExpanded: true,
          decoration: InputDecoration(labelText: 'trend.device'.getString(context)),
          items: [for (final x in widget.devices) DropdownMenuItem(value: x.id, child: AppText(x.name, maxLines: 1, overflow: TextOverflow.ellipsis))],
          onChanged: (v) {
            setState(() => (_deviceId = v, _point = null));
            _load();
          },
        ),
        const SizedBox(height: 12),
        if (points.isEmpty)
          TechEmptyState(icon: LucideIcons.chartLine, title: 'trend.no_points'.getString(context))
        else ...[
          DropdownButtonFormField<String>(
            key: ValueKey('point-${d.id}'),
            initialValue: points.contains(_point) ? _point : points.first,
            isExpanded: true,
            decoration: InputDecoration(labelText: 'trend.reading'.getString(context)),
            items: [for (final p in points) DropdownMenuItem(value: p, child: AppText(d.labelOf(p), maxLines: 1, overflow: TextOverflow.ellipsis))],
            onChanged: (v) {
              setState(() => _point = v);
              _load();
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<TrendWindow>(
            segments: [for (final w in trendWindows) ButtonSegment(value: w, label: AppText(w.key.getString(context)))],
            selected: {_window},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              setState(() => _window = s.first);
              _load();
            },
          ),
          const SizedBox(height: 16),
          if (_loading && _samples == null)
            const Padding(padding: EdgeInsets.all(32), child: TechSpinner())
          else if (_error != null)
            TechEmptyState(
              icon: LucideIcons.circleAlert,
              title: 'module.load_error'.getString(context),
              subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null,
            )
          else if ((_samples ?? const []).isEmpty)
            TechEmptyState(icon: LucideIcons.chartLine, title: 'trend.no_data'.getString(context), subtitle: 'trend.no_data_hint'.getString(context))
          else ...[
            _Stats(samples: _samples!),
            const SizedBox(height: 12),
            SizedBox(height: 220, child: _Chart(samples: _samples!, span: _window.span, binary: d.raw[_point] is bool)),
          ],
        ],
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.samples});
  final List<TrendSample> samples;

  @override
  Widget build(BuildContext context) {
    final vs = samples.map((x) => x.v).toList();
    final lo = vs.reduce((a, b) => a < b ? a : b);
    final hi = vs.reduce((a, b) => a > b ? a : b);
    final avg = vs.reduce((a, b) => a + b) / vs.length;
    String f(double v) => fmtNum(v, decimals: v.abs() < 10 ? 2 : 1);
    return LayoutBuilder(
      builder: (context, c) {
        // Two a row: four cut "Average" mid-word on a phone.
        final w = (c.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (k, v) in [('trend.low', lo), ('trend.avg', avg), ('trend.high', hi), ('trend.latest', vs.last)])
              SizedBox(width: w, child: KpiTile(Kpi(k, f(v)))),
          ],
        );
      },
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.samples, required this.span, required this.binary});
  final List<TrendSample> samples;
  final Duration span;
  final bool binary;

  @override
  Widget build(BuildContext context) {
    final t0 = samples.first.t.millisecondsSinceEpoch.toDouble();
    final spots = [for (final x in samples) FlSpot((x.t.millisecondsSinceEpoch - t0) / 3600e3, x.v)];
    final hours = spots.last.x;
    String two(int i) => i.toString().padLeft(2, '0');
    String label(double h) {
      final t = samples.first.t.add(Duration(minutes: (h * 60).round()));
      return span.inHours <= 24 ? '${two(t.hour)}:${two(t.minute)}' : '${t.day}/${t.month}';
    }

    // A flat line (a setpoint) gets room above and below, or fl_chart draws
    // it on the bottom edge over the time labels (seen on the phone).
    final lo = spots.map((p) => p.y).reduce((a, b) => a < b ? a : b);
    final hi = spots.map((p) => p.y).reduce((a, b) => a > b ? a : b);
    final pad = hi - lo < 1e-9 ? (lo.abs() * 0.05).clamp(1.0, double.infinity) : null;
    return LineChart(
      LineChartData(
        minY: binary ? -0.05 : (pad == null ? null : lo - pad),
        maxY: binary ? 1.05 : (pad == null ? null : hi + pad),
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (items) => [
              for (final i in items) LineTooltipItem('${label(i.x)}\n${fmtNum(i.y, decimals: 2)}', const TextStyle(fontFamily: kAppFont, color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, meta) => v == meta.max || v == meta.min ? const SizedBox.shrink() : AppText.caption(fmtNum(v, decimals: 1)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: hours > 0 ? hours / 3 : 1,
              getTitlesWidget: (v, meta) => v == meta.max ? const SizedBox.shrink() : AppText.caption(label(v)),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isStepLineChart: binary,
            color: FeColors.primary,
            barWidth: 2,
            dotData: FlDotData(show: spots.length < 30),
            belowBarData: BarAreaData(show: true, color: FeColors.primary.withValues(alpha: 0.08)),
          ),
        ],
      ),
    );
  }
}

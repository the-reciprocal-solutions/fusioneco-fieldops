import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../domain/maintenance_record.dart';
import '../../domain/technician_insights.dart';
import '../../state/overview_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/common.dart';
import '../../theme/app_font.dart';

/// Analytics for the signed-in technician: tabs per maintenance type,
/// year-to-date and in-progress stat cards, and 12-month volume bar chart.
class OverviewScreen extends ConsumerStatefulWidget {
  const OverviewScreen({super.key});

  @override
  ConsumerState<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends ConsumerState<OverviewScreen> {
  OrderType _tab = OrderType.workOrder;

  /// The chart fill gradient colors per tab.
  static const _chartGradients = {
    OrderType.workOrder: [Color(0xFF60A5FA), Color(0xFF2563EB)],
    OrderType.reactive: [Color(0xFFF87171), Color(0xFFDC2626)],
    OrderType.preventive: [Color(0xFF4ADE80), Color(0xFF16A34A)],
    OrderType.annual: [Color(0xFFFBBF24), Color(0xFFD97706)],
  };

  static String _totalLabel(BuildContext context, OrderType type) =>
      switch (type) {
        OrderType.workOrder =>
          'overview.total_work_orders'.getString(context),
        OrderType.preventive =>
          'overview.total_preventive_tasks'.getString(context),
        OrderType.reactive =>
          'overview.total_reactive_requests'.getString(context),
        OrderType.annual =>
          'overview.total_annual_contracts'.getString(context),
      };

  static String _tabLabel(BuildContext context, OrderType type) =>
      switch (type) {
        OrderType.workOrder => 'overview.tab_work_order'.getString(context),
        OrderType.reactive => 'overview.tab_reactive'.getString(context),
        OrderType.preventive => 'overview.tab_preventive'.getString(context),
        OrderType.annual => 'overview.tab_annual'.getString(context),
      };

  static String _trendLabel(BuildContext context, OrderType type) =>
      switch (type) {
        OrderType.workOrder => 'overview.trend_work_order'.getString(context),
        OrderType.reactive => 'overview.trend_reactive'.getString(context),
        OrderType.preventive =>
          'overview.trend_preventive'.getString(context),
        OrderType.annual => 'overview.trend_annual'.getString(context),
      };

  @override
  Widget build(BuildContext context) {
    final insights = ref.watch(technicianInsightsProvider);
    final unseenCount =
        ref.watch(unseenNotificationCountProvider).valueOrNull ?? 0;
    final gradient = _chartGradients[_tab]!;

    return Scaffold(
      backgroundColor: FeColors.page,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async => ref.invalidate(technicianInsightsProvider),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Top Header with title, subtitle, and circular action buttons
              _TopBar(
                unseenNotifications: unseenCount,
                onCalendar: () => context.push(Routes.calendar),
                onNotifications: () => context.push(Routes.notifications),
              ),
              const SizedBox(height: 16),

              // Filter Tabs (Work Order, Reactive, Preventive, Annual)
              _TypeTabs(
                selected: _tab,
                onSelect: (type) => setState(() => _tab = type),
                label: _tabLabel,
              ),
              const SizedBox(height: 16),

              if (insights.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: TechSpinner(),
                )
              else if (insights.hasError)
                TechEmptyState(
                  icon: LucideIcons.circleAlert,
                  title: 'overview.load_error_title'.getString(context),
                  subtitle: 'common.pull_to_retry'.getString(context),
                )
              else ...[
                // Side-by-side 2 Metric Stat Cards with soft tint gradients
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        title: _totalLabel(context, _tab),
                        value: insights.requireValue.totalsFor(_tab).total,
                        caption: 'overview.stat_this_year'.getString(context),
                        icon: LucideIcons.trendingUp,
                        iconColor: const Color(0xFF10B981),
                        iconBackground: const Color(0xFFDCFCE7),
                        tintColor: const Color(0xFFDCFCE7),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        title: 'overview.stat_work_in_progress'.getString(
                          context,
                        ),
                        value: insights.requireValue.inProgressFor(_tab),
                        caption: 'overview.stat_this_month'.getString(context),
                        icon: LucideIcons.activity,
                        iconColor: const Color(0xFF0284C7),
                        iconBackground: const Color(0xFFDBEAFE),
                        tintColor: const Color(0xFFE0F2FE),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Trends Chart Card
                _TrendCard(
                  title: _trendLabel(context, _tab),
                  trends: insights.requireValue.monthlyTrends,
                  type: _tab,
                  gradient: gradient,
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header with Analytics Overview title, subtitle, and circular action buttons
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.unseenNotifications,
    required this.onCalendar,
    required this.onNotifications,
  });

  final int unseenNotifications;
  final VoidCallback onCalendar;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'overview.title'.getString(context),
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: FeColors.ink,
                  letterSpacing: context.letterSpacingFor(-0.5),
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'overview.subtitle'.getString(context),
                style: const TextStyle(
                  fontSize: 13.5,
                  color: FeColors.ink2,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _CircleActionButton(
          icon: LucideIcons.calendarDays,
          tooltip: 'common.calendar'.getString(context),
          onTap: onCalendar,
        ),
        const SizedBox(width: 8),
        _CircleActionButton(
          icon: LucideIcons.bell,
          tooltip: 'common.notifications'.getString(context),
          badge: unseenNotifications,
          onTap: onNotifications,
        ),
      ],
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: FeColors.panel,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, size: 19, color: FeColors.ink),
        ),
      ),
    );

    if (badge <= 0) return button;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        PositionedDirectional(
          top: -2,
          end: -2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16),
            decoration: BoxDecoration(
              color: FeColors.danger,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: FeColors.panel, width: 1.5),
            ),
            child: Text(
              badge > 9 ? '9+' : '$badge',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 9,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The four maintenance types laid out as a single rounded pill bar
class _TypeTabs extends StatelessWidget {
  const _TypeTabs({
    required this.selected,
    required this.onSelect,
    required this.label,
  });

  final OrderType selected;
  final ValueChanged<OrderType> onSelect;
  final String Function(BuildContext, OrderType) label;

  static const _order = [
    OrderType.workOrder,
    OrderType.reactive,
    OrderType.preventive,
    OrderType.annual,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          for (final type in _order)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(type),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: type == selected
                        ? const Color(0xFF0284C7)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: type == selected
                        ? [
                            BoxShadow(
                              color: const Color(0xFF0284C7)
                                  .withValues(alpha: 0.25),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    label(context, type),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: type == selected
                          ? Colors.white
                          : const Color(0xFF64748B),
                      fontWeight: type == selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Stat card matching the screenshot's soft gradient tint
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.tintColor,
  });

  final String title;
  final int value;
  final String caption;
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final Color tintColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            Colors.white,
            tintColor,
          ],
          stops: const [0.0, 0.72, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 44,
            width: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: iconBackground,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, color: iconColor),
          ),
          const SizedBox(height: 12),
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: FeColors.ink,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF475569),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF94A3B8),
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// Trend Card containing header, filter dropdown button, chart, and bottom pill
class _TrendCard extends StatelessWidget {
  const _TrendCard({
    required this.title,
    required this.trends,
    required this.type,
    required this.gradient,
  });

  final String title;
  final List<MonthlyTrend> trends;
  final OrderType type;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: FeColors.ink,
                  letterSpacing: context.letterSpacingFor(-0.2),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'overview.chart_period_monthly'.getString(context),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF475569),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      LucideIcons.chevronDown,
                      size: 14,
                      color: Color(0xFF475569),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 240,
            child: trends.isEmpty
                ? Center(
                    child: Text(
                      'overview.chart_no_activity'.getString(context),
                      style: const TextStyle(
                        color: FeColors.ink2,
                        fontSize: 13,
                      ),
                    ),
                  )
                : _TrendChart(trends: trends, type: type, gradient: gradient),
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFF1F5F9)),
              ),
              child: Text(
                context.formatString(
                  'overview.chart_volume_caption'.getString(context),
                  [DateTime.now().year],
                ),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF64748B),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({
    required this.trends,
    required this.type,
    required this.gradient,
  });

  final List<MonthlyTrend> trends;
  final OrderType type;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) {
    final counts = [for (final t in trends) t.countFor(type)];
    final peak = counts.fold<int>(0, (a, b) => a > b ? a : b);
    final rawMaxY = (peak == 0 ? 4 : peak * 1.2).toDouble();
    // Round to nearest multiple of 5 for clean Y-axis gridlines
    final maxY = ((rawMaxY / 5).ceil() * 5).toDouble().clamp(10.0, 1000.0);

    return BarChart(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 5,
          getDrawingHorizontalLine: (_) => const FlLine(
            color: Color(0xFFE2E8F0),
            strokeWidth: 1,
            dashArray: [4, 4],
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: 5,
              getTitlesWidget: (value, meta) {
                if (value % 5 != 0) return const SizedBox.shrink();
                return Text(
                  '${value.toInt()}',
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= trends.length) {
                  return const SizedBox.shrink();
                }
                final month = trends[index].month;
                final shortMonth =
                    month.length > 3 ? month.substring(0, 3) : month;
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    shortMonth,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => FeColors.panel,
            tooltipBorder: const BorderSide(color: Color(0xFFE2E8F0)),
            tooltipPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                BarTooltipItem(
                  '${trends[groupIndex].month}\n',
                  const TextStyle(
                    fontFamily: kAppFont,
                    color: FeColors.ink2,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  children: [
                    TextSpan(
                      text: '${rod.toY.toInt()}',
                      style: TextStyle(
                        color: gradient.last,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < trends.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: counts[i].toDouble(),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: gradient,
                  ),
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(7),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

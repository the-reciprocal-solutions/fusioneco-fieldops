import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/router.dart';
import '../../../core/utils/notification_route.dart';
import '../../../domain/day_brief.dart';
import '../../../domain/maintenance_record.dart';
import '../../../state/auth_controller.dart';
import '../../../state/day_brief_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/tech_popup.dart';
import '../../order_detail/order_chat_sheet.dart';
import 'process_guides_sheet.dart';

/// The home screen's "Your day" card (docs/day-brief.md): an AI summary when
/// one passed the server's guards, the day's jobs as an ordered checklist,
/// "Before you go" per job, a "Request the permit first" tip, "Start next
/// job", and the "How do I…?" guides one tap away.
///
/// Never blocks the dashboard: while the server brief loads, or with no
/// signal, it shows the phone's own plan from the jobs it has cached
/// (`DayPlanner`). Ticks are real job status only; the model never sets one.
class DayBriefCard extends ConsumerWidget {
  const DayBriefCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dayBriefControllerProvider);
    final canAskAi = ref.watch(authControllerProvider.select((a) => a.permissions.isAiAgent));
    return DayBriefView(
      state: state,
      onRefresh: () => ref.read(dayBriefControllerProvider.notifier).refresh(),
      onOpenRoute: (route) => openDayRoute(context, route),
      onOpenGuides: () => showProcessGuidesSheet(
        context,
        nextJobId: _nextWorkOrderId(state),
        onAskAi: canAskAi ? (question) => _askAi(context, state, question) : null,
      ),
    );
  }

  static String? _nextWorkOrderId(DayBriefState state) =>
      state.steps.where((s) => !s.done && (s.kind == 'wo' || s.kind == 'pm' || s.kind == 'rm')).firstOrNull?.id;

  static void _askAi(BuildContext context, DayBriefState state, String question) {
    final id = _nextWorkOrderId(state);
    if (id == null) {
      showTechPopup(context, message: 'day.guide.ask_ai_needs_job'.getString(context));
      return;
    }
    showOrderChatSheet(context, orderKey: (type: OrderType.workOrder, id: id), initialQuestion: question);
  }
}

/// A server or local step route (`/technician/...` or an app path) → a screen.
/// The five bottom-nav branches are switched to with `go`, never pushed
/// (router.dart: `!keyReservation.contains(key)`).
void openDayRoute(BuildContext context, String route) {
  final mapped = appRouteForWebLink(route) ?? route;
  if (!isKnownAppRoute(mapped)) return;
  final path = Uri.tryParse(mapped)?.path ?? mapped;
  if (Routes.isShellBranch(path)) {
    context.go(mapped);
  } else {
    context.push(mapped);
  }
}

/// The card itself, driven only by [state] — so every state can be pumped in
/// a widget test without providers or a network.
class DayBriefView extends StatefulWidget {
  const DayBriefView({
    super.key,
    required this.state,
    required this.onRefresh,
    required this.onOpenRoute,
    required this.onOpenGuides,
    this.now,
    this.tick = true,
  });

  final DayBriefState state;
  final Future<void> Function() onRefresh;
  final void Function(String route) onOpenRoute;
  final VoidCallback onOpenGuides;

  /// Fixed clock for tests; null = the real time.
  final DateTime? now;

  /// Re-render "Updated N min ago" every minute (off in tests).
  final bool tick;

  @override
  State<DayBriefView> createState() => _DayBriefViewState();
}

class _DayBriefViewState extends State<DayBriefView> {
  static const _collapsedCount = 5;
  final _expanded = <String>{};
  bool _showAll = false;
  bool _refreshing = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (widget.tick) _ticker = Timer.periodic(const Duration(minutes: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  DateTime get _now => widget.now ?? DateTime.now();

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _tr(String key, [List<Object> args = const []]) =>
      args.isEmpty ? key.getString(context) : context.formatString(key.getString(context), args);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final loading = s.phase == DayBriefPhase.loading && s.brief == null;
    final ai = s.showAiSummary;
    final steps = s.steps;
    final visible = _showAll ? steps : steps.take(_collapsedCount).toList();
    final next = s.next;
    final tip = next == null ? null : _tipFor(next);

    return Container(
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ai ? FeColors.aiLine : FeColors.line),
        boxShadow: [BoxShadow(color: FeColors.ink.withValues(alpha: 0.06), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(ai, loading),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                if (loading) const _Shimmer(key: Key('day-brief-shimmer')) else _summary(ai),
                if (s.phase == DayBriefPhase.offline || s.phase == DayBriefPhase.error) ...[
                  const SizedBox(height: 8),
                  _notice(s),
                ],
                if (tip != null) ...[const SizedBox(height: 10), tip],
                const SizedBox(height: 8),
                if (steps.isEmpty && !loading)
                  _empty()
                else
                  for (final step in visible) _stepRow(step),
                if (steps.length > _collapsedCount)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => setState(() => _showAll = !_showAll),
                      child: Text(_showAll ? _tr('day.show_less') : _tr('day.show_all', [steps.length])),
                    ),
                  ),
                if (next != null && next.route != null) ...[
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    key: const Key('day-start-next'),
                    onPressed: () => widget.onOpenRoute(next.route!),
                    icon: const Icon(LucideIcons.play, size: 16),
                    label: Text(_tr('day.start_next')),
                    style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  ),
                ],
                const SizedBox(height: 6),
                _guidesRow(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(bool ai, bool loading) {
    final s = widget.state;
    final updated = _updatedLabel();
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: ai ? FeColors.aiSoft : FeColors.infoSoft, borderRadius: BorderRadius.circular(10)),
          child: Icon(ai ? LucideIcons.sparkles : LucideIcons.listChecks, size: 18, color: ai ? FeColors.ai : FeColors.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.titleMedium(_tr('day.title'), weight: FontWeight.w800),
              if (updated != null) AppText.caption(updated, color: FeColors.ink2, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        IconButton(
          key: const Key('day-refresh'),
          tooltip: _tr('day.refresh'),
          onPressed: (_refreshing || (s.phase == DayBriefPhase.loading && !loading)) ? null : _refresh,
          icon: (_refreshing || s.phase == DayBriefPhase.loading)
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(LucideIcons.refreshCw, size: 18, color: FeColors.ink2),
        ),
      ],
    );
  }

  String? _updatedLabel() {
    final s = widget.state;
    if (s.phase == DayBriefPhase.loading && s.brief == null) return _tr('day.loading');
    if (s.phase == DayBriefPhase.offline) {
      return s.savedAt == null ? null : _tr('day.saved_earlier', [DateFormat('HH:mm').format(s.savedAt!.toLocal())]);
    }
    final at = s.brief?.generatedAt;
    if (at == null || s.phase == DayBriefPhase.error) return null;
    final mins = _now.difference(at).inMinutes;
    if (mins < 1) return _tr('day.updated_now');
    if (mins < 60) return _tr('day.updated_min', [mins]);
    return _tr('day.updated_hours', [mins ~/ 60]);
  }

  Widget _summary(bool ai) {
    final s = widget.state;
    if (ai) {
      return Container(
        key: const Key('day-ai-summary'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: FeColors.aiSoft,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: FeColors.aiLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(LucideIcons.sparkles, size: 13, color: FeColors.ai),
              const SizedBox(width: 6),
              Flexible(child: AppText.label(_tr('day.ai_label'), color: FeColors.ai, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 6),
            _TypeIn(text: s.brief!.summary, animate: widget.tick),
          ],
        ),
      );
    }
    return AppText.bodyMedium(localSummary(context, s.steps), key: const Key('day-rules-summary'), color: FeColors.ink);
  }

  Widget _notice(DayBriefState s) {
    final offline = s.phase == DayBriefPhase.offline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(offline ? LucideIcons.wifiOff : LucideIcons.circleAlert, size: 14, color: offline ? FeColors.ink2 : FeColors.warning),
        const SizedBox(width: 6),
        Expanded(child: AppText.caption(_tr(offline ? 'day.offline_plan' : 'day.error_plan'), color: FeColors.ink2)),
      ],
    );
  }

  Widget? _tipFor(DayStep next) {
    final p = next.permit;
    if (p == null || !next.permitBlocked) return null;
    final job = next.ref ?? next.title;
    final typeLabel = _permitTypeLabel(p);
    final text = switch (p.state) {
      'suggested' => _tr('day.tip.permit_suggested', [job, typeLabel]),
      'suspended' => _tr('day.tip.permit_suspended', [p.permitNo ?? '', job]),
      _ => _tr('day.tip.permit_not_live', [p.permitNo ?? '', job]),
    };
    final isOrder = next.kind == 'wo' || next.kind == 'pm' || next.kind == 'rm';
    final String? target = p.permitId != null ? Routes.permitDetail(p.permitId!) : (isOrder ? Routes.orderConversation(next.id) : null);
    return Container(
      key: const Key('day-permit-tip'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: FeColors.warningSoft, borderRadius: BorderRadius.circular(14), border: Border.all(color: FeColors.warning.withValues(alpha: 0.4))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(LucideIcons.shieldAlert, size: 16, color: FeColors.warning),
            const SizedBox(width: 6),
            Expanded(child: AppText.label(_tr('day.tip.permit_title'), weight: FontWeight.w800)),
          ]),
          const SizedBox(height: 4),
          AppText.bodySmall(text, color: FeColors.ink),
          if (p.nextAction != null && p.state != 'suggested') AppText.caption(_tr('day.item.permit_next', [p.nextAction!]), color: FeColors.ink2),
          if (target != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () => widget.onOpenRoute(target),
                icon: Icon(p.permitId != null ? LucideIcons.shieldCheck : LucideIcons.messageSquare, size: 16),
                label: Text(_tr(p.permitId != null ? 'day.tip.open_permit' : 'day.tip.message_office')),
              ),
            ),
        ],
      ),
    );
  }

  String _permitTypeLabel(DayPermit p) {
    final key = 'permits.type.${p.type}';
    final local = p.type == null ? key : key.getString(context);
    return local == key ? (p.typeLabel ?? '') : local;
  }

  Widget _empty() => Padding(
        key: const Key('day-empty'),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          const Icon(LucideIcons.coffee, size: 20, color: FeColors.ink2),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppText.label(_tr('day.empty_title'), weight: FontWeight.w700),
              AppText.caption(_tr('day.empty_sub'), color: FeColors.ink2),
            ]),
          ),
        ]),
      );

  Widget _stepRow(DayStep step) {
    final open = _expanded.contains(step.id);
    final items = step.items;
    final reason = stepReason(context, step);
    return Column(
      key: Key('day-step-${step.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: step.route == null ? null : () => widget.onOpenRoute(step.route!),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Check(step: step),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            step.ref == null ? step.title : '${step.ref} · ${step.title}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: step.done ? FeColors.ink2 : FeColors.ink,
                              decoration: step.done ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          ..._chips(step),
                        ],
                      ),
                      if (reason.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (step.reasonSource == TextSource.ai)
                              const Padding(
                                padding: EdgeInsetsDirectional.only(top: 2, end: 4),
                                child: Icon(LucideIcons.sparkles, size: 11, color: FeColors.ai),
                              ),
                            Expanded(child: AppText.caption(reason, color: FeColors.ink2)),
                          ],
                        ),
                      ],
                      if (step.location != null && step.location!.isNotEmpty)
                        Row(children: [
                          const Icon(LucideIcons.mapPin, size: 11, color: FeColors.ink2),
                          const SizedBox(width: 3),
                          Expanded(child: AppText.caption(step.location!, color: FeColors.ink2, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ]),
                    ],
                  ),
                ),
                if (items.isNotEmpty && !step.done)
                  IconButton(
                    key: Key('day-expand-${step.id}'),
                    visualDensity: VisualDensity.compact,
                    tooltip: _tr('day.before_you_go'),
                    onPressed: () => setState(() => open ? _expanded.remove(step.id) : _expanded.add(step.id)),
                    icon: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: FeColors.ink2),
                  ),
              ],
            ),
          ),
        ),
        if (open && items.isNotEmpty)
          Container(
            margin: const EdgeInsetsDirectional.only(start: 36, bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: FeColors.page, borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.label(_tr('day.before_you_go'), weight: FontWeight.w800),
                const SizedBox(height: 4),
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(it.source == TextSource.ai ? LucideIcons.sparkles : LucideIcons.dot, size: 13, color: it.source == TextSource.ai ? FeColors.ai : FeColors.ink2),
                        const SizedBox(width: 6),
                        Expanded(child: AppText.bodySmall(itemText(context, it), color: FeColors.ink)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1, color: FeColors.line),
      ],
    );
  }

  List<Widget> _chips(DayStep s) {
    Widget chip(String key, Color fg, Color bg) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
          child: Text(_tr(key), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
        );
    if (s.done) return const [];
    return [
      if (s.kind == 'invite') chip('day.chip_invite', FeColors.primary, FeColors.infoSoft),
      if (s.kind == 'inspection') chip('day.chip_inspection', FeColors.primary, FeColors.infoSoft),
      if (s.kind == 'snag') chip('day.chip_snag', FeColors.primary, FeColors.infoSoft),
      if (s.kind == 'pm') chip('day.chip_pm', FeColors.primary, FeColors.infoSoft),
      if (s.safety) chip('day.chip_safety', FeColors.danger, FeColors.dangerSoft),
      if (s.overdue && !s.safety) chip('day.chip_overdue', FeColors.danger, FeColors.dangerSoft),
      if (s.permitBlocked) chip('day.chip_permit', FeColors.warning, FeColors.warningSoft),
    ];
  }

  Widget _guidesRow() => InkWell(
        key: const Key('day-guides'),
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onOpenGuides,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            const Icon(LucideIcons.lifeBuoy, size: 18, color: FeColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppText.label(_tr('day.guides_title'), weight: FontWeight.w800),
                AppText.caption(_tr('day.guides_sub'), color: FeColors.ink2),
              ]),
            ),
            const Icon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
          ]),
        ),
      );
}

class _Check extends StatelessWidget {
  const _Check({required this.step});
  final DayStep step;

  @override
  Widget build(BuildContext context) {
    if (step.done) {
      return const CircleAvatar(radius: 13, backgroundColor: FeColors.success, child: Icon(LucideIcons.check, size: 15, color: Colors.white));
    }
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: step.safety ? FeColors.danger : FeColors.line, width: 2)),
      child: Text('${step.order}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: FeColors.ink2)),
    );
  }
}

/// Soft loading lines while the first brief is on its way.
class _Shimmer extends StatefulWidget {
  const _Shimmer({super.key});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          Widget bar(double widthFactor) => FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: widthFactor,
                child: Container(
                  height: 11,
                  margin: const EdgeInsets.only(bottom: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    gradient: LinearGradient(
                      begin: Alignment(-1 + 2 * _c.value - 1, 0),
                      end: Alignment(-1 + 2 * _c.value + 1, 0),
                      colors: const [FeColors.aiSoft, FeColors.aiLine, FeColors.aiSoft],
                    ),
                  ),
                ),
              );
          return Column(children: [bar(1), bar(0.92), bar(0.6)]);
        },
      );
}

/// The AI summary types itself in once, quickly — the "it was just written"
/// cue. Off in tests (and for long texts it finishes in under a second).
class _TypeIn extends StatefulWidget {
  const _TypeIn({required this.text, required this.animate});
  final String text;
  final bool animate;

  @override
  State<_TypeIn> createState() => _TypeInState();
}

class _TypeInState extends State<_TypeIn> {
  int _shown = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _TypeIn old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _start();
  }

  void _start() {
    _t?.cancel();
    if (!widget.animate) {
      _shown = widget.text.length;
      return;
    }
    _shown = 0;
    final step = (widget.text.length / 40).ceil().clamp(1, 1 << 20);
    _t = Timer.periodic(const Duration(milliseconds: 18), (t) {
      if (!mounted) return t.cancel();
      setState(() => _shown = (_shown + step).clamp(0, widget.text.length));
      if (_shown >= widget.text.length) t.cancel();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        widget.text.substring(0, _shown.clamp(0, widget.text.length)),
        style: const TextStyle(fontSize: 14, height: 1.4, color: FeColors.ink),
      );
}

// ── text, in the phone's language ────────────────────────────────────────────

String _f(BuildContext c, String key, [List<Object> args = const []]) =>
    args.isEmpty ? key.getString(c) : c.formatString(key.getString(c), args);

String _time(DateTime d) => DateFormat('HH:mm').format(d.toLocal());

String _when(DateTime d, DateTime now) {
  final l = d.toLocal();
  return (l.year == now.year && l.month == now.month && l.day == now.day) ? _time(l) : DateFormat('d MMM HH:mm').format(l);
}

/// The rules summary, built on the phone from the steps (both languages), so
/// it is right offline and in Arabic. The model's summary is shown as is.
String localSummary(BuildContext c, List<DayStep> steps) {
  final counts = DayCounts.of(steps);
  final parts = <String>[];
  if (counts.open == 0) {
    parts.add(counts.doneToday > 0 ? _f(c, 'day.summary.none_done', [counts.doneToday]) : _f(c, 'day.summary.none'));
  } else {
    parts.add(counts.open == 1 ? _f(c, 'day.summary.jobs_one') : _f(c, 'day.summary.jobs', [counts.open]));
    if (counts.overdue > 0) parts.add(_f(c, 'day.summary.overdue', [counts.overdue]));
    if (counts.permitsNeeded > 0) parts.add(_f(c, 'day.summary.permits', [counts.permitsNeeded]));
    final first = steps.where((s) => !s.done && s.isJob).firstOrNull;
    if (first != null) parts.add(_f(c, 'day.summary.start', [first.ref ?? first.title]));
  }
  if (counts.invites > 0) parts.add(_f(c, 'day.summary.invites', [counts.invites]));
  return parts.join(' ');
}

/// A step's reason: the model's line as is, else the rules line from its code.
String stepReason(BuildContext c, DayStep s, {DateTime? now}) {
  if (s.reasonSource == TextSource.ai && s.reason.isNotEmpty) return s.reason;
  final p = s.reasonParams;
  final n = now ?? DateTime.now();
  final base = switch (s.reasonCode) {
    'safety' => _f(c, 'day.reason.safety'),
    'permit_expiring' => _f(c, 'day.reason.permit_expiring', [
        p['permitNo'] ?? s.permit?.permitNo ?? '',
        s.permit?.validUntil != null ? _time(s.permit!.validUntil!) : (p['time'] ?? ''),
      ]),
    'sla_breached' => _f(c, 'day.reason.sla_breached'),
    'sla_risk' => (p['time'] ?? '').isNotEmpty
        ? _f(c, 'day.reason.sla_risk', [p['time']!])
        : (s.due != null ? _f(c, 'day.reason.sla_risk', [_when(s.due!, n)]) : _f(c, 'day.reason.sla_risk_plain')),
    'overdue' => s.due != null ? _f(c, 'day.reason.overdue', [_when(s.due!, n)]) : '',
    'in_progress' => _f(c, 'day.reason.in_progress'),
    'on_hold' => _f(c, 'day.reason.on_hold'),
    'invite' => _f(c, 'day.reason.invite'),
    'done' => _f(c, 'day.reason.done'),
    _ => (s.due != null && _time(s.due!) != '00:00') ? _f(c, 'day.reason.due_today', [_time(s.due!)]) : _f(c, 'day.reason.due_today_plain'),
  };
  return s.samePlaceAsPrevious ? '$base ${_f(c, 'day.reason.same_place')}' : base;
}

/// A "before you go" item: the model's text as is, else the rules item from its code.
String itemText(BuildContext c, DayItem it) {
  if (it.source == TextSource.ai) return it.text;
  final p = it.params;
  String typeLabel() {
    final key = 'permits.type.${p['type'] ?? ''}';
    final local = key.getString(c);
    return local == key || (p['type'] ?? '').isEmpty ? (p['typeLabel'] ?? '') : local;
  }

  final text = switch (it.code) {
    'permit_live' => _f(c, 'day.item.permit_live', [p['permitNo'] ?? '']),
    'permit_expiring' => _f(c, 'day.item.permit_expiring', [p['permitNo'] ?? '', p['time'] ?? '']),
    'permit_not_live' => [
        _f(c, 'day.item.permit_not_live', [p['permitNo'] ?? '']),
        if ((p['nextAction'] ?? '').isNotEmpty) _f(c, 'day.item.permit_next', [p['nextAction']!]),
      ].join(' '),
    'permit_suspended' => _f(c, 'day.item.permit_suspended', [p['permitNo'] ?? '']),
    'permit_suggested' => _f(c, 'day.item.permit_suggested', [typeLabel()]),
    'parts_reserved' => _f(c, 'day.item.parts_reserved', [p['parts'] ?? '']),
    'parts_listed' => _f(c, 'day.item.parts_listed', [p['parts'] ?? '']),
    'checklist' => _f(c, 'day.item.checklist', [p['done'] ?? '0', p['total'] ?? '0']),
    'face_capture' => _f(c, 'day.item.face_capture'),
    'location' => _f(c, 'day.item.location'),
    'signature' => _f(c, 'day.item.signature'),
    'access' => _f(c, 'day.item.access', [p['note'] ?? '']),
    _ => it.text,
  };
  return text.isEmpty ? it.text : text;
}

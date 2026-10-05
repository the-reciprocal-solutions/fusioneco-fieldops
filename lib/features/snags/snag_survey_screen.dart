import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/snag/snag_rules.dart';
import '../../core/snag/snag_send_state.dart';
import '../../domain/snag.dart';
import '../../state/snag_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/progress_ring.dart';
import 'widgets/snag_card.dart';
import 'widgets/snag_visuals.dart';

/// UC-9 — one survey round: how much of the building was actually walked,
/// what was found, and where. Coverage is the number that makes a takeover
/// survey credible: "12 snags" means little until you know it came from 40
/// of 42 rooms rather than 8.
class SnagSurveyScreen extends ConsumerWidget {
  const SnagSurveyScreen({super.key, required this.surveyId});
  final String surveyId;

  Future<void> _complete(BuildContext context, WidgetRef ref, SnagSurvey survey) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('snags.complete_survey'.getString(context)),
        content: Text('snags.complete_survey_hint'.getString(context)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('common.cancel'.getString(context))),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text('snags.confirm'.getString(context))),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(snagRepositoryProvider).completeSurvey(survey);
    bumpSnags(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingSnagIdsProvider).valueOrNull ?? const <String>{};
    final flushing = ref.watch(snagQueueFlushingProvider);
    final survey = ref.watch(snagSurveyProvider(surveyId)).valueOrNull;
    if (survey == null) {
      return Scaffold(
        appBar: FeHeader(title: 'snags.surveys'.getString(context)),
        body: ref.watch(snagSurveyProvider(surveyId)).isLoading
            ? const TechSpinner()
            : Padding(
                padding: const EdgeInsets.all(16),
                child: TechEmptyState(icon: LucideIcons.searchX, title: 'snags.not_found'.getString(context)),
              ),
      );
    }
    final buildingId = survey.buildingId;
    final tree = buildingId == null ? null : ref.watch(snagTreeProvider(buildingId)).valueOrNull;
    final snags = (ref.watch(snagsProvider(buildingId)).valueOrNull ?? const <Snag>[])
        .where((s) => s.surveyId == survey.id)
        .toList();
    final readiness = SnagReadinessCalculator.compute(
      snags: snags,
      spacesInScope: tree?.spaceCount,
      spacesInspected: survey.inspectedSpaces.length,
    );
    final coverage = tree == null ? const <FloorCoverage>[] : floorCoverage(tree, survey);
    final live = snags.where((s) => s.status.isLive).toList();
    final byPriority = {for (final p in SnagPriority.values) p: live.where((s) => s.priority == p).length};
    final byTrade = <String, int>{};
    for (final s in live) {
      byTrade[s.trade] = (byTrade[s.trade] ?? 0) + 1;
    }
    final trades = byTrade.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: survey.name),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          Row(
            children: [
              TechChip(
                label: SnagVisuals.contextLabel(context, survey.context),
                style: SnagVisuals.chip(FeColors.dashboardAccent),
                uppercase: false,
              ),
              const SizedBox(width: 6),
              TechChip(
                label: (survey.completed ? 'snags.survey_completed' : 'snags.survey_active').getString(context),
                style: SnagVisuals.chip(survey.completed ? FeColors.success : FeColors.primary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.caption(
                  '${survey.startedByName ?? ''} · ${DateFormat.MMMd().format(survey.startedAt)}',
                  color: FeColors.ink2,
                  align: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TechCard(
            dark: true,
            child: Row(
              children: [
                ProgressRing(
                  value: readiness.score,
                  size: 104,
                  strokeWidth: 11,
                  colors: const [FeColors.primaryLight, FeColors.success],
                  child: Text(
                    readiness.score == null ? '—' : '${(readiness.score! * 100).round()}%',
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final d in readiness.dimensions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'snags.dim.${d.key}'.getString(context),
                                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ),
                              Text(
                                d.measured ? d.detail : 'snags.not_measured'.getString(context),
                                style: TextStyle(
                                  color: d.measured ? Colors.white : Colors.white38,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (coverage.isNotEmpty) ...[
            const SizedBox(height: 18),
            AppText.titleMedium('snags.coverage_by_floor'.getString(context), weight: FontWeight.w800),
            const SizedBox(height: 10),
            TechCard(
              // ExpansionTile paints ink on the nearest Material; TechCard is a
              // DecoratedBox, which would hide it (and asserts in debug).
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    for (final c in coverage) _FloorRow(coverage: c, survey: survey),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          AppText.titleMedium('snags.open_by_severity'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 10),
          TechCard(
            child: Column(
              children: [
                for (final p in SnagPriority.values)
                  _Bar(
                    label: SnagVisuals.priorityLabel(context, p),
                    value: byPriority[p]!,
                    max: live.isEmpty ? 1 : live.length,
                    color: SnagVisuals.priorityColor(p),
                  ),
              ],
            ),
          ),
          if (trades.isNotEmpty) ...[
            const SizedBox(height: 18),
            AppText.titleMedium('snags.open_by_trade'.getString(context), weight: FontWeight.w800),
            const SizedBox(height: 10),
            TechCard(
              child: Column(
                children: [
                  for (final t in trades.take(8))
                    _Bar(
                      label: SnagVisuals.tradeLabel(context, t.key),
                      icon: SnagVisuals.tradeIcon(t.key),
                      value: t.value,
                      max: trades.first.value,
                      color: FeColors.primary,
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          AppText.titleMedium(snagTr(context, 'snags.survey_snags', [snags.length]), weight: FontWeight.w800),
          const SizedBox(height: 10),
          if (snags.isEmpty)
            TechEmptyState(icon: LucideIcons.camera, title: 'snags.survey_no_snags'.getString(context))
          else
            for (final s in SnagQueues.sortForList(snags))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SnagCard(
                  snag: s,
                  pending: pending.contains(s.id),
                  send: snagSendStatus(s, queued: pending.contains(s.id), flushing: flushing),
                  onTap: () => context.push(Routes.snagDetail(s.id)),
                ),
              ),
        ],
      ),
      bottomNavigationBar: survey.completed
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                        onPressed: () => _complete(context, ref, survey),
                        child: Text('snags.complete_survey'.getString(context)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                        onPressed: () => context.push(Routes.snagWalk(survey.id)),
                        icon: const Icon(LucideIcons.camera, size: 18),
                        label: Text('snags.continue_walk'.getString(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _FloorRow extends StatelessWidget {
  const _FloorRow({required this.coverage, required this.survey});
  final FloorCoverage coverage;
  final SnagSurvey survey;

  @override
  Widget build(BuildContext context) {
    final c = coverage;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Row(
          children: [
            SizedBox(width: 90, child: AppText.bodyMedium(c.floor.name, weight: FontWeight.w700, maxLines: 1)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: c.ratio,
                  minHeight: 8,
                  backgroundColor: FeColors.line,
                  color: c.ratio >= 1 ? FeColors.success : FeColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            AppText.caption('${c.inspected}/${c.total}', weight: FontWeight.w800),
          ],
        ),
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in c.floor.spaces)
                Builder(
                  builder: (context) {
                    final sweep = survey.sweepFor(s.id);
                    final color = sweep == null
                        ? FeColors.ink2
                        : (sweep.clear ? FeColors.success : FeColors.warning);
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: sweep == null ? 0.06 : 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: color.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        sweep == null || sweep.clear ? s.name : '${s.name} · ${sweep.snagCount}',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.value, required this.max, required this.color, this.icon});
  final String label;
  final int value;
  final int max;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: FeColors.ink2), const SizedBox(width: 6)],
          SizedBox(width: 96, child: AppText.bodySmall(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Align(
                alignment: AlignmentDirectional.centerStart,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOut,
                  height: 12,
                  width: max == 0 ? 0 : box.maxWidth * (value / max).clamp(0.0, 1.0),
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 28, child: AppText.caption('$value', align: TextAlign.end, weight: FontWeight.w800)),
        ],
      ),
    );
  }
}

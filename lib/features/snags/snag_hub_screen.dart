import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/snag/snag_rules.dart';
import '../../core/snag/snag_send_state.dart';
import '../../domain/snag.dart';
import '../../state/snag_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/motion.dart';
import '../../widgets/progress_ring.dart';
import '../../widgets/tech_popup.dart';
import 'widgets/snag_card.dart';
import 'widgets/snag_sheets.dart';
import 'widgets/snag_visuals.dart';

enum _ListFilter { live, ready, closed, all }

/// The Snag Assistant's home (UC-8, UC-9). Top to bottom it answers: which
/// building, how close to done is it, what should I do now, and what is on
/// the list. Everything renders from the local store, so it opens instantly
/// in a basement; a pull (or opening it online) merges the server in.
class SnagHubScreen extends ConsumerStatefulWidget {
  const SnagHubScreen({super.key});

  @override
  ConsumerState<SnagHubScreen> createState() => _SnagHubScreenState();
}

class _SnagHubScreenState extends ConsumerState<SnagHubScreen> {
  SnagContext? _context;
  _ListFilter _filter = _ListFilter.live;
  String? _syncedFor;

  void _syncIfNeeded(String buildingId) {
    if (_syncedFor == buildingId) return;
    _syncedFor = buildingId;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(snagSyncProvider.notifier).refresh(buildingId),
    );
  }

  Future<void> _pickBuilding(List<SnagBuilding> buildings) async {
    final picked = await showModalBottomSheet<SnagBuilding>(
      context: context,
      showDragHandle: true,
      backgroundColor: FeColors.panel,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final b in buildings)
              ListTile(
                leading: const Icon(LucideIcons.building2, color: FeColors.primary),
                title: AppText.bodyMedium(b.name, weight: FontWeight.w700),
                subtitle: b.location == null ? null : AppText.bodySmall(b.location!),
                onTap: () => Navigator.of(context).pop(b),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await ref.read(snagBuildingIdProvider.notifier).select(picked.id);
  }

  Future<void> _startWalk(SnagBuilding building) async {
    final setup = await showStartSurveySheet(context, buildingName: building.name);
    final actor = ref.read(snagActorProvider);
    if (setup == null || actor == null || !mounted) return;
    final survey = await ref.read(snagRepositoryProvider).startSurvey(
      name: setup.name,
      context: setup.context,
      building: building,
      actor: actor,
    );
    if (!mounted) return;
    bumpSnags(ref);
    context.push(Routes.snagWalk(survey.id));
  }

  Future<void> _downloadOffline(String buildingId) async {
    showTechPopup(context, message: 'snags.downloading'.getString(context));
    final repo = ref.read(snagRepositoryProvider);
    try {
      await ref.read(snagTreeProvider(buildingId).future);
    } catch (_) {}
    final n = await repo.prefetchMedia(buildingId: buildingId);
    if (mounted) showTechPopup(context, message: snagTr(context, 'snags.downloaded_n', [n]));
  }

  @override
  Widget build(BuildContext context) {
    final buildingsAsync = ref.watch(snagBuildingsProvider);
    final buildings = buildingsAsync.valueOrNull ?? const <SnagBuilding>[];
    var buildingId = ref.watch(snagBuildingIdProvider);
    if (buildingId == null && buildings.isNotEmpty) {
      buildingId = buildings.first.id;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(snagBuildingIdProvider.notifier).select(buildings.first.id),
      );
    }
    SnagBuilding? building;
    for (final b in buildings) {
      if (b.id == buildingId) building = b;
    }
    if (buildingId != null) _syncIfNeeded(buildingId);

    final me = ref.watch(snagActorProvider)?.id ?? '';
    final all = ref.watch(snagsProvider(buildingId)).valueOrNull ?? const <Snag>[];
    final scoped = _context == null ? all : all.where((s) => s.context == _context).toList();
    final pending = ref.watch(pendingSnagIdsProvider).valueOrNull ?? const <String>{};
    final surveys = ref.watch(snagSurveysProvider(buildingId)).valueOrNull ?? const <SnagSurvey>[];
    final tree = buildingId == null ? null : ref.watch(snagTreeProvider(buildingId)).valueOrNull;
    final sync = ref.watch(snagSyncProvider);
    final flushing = ref.watch(snagQueueFlushingProvider);

    final activeSurvey = surveys.where((s) => !s.completed && (_context == null || s.context == _context)).firstOrNull;
    final readiness = SnagReadinessCalculator.compute(
      snags: scoped,
      spacesInScope: activeSurvey == null ? null : tree?.spaceCount,
      spacesInspected: activeSurvey?.inspectedSpaces.length,
    );
    final waiting = SnagQueues.waitingOn(me, scoped);
    final toVerify = SnagQueues.toVerify(me, scoped.where((s) => !s.localOnly)).length;
    final listed = SnagQueues.sortForList(scoped.where((s) => switch (_filter) {
      _ListFilter.live => s.status == SnagStatus.open || s.status == SnagStatus.inProgress,
      _ListFilter.ready => s.status == SnagStatus.ready,
      _ListFilter.closed => s.status == SnagStatus.closed || s.status == SnagStatus.waived,
      _ListFilter.all => true,
    }));

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: 'snags.title'.getString(context),
        actions: [
          if (buildingId != null)
            IconButton(
              tooltip: 'snags.download_offline'.getString(context),
              icon: const Icon(LucideIcons.cloudDownload),
              onPressed: () => _downloadOffline(buildingId!),
            ),
          IconButton(
            tooltip: 'snags.sync'.getString(context),
            icon: sync.syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.refreshCw),
            onPressed: buildingId == null ? null : () => ref.read(snagSyncProvider.notifier).refresh(buildingId!),
          ),
        ],
      ),
      body: buildingsAsync.isLoading && buildings.isEmpty
          ? const TechSpinner()
          : buildings.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: TechEmptyState(
                icon: LucideIcons.building2,
                title: 'snags.no_buildings'.getString(context),
                subtitle: 'common.pull_to_retry'.getString(context),
              ),
            )
          : RefreshIndicator(
              onRefresh: () => ref.read(snagSyncProvider.notifier).refresh(buildingId!),
              // Slivers (2026-10-06): the header scrolls with the list, but
              // snag cards are built lazily as they scroll in. The old
              // ListView(children:) built every card — photo lookup, decode
              // and entrance animation — for the whole building up front.
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverList.list(
                children: [
                  _BuildingBar(
                    name: building?.name ?? '—',
                    onTap: () => _pickBuilding(buildings),
                    online: sync.online,
                  ),
                  const SizedBox(height: 10),
                  _ContextFilter(value: _context, onChanged: (c) => setState(() => _context = c)),
                  const SizedBox(height: 14),
                  _ReadinessHero(
                    readiness: readiness,
                    takeover: (_context ?? activeSurvey?.context) == SnagContext.fmTakeover,
                    open: scoped.where((s) => s.status == SnagStatus.open || s.status == SnagStatus.inProgress).length,
                    ready: scoped.where((s) => s.status == SnagStatus.ready).length,
                    closed: scoped.where((s) => s.status == SnagStatus.closed).length,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: _WalkCard(onTap: building == null ? null : () => _startWalk(building!)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            _MiniAction(
                              icon: LucideIcons.badgeCheck,
                              label: 'snags.verify'.getString(context),
                              count: toVerify,
                              color: FeColors.success,
                              onTap: () => context.push(Routes.snagVerify(buildingId!)),
                            ),
                            const SizedBox(height: 10),
                            _MiniAction(
                              icon: LucideIcons.camera,
                              label: 'snags.quick_snag'.getString(context),
                              color: FeColors.primary,
                              onTap: () => context.push(Routes.snagNew(buildingId: buildingId)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (waiting.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SectionTitle(title: 'snags.waiting_on_you'.getString(context), count: waiting.length),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 184,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: waiting.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, i) => _WaitingCard(
                          item: waiting[i],
                          onTap: () => context.push(Routes.snagDetail(waiting[i].snag.id)),
                        ),
                      ),
                    ),
                  ],
                  if (surveys.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SectionTitle(title: 'snags.surveys'.getString(context), count: surveys.length),
                    const SizedBox(height: 10),
                    for (final s in surveys.take(3))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SurveyTile(
                          survey: s,
                          total: tree?.spaceCount ?? 0,
                          snagCount: all.where((x) => x.surveyId == s.id).length,
                          onTap: () => context.push(Routes.snagSurvey(s.id)),
                        ),
                      ),
                  ],
                  const SizedBox(height: 20),
                  _SectionTitle(title: 'snags.list'.getString(context), count: listed.length),
                  const SizedBox(height: 10),
                  SegmentedButton<_ListFilter>(
                    segments: [
                      for (final f in _ListFilter.values)
                        ButtonSegment(value: f, label: Text('snags.filter.${f.name}'.getString(context))),
                    ],
                    selected: {_filter},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => setState(() => _filter = v.first),
                  ),
                  const SizedBox(height: 12),
                ],
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    sliver: listed.isEmpty
                        ? SliverToBoxAdapter(
                            child: TechEmptyState(
                              icon: LucideIcons.sparkles,
                              iconColor: FeColors.success,
                              title: 'snags.list_empty'.getString(context),
                            ),
                          )
                        : SliverList.builder(
                            itemCount: listed.length,
                            itemBuilder: (context, i) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: StaggeredEntrance(
                                index: i,
                                child: SnagCard(
                                  snag: listed[i],
                                  pending: pending.contains(listed[i].id),
                                  send: snagSendStatus(
                                    listed[i],
                                    queued: pending.contains(listed[i].id),
                                    flushing: flushing,
                                  ),
                                  onTap: () => context.push(Routes.snagDetail(listed[i].id)),
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _BuildingBar extends StatelessWidget {
  const _BuildingBar({required this.name, required this.onTap, required this.online});
  final String name;
  final VoidCallback onTap;
  final bool? online;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TechCard(
            onTap: onTap,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            radius: 16,
            child: Row(
              children: [
                const Icon(LucideIcons.building2, size: 18, color: FeColors.primary),
                const SizedBox(width: 8),
                Expanded(child: AppText.titleSmall(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const Icon(LucideIcons.chevronsUpDown, size: 16, color: FeColors.ink2),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: online == false ? 'snags.offline_local'.getString(context) : 'snags.online'.getString(context),
          child: IconBadge(
            icon: online == false ? LucideIcons.cloudOff : LucideIcons.cloud,
            style: online == false ? context.accents.amber : context.accents.emerald,
            size: 40,
          ),
        ),
      ],
    );
  }
}

class _ContextFilter extends StatelessWidget {
  const _ContextFilter({required this.value, required this.onChanged});
  final SnagContext? value;
  final ValueChanged<SnagContext?> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(SnagContext? c) {
      final selected = c == value;
      return ChoiceChip(
        selected: selected,
        onSelected: (_) => onChanged(c),
        showCheckmark: false,
        avatar: c == null
            ? null
            : Icon(SnagVisuals.contextIcon(c), size: 15, color: selected ? Colors.white : FeColors.ink2),
        label: Text(c == null ? 'snags.context_all'.getString(context) : SnagVisuals.contextLabel(context, c)),
        selectedColor: FeColors.ink,
        backgroundColor: FeColors.panel,
        labelStyle: TextStyle(color: selected ? Colors.white : FeColors.ink, fontWeight: FontWeight.w700),
        side: const BorderSide(color: FeColors.line),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip(null),
          for (final c in SnagContext.values) ...[const SizedBox(width: 8), chip(c)],
        ],
      ),
    );
  }
}

/// The headline card: one ring, one number, and the four dimensions behind
/// it — with "not measured yet" shown as such rather than as zero.
class _ReadinessHero extends StatelessWidget {
  const _ReadinessHero({
    required this.readiness,
    required this.takeover,
    required this.open,
    required this.ready,
    required this.closed,
  });

  final SnagReadiness readiness;
  final bool takeover;
  final int open;
  final int ready;
  final int closed;

  @override
  Widget build(BuildContext context) {
    final score = readiness.score;
    return TechCard(
      dark: true,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ProgressRing(
                value: score,
                size: 96,
                strokeWidth: 10,
                colors: const [FeColors.primaryLight, FeColors.success],
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      score == null ? '—' : '${(score * 100).round()}%',
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (takeover ? 'snags.takeover_readiness' : 'snags.readiness').getString(context),
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _HeroStat(label: 'snags.status.open'.getString(context), value: open, color: FeColors.primaryLight),
                        _HeroStat(label: 'snags.status.ready'.getString(context), value: ready, color: FeColors.warning),
                        _HeroStat(label: 'snags.status.closed'.getString(context), value: closed, color: FeColors.success),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final d in readiness.dimensions)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: d.score ?? 0,
                          minHeight: 5,
                          backgroundColor: Colors.white12,
                          color: d.measured ? FeColors.primaryLight : Colors.white24,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'snags.dim.${d.key}'.getString(context),
                        style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        d.measured ? d.detail : 'snags.not_measured'.getString(context),
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
            ].expand((w) => [w, const SizedBox(width: 10)]).toList()..removeLast(),
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
      ],
    ),
  );
}

/// The big, obvious "go snag" button — gradient, camera-first, like the
/// dashboard's Scan QR card.
class _WalkCard extends StatelessWidget {
  const _WalkCard({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            // A floor, not a fixed height: a long translation or a large
            // system font grows the card instead of overflowing it.
            constraints: const BoxConstraints(minHeight: 150),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [FeColors.primaryLight, FeColors.primary],
              ),
              boxShadow: FeElevation.tinted(FeColors.primary),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                  child: const Icon(LucideIcons.scanEye, color: Colors.white, size: 22),
                ),
                const SizedBox(height: 18),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'snags.start_walk'.getString(context),
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'snags.start_walk_sub'.getString(context),
                  maxLines: 2,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.icon, required this.label, required this.color, required this.onTap, this.count});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return TechCard(
      onTap: onTap,
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: AppText.label(label, weight: FontWeight.w800, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (count != null && count! > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
              child: Text('$count', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(
        child: AppText.titleMedium(title, weight: FontWeight.w800, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(999)),
        child: AppText.caption('$count', weight: FontWeight.w800),
      ),
    ],
  );
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({required this.item, required this.onTap});
  final WaitingItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (item.reason) {
      WaitingReason.verify => ('snags.waiting.verify'.getString(context), FeColors.success, LucideIcons.badgeCheck),
      WaitingReason.fix => ('snags.waiting.fix'.getString(context), FeColors.primary, LucideIcons.hammer),
      WaitingReason.overdue => ('snags.waiting.overdue'.getString(context), FeColors.danger, LucideIcons.alarmClock),
    };
    return SizedBox(
      width: 150,
      child: TechCard(
        onTap: onTap,
        padding: EdgeInsets.zero,
        radius: 18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                SnagPhoto(evidence: item.snag.coverPhoto, height: 84),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 11, color: Colors.white),
                        const SizedBox(width: 3),
                        Text(label, style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.bodySmall(item.snag.title, maxLines: 2, overflow: TextOverflow.ellipsis, weight: FontWeight.w700, color: FeColors.ink),
                  AppText.caption(item.snag.displayRef, color: FeColors.ink2),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SurveyTile extends StatelessWidget {
  const _SurveyTile({required this.survey, required this.total, required this.snagCount, required this.onTap});
  final SnagSurvey survey;
  final int total;
  final int snagCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final swept = survey.inspectedSpaces.length;
    final ratio = total == 0 ? 0.0 : (swept / total).clamp(0.0, 1.0);
    return TechCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          IconBadge(
            icon: SnagVisuals.contextIcon(survey.context),
            style: survey.completed ? context.accents.emerald : context.accents.blue,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.titleSmall(survey.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    backgroundColor: FeColors.line,
                    color: survey.completed ? FeColors.success : FeColors.primary,
                  ),
                ),
                const SizedBox(height: 4),
                AppText.caption(
                  snagTr(context, 'snags.survey_line', [swept, total, snagCount]),
                  color: FeColors.ink2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(LucideIcons.chevronRight, color: FeColors.ink2, size: 18),
        ],
      ),
    );
  }
}

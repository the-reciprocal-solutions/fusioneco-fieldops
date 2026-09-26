import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_view_models.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/tech_popup.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import 'ar_drill_panel.dart';
import 'ar_element_card.dart';

/// What the action card (iPad) or sheet (phone) shows for the current mode.
/// The mode decides what a tap does (§2.9): Locate identifies and targets,
/// Verify pre-fills the field verification, Progress marks installed /
/// verified with four-eyes, Snags raises and opens snags, Forms opens the
/// job's paperwork.
class ArModePanel extends ConsumerWidget {
  const ArModePanel({super.key, required this.tablet, required this.onBackToSetup});

  final bool tablet;
  final VoidCallback onBackToSetup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(arWorkspaceProvider.select((w) => w.mode));
    final drilling = ref.watch(arWorkspaceProvider.select((w) => w.drilling));
    final s = ref.watch(arSessionProvider);
    // Drill check owns the card while it's on; it says "align first" itself.
    if (drilling) return ArDrillPanel(tablet: tablet, onBackToSetup: onBackToSetup);
    if (!s.isPlaced) {
      return _NotPlaced(onPlace: onBackToSetup);
    }
    final panel = AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: KeyedSubtree(
        key: ValueKey(mode),
        child: switch (mode) {
          ArMode.locate => _LocatePanel(tablet: tablet),
          ArMode.verify => _VerifyPanel(tablet: tablet),
          ArMode.progress => _ProgressPanel(tablet: tablet),
          ArMode.snags => _SnagsPanel(tablet: tablet),
          ArMode.forms => const _FormsPanel(),
        },
      ),
    );
    if (!ArWorkspaceController.roughPlacement(s)) return panel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RoughPlacementHint(onImprove: onBackToSetup),
        const SizedBox(height: 10),
        panel,
      ],
    );
  }
}

/// Every corner so far was placed by tapping the floor: no wall face was
/// detected, so the heading is a guess from the plan. Say so on every card,
/// with the fix, until a real corner or a board refines it. Tapping it goes
/// back to setup keeping what was measured.
class _RoughPlacementHint extends StatelessWidget {
  const _RoughPlacementHint({required this.onImprove});
  final VoidCallback onImprove;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onImprove,
        child: ArHintRow(text: 'ar.work.rough_placement'.getString(context), icon: ArIcons.warning),
      ),
    );
  }
}

/// Pauses the AR engine while another screen is on top, and resumes it on
/// return: the camera and tracking shouldn't run behind a form.
Future<void> arPushFromSession(BuildContext context, WidgetRef ref, String route) async {
  final session = ref.read(arSessionProvider.notifier);
  await session.pause();
  if (!context.mounted) return;
  await context.push(route);
  await session.resume();
}

class _NotPlaced extends StatelessWidget {
  const _NotPlaced({required this.onPlace});
  final VoidCallback onPlace;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText.titleMedium('ar.work.not_placed'.getString(context), weight: FontWeight.w800),
        const SizedBox(height: 4),
        AppText.bodyMedium('ar.work.not_placed_body'.getString(context), color: FeColors.ink2),
        const SizedBox(height: 12),
        ArPrimaryButton(label: 'ar.work.place_now'.getString(context), icon: ArIcons.realign, onPressed: onPlace),
      ],
    );
  }
}

// ----------------------------------------------------------------- locate

class _LocatePanel extends ConsumerWidget {
  const _LocatePanel({required this.tablet});
  final bool tablet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arSessionProvider);
    final ws = ref.watch(arWorkspaceProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final picked = ws.primary;
    final target = s.target;
    final f = picked ?? target;
    if (f == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium('ar.locate.empty_title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium('ar.locate.empty_body'.getString(context), color: FeColors.ink2),
        ],
      );
    }
    final isTarget = target != null && f.featureId == target.featureId && f.buildId == target.buildId;
    final cam = s.cameraTile;
    final distance = cam?.distanceTo(f.centre);
    final facts = ctrl.factsFor(f);
    final sub = [
      if (distance != null) arTr(context, 'ar.locate.distance', [arMetres(context, distance)]),
      // The system is on its own tag below; the type says what it is.
      if (f.name != null && f.name!.trim().isNotEmpty) f.ifcType,
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArElementHeader(
          feature: f,
          title: f.displayName,
          subtitle: sub,
          target: isTarget,
          trailing: ws.selection.length > 1 ? TechCountChip(text: arTr(context, 'ar.work.n_selected', [ws.selection.length])) : null,
        ),
        const SizedBox(height: 8),
        ArElementTags(feature: f, target: isTarget),
        const SizedBox(height: 8),
        ArElementFactsView(facts: facts),
        if (s.args?.workOrderId != null && isTarget) ...[
          const SizedBox(height: 8),
          ArHintRow(text: 'ar.locate.from_wo'.getString(context), icon: ArIcons.forms),
        ],
        const SizedBox(height: 12),
        _ActionRow(
          tablet: tablet,
          actions: [
            _Action(
              icon: ArIcons.identify,
              label: 'ar.locate.identify'.getString(context),
              onTap: f.assetId == null || s.demo
                  ? () => showTechPopup(
                      context,
                      message: (s.demo ? 'ar.demo.identify' : 'ar.locate.no_asset').getString(context),
                    )
                  : () => arPushFromSession(context, ref, Routes.assetDetail(f.assetId!)),
            ),
            if (!isTarget)
              _Action(icon: ArIcons.locate, label: 'ar.locate.make_target'.getString(context), onTap: () => ctrl.locate(f))
            else
              _Action(icon: ArIcons.verify, label: 'ar.mode.verify'.getString(context), onTap: () => ctrl.setMode(ArMode.verify)),
            if (f.systemGlobalId != null)
              _Action(icon: ArIcons.swap, label: 'ar.locate.trace'.getString(context), onTap: () => ctrl.selectSystemOf(f))
            else
              _Action(icon: ArIcons.layers, label: 'ar.tool.layers'.getString(context), onTap: () => ctrl.openPanel(ArPanel.layers)),
          ],
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- verify

class _VerifyPanel extends ConsumerStatefulWidget {
  const _VerifyPanel({required this.tablet});
  final bool tablet;

  @override
  ConsumerState<_VerifyPanel> createState() => _VerifyPanelState();
}

class _VerifyPanelState extends ConsumerState<_VerifyPanel> {
  String? _photo;
  var _photoTried = false;

  Future<void> _takePhoto() async {
    final path = await ref.read(arSessionProvider.notifier).capture();
    if (!mounted) return;
    ArHaptics.snap();
    setState(() {
      _photo = path;
      _photoTried = true;
    });
  }

  Future<void> _continue(ArFeature f, ArVerifyCheck? check) async {
    final s = ref.read(arSessionProvider);
    final ws = ref.read(arWorkspaceProvider);
    if (s.demo) {
      showTechPopup(context, message: 'ar.demo.verify'.getString(context));
      return;
    }
    final fit = s.fit;
    final base = Uri.parse(Routes.verifyAsset(f.assetId!, assetName: f.displayName, floorId: s.floor?.floorId));
    // The AR pre-fill rides as query params (only strings cross the router);
    // the verification form reads them to fill its location check.
    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        'arCheck': check?.result ?? 'unchecked',
        if (check?.offsetM != null) 'arOffsetM': check!.offsetM!.toStringAsFixed(2),
        'arToleranceM': (check?.toleranceM ?? 0.35).toStringAsFixed(2),
        if (check?.tagMatches != null) 'arTagMatches': check!.tagMatches! ? '1' : '0',
        'arBuildId': f.buildId,
        'arGlobalId': f.globalId,
        'arFeatureId': '${f.featureId}',
        if (fit != null) 'arFitMethod': fit.method,
        if (fit != null) 'arMaxResidualMm': fit.maxResidualMm.round().toString(),
        'arQuality': s.quality.name,
        'arMapping': ws.mappingConfirmed ? '1' : '0',
        'arPhoto': ?_photo,
      },
    );
    await arPushFromSession(context, ref, uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(arSessionProvider);
    final ws = ref.watch(arWorkspaceProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final f = ctrl.verifyTarget;
    if (f == null || f.assetId == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium('ar.verify.pick_title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodyMedium(
            (f == null ? 'ar.verify.pick' : 'ar.verify.no_asset').getString(context),
            color: FeColors.ink2,
          ),
        ],
      );
    }
    final check = ws.verify?.assetId == f.assetId ? ws.verify : null;
    final tol = arCentimetres(context, check?.toleranceM ?? (s.isLocked ? 0.35 : 0.75));
    final whereSub = check == null || !check.measured
        ? 'ar.verify.scan_tag'.getString(context)
        : (check.consistent
              ? arTr(context, 'ar.verify.offset_ok', [arCentimetres(context, check.offsetM!), tol])
              : arTr(context, 'ar.verify.offset_bad', [arMetres(context, check.offsetM!), tol]));
    final tagText = check?.tagMatches == null
        ? 'ar.verify.tag_unchecked'.getString(context)
        : (check!.tagMatches! ? 'ar.verify.tag_ok'.getString(context) : 'ar.verify.tag_other'.getString(context));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArElementHeader(
          feature: f,
          title: arTr(context, 'ar.verify.title', [f.displayName]),
          subtitle: 'ar.verify.prefilled'.getString(context),
        ),
        const SizedBox(height: 10),
        _CheckRow(
          state: check == null || !check.measured ? _Check.pending : (check.consistent ? _Check.ok : _Check.warn),
          title: 'ar.verify.where'.getString(context),
          subtitle: whereSub,
        ),
        _CheckRow(
          state: check?.tagMatches == null ? _Check.pending : (check!.tagMatches! ? _Check.ok : _Check.warn),
          title: 'ar.verify.tag'.getString(context),
          subtitle: tagText,
        ),
        _CheckRow(
          state: ws.mappingConfirmed ? _Check.ok : _Check.pending,
          title: 'ar.verify.mapping'.getString(context),
          subtitle: 'ar.verify.mapping_sub'.getString(context),
          trailing: Switch(value: ws.mappingConfirmed, activeThumbColor: FeColors.success, onChanged: (_) => ctrl.toggleMappingConfirmed()),
        ),
        _CheckRow(
          state: _photo != null ? _Check.ok : _Check.pending,
          title: 'ar.verify.photo'.getString(context),
          subtitle: _photo != null
              ? 'ar.verify.photo_ok'.getString(context)
              : (_photoTried && !s.demo ? 'ar.work.photo_failed'.getString(context) : 'ar.verify.photo_sub'.getString(context)),
          trailing: TextButton(
            onPressed: _takePhoto,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: AppText.label(
              (_photo == null ? 'ar.verify.take' : 'ar.verify.retake').getString(context),
              color: FeColors.primary,
              weight: FontWeight.w700,
            ),
          ),
        ),
        if (s.demo && (check == null || !check.measured)) ...[
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: ctrl.demoScanTag,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: FeArColors.placedFg,
              side: const BorderSide(color: FeColors.warning, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            icon: const Icon(ArIcons.demo, size: 16),
            label: AppText.label('ar.demo.scan_tag'.getString(context), color: FeArColors.placedFg, weight: FontWeight.w700),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(ArIcons.offline, size: 14, color: FeColors.ink2),
            const SizedBox(width: 6),
            Expanded(child: AppText.caption('ar.verify.offline_note'.getString(context), color: FeColors.ink2)),
          ],
        ),
        const SizedBox(height: 12),
        ArPrimaryButton(label: 'ar.verify.continue'.getString(context), icon: ArIcons.verify, onPressed: () => _continue(f, check)),
      ],
    );
  }
}

enum _Check { ok, warn, pending }

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.state, required this.title, required this.subtitle, this.trailing});
  final _Check state;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (state) {
      _Check.ok => (FeArColors.lockedBg, FeArColors.lockedIcon, ArIcons.check),
      _Check.warn => (FeArColors.placedBg, FeColors.warning, ArIcons.warning),
      _Check.pending => (FeArColors.manualBg, FeColors.ink2, ArIcons.help),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(icon, size: 15, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium(title, weight: FontWeight.w700),
                AppText.bodySmall(subtitle, color: FeColors.ink2),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- progress

class _ProgressPanel extends ConsumerWidget {
  const _ProgressPanel({required this.tablet});
  final bool tablet;

  Future<void> _mark(BuildContext context, WidgetRef ref, ArProgressStatus status) async {
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final result = await ctrl.setStatus(status);
    if (!context.mounted || result == null) return;
    if (result.queued) {
      showTechPopup(context, message: 'ar.offline_saved'.getString(context), queued: true);
    } else if (result.errorCode != null) {
      showTechPopup(context, message: 'ar.progress.failed'.getString(context), isError: true);
    } else if (result.updated > 0) {
      ArHaptics.success();
      showTechPopup(
        context,
        message: arTr(context, 'ar.progress.marked', [result.updated, 'ar.progress.status.${status.wire}'.getString(context)]),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    final s = ref.watch(arSessionProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final sel = ws.selection;
    final summary = ArSelectionSummary.of(sel);
    final blockers = ctrl.verifyBlockers();
    final allBlocked = sel.isNotEmpty && blockers.length == sel.length;
    final mine = blockers.where((b) => b.reason == 'SECOND_PERSON_REQUIRED').length;
    final modelBuild = sel.isEmpty ? null : s.floor?.buildFor(sel.first.buildId);

    final quantities = <String>[
      if (summary.runLengthM > 0) arTr(context, 'ar.progress.run_length', [summary.runLengthM.toStringAsFixed(1)]),
      if (summary.valves == 1) 'ar.progress.valves_one'.getString(context),
      if (summary.valves > 1) arTr(context, 'ar.progress.valves', [summary.valves]),
      if (summary.equipment == 1) 'ar.progress.equipment_one'.getString(context),
      if (summary.equipment > 1) arTr(context, 'ar.progress.equipment', [summary.equipment]),
      if (modelBuild != null) arTr(context, 'ar.progress.build', [modelBuild.modelName, modelBuild.version ?? '-']),
    ];

    final uniform = sel.isEmpty ? null : ws.progress.statusOf(sel.first.globalId);
    final allSame = uniform != null && sel.every((f) => ws.progress.statusOf(f.globalId) == uniform);

    final buttons = <Widget>[
      _StatusButton(
        label: 'ar.progress.status.not_started'.getString(context),
        bg: FeArColors.notStartedBg,
        fg: FeArColors.notStartedFg,
        current: allSame && uniform == ArProgressStatus.notStarted,
        onTap: sel.isEmpty || ws.progressBusy ? null : () => _mark(context, ref, ArProgressStatus.notStarted),
      ),
      _StatusButton(
        label: 'ar.progress.status.installed'.getString(context),
        bg: FeArColors.lockedBg,
        fg: FeArColors.installedFg,
        border: FeArColors.installed,
        current: allSame && uniform == ArProgressStatus.installed,
        onTap: sel.isEmpty || ws.progressBusy ? null : () => _mark(context, ref, ArProgressStatus.installed),
      ),
      _StatusButton(
        label: 'ar.progress.status.verified'.getString(context),
        sub: allBlocked
            ? (mine > 0 ? 'ar.progress.ask_colleague' : 'ar.progress.install_first').getString(context)
            : 'ar.progress.second_person'.getString(context),
        bg: FeArColors.verified,
        fg: Colors.white,
        current: allSame && uniform == ArProgressStatus.verified,
        onTap: sel.isEmpty || ws.progressBusy || allBlocked ? null : () => _mark(context, ref, ArProgressStatus.verified),
      ),
      _StatusButton(
        label: 'ar.progress.raise_snag'.getString(context),
        bg: FeArColors.mismatchBg,
        fg: FeArColors.mismatchFg,
        border: FeArColors.snagBorder,
        onTap: () => _raiseSnag(context, ref, sel.isEmpty ? null : sel.first),
      ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.titleMedium(
                    sel.isEmpty
                        ? 'ar.progress.select_title'.getString(context)
                        : (summary.systemName == null
                              ? arTr(context, 'ar.work.n_selected', [sel.length])
                              : arTr(context, 'ar.progress.selected_system', [sel.length, summary.systemName!])),
                    weight: FontWeight.w800,
                  ),
                  AppText.bodySmall(
                    sel.isEmpty ? 'ar.progress.select_body'.getString(context) : quantities.join(' · '),
                    color: FeColors.ink2,
                  ),
                ],
              ),
            ),
            if (tablet) _Legend(progress: ws.progress, loaded: ws.progressLoaded),
          ],
        ),
        const SizedBox(height: 12),
        if (tablet)
          Row(
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: buttons[i]),
              ],
            ],
          )
        else
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.1,
            children: buttons,
          ),
        if (ws.rejections.isNotEmpty) ...[
          const SizedBox(height: 10),
          ArHintRow(text: _rejectionText(context, ws.rejections)),
        ] else if (!allBlocked && blockers.isNotEmpty && sel.length > 1) ...[
          const SizedBox(height: 10),
          ArHintRow(text: arTr(context, 'ar.progress.some_blocked', [blockers.length])),
        ],
        if (!tablet) ...[
          const SizedBox(height: 10),
          _Legend(progress: ws.progress, loaded: ws.progressLoaded),
        ],
      ],
    );
  }

  String _rejectionText(BuildContext context, List<ArProgressRejection> r) {
    final second = r.where((x) => x.reason == 'SECOND_PERSON_REQUIRED').length;
    final notInstalled = r.where((x) => x.reason == 'NOT_INSTALLED').length;
    return [
      if (second > 0) arTr(context, 'ar.progress.rejected_second', [second]),
      if (notInstalled > 0) arTr(context, 'ar.progress.rejected_not_installed', [notInstalled]),
    ].join(' · ');
  }
}

Future<void> _raiseSnag(BuildContext context, WidgetRef ref, ArFeature? f) async {
  final s = ref.read(arSessionProvider);
  if (s.demo) {
    showTechPopup(context, message: 'ar.demo.snag'.getString(context));
    return;
  }
  final route = Routes.snagNew(
    buildingId: s.floor?.buildingId,
    floorId: s.floor?.floorId,
    assetId: f?.assetId,
    assetName: f?.displayName,
    workOrderId: s.args?.workOrderId,
    context: 'operations',
  );
  await arPushFromSession(context, ref, route);
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.label,
    required this.bg,
    required this.fg,
    required this.onTap,
    this.border,
    this.sub,
    this.current = false,
  });

  final String label;
  final String? sub;
  final Color bg;
  final Color fg;
  final Color? border;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: current,
      label: label,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 54),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: border == null ? null : Border.all(color: border!, width: 2),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (current) ...[Icon(ArIcons.check, size: 15, color: fg), const SizedBox(width: 4)],
                      Flexible(
                        child: AppText.bodyMedium(label, color: fg, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  if (sub != null)
                    AppText.caption(sub!, color: fg.withValues(alpha: 0.9), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.progress, required this.loaded});
  final ArProgressSnapshot progress;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    if (!loaded) {
      return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
    }
    Widget dot(Color c, String text, {bool dashed = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dashed ? Colors.transparent : c,
            shape: BoxShape.circle,
            border: dashed ? Border.all(color: c, width: 2) : null,
          ),
        ),
        const SizedBox(width: 5),
        AppText.caption(text, color: FeArColors.manualFg),
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        dot(FeArColors.installed, arTr(context, 'ar.progress.legend_installed', [(progress.installedShare * 100).round()])),
        dot(FeArColors.verified, arTr(context, 'ar.progress.legend_verified', [(progress.verifiedShare * 100).round()])),
        dot(FeArColors.notStartedDot, 'ar.progress.status.not_started'.getString(context), dashed: true),
      ],
    );
  }
}

// ------------------------------------------------------------------ snags

class _SnagsPanel extends ConsumerWidget {
  const _SnagsPanel({required this.tablet});
  final bool tablet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(arWorkspaceProvider);
    final s = ref.watch(arSessionProvider);
    final f = ws.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText.titleMedium('ar.snags.title'.getString(context), weight: FontWeight.w800),
        const SizedBox(height: 4),
        if (ws.snagPins.isEmpty)
          AppText.bodySmall('ar.snags.none'.getString(context), color: FeColors.ink2)
        else
          for (final p in ws.snagPins.take(tablet ? 3 : 6))
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => arPushFromSession(context, ref, Routes.snagDetail(p.snagId)),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const Icon(ArIcons.snags, size: 16, color: FeColors.danger),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText.bodyMedium(p.title, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis),
                          AppText.caption(p.feature.displayName, color: FeColors.ink2),
                        ],
                      ),
                    ),
                    const ArDirectionalIcon(ArIcons.next, size: 16, color: FeColors.ink2),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 12),
        ArPrimaryButton(
          label: f == null ? 'ar.snags.raise'.getString(context) : arTr(context, 'ar.snags.raise_on', [f.displayName]),
          icon: ArIcons.snags,
          color: FeColors.danger,
          onPressed: () => _raiseSnag(context, ref, f),
        ),
        const SizedBox(height: 6),
        AppText.caption(
          (s.demo ? 'ar.demo.snag_hint' : 'ar.snags.hint').getString(context),
          color: FeColors.ink2,
          align: TextAlign.center,
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ forms

class _FormsPanel extends ConsumerWidget {
  const _FormsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arSessionProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final wo = s.args?.workOrderId;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText.titleMedium('ar.forms.title'.getString(context), weight: FontWeight.w800),
        const SizedBox(height: 4),
        AppText.bodySmall('ar.forms.body'.getString(context), color: FeColors.ink2),
        const SizedBox(height: 8),
        if (wo != null)
          _FormRow(
            icon: ArIcons.forms,
            label: 'ar.forms.work_order'.getString(context),
            onTap: s.demo
                ? () => showTechPopup(context, message: 'ar.demo.forms'.getString(context))
                : () => arPushFromSession(context, ref, Routes.orderDetail('work-order', wo)),
          ),
        _FormRow(
          icon: ArIcons.verify,
          label: 'ar.forms.verify'.getString(context),
          onTap: () => ctrl.setMode(ArMode.verify),
        ),
        _FormRow(
          icon: ArIcons.forms,
          label: 'ar.forms.inspections'.getString(context),
          onTap: () => arPushFromSession(context, ref, Routes.inspections),
        ),
      ],
    );
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: FeColors.infoSoft, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: FeColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(child: AppText.bodyMedium(label, weight: FontWeight.w700)),
            const ArDirectionalIcon(ArIcons.next, size: 16, color: FeColors.ink2),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- helpers

class _Action {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// Three big actions (M5: Identify · Verify · Layers).
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.tablet, required this.actions});
  final bool tablet;
  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Material(
              color: FeArColors.manualBg,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: actions[i].onTap,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 60),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(actions[i].icon, size: 20, color: FeColors.ink),
                      const SizedBox(height: 4),
                      AppText.caption(actions[i].label, weight: FontWeight.w700, color: FeColors.ink, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A small count pill ("3 selected").
class TechCountChip extends StatelessWidget {
  const TechCountChip({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: FeColors.infoSoft, borderRadius: BorderRadius.circular(99)),
      child: AppText.caption(text, color: FeColors.primary, weight: FontWeight.w700),
    );
  }
}

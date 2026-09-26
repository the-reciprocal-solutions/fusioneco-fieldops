import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_exception.dart';
import '../../core/offline/sync_client.dart';
import '../../core/permit/permit_gas.dart';
import '../../core/utils/dates.dart';
import '../../data/permit_repository.dart';
import '../../domain/permit.dart';
import '../../state/permit_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/tech_popup.dart';
import 'sheets/gas_test_sheet.dart';
import 'sheets/isolation_sheet.dart';
import 'sheets/sign_on_sheet.dart';
import 'sheets/stop_work_sheet.dart';
import 'widgets/permit_visuals.dart';

/// Permit detail (docs/permit-to-work.md). Everything here renders the
/// server's `readiness` object — no rule is re-derived locally. The one
/// primary action button always comes from `readiness.nextAction`; anything
/// else live shows as "Waiting on the office: <label>". Responsive: a single
/// scroll column under 700dp, a two-pane layout (hero+actions / sections)
/// at or above it, so a tablet held in a plant room doesn't waste half its
/// screen. Every tappable control is at least 48dp tall for gloved hands,
/// and text wraps rather than clips at larger accessibility text scales.
class PermitDetailScreen extends ConsumerWidget {
  const PermitDetailScreen({super.key, required this.permitId});

  final String permitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(permitDetailProvider(permitId));

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'permits.detail_title'.getString(context)),
      body: async.when(
        loading: () => const Center(child: TechSpinner()),
        error: (error, stack) => _ErrorBody(permitId: permitId),
        data: (permit) {
          if (permit == null) return _ErrorBody(permitId: permitId);
          return _PermitDetailBody(permit: permit);
        },
      ),
    );
  }
}

class _ErrorBody extends ConsumerWidget {
  const _ErrorBody({required this.permitId});
  final String permitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TechEmptyState(
          icon: LucideIcons.fileWarning,
          title: 'permits.load_error'.getString(context),
          subtitle: 'permits.load_error_sub'.getString(context),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            onPressed: () => ref.invalidate(permitDetailProvider(permitId)),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: AppText('common.retry'.getString(context)),
          ),
        ),
      ],
    ),
  );
}

class _PermitDetailBody extends ConsumerStatefulWidget {
  const _PermitDetailBody({required this.permit});
  final PermitDetail permit;

  @override
  ConsumerState<_PermitDetailBody> createState() => _PermitDetailBodyState();
}

class _PermitDetailBodyState extends ConsumerState<_PermitDetailBody> {
  Timer? _ticker;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _PermitDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// Ticks once a second while the countdown(s) on screen actually move —
  /// only while the permit is live. Anything else (draft, closed) never
  /// needs a repaint just for the clock.
  void _syncTicker() {
    final needed = widget.permit.isLive;
    if (needed && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needed && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  PermitRepository get _repo => ref.read(permitRepositoryProvider);

  /// `read`, not `watch`: this is called from action handlers (button taps),
  /// not just `build` — `WidgetRef.watch` is only valid during a build, and
  /// the signed-in technician's id essentially never changes mid-visit to
  /// one permit anyway.
  String? get _me => ref.read(permitSessionUserIdProvider);

  Future<void> _run(Future<PermitWriteResult> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await call();
      if (!mounted) return;
      showTechPopup(
        context,
        message: result.synced ? 'permits.action_done'.getString(context) : kOfflineQueuedMessage,
        queued: !result.synced,
      );
    } on ApiFailure catch (e) {
      if (!mounted) return;
      showTechPopup(context, message: e.message, isError: true);
    } finally {
      refreshPermit(ref, widget.permit.id);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({required String title, required String message, bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: FeColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.radii.sheet)),
        title: AppText.titleMedium(title, weight: FontWeight.w800),
        content: AppText.bodyMedium(message, color: FeColors.ink2),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: AppText('common.cancel'.getString(context)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: danger ? FeColors.danger : FeColors.primary),
            onPressed: () => Navigator.of(context).pop(true),
            child: AppText('common.confirm'.getString(context)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------- actions

  Future<void> _signOn(PermitDetail permit) async {
    final crew = permit.myCrew(_me);
    if (crew == null) return;
    final catalog = ref.read(permitCatalogProvider).valueOrNull ?? PermitCatalog.empty;
    final result = await showSignOnSheet(context, permit: permit, catalog: catalog);
    if (result == null) return;
    await _run(() => _repo.signOn(permit.id, crew.id, briefingAck: true, signaturePngBytes: result.signaturePng));
  }

  Future<void> _signOff(PermitDetail permit) async {
    final crew = permit.myCrew(_me);
    if (crew == null) return;
    await _run(() => _repo.signOff(permit.id, crew.id));
  }

  Future<void> _recordGasTest(PermitDetail permit) async {
    final draft = await showGasTestSheet(context, permit: permit);
    if (draft == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await _repo.addGasTest(
        permit.id,
        o2: draft.o2,
        lel: draft.lel,
        h2s: draft.h2s,
        co: draft.co,
        instrumentId: draft.instrumentId,
        calibrationDue: draft.calibrationDue,
        location: draft.location,
        note: draft.note,
      );
      if (!mounted) return;
      showTechPopup(
        context,
        message: !outcome.synced
            ? kOfflineQueuedMessage
            : outcome.autoSuspended
            ? 'permits.gas_test_auto_suspended'.getString(context)
            : 'permits.action_done'.getString(context),
        queued: !outcome.synced,
        isError: outcome.synced && outcome.test?.passed == false,
      );
    } on ApiFailure catch (e) {
      if (!mounted) return;
      showTechPopup(context, message: e.message, isError: true);
    } finally {
      refreshPermit(ref, permit.id);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _isolate(PermitDetail permit, PermitIsolation iso) async {
    final draft = await showIsolateSheet(context, isolation: iso);
    if (draft == null) return;
    await _run(() => _repo.isolate(
          permit.id,
          iso.id,
          lockNo: draft.lockNo,
          tagNo: draft.tagNo,
          note: draft.note,
          photo: draft.photo,
        ));
  }

  Future<void> _verify(PermitDetail permit, PermitIsolation iso) async {
    final draft = await showVerifyIsolationSheet(context, isolation: iso);
    if (draft == null) return;
    await _run(() => _repo.verifyIsolation(permit.id, iso.id, tryOut: draft.tryOut, note: draft.note));
  }

  Future<void> _restore(PermitDetail permit, PermitIsolation iso) async {
    final ok = await _confirm(
      title: 'permits.restore_confirm_title'.getString(context),
      message: 'permits.restore_confirm_message'.getString(context),
      danger: true,
    );
    if (!ok) return;
    await _run(() => _repo.restoreIsolation(permit.id, iso.id));
  }

  Future<void> _stopWork(PermitDetail permit) async {
    final reason = await showStopWorkSheet(context);
    if (reason == null) return;
    await _run(() => _repo.stopWork(permit.id, reason));
  }

  Future<void> _completeWork(PermitDetail permit) async {
    final ok = await _confirm(
      title: 'permits.complete_confirm_title'.getString(context),
      message: 'permits.complete_confirm_message'.getString(context),
    );
    if (!ok) return;
    await _run(() => _repo.completeWork(permit.id));
  }

  Future<void> _fireWatchDone(PermitDetail permit) async {
    final ok = await _confirm(
      title: 'permits.fire_watch_confirm_title'.getString(context),
      message: 'permits.fire_watch_confirm_message'.getString(context),
    );
    if (!ok) return;
    await _run(() => _repo.fireWatchDone(permit.id));
  }

  /// The one button [PermitReadiness.nextAction] earns — null when the
  /// action isn't one this app performs in the field (approval, issue,
  /// close-out, extend…), which renders as "Waiting on the office" instead.
  VoidCallback? _handlerFor(PermitDetail permit, PermitNextAction action) {
    if (_busy) return null;
    return switch (action.action) {
      'sign_on_crew' => permit.myCrew(_me) == null ? null : () => _signOn(permit),
      'sign_off_crew' => permit.myCrew(_me) == null ? null : () => _signOff(permit),
      'record_gas_test' => () => _recordGasTest(permit),
      'suspend' => () => _stopWork(permit),
      'complete' => () => _completeWork(permit),
      'fire_watch_done' => () => _fireWatchDone(permit),
      _ => null, // apply_isolations / restore_isolations: see the section below
    };
  }

  @override
  Widget build(BuildContext context) {
    final permit = widget.permit;
    final catalogAsync = ref.watch(permitCatalogProvider);
    final catalog = catalogAsync.valueOrNull ?? PermitCatalog.empty;
    final me = _me;

    final heroColumn = <Widget>[
      _Hero(permit: permit, catalog: catalog),
      const SizedBox(height: 12),
      _NextActionCard(
        permit: permit,
        onAction: (a) => _handlerFor(permit, a)?.call(),
        canAct: (a) => _handlerFor(permit, a) != null,
        busy: _busy,
      ),
      if (permit.fireWatch != null) ...[
        const SizedBox(height: 12),
        _FireWatchCard(
          fireWatch: permit.fireWatch!,
          onSignOff: _busy ? null : () => _fireWatchDone(permit),
        ),
      ],
      const SizedBox(height: 12),
      _LifecycleStrip(steps: permit.readiness.lifecycle),
    ];

    final sectionsColumn = <Widget>[
      if (permit.readiness.allBlockers.isNotEmpty) ...[
        _BlockersSection(blockers: permit.readiness.allBlockers),
        const SizedBox(height: 12),
      ],
      _CrewSection(
        crew: permit.crew,
        catalog: catalog,
        sessionUserId: me,
        busy: _busy,
        onSignOn: () => _signOn(permit),
        onSignOff: () => _signOff(permit),
      ),
      const SizedBox(height: 12),
      _GasSection(
        permit: permit,
        busy: _busy,
        onRecord: () => _recordGasTest(permit),
      ),
      const SizedBox(height: 12),
      _IsolationsSection(
        permit: permit,
        sessionUserId: me,
        busy: _busy,
        onIsolate: (iso) => _isolate(permit, iso),
        onVerify: (iso) => _verify(permit, iso),
        onRestore: (iso) => _restore(permit, iso),
      ),
      const SizedBox(height: 12),
      _HazardsSection(permit: permit, catalog: catalog),
      const SizedBox(height: 12),
      _ActivitySection(activity: permit.activity),
      const SizedBox(height: 24),
    ];

    final showStopBar = permit.isActive;

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                refreshPermit(ref, permit.id);
                await ref.read(permitDetailProvider(permit.id).future);
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 700) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 340,
                            // `mainAxisSize: min` matters here, not just style:
                            // this Column sits inside a Row inside a vertical
                            // `SingleChildScrollView`, which hands it an
                            // unbounded height. The default `max` would try to
                            // fill that and crash with an infinite-size layout
                            // error; `min` just sizes to its own content, which
                            // is exactly the "each pane scrolls together, sized
                            // to its own content" split-view behaviour wanted.
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: heroColumn,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: sectionsColumn,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, showStopBar ? 16 : 32),
                    children: [...heroColumn, const SizedBox(height: 12), ...sectionsColumn],
                  );
                },
              ),
            ),
          ),
          if (showStopBar)
            _StopWorkBar(busy: _busy, onTap: () => _stopWork(permit)),
        ],
      ),
    );
  }
}

// ============================================================================
// Hero
// ============================================================================

class _Hero extends StatelessWidget {
  const _Hero({required this.permit, required this.catalog});
  final PermitDetail permit;
  final PermitCatalog catalog;

  @override
  Widget build(BuildContext context) {
    final (countdownText, countdownColor) =
        permit.isLive ? PermitDisplay.countdown(context, permit.validUntil, DateTime.now()) : (null, null);
    final location = [permit.buildingName, permit.floorName, permit.zoneName, permit.spaceName]
        .where((s) => s != null && s.isNotEmpty)
        .join(' › ');

    return TechCard(
      dark: true,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TechChip(
                label: PermitDisplay.statusLabel(context, permit.status),
                style: FeChipStyle(
                  background: PermitDisplay.statusHue(permit.status).withValues(alpha: 0.22),
                  foreground: Colors.white,
                  border: Colors.transparent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.bodySmall(permit.permitNo, color: Colors.white70, weight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AppText.titleMedium(permit.title, color: Colors.white, weight: FontWeight.w800, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (location.isNotEmpty) ...[
            const SizedBox(height: 4),
            AppText.bodySmall(location, color: Colors.white70, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 14),
          if (countdownText != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.clock, size: 22, color: countdownColor),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.titleSmall(
                    countdownText,
                    color: countdownColor,
                    weight: FontWeight.w800,
                    maxLines: 2,
                  ),
                ),
              ],
            )
          else
            AppText.bodySmall('permits.validity_not_issued'.getString(context), color: Colors.white70),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _typeChip(context, permit.type, catalog),
              for (final t in permit.secondaryTypes) _typeChip(context, t, catalog),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeChip(BuildContext context, String type, PermitCatalog catalog) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(PermitDisplay.typeIcon(type), size: 14, color: Colors.white),
        const SizedBox(width: 6),
        AppText.caption(PermitDisplay.typeLabel(context, catalog, type), color: Colors.white, weight: FontWeight.w700),
      ],
    ),
  );
}

// ============================================================================
// Next action
// ============================================================================

class _NextActionCard extends StatelessWidget {
  const _NextActionCard({required this.permit, required this.onAction, required this.canAct, required this.busy});
  final PermitDetail permit;
  final void Function(PermitNextAction) onAction;
  final bool Function(PermitNextAction) canAct;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final action = permit.readiness.nextAction;
    if (action == null) {
      return TechCard(
        child: Row(
          children: [
            const Icon(LucideIcons.circleCheck, color: FeColors.success),
            const SizedBox(width: 10),
            Expanded(child: AppText.bodyMedium('permits.up_to_date'.getString(context))),
          ],
        ),
      );
    }

    final mine = canAct(action);
    if (!mine) {
      return TechCard(
        tint: FeColors.page,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(LucideIcons.clockAlert, color: FeColors.ink2),
            const SizedBox(width: 10),
            Expanded(
              child: AppText.bodyMedium(
                context.formatString('permits.waiting_on_office'.getString(context), [action.label]),
                color: FeColors.ink2,
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: context.metrics.buttonCta,
      child: FilledButton.icon(
        onPressed: busy ? null : () => onAction(action),
        style: FilledButton.styleFrom(backgroundColor: FeColors.primary),
        icon: const Icon(LucideIcons.arrowRight, size: 18),
        label: AppText.bodyMedium(action.label, color: Colors.white, weight: FontWeight.w800),
      ),
    );
  }
}

// ============================================================================
// Fire watch
// ============================================================================

class _FireWatchCard extends StatelessWidget {
  const _FireWatchCard({required this.fireWatch, required this.onSignOff});
  final PermitFireWatch fireWatch;
  final VoidCallback? onSignOff;

  @override
  Widget build(BuildContext context) {
    if (fireWatch.isDone) {
      return TechCard(
        child: Row(
          children: [
            const Icon(LucideIcons.shieldCheck, color: FeColors.success),
            const SizedBox(width: 10),
            Expanded(child: AppText.bodyMedium('permits.fire_watch_done'.getString(context))),
          ],
        ),
      );
    }
    final now = DateTime.now();
    final elapsed = fireWatch.isElapsed(now);
    final remaining = fireWatch.remaining(now);
    final totalSeconds = fireWatch.endsAt.difference(fireWatch.startedAt).inSeconds;
    final progress = totalSeconds <= 0 ? 1.0 : (1 - remaining.inSeconds / totalSeconds).clamp(0.0, 1.0);
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

    return TechCard(
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 5,
                    backgroundColor: FeColors.line,
                    valueColor: AlwaysStoppedAnimation(elapsed ? FeColors.danger : FeColors.warning),
                  ),
                ),
                AppText.caption(elapsed ? '0:00' : '$mm:$ss', weight: FontWeight.w800),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium('permits.fire_watch_title'.getString(context), weight: FontWeight.w700),
                const SizedBox(height: 2),
                AppText.bodySmall(
                  elapsed
                      ? 'permits.fire_watch_elapsed'.getString(context)
                      : 'permits.fire_watch_running'.getString(context),
                  color: FeColors.ink2,
                ),
              ],
            ),
          ),
          if (elapsed)
            SizedBox(
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: FeColors.warning),
                onPressed: onSignOff,
                child: AppText.bodySmall(
                  'permits.fire_watch_sign_off'.getString(context),
                  color: FeColors.ink,
                  weight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// Lifecycle strip
// ============================================================================

class _LifecycleStrip extends StatelessWidget {
  const _LifecycleStrip({required this.steps});
  final List<LifecycleStep> steps;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    return TechCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (final s in steps)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  s.isDone
                      ? LucideIcons.circleCheck
                      : s.isBlocked
                      ? LucideIcons.circleX
                      : s.isCurrent
                      ? LucideIcons.circleDot
                      : LucideIcons.circleDashed,
                  size: 16,
                  color: s.isDone
                      ? FeColors.success
                      : s.isBlocked
                      ? FeColors.danger
                      : s.isCurrent
                      ? FeColors.primary
                      : FeColors.ink2,
                ),
                const SizedBox(width: 5),
                AppText.caption(
                  s.label,
                  weight: s.isCurrent ? FontWeight.w800 : FontWeight.w600,
                  color: s.isSkipped ? FeColors.ink2 : FeColors.ink,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// Blockers
// ============================================================================

class _BlockersSection extends StatelessWidget {
  const _BlockersSection({required this.blockers});
  final List<PermitBlocker> blockers;

  @override
  Widget build(BuildContext context) => TechCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText.titleSmall('permits.section_blockers'.getString(context), weight: FontWeight.w800),
        const SizedBox(height: 10),
        for (final b in blockers)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  b.isBlocking ? LucideIcons.circleX : LucideIcons.triangleAlert,
                  size: 16,
                  color: b.isBlocking ? FeColors.danger : FeColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.bodySmall(b.message, color: b.isBlocking ? FeColors.danger : FeColors.ink2),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

// ============================================================================
// Crew
// ============================================================================

class _CrewSection extends StatelessWidget {
  const _CrewSection({
    required this.crew,
    required this.catalog,
    required this.sessionUserId,
    required this.busy,
    required this.onSignOn,
    required this.onSignOff,
  });

  final List<PermitCrew> crew;
  final PermitCatalog catalog;
  final String? sessionUserId;
  final bool busy;
  final VoidCallback onSignOn;
  final VoidCallback onSignOff;

  @override
  Widget build(BuildContext context) => TechCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: AppText.titleSmall('permits.section_crew'.getString(context), weight: FontWeight.w800)),
            AppText.caption('${crew.where((c) => c.isOnSite || c.isSignedOff).length}/${crew.length}', color: FeColors.ink2),
          ],
        ),
        const SizedBox(height: 10),
        if (crew.isEmpty)
          AppText.bodySmall('permits.crew_empty'.getString(context), color: FeColors.ink2)
        else
          for (final c in crew)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.bodyMedium(c.name, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis),
                        AppText.caption(catalog.roleLabel(c.role), color: FeColors.ink2),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _crewStatusChip(context, c),
                  if (c.isMe(sessionUserId)) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 44,
                      child: c.needsSignOn
                          ? FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: FeColors.primary, padding: const EdgeInsets.symmetric(horizontal: 14)),
                              onPressed: busy ? null : onSignOn,
                              child: AppText.caption('permits.sign_on'.getString(context), color: Colors.white, weight: FontWeight.w800),
                            )
                          : c.isSignedOff
                          ? const SizedBox.shrink()
                          : OutlinedButton(
                              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
                              onPressed: busy ? null : onSignOff,
                              child: AppText.caption('permits.sign_off'.getString(context), weight: FontWeight.w800),
                            ),
                    ),
                  ],
                ],
              ),
            ),
      ],
    ),
  );

  Widget _crewStatusChip(BuildContext context, PermitCrew c) {
    final (label, color) = switch (c.status) {
      'on_site' => ('permits.crew_on_site'.getString(context), FeColors.success),
      'signed_off' => ('permits.crew_signed_off'.getString(context), FeColors.ink2),
      _ => ('permits.crew_expected'.getString(context), FeColors.warning),
    };
    return TechChip(
      label: label,
      style: FeChipStyle(
        background: color.withValues(alpha: 0.12),
        foreground: color,
        border: color.withValues(alpha: 0.28),
      ),
    );
  }
}

// ============================================================================
// Gas tests
// ============================================================================

class _GasSection extends StatelessWidget {
  const _GasSection({required this.permit, required this.busy, required this.onRecord});
  final PermitDetail permit;
  final bool busy;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final latest = permit.latestGasTest;
    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: AppText.titleSmall('permits.section_gas'.getString(context), weight: FontWeight.w800)),
              SizedBox(
                height: 44,
                child: FilledButton.icon(
                  onPressed: busy ? null : onRecord,
                  style: FilledButton.styleFrom(backgroundColor: FeColors.primary, padding: const EdgeInsets.symmetric(horizontal: 12)),
                  icon: const Icon(LucideIcons.wind, size: 16),
                  label: AppText.caption('permits.record_gas_test'.getString(context), color: Colors.white, weight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (permit.gasProfile.limits.isEmpty)
            AppText.bodySmall('permits.gas_not_required'.getString(context), color: FeColors.ink2)
          else if (latest == null)
            AppText.bodySmall('permits.gas_none_yet'.getString(context), color: FeColors.ink2)
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final limit in permit.gasProfile.limits)
                  _gasChip(context, limit, latest.valueFor(limit.gas)),
              ],
            ),
            const SizedBox(height: 6),
            AppText.caption(
              context.formatString(
                'permits.gas_last_tested'.getString(context),
                [formatDateTimeShort(latest.testedAt), latest.testedByName ?? ''],
              ),
              color: FeColors.ink2,
            ),
          ],
          if (permit.gasTests.length > 1) ...[
            const SizedBox(height: 10),
            for (final t in permit.gasTests.skip(1).take(4))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(t.passed ? LucideIcons.circleCheck : LucideIcons.circleX,
                        size: 14, color: t.passed ? FeColors.success : FeColors.danger),
                    const SizedBox(width: 6),
                    Expanded(child: AppText.caption(formatDateTimeShort(t.testedAt), color: FeColors.ink2)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _gasChip(BuildContext context, GasLimit limit, double? value) {
    final result = PermitGas.evaluate(limit, value);
    final color = PermitDisplay.gasVerdictColor(result.verdict);
    final text = value == null ? '—' : value.toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText.caption(limit.label, color: color, weight: FontWeight.w700),
          AppText.bodySmall('$text ${limit.unit}', color: color, weight: FontWeight.w800),
        ],
      ),
    );
  }
}

// ============================================================================
// Isolations
// ============================================================================

class _IsolationsSection extends StatelessWidget {
  const _IsolationsSection({
    required this.permit,
    required this.sessionUserId,
    required this.busy,
    required this.onIsolate,
    required this.onVerify,
    required this.onRestore,
  });

  final PermitDetail permit;
  final String? sessionUserId;
  final bool busy;
  final void Function(PermitIsolation) onIsolate;
  final void Function(PermitIsolation) onVerify;
  final void Function(PermitIsolation) onRestore;

  @override
  Widget build(BuildContext context) {
    if (permit.isolations.isEmpty && !permit.readiness.isolationRequired) return const SizedBox.shrink();
    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.titleSmall('permits.section_isolations'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 10),
          if (permit.isolations.isEmpty)
            AppText.bodySmall('permits.isolations_empty'.getString(context), color: FeColors.ink2)
          else
            for (final iso in permit.isolations)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _IsolationRow(
                  iso: iso,
                  sessionUserId: sessionUserId,
                  busy: busy,
                  onIsolate: () => onIsolate(iso),
                  onVerify: () => onVerify(iso),
                  onRestore: () => onRestore(iso),
                ),
              ),
        ],
      ),
    );
  }
}

class _IsolationRow extends StatelessWidget {
  const _IsolationRow({
    required this.iso,
    required this.sessionUserId,
    required this.busy,
    required this.onIsolate,
    required this.onVerify,
    required this.onRestore,
  });

  final PermitIsolation iso;
  final String? sessionUserId;
  final bool busy;
  final VoidCallback onIsolate;
  final VoidCallback onVerify;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final steps = ['planned', 'isolated', 'verified', 'restored'];
    final currentIndex = steps.indexOf(iso.status).clamp(0, steps.length - 1);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: FeColors.page, borderRadius: BorderRadius.circular(context.radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText.bodyMedium(iso.pointTag, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              AppText.caption(iso.energyType, color: FeColors.ink2),
            ],
          ),
          if ((iso.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            AppText.caption(iso.description!, color: FeColors.ink2),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i <= currentIndex ? FeColors.primary : FeColors.line,
                  ),
                ),
                if (i < steps.length - 1)
                  Expanded(
                    child: Container(height: 2, color: i < currentIndex ? FeColors.primary : FeColors.line),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          AppText.caption('permits.isolation_status.${iso.status}'.getString(context), color: FeColors.ink2, weight: FontWeight.w700),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (iso.isPlanned)
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: FeColors.primary),
                    onPressed: busy ? null : onIsolate,
                    child: AppText.caption('permits.isolate'.getString(context), color: Colors.white, weight: FontWeight.w800),
                  ),
                ),
              if (iso.isIsolated)
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: FeColors.warning),
                    onPressed: busy ? null : onVerify,
                    child: AppText.caption('permits.verify'.getString(context), color: FeColors.ink, weight: FontWeight.w800),
                  ),
                ),
              if (iso.isVerified)
                Tooltip(
                  message: iso.canRestore(sessionUserId)
                      ? ''
                      : context.formatString(
                          'permits.restore_locked_to'.getString(context),
                          [iso.isolatedByName ?? ''],
                        ),
                  child: SizedBox(
                    height: 44,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: FeColors.danger),
                      onPressed: busy || !iso.canRestore(sessionUserId) ? null : onRestore,
                      child: AppText.caption('permits.restore'.getString(context), color: Colors.white, weight: FontWeight.w800),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Hazards / controls / PPE
// ============================================================================

class _HazardsSection extends StatelessWidget {
  const _HazardsSection({required this.permit, required this.catalog});
  final PermitDetail permit;
  final PermitCatalog catalog;

  @override
  Widget build(BuildContext context) {
    if (permit.hazards.isEmpty && permit.controls.isEmpty && permit.ppe.isEmpty) return const SizedBox.shrink();
    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (permit.hazards.isNotEmpty) ...[
            AppText.labelMedium('permits.section_hazards'.getString(context), color: FeColors.ink2),
            const SizedBox(height: 6),
            _chipWrap(permit.hazards.map(catalog.hazardLabel), FeColors.danger),
            const SizedBox(height: 12),
          ],
          if (permit.controls.isNotEmpty) ...[
            AppText.labelMedium('permits.section_controls'.getString(context), color: FeColors.ink2),
            const SizedBox(height: 6),
            _chipWrap(permit.controls.map(catalog.controlLabel), FeColors.info),
            const SizedBox(height: 12),
          ],
          if (permit.ppe.isNotEmpty) ...[
            AppText.labelMedium('permits.section_ppe'.getString(context), color: FeColors.ink2),
            const SizedBox(height: 6),
            _chipWrap(permit.ppe.map(catalog.ppeLabel), FeColors.success),
          ],
        ],
      ),
    );
  }

  Widget _chipWrap(Iterable<String> labels, Color hue) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final l in labels)
        TechChip(
          label: l,
          uppercase: false,
          style: FeChipStyle(background: hue.withValues(alpha: 0.1), foreground: hue, border: hue.withValues(alpha: 0.24)),
        ),
    ],
  );
}

// ============================================================================
// Activity
// ============================================================================

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.activity});
  final List<PermitActivity> activity;

  @override
  Widget build(BuildContext context) {
    if (activity.isEmpty) return const SizedBox.shrink();
    final sorted = [...activity]..sort((a, b) => b.at.compareTo(a.at));
    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.titleSmall('permits.section_activity'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 10),
          for (final a in sorted.take(20))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(LucideIcons.circleDot, size: 10, color: FeColors.ink2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.bodySmall(
                          [a.byName, if (a.note != null) a.note, if (a.reason != null) a.reason]
                              .whereType<String>()
                              .join(' — '),
                        ),
                        AppText.caption(formatDateTimeShort(a.at), color: FeColors.ink2),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// Stop work — always visible while the permit is active
// ============================================================================

class _StopWorkBar extends StatelessWidget {
  const _StopWorkBar({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    decoration: const BoxDecoration(
      color: FeColors.panel,
      border: Border(top: BorderSide(color: FeColors.line)),
    ),
    child: SizedBox(
      width: double.infinity,
      height: context.metrics.buttonCta,
      child: FilledButton.icon(
        onPressed: busy ? null : onTap,
        style: FilledButton.styleFrom(backgroundColor: FeColors.danger),
        icon: const Icon(LucideIcons.ban, size: 18),
        label: AppText.bodyMedium('permits.stop_work'.getString(context), color: Colors.white, weight: FontWeight.w800),
      ),
    ),
  );
}

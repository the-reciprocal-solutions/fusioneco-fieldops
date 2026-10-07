import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ar/alignment_estimator.dart';
import '../../state/ar_engine_bridge.dart';
import '../../state/ar_install_controller.dart';
import '../../state/ar_manual_place_controller.dart';
import '../../state/ar_prefs_controller.dart';
import '../../state/ar_session_controller.dart';
import '../../state/ar_setup_controller.dart';
import '../../state/ar_workspace_controller.dart';
import '../../theme/fe_ar_colors.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/tech_popup.dart';
import 'ar_coach_overlay.dart';
import 'ar_ui.dart';
import 'install/ar_install_check_overlay.dart';
import 'setup/ar_setup_overlay.dart';
import 'setup/manual/ar_manual_place_overlay.dart';
import 'widgets/ar_chrome.dart';
import 'widgets/ar_demo_scene.dart';
import 'widgets/ar_status.dart';
import 'widgets/ar_unsupported.dart';
import 'workspace/ar_workspace.dart';

/// `/ar/session`: the one AR screen. The camera (or Demo mode's stand-in)
/// fills it; setup, the workspace or the installer's self-check float on
/// top. The engine pauses when the app goes to the background and when
/// another screen is pushed over it (a form, a snag), and resumes on return.
class ArSessionScreen extends ConsumerStatefulWidget {
  const ArSessionScreen({
    super.key,
    required this.floorId,
    this.method,
    this.targetGlobalId,
    this.assetId,
    this.workOrderId,
    this.focusCode,
    this.models = const {},
    this.spaceName,
    this.installCode,
  });

  final String floorId;
  final String? method;
  final String? targetGlobalId;
  final String? assetId;
  final String? workOrderId;
  final String? focusCode;
  final Set<String> models;
  final String? spaceName;
  final String? installCode;

  @override
  ConsumerState<ArSessionScreen> createState() => _ArSessionScreenState();
}

class _ArSessionScreenState extends ConsumerState<ArSessionScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    // The one screen allowed to turn sideways (ArOrientation).
    ArOrientation.enter();
  }

  ArSessionArgs get _args => ArSessionArgs(
    floorId: widget.floorId,
    method: ArPlaceMethod.parse(widget.method),
    targetGlobalId: widget.targetGlobalId,
    assetId: widget.assetId,
    workOrderId: widget.workOrderId,
    focusCode: widget.focusCode,
    lineages: widget.models,
    spaceName: widget.spaceName,
    installCode: widget.installCode,
  );

  Future<void> _start() async {
    if (!mounted || widget.floorId.isEmpty) return;
    final code = widget.installCode;
    if (code != null) {
      final install = ref.read(arInstallProvider.notifier);
      install.begin(code);
      install.startScan();
    }
    // `method=manual` ("Place by hand") isn't an ArPlaceMethod the setup
    // ladder knows: the manual controller starts itself once the floor is in.
    if (widget.method == 'manual') ref.read(arManualPlaceProvider.notifier).requestStart();
    await ref.read(arSessionProvider.notifier).start(_args);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = ref.read(arSessionProvider.notifier);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      session.pause();
    } else if (state == AppLifecycleState.resumed) {
      // A power pause (idle / hot) waits for the user's tap, not the app coming back.
      if (ref.read(arSessionProvider).pausedFor == null) session.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ArOrientation.leave();
    super.dispose();
  }

  void _listen() {
    ref.listen<ArToast?>(arSessionProvider.select((s) => s.toast), (prev, next) {
      if (next == null || next.seq == prev?.seq || !mounted) return;
      showTechPopup(
        context,
        message: arTr(context, next.key, next.args),
        isError: next.tone == ArToastTone.error,
        queued: next.key == 'ar.offline_saved',
      );
    });
    ref.listen<int>(arSetupProvider.select((s) => s.snapSeq), (prev, next) {
      if (next != prev) ArHaptics.snap();
    });
    ref.listen<int>(arSetupProvider.select((s) => s.lockSeq), (prev, next) {
      if (next != prev) ArHaptics.lock();
    });
    ref.listen<int>(arManualPlaceProvider.select((s) => s.snapSeq), (prev, next) {
      if (next != prev) ArHaptics.snap();
    });
    ref.listen<int>(arManualPlaceProvider.select((s) => s.lockSeq), (prev, next) {
      if (next != prev) ArHaptics.lock();
    });
    ref.listen<AlignmentQuality>(arSessionProvider.select((s) => s.quality), (prev, next) {
      if (next == AlignmentQuality.locked && prev != AlignmentQuality.locked) ArHaptics.success();
      if (next == AlignmentQuality.siteMismatch && prev != AlignmentQuality.siteMismatch) ArHaptics.warn();
      if (next == AlignmentQuality.placed && prev == AlignmentQuality.none) ArHaptics.lock();
    });
    if (widget.installCode != null) {
      ref.listen<ArInstallPhase>(arInstallProvider.select((s) => s.phase), (prev, next) {
        if (next == ArInstallPhase.done && prev != ArInstallPhase.done) ArHaptics.success();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _listen();
    final s = ref.watch(arSessionProvider);
    // Keep the setup and workspace controllers alive with the screen.
    final step = ref.watch(arSetupProvider.select((x) => x.step));
    ref.watch(arWorkspaceProvider.select((x) => x.mode));
    // "Place by hand" replaces the setup overlay while it runs.
    final manual = ref.watch(arManualPlaceProvider.select((x) => x.active));
    if (widget.installCode != null) ref.watch(arInstallProvider.select((x) => x.phase));

    if (widget.floorId.isEmpty) {
      return const Scaffold(
        body: ArUnsupportedView(reason: null, errorKey: 'ar.error.no_floor', floorId: null),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      // Sunlight mode reaches every piece of chrome on this screen from here.
      child: ArSunlightHost(
        child: Scaffold(
        backgroundColor: FeArColors.cameraFloor,
        resizeToAvoidBottomInset: false,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            // A phone on its side is wide but short: not a tablet.
            final layout = arLayoutFor(size);
            final tablet = layout == ArLayout.tablet;
            ref.read(arSessionProvider.notifier).viewSize = size;

            if (s.phase == ArSessionPhase.unsupported) {
              return ArUnsupportedView(
                reason: s.error,
                floorId: widget.floorId,
                assetId: widget.assetId,
                onDemo: () => ref.read(arSessionProvider.notifier).restart(),
              );
            }
            if (s.phase == ArSessionPhase.failed) {
              return ArUnsupportedView(
                reason: null,
                errorKey: s.error ?? 'ar.error.generic',
                floorId: widget.floorId,
                assetId: widget.assetId,
                onRetry: () => ref.read(arSessionProvider.notifier).restart(),
                onDemo: () => ref.read(arSessionProvider.notifier).restart(),
              );
            }

            final topInset = MediaQuery.paddingOf(context).top + 64;
            final running = s.phase == ArSessionPhase.running;
            final working = running && s.stage == ArSessionStage.work && widget.installCode == null;
            final prefs = ref.watch(arPrefsProvider);
            final coach = running && widget.installCode == null && prefs.loaded && !prefs.coachSeen;

            return Stack(
              children: [
                Positioned.fill(child: _Camera(demo: s.demo, step: step)),
                if (!running) Positioned.fill(child: _Starting(phase: s.phase)),
                if (running && widget.installCode != null)
                  Positioned.fill(child: ArInstallCheckOverlay(tablet: tablet, topInset: topInset))
                else if (running && s.stage == ArSessionStage.setup)
                  Positioned.fill(
                    child: manual
                        ? ArManualPlaceOverlay(tablet: tablet, topInset: topInset, landscape: layout == ArLayout.landscapePhone)
                        : ArSetupOverlay(tablet: tablet, topInset: topInset),
                  ),
                if (working)
                  Positioned.fill(
                    child: ArWorkspace(
                      tablet: tablet,
                      landscape: layout == ArLayout.landscapePhone,
                      viewSize: size,
                      onBack: () => context.pop(),
                    ),
                  )
                else
                  _SetupTopBar(demo: s.demo, placed: s.isPlaced, tablet: tablet),
                if (coach)
                  Positioned.fill(
                    child: ArCoachOverlay(
                      key: ValueKey(s.stage),
                      startAtWork: s.stage == ArSessionStage.work,
                    ),
                  ),
                if (s.paused && s.pausedFor != null)
                  Positioned.fill(child: _PowerPaused(reason: s.pausedFor!)),
              ],
            );
          },
        ),
      ),
      ),
    );
  }
}

/// The camera layer: the native AR view, or Demo mode's stand-in room.
class _Camera extends ConsumerWidget {
  const _Camera({required this.demo, required this.step});
  final bool demo;
  final ArSetupStep step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!demo) {
      // Only capabilities matter here: the platform view must not rebuild on
      // every pose.
      return buildArView(
        capabilities: ref.watch(arSessionProvider.select((x) => x.capabilities)),
        onCreated: ref.read(arSessionProvider.notifier).onViewCreated,
      );
    }
    final s = ref.watch(arSessionProvider);
    final ws = ref.watch(arWorkspaceProvider);
    final setup = ref.watch(arSetupProvider);
    final gridStep = step == ArSetupStep.start || step == ArSetupStep.cornerA || step == ArSetupStep.cornerB;
    final progressColours = ws.mode == ArMode.progress || ws.layers.colourBy == ArColourBy.progress;
    return buildArView(
      demo: true,
      child: ArDemoScene(
      scene: ArDemoSceneState(
        placed: s.isPlaced,
        locked: s.isLocked,
        showGrid: s.gridVisible && (gridStep || s.stage == ArSessionStage.work),
        showGhost: setup.ghost != null && (step == ArSetupStep.locked || step == ArSetupStep.leaveBoard),
        showModel: s.stage == ArSessionStage.work || s.isPlaced,
        targetGlobalId: ws.mode == ArMode.locate ? s.target?.globalId : null,
        selected: {
          for (final f in ws.selection) f.globalId,
          if (ws.drilling && ws.drill?.feature != null) ws.drill!.feature!.globalId,
        },
        statusColors: !progressColours
            ? const {}
            : {
                for (final e in ws.progress.entries.values)
                  e.globalId: switch (e.status.wire) {
                    'installed' => FeArColors.installed,
                    'verified' => FeArColors.verified,
                    'issue' => FeColors.danger,
                    _ => FeArColors.notStartedDot,
                  },
              },
        snagGlobalIds: {for (final p in ws.snagPins) p.feature.globalId},
        hidden: {
          for (final f in s.features)
            if ((!ws.layers.mep && ArDiscipline.of(f.discipline).isMep) || ArWorkspaceController.filteredOut(f, ws.layers))
              f.globalId,
        },
        // Drifting: dimmed like the live model until re-checked.
        opacity: s.recheck != null ? ws.layers.opacity * 0.35 : ws.layers.opacity,
        nudgePx: s.nudgeM * 600,
      ),
      ),
    );
  }
}

/// Back, badge and the Demo banner while placing the model.
class _SetupTopBar extends ConsumerWidget {
  const _SetupTopBar({required this.demo, required this.placed, required this.tablet});
  final bool demo;
  final bool placed;
  final bool tablet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final top = MediaQuery.paddingOf(context).top + 12;
    return PositionedDirectional(
      top: top,
      start: 12,
      end: 12,
      child: Row(
        children: [
          ArGlassButton(icon: ArIcons.back, label: 'ar.common.back'.getString(context), onTap: () => context.pop()),
          const SizedBox(width: 8),
          Expanded(
            child: Center(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (placed) const ArSessionBadge(compact: true, withSync: true),
                  if (demo)
                    ArDemoBanner(
                      onExit: () async {
                        await ref.read(arPrefsProvider.notifier).setDemo(false);
                        await ref.read(arSessionProvider.notifier).restart();
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 56),
        ],
      ),
    );
  }
}

class _Starting extends StatelessWidget {
  const _Starting({required this.phase});
  final ArSessionPhase phase;

  @override
  Widget build(BuildContext context) {
    final key = phase == ArSessionPhase.loading ? 'ar.session.loading_floor' : 'ar.session.starting';
    return ColoredBox(
      color: Colors.black26,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: ArChromeStyle.of(context).surface(strong: true),
            borderRadius: BorderRadius.circular(18),
            border: ArChromeStyle.of(context).border(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: FeArColors.snap),
              ),
              const SizedBox(width: 12),
              AppText.bodyMedium(key.getString(context), color: Colors.white, weight: FontWeight.w600),
            ],
          ),
        ),
      ),
    );
  }
}

/// AR paused itself to save power: no movement for 2 minutes, or the phone
/// reported a severe thermal status. The camera and tracking are stopped; a
/// tap brings them back (tracking relocalises and anchors keep the model).
class _PowerPaused extends ConsumerWidget {
  const _PowerPaused({required this.reason});
  final String reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hot = reason == 'hot';
    return Material(
      color: Colors.black.withValues(alpha: 0.78),
      child: InkWell(
        onTap: () => ref.read(arSessionProvider.notifier).resume(),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(hot ? Icons.thermostat_rounded : Icons.battery_saver_rounded, color: Colors.white, size: 48),
                const SizedBox(height: 14),
                AppText.titleMedium(
                  (hot ? 'ar.power.hot_title' : 'ar.power.idle_title').getString(context),
                  color: Colors.white,
                  weight: FontWeight.w800,
                  align: TextAlign.center,
                ),
                const SizedBox(height: 6),
                AppText.bodyMedium(
                  (hot ? 'ar.power.hot_body' : 'ar.power.idle_body').getString(context),
                  color: Colors.white70,
                  align: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ArPrimaryButton(
                  label: 'ar.power.resume'.getString(context),
                  icon: ArIcons.sync,
                  onPressed: () => ref.read(arSessionProvider.notifier).resume(),
                ),
                if (hot) ...[
                  const SizedBox(height: 10),
                  // Some jobs must be finished in one go: the user can take
                  // the risk; the OS's emergency level still pauses.
                  TextButton(
                    onPressed: () => ref.read(arSessionProvider.notifier).continueDespiteHeat(),
                    style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
                    child: AppText.label('ar.power.continue_anyway'.getString(context), color: Colors.white, weight: FontWeight.w700),
                  ),
                  AppText.caption('ar.power.continue_note'.getString(context), color: Colors.white60, align: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

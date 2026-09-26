import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ar/alignment_estimator.dart';
import '../../state/ar_engine_bridge.dart';
import '../../state/ar_install_controller.dart';
import '../../state/ar_prefs_controller.dart';
import '../../state/ar_session_controller.dart';
import '../../state/ar_setup_controller.dart';
import '../../state/ar_workspace_controller.dart';
import '../../theme/fe_ar_colors.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/tech_popup.dart';
import 'ar_ui.dart';
import 'install/ar_install_check_overlay.dart';
import 'setup/ar_setup_overlay.dart';
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
    await ref.read(arSessionProvider.notifier).start(_args);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = ref.read(arSessionProvider.notifier);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      session.pause();
    } else if (state == AppLifecycleState.resumed) {
      session.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (widget.installCode != null) ref.watch(arInstallProvider.select((x) => x.phase));

    if (widget.floorId.isEmpty) {
      return const Scaffold(
        body: ArUnsupportedView(reason: null, errorKey: 'ar.error.no_floor', floorId: null),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: FeArColors.cameraFloor,
        resizeToAvoidBottomInset: false,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final tablet = arIsTablet(constraints);
            final size = constraints.biggest;
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

            return Stack(
              children: [
                Positioned.fill(child: _Camera(demo: s.demo, step: step)),
                if (!running) Positioned.fill(child: _Starting(phase: s.phase)),
                if (running && widget.installCode != null)
                  Positioned.fill(child: ArInstallCheckOverlay(tablet: tablet, topInset: topInset))
                else if (running && s.stage == ArSessionStage.setup)
                  Positioned.fill(child: ArSetupOverlay(tablet: tablet, topInset: topInset)),
                if (working)
                  Positioned.fill(child: ArWorkspace(tablet: tablet, viewSize: size, onBack: () => context.pop()))
                else
                  _SetupTopBar(demo: s.demo, placed: s.isPlaced, tablet: tablet),
              ],
            );
          },
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
        opacity: ws.layers.opacity,
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
          decoration: BoxDecoration(color: FeArColors.glassStrong, borderRadius: BorderRadius.circular(18)),
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

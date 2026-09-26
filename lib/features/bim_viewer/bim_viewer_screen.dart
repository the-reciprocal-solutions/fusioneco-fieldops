import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/bim_viewer/bim_view_engine.dart';
import '../../state/bim_viewer_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../ar/ar_ui.dart';
import '../ar/widgets/ar_chrome.dart' show ArDemoBanner;
import 'bim_plan_view.dart';
import 'webview_bim_view_engine.dart';

/// Makes the 3D engine. Overridden in widget tests with a
/// [FakeBimViewEngine] (a WebView can't run under `flutter test`).
final bimViewEngineFactoryProvider = Provider<BimViewEngine Function()>((ref) => () => WebViewBimViewEngine());

/// The 2D/3D model viewer (docs/bim-viewer.md) — Dalux-style: the floor's
/// model in 3D (orbit or walk) over its plan in 2D, a position dot and view
/// cone on the plan that follow the camera, and a plan tap that moves the
/// camera there. Opened from an asset (framed and highlighted) or a floor.
///
/// Added alongside [TwinScreen] (the web's xeokit twin in a WebView), not
/// instead of it: that page stays as it was. This one ships in the app,
/// reads the offline floor pack the AR screens already download, and
/// works with no signal.
class BimViewerScreen extends ConsumerStatefulWidget {
  const BimViewerScreen({super.key, required this.floorId, this.assetId, this.assetName});

  final String floorId;
  final String? assetId;
  final String? assetName;

  @override
  ConsumerState<BimViewerScreen> createState() => _BimViewerScreenState();
}

class _BimViewerScreenState extends ConsumerState<BimViewerScreen> {
  late final BimViewEngine _engine;
  late final BimViewerController _controller;
  var _engineStarted = false;

  @override
  void initState() {
    super.initState();
    _engine = ref.read(bimViewEngineFactoryProvider)();
    _controller = ref.read(bimViewerProvider.notifier);
    // After this frame: Riverpod forbids changing provider state while the
    // tree builds (initState is inside it). Attach BEFORE start, so the
    // engine's ready event can't fire into a stream nobody listens to yet.
    scheduleMicrotask(() {
      if (!mounted) return;
      _controller.attach(_engine);
      unawaited(_engine.start().then((_) {
        if (mounted) setState(() => _engineStarted = true);
      }));
      unawaited(_controller.open(floorId: widget.floorId, assetId: widget.assetId, assetName: widget.assetName));
    });
  }

  @override
  void dispose() {
    _controller.detach();
    unawaited(_engine.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(bimViewerProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark != s.dark) scheduleMicrotask(() => _controller.setDark(dark));
    final title = s.floor?.floorName.isNotEmpty == true ? s.floor!.floorName : 'bim_viewer.title'.getString(context);

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: title,
        actions: [
          IconButton(
            tooltip: 'bim_viewer.layers'.getString(context),
            icon: const Icon(LucideIcons.layers),
            onPressed: s.floor == null ? null : () => _showLayers(context),
          ),
          IconButton(
            tooltip: 'bim_viewer.reset_view'.getString(context),
            icon: const Icon(LucideIcons.rotateCcw),
            onPressed: s.engineReady ? _controller.resetView : null,
          ),
        ],
      ),
      body: SafeArea(top: false, child: _body(context, s)),
    );
  }

  Widget _body(BuildContext context, BimViewerState s) {
    if (s.errorKey != null && s.floor == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TechEmptyState(icon: LucideIcons.wifiOff, title: s.errorKey!.getString(context)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _controller.open(floorId: widget.floorId, assetId: widget.assetId, assetName: widget.assetName),
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: AppText.label('common.retry'.getString(context)),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _Toolbar(state: s, controller: _controller),
        if (s.isDemo)
          const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: Align(alignment: Alignment.centerLeft, child: ArDemoBanner())),
        if (s.needsDownload || s.downloading != null || s.downloadErrorKey != null)
          _DownloadBanner(state: s, onDownload: _controller.download),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _panes(context, s)),
              if (s.loading) const Center(child: CircularProgressIndicator()),
              if (s.selection != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: _SelectionCard(selection: s.selection!, onClose: _controller.clearSelection),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _panes(BuildContext context, BimViewerState s) {
    final model = _ModelPane(engine: _engine, started: _engineStarted, state: s, controller: _controller);
    final plan = _PlanPane(state: s, controller: _controller);
    switch (s.layout) {
      case BimViewLayout.model:
        return model;
      case BimViewLayout.plan:
        return plan;
      case BimViewLayout.split:
        return LayoutBuilder(builder: (context, c) {
          final landscape = c.maxWidth > c.maxHeight;
          const divider = SizedBox(width: 2, height: 2, child: ColoredBox(color: FeColors.line));
          return landscape
              ? Row(children: [Expanded(flex: 11, child: model), divider, Expanded(flex: 9, child: plan)])
              : Column(children: [Expanded(flex: 11, child: model), divider, Expanded(flex: 9, child: plan)]);
        });
      case BimViewLayout.pip:
        // The 3D view full-bleed with the plan as a small overlay. `BimPipCorner`
        // and `BimPipSize` already exist in bim_viewer_prefs.dart (with a
        // remembered choice and a `cornerNearest` helper for a drag gesture),
        // but this screen never wired a drag onto the box or read the
        // remembered corner/size back out of `BimViewerPrefs` — this is a
        // static default (bottom end-corner, medium size) so the layout is at
        // least usable and RTL-correct, not the finished picture-in-picture UX.
        return LayoutBuilder(builder: (context, c) {
          final short = c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight;
          final side = short * BimPipSize.medium.share;
          return Stack(
            fit: StackFit.expand,
            children: [
              model,
              PositionedDirectional(
                end: 12,
                bottom: 12,
                width: side,
                height: side,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: FeColors.line, width: 2),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8)],
                  ),
                  child: ClipRRect(borderRadius: BorderRadius.circular(8), child: plan),
                ),
              ),
            ],
          );
        });
    }
  }

  Future<void> _showLayers(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        backgroundColor: FeColors.panel,
        builder: (_) => _LayersSheet(controller: _controller),
      );
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.state, required this.controller});

  final BimViewerState state;
  final BimViewerController controller;

  @override
  Widget build(BuildContext context) {
    final layouts = state.model3dAvailable ? BimViewLayout.values : const [BimViewLayout.plan];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<BimViewLayout>(
              segments: [
                for (final l in layouts)
                  ButtonSegment(
                    value: l,
                    icon: Icon(switch (l) {
                      BimViewLayout.split => LucideIcons.columns2,
                      BimViewLayout.pip => LucideIcons.pictureInPicture2,
                      BimViewLayout.model => LucideIcons.box,
                      BimViewLayout.plan => LucideIcons.map,
                    }, size: 16),
                    label: Text('bim_viewer.layout_${l.name}'.getString(context)),
                  ),
              ],
              selected: {state.layout},
              showSelectedIcon: false,
              onSelectionChanged: (v) => controller.setLayout(v.first),
            ),
          ),
          if (state.layout != BimViewLayout.plan) ...[
            const SizedBox(width: 8),
            SegmentedButton<BimCameraMode>(
              segments: [
                ButtonSegment(
                  value: BimCameraMode.orbit,
                  icon: const Icon(LucideIcons.rotateCw, size: 16),
                  tooltip: 'bim_viewer.orbit'.getString(context),
                ),
                ButtonSegment(
                  value: BimCameraMode.walk,
                  icon: const Icon(LucideIcons.footprints, size: 16),
                  tooltip: 'bim_viewer.walk'.getString(context),
                ),
              ],
              selected: {state.camera},
              showSelectedIcon: false,
              onSelectionChanged: (v) => controller.setCamera(v.first),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelPane extends StatelessWidget {
  const _ModelPane({required this.engine, required this.started, required this.state, required this.controller});

  final BimViewEngine engine;
  final bool started;
  final BimViewerState state;
  final BimViewerController controller;

  @override
  Widget build(BuildContext context) {
    if (!state.model3dAvailable) {
      return Center(
        child: TechEmptyState(
          icon: LucideIcons.triangleAlert,
          title: 'bim_viewer.no_3d_title'.getString(context),
          subtitle: 'bim_viewer.no_3d_subtitle'.getString(context),
        ),
      );
    }
    final loadingTiles = state.tilesTotal > 0 && !state.tilesDone;
    return Stack(
      children: [
        Positioned.fill(child: started ? engine.buildView(context) : const SizedBox.expand()),
        if (!state.engineReady) const Center(child: CircularProgressIndicator()),
        if (loadingTiles)
          Positioned(
            top: 10,
            left: 10,
            child: _Pill(
              icon: LucideIcons.download,
              text: arTr(context, 'bim_viewer.tiles_loading', [state.tilesLoaded, state.tilesTotal]),
            ),
          ),
        if (state.engineReady && state.usesMassing && state.floor != null && !state.isDemo && state.layers.architectureSolid)
          Positioned(
            top: loadingTiles ? 44 : 10,
            left: 10,
            right: 10,
            child: Align(
              alignment: Alignment.topLeft,
              child: _Pill(icon: LucideIcons.info, text: 'bim_viewer.walls_from_plan'.getString(context)),
            ),
          ),
        if (state.camera == BimCameraMode.walk && state.engineReady)
          Positioned(
            top: 10,
            right: 10,
            child: _Pill(icon: LucideIcons.info, text: 'bim_viewer.walk_hint'.getString(context)),
          ),
      ],
    );
  }
}

class _PlanPane extends StatelessWidget {
  const _PlanPane({required this.state, required this.controller});

  final BimViewerState state;
  final BimViewerController controller;

  @override
  Widget build(BuildContext context) {
    final plan = state.plan;
    final grid = state.floor?.gridLines ?? const [];
    if (plan == null && grid.isEmpty && !state.loading) {
      return Center(
        child: TechEmptyState(
          icon: LucideIcons.map,
          title: 'bim_viewer.no_plan_title'.getString(context),
          subtitle: 'bim_viewer.no_plan_subtitle'.getString(context),
        ),
      );
    }
    final pose = state.pose;
    final room = pose == null ? null : plan?.spaceAt(pose.planPoint.x, pose.planPoint.y);
    return Stack(
      children: [
        Positioned.fill(
          child: BimPlanView(
            plan: plan,
            bounds: state.bounds,
            gridLines: grid,
            pose: state.layout == BimViewLayout.plan ? null : pose,
            selection: state.selection,
            follow: state.camera == BimCameraMode.walk,
            onTap: (p, tol) => controller.tapPlan(p, toleranceM: tol),
          ),
        ),
        if (room != null && room.name.trim().isNotEmpty && state.layout == BimViewLayout.split)
          Positioned(
            top: 8,
            left: 8,
            child: _Pill(icon: LucideIcons.mapPin, text: arTr(context, 'bim_viewer.you_are_in', [room.name])),
          ),
      ],
    );
  }
}

class _DownloadBanner extends StatelessWidget {
  const _DownloadBanner({required this.state, required this.onDownload});

  final BimViewerState state;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final p = state.downloading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TechCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Icon(p != null ? LucideIcons.download : LucideIcons.cloudDownload, color: FeColors.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText.bodyMedium(
                    (p != null ? 'bim_viewer.downloading' : 'bim_viewer.download_title').getString(context),
                    weight: FontWeight.w700,
                  ),
                  const SizedBox(height: 2),
                  if (p != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(value: p.fraction, minHeight: 4),
                    )
                  else if (state.downloadErrorKey != null)
                    AppText.caption(state.downloadErrorKey!.getString(context), color: FeColors.danger)
                  else
                    AppText.caption(
                      arTr(context, 'bim_viewer.download_subtitle', [arMegabytes(context, state.missingBytes)]),
                      color: FeColors.ink2,
                    ),
                ],
              ),
            ),
            if (p == null && state.needsDownload) ...[
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onDownload,
                style: FilledButton.styleFrom(backgroundColor: FeColors.primary),
                child: AppText.label('bim_viewer.download'.getString(context), color: Colors.white, weight: FontWeight.w700),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SelectionCard extends StatelessWidget {
  const _SelectionCard({required this.selection, required this.onClose});

  final BimSelection selection;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final sub = [selection.ifcType, selection.discipline].where((v) => v != null && v.isNotEmpty).join(' · ');
    final assetId = selection.assetId;
    return TechCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: FeColors.warning.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(LucideIcons.box, size: 16, color: FeColors.warning),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText.bodyMedium(selection.name, weight: FontWeight.w800, maxLines: 1, overflow: TextOverflow.ellipsis),
                AppText.caption(
                  assetId == null
                      ? [if (sub.isNotEmpty) sub, 'bim_viewer.not_linked'.getString(context)].join(' · ')
                      : sub,
                  color: FeColors.ink2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (assetId != null)
            TextButton(
              onPressed: () => context.push(Routes.assetDetail(assetId)),
              child: AppText.label('bim_viewer.open_asset'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
            ),
          IconButton(
            tooltip: 'common.clear'.getString(context),
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _LayersSheet extends ConsumerWidget {
  const _LayersSheet({required this.controller});

  final BimViewerController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(bimViewerProvider);
    final l = s.layers;
    Widget row(IconData icon, String key, bool value, BimLayerState Function(bool) apply, {String? hintKey}) =>
        SwitchListTile(
          secondary: Icon(icon, size: 20, color: FeColors.ink2),
          title: AppText.bodyMedium(key.getString(context), weight: FontWeight.w600),
          subtitle: hintKey == null ? null : AppText.caption(hintKey.getString(context), color: FeColors.ink2),
          value: value,
          onChanged: (v) => controller.setLayers(apply(v)),
        );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: AppText.title('bim_viewer.layers'.getString(context)),
            ),
            row(LucideIcons.fan, 'bim_viewer.layer_mep', l.mep, (v) => l.copyWith(mep: v)),
            row(LucideIcons.building2, 'bim_viewer.layer_structure', l.structure, (v) => l.copyWith(structure: v)),
            row(
              LucideIcons.brickWall,
              'bim_viewer.layer_walls',
              l.architectureSolid,
              (v) => l.copyWith(architectureSolid: v),
              hintKey: s.usesMassing ? 'bim_viewer.walls_from_plan' : null,
            ),
            row(LucideIcons.penLine, 'bim_viewer.layer_outlines', l.architecture, (v) => l.copyWith(architecture: v)),
            row(LucideIcons.scanEye, 'bim_viewer.layer_xray', l.xray, (v) => l.copyWith(xray: v)),
            row(LucideIcons.scissors, 'bim_viewer.layer_cut', l.cut, (v) => l.copyWith(cut: v), hintKey: 'bim_viewer.layer_cut_hint'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: FeColors.ink.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(child: AppText.caption(text, color: Colors.white, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

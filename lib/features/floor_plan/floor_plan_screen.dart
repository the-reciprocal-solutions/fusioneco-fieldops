import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/network/api_exception.dart';
import '../../data/floor_plan_repository.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// FR-2.8 — the floor plan for [assetId]'s floor, pannable/zoomable, with
/// the asset's own position pinned on it when one has been recorded.
///
/// Never fetched per scan — the image is a few MB. It reaches the device
/// either when a route covering this floor is downloaded
/// (`RouteFloorPlanPrefetcher`) or the first time it is opened here online;
/// after that [FloorPlanImageCache] keeps it on disk, so it shows offline.
class FloorPlanScreen extends ConsumerStatefulWidget {
  const FloorPlanScreen({
    super.key,
    required this.floorId,
    required this.assetId,
    this.assetName,
    this.assetReferenceId,
    this.assetType,
  });

  final String floorId;
  final String assetId;
  final String? assetName;
  final String? assetReferenceId;
  final String? assetType;

  @override
  ConsumerState<FloorPlanScreen> createState() => _FloorPlanScreenState();
}

enum _LoadState { loading, noPlan, offlineNotCached, error, ready }

class _FloorPlanScreenState extends ConsumerState<FloorPlanScreen> {
  _LoadState _state = _LoadState.loading;
  FloorPlanRecord? _record;
  File? _imageFile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _LoadState.loading);

    FloorPlanRecord? record;
    try {
      record = await ref.read(floorPlanRepositoryProvider).get(widget.floorId);
    } on NetworkFailure {
      // No signal and this floor was never downloaded. Not "no plan" — it
      // may well have one (caught on device: offline read as "No floor
      // plan available").
      if (mounted) setState(() => _state = _LoadState.offlineNotCached);
      return;
    } catch (_) {
      if (mounted) setState(() => _state = _LoadState.error);
      return;
    }

    if (!mounted) return;

    final imageUrl = record?.imageUrl;
    if (record == null || imageUrl == null) {
      setState(() {
        _record = record;
        _state = _LoadState.noPlan;
      });
      return;
    }

    final cache = ref.read(floorPlanImageCacheProvider);

    // Offline-first: a copy already on disk is shown without ever touching
    // the network, same as every other cached read in this app. A disk
    // read failing outright (corrupt cache dir, permissions) is distinct
    // from "not downloaded yet" below, so it gets its own state rather than
    // being misreported as an offline/network problem.
    File? cached;
    try {
      cached = await cache.cached(imageUrl);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _record = record;
        _state = _LoadState.error;
      });
      return;
    }
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _record = record;
        _imageFile = cached;
        _state = _LoadState.ready;
      });
      return;
    }

    try {
      final file = await cache.getOrDownload(imageUrl);
      if (!mounted) return;
      setState(() {
        _record = record;
        _imageFile = file;
        _state = _LoadState.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _record = record;
        _state = _LoadState.offlineNotCached;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        showBack: true,
        title: widget.assetName ?? 'floorPlan.title'.getString(context),
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_state) {
      case _LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.noPlan:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: TechEmptyState(
            icon: LucideIcons.map,
            title: 'floorPlan.no_plan_title'.getString(context),
            subtitle: 'floorPlan.no_plan_subtitle'.getString(context),
          ),
        );
      case _LoadState.offlineNotCached:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: TechEmptyState(
            icon: LucideIcons.wifiOff,
            title: 'floorPlan.offline_title'.getString(context),
            subtitle: 'floorPlan.offline_subtitle'.getString(context),
          ),
        );
      case _LoadState.error:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: TechEmptyState(
            icon: LucideIcons.circleAlert,
            title: 'floorPlan.error_title'.getString(context),
          ),
        );
      case _LoadState.ready:
        return _PlanView(
          file: _imageFile!,
          pin: _record?.pinFor(widget.assetId),
          notPinnedLabel: 'floorPlan.not_pinned'.getString(context),
          assetName: widget.assetName,
          assetReferenceId: widget.assetReferenceId,
          assetType: widget.assetType,
        );
    }
  }
}

class _PlanView extends StatefulWidget {
  const _PlanView({
    required this.file,
    required this.pin,
    required this.notPinnedLabel,
    this.assetName,
    this.assetReferenceId,
    this.assetType,
  });

  final File file;
  final FloorPin? pin;
  final String notPinnedLabel;
  final String? assetName;
  final String? assetReferenceId;
  final String? assetType;

  @override
  State<_PlanView> createState() => _PlanViewState();
}

class _PlanViewState extends State<_PlanView> {
  final _transform = TransformationController();
  final _viewportKey = GlobalKey();
  ui.Image? _decoded;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final bytes = await widget.file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _decoded = frame.image);
    // Without this, InteractiveViewer opens showing the plan at its native
    // pixel size — for any plan bigger than the phone's screen (the normal
    // case) that is a corner of the image, cropped, not "the floor plan".
    // Fitting it to the viewport on first open is what makes this read as
    // a floor plan rather than a broken close-up.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToViewport());
  }

  void _fitToViewport() {
    final image = _decoded;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (image == null || box == null || !box.hasSize) return;
    final viewport = box.size;
    final scale = (viewport.width / image.width).clamp(0.02, 10.0);
    final scaledHeight = image.height * scale;
    final dy = scaledHeight < viewport.height ? (viewport.height - scaledHeight) / 2 : 0.0;
    // Column-major: scale on the diagonal, dy in the translation column —
    // equivalent to "scale first, then translate by dy screen pixels".
    _transform.value = Matrix4(
      scale, 0, 0, 0,
      0, scale, 0, 0,
      0, 0, 1, 0,
      0, dy, 0, 1,
    );
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _decoded;
    return Stack(
      key: _viewportKey,
      children: [
        if (image == null)
          const Center(child: CircularProgressIndicator())
        else
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transform,
              // The plan is panned/zoomed at its own pixel size (set below),
              // not squeezed to fit the viewport by default — that default
              // is what was previously making everything past one screen's
              // width unreachable no matter how the image was framed.
              constrained: false,
              minScale: 0.02,
              maxScale: 8,
              child: SizedBox(
                width: image.width.toDouble(),
                height: image.height.toDouble(),
                child: Image.file(widget.file, fit: BoxFit.fill),
              ),
            ),
          ),
        // A screen-space overlay, deliberately NOT a child of
        // InteractiveViewer: a marker is a *label* for a point on the map,
        // not part of the map's own content, so — same as a pin on Google
        // Maps — it stays one constant, legible size at every zoom level
        // instead of shrinking to an unreadable dot when the plan is
        // zoomed out to fit the screen, or ballooning when zoomed in.
        // Its position still has to track the map exactly, so it listens
        // to the same [_transform] InteractiveViewer is driving and
        // reprojects the pin's fixed image-space point through the current
        // matrix on every pan/zoom frame.
        if (widget.pin != null && image != null)
          AnimatedBuilder(
            animation: _transform,
            builder: (context, _) {
              final local = Offset(
                widget.pin!.xPct / 100 * image.width,
                widget.pin!.yPct / 100 * image.height,
              );
              final screen = MatrixUtils.transformPoint(_transform.value, local);
              return Positioned(
                left: screen.dx - 13,
                top: screen.dy - 13,
                child: const IgnorePointer(child: _PinMarker()),
              );
            },
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.pin == null) ...[
                _NotPinnedBanner(label: widget.notPinnedLabel),
                const SizedBox(height: 10),
              ],
              if (widget.assetName != null || widget.assetReferenceId != null)
                _AssetInfoCard(
                  name: widget.assetName,
                  referenceId: widget.assetReferenceId,
                  type: widget.assetType,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The minimal "which asset am I looking at" reminder — name, reference id
/// and type only, deliberately not the full identity block the detail
/// screen already showed a moment ago. This screen's job is the map; a
/// technician who wants the rest can go back to it.
class _AssetInfoCard extends StatelessWidget {
  const _AssetInfoCard({this.name, this.referenceId, this.type});

  final String? name;
  final String? referenceId;
  final String? type;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: FeColors.ink.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: FeColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(LucideIcons.box, size: 16, color: FeColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (name != null)
                  AppText.bodyMedium(
                    name!,
                    weight: FontWeight.w800,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                if (referenceId != null || type != null)
                  AppText.caption(
                    [referenceId, type].where((v) => v != null && v.isNotEmpty).join(' · '),
                    color: FeColors.ink2,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PinMarker extends StatelessWidget {
  const _PinMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: FeColors.primary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: FeColors.primary.withValues(alpha: 0.5),
            blurRadius: 8,
          ),
        ],
      ),
      child: const Icon(LucideIcons.mapPin, size: 14, color: Colors.white),
    );
  }
}

class _NotPinnedBanner extends StatelessWidget {
  const _NotPinnedBanner({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: FeColors.ink.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.info, size: 14, color: Colors.white),
          const SizedBox(width: 8),
          Flexible(
            child: AppText.bodySmall(label, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

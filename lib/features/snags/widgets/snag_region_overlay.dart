import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../domain/snag.dart';
import '../../../theme/fe_colors.dart';
import 'snag_visuals.dart';

/// Defect highlights drawn over a snag photo (owner request, iPhone test
/// 2026-10-06: "proper annotation highlights on the image captured").
///
/// Regions are normalised to the PHOTO (see [SnagRegion]), so drawing one
/// means working out where the photo itself landed inside the widget — with
/// `BoxFit.cover` part of the photo is cropped away, with `contain` it is
/// letterboxed. [snagRegionRect] does that, purely, and is unit-tested.
/// Photo space is never mirrored: in Arabic (RTL) a box sits on exactly the
/// same pixels, which is why the layer positions with absolute `left/top`
/// (never `PositionedDirectional`).

/// Where [r] lands inside a [boxSize] widget that paints an [imageSize] photo
/// with [fit] and [alignment]. Not clipped: with `cover` it can extend past
/// the box (the caller clips with [Rect.intersect]).
Rect snagRegionRect(
  SnagRegion r, {
  required Size imageSize,
  required Size boxSize,
  BoxFit fit = BoxFit.cover,
  Alignment alignment = Alignment.center,
}) {
  if (imageSize.isEmpty || boxSize.isEmpty) return Rect.zero;
  final fitted = applyBoxFit(fit, imageSize, boxSize);
  // Scale of the whole photo on screen (the fitted source may be a crop).
  final sx = fitted.destination.width / fitted.source.width;
  final sy = fitted.destination.height / fitted.source.height;
  final drawn = alignment.inscribe(Size(imageSize.width * sx, imageSize.height * sy), Offset.zero & boxSize);
  return Rect.fromLTWH(
    drawn.left + r.x * drawn.width,
    drawn.top + r.y * drawn.height,
    r.w * drawn.width,
    r.h * drawn.height,
  );
}

/// Severity colour of a highlight; an unrated one uses the AI accent.
Color snagRegionColor(SnagRegion r) =>
    r.severity == null ? FeColors.ai : SnagVisuals.priorityColor(r.severity!);

/// Puts [regions] over [child] (the photo, painted from [image] with [fit]).
///
/// - colour by severity, a label chip (issue type · severity) per box;
/// - a short, subtle double pulse the first time boxes appear (skipped when
///   the OS asks for reduced motion);
/// - [onDelete] adds a × to each chip so a technician can drop a wrong box;
/// - [compact] (thumbnails): thin outline, no chips.
///
/// [imageSize] skips resolving [image] for its size (tests, or a caller that
/// already knows it). Until the size is known nothing is drawn — a box in
/// the wrong place is worse than a box a frame late.
class SnagRegionLayer extends StatefulWidget {
  const SnagRegionLayer({
    super.key,
    required this.image,
    required this.regions,
    required this.child,
    this.fit = BoxFit.cover,
    this.visible = true,
    this.compact = false,
    this.onDelete,
    this.imageSize,
  });

  final ImageProvider image;
  final List<SnagRegion> regions;
  final Widget child;
  final BoxFit fit;
  final bool visible;
  final bool compact;
  final ValueChanged<int>? onDelete;
  final Size? imageSize;

  @override
  State<SnagRegionLayer> createState() => _SnagRegionLayerState();
}

class _SnagRegionLayerState extends State<SnagRegionLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _resolved;

  Size? get _size => widget.imageSize ?? _resolved;

  var _firstPulseDone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
    // Once: didChangeDependencies also runs on every MediaQuery change (the
    // keyboard opening), and the boxes must not pulse again for that.
    if (!_firstPulseDone && _shows(widget)) {
      _firstPulseDone = true;
      _startPulse();
    }
  }

  @override
  void didUpdateWidget(SnagRegionLayer old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
    if (_shows(widget) && !_shows(old)) {
      _firstPulseDone = true;
      _startPulse();
    }
  }

  static bool _shows(SnagRegionLayer w) => w.visible && w.regions.isNotEmpty;

  void _startPulse() {
    if (widget.compact) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _pulse.forward(from: 0);
  }

  void _resolve() {
    if (widget.imageSize != null) return;
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _unlisten();
    _listener = ImageStreamListener(
      (info, _) {
        final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
        if (mounted && size != _resolved) setState(() => _resolved = size);
      },
      onError: (_, _) {},
    );
    _stream = stream..addListener(_listener!);
  }

  void _unlisten() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _unlisten();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = _size;
    // passthrough: the photo gets exactly the constraints this layer got, so
    // wrapping an image that fills a StackFit.expand parent still fills it.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (size != null && _shows(widget))
          Positioned.fill(
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, c) {
                  final box = Size(c.maxWidth, c.maxHeight);
                  final bounds = Offset.zero & box;
                  final items = <Widget>[];
                  for (var i = 0; i < widget.regions.length; i++) {
                    final r = widget.regions[i];
                    final rect = snagRegionRect(r, imageSize: size, boxSize: box, fit: widget.fit).intersect(bounds);
                    if (rect.width < 4 || rect.height < 4) continue;
                    items.add(_RegionBox(key: ValueKey('region-$i'), region: r, rect: rect, pulse: _pulse, compact: widget.compact));
                    if (!widget.compact) {
                      items.add(_chip(context, i, r, rect, box));
                    }
                  }
                  return Stack(children: items);
                },
              ),
            ),
          ),
      ],
    );
  }

  /// The label chip sits just above the box, or inside its top edge when the
  /// box touches the top of the photo; it never leaves the photo.
  Widget _chip(BuildContext context, int i, SnagRegion r, Rect rect, Size box) {
    const chipH = 26.0;
    final top = rect.top >= chipH + 2 ? rect.top - chipH - 2 : rect.top + 2;
    final maxW = math.max(64.0, box.width - rect.left - 4);
    final left = math.min(rect.left, math.max(0.0, box.width - maxW));
    return Positioned(
      left: left,
      top: top,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: _RegionChip(
          region: r,
          onDelete: widget.onDelete == null ? null : () => widget.onDelete!(i),
        ),
      ),
    );
  }
}

class _RegionBox extends StatelessWidget {
  const _RegionBox({super.key, required this.region, required this.rect, required this.pulse, required this.compact});
  final SnagRegion region;
  final Rect rect;
  final Animation<double> pulse;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hue = snagRegionColor(region);
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Semantics(
          label: [
            SnagVisuals.issueLabel(context, region.label),
            if (region.severity != null) SnagVisuals.priorityLabel(context, region.severity!),
          ].join(', '),
          child: AnimatedBuilder(
            animation: pulse,
            builder: (context, _) {
              // Two soft bumps that fade out: noticeable once, then calm.
              final t = pulse.isAnimating ? pulse.value : 0.0;
              final glow = t == 0 ? 0.0 : (1 - t) * (0.5 - 0.5 * math.cos(t * 4 * math.pi));
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: hue.withValues(alpha: compact ? 0.08 : 0.12 + 0.12 * glow),
                  borderRadius: BorderRadius.circular(compact ? 3 : 8),
                  border: Border.all(color: hue, width: compact ? 1.5 : 2.5),
                  boxShadow: [
                    if (!compact)
                      BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 3),
                    if (glow > 0)
                      BoxShadow(color: hue.withValues(alpha: 0.6 * glow), blurRadius: 4 + 14 * glow, spreadRadius: 6 * glow),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RegionChip extends StatelessWidget {
  const _RegionChip({required this.region, this.onDelete});
  final SnagRegion region;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final hue = snagRegionColor(region);
    final text = [
      SnagVisuals.issueLabel(context, region.label),
      if (region.severity != null) SnagVisuals.priorityLabel(context, region.severity!),
    ].join(' · ');
    return Container(
      height: 26,
      padding: EdgeInsetsDirectional.only(start: 8, end: onDelete == null ? 8 : 0),
      decoration: BoxDecoration(
        color: hue,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800),
            ),
          ),
          if (onDelete != null)
            Semantics(
              button: true,
              label: 'snags.ai.region_remove'.getString(context),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDelete,
                child: const SizedBox(
                  width: 30,
                  height: 26,
                  child: Icon(LucideIcons.x, size: 14, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "2 highlighted" with an eye: shows or hides the highlights on a photo.
class SnagHighlightsToggle extends StatelessWidget {
  const SnagHighlightsToggle({super.key, required this.count, required this.visible, required this.onChanged});
  final int count;
  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: visible,
      child: GestureDetector(
        onTap: () => onChanged(!visible),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: FeColors.ai.withValues(alpha: 0.8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(visible ? LucideIcons.eye : LucideIcons.eyeOff, size: 14, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                snagTr(context, 'snags.ai.regions_count', [count]),
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo with its highlights and a show/hide toggle in the top corner —
/// the create step's AI panel and the full-screen viewer use it.
class SnagAnnotatedPhoto extends StatefulWidget {
  const SnagAnnotatedPhoto({
    super.key,
    required this.image,
    required this.regions,
    this.fit = BoxFit.cover,
    this.onDelete,
    this.height,
    this.radius = 14,
    this.imageSize,
  });

  final ImageProvider image;
  final List<SnagRegion> regions;
  final BoxFit fit;
  final ValueChanged<int>? onDelete;
  final double? height;
  final double radius;
  final Size? imageSize;

  @override
  State<SnagAnnotatedPhoto> createState() => _SnagAnnotatedPhotoState();
}

class _SnagAnnotatedPhotoState extends State<SnagAnnotatedPhoto> {
  var _visible = true;

  @override
  Widget build(BuildContext context) {
    final photo = SnagRegionLayer(
      image: widget.image,
      regions: widget.regions,
      fit: widget.fit,
      visible: _visible,
      onDelete: widget.onDelete,
      imageSize: widget.imageSize,
      child: SizedBox(
        width: double.infinity,
        height: widget.height,
        child: Image(image: widget.image, fit: widget.fit, gaplessPlayback: true),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Stack(
        children: [
          photo,
          if (widget.regions.isNotEmpty)
            PositionedDirectional(
              top: 8,
              end: 8,
              child: SnagHighlightsToggle(
                count: widget.regions.length,
                visible: _visible,
                onChanged: (v) => setState(() => _visible = v),
              ),
            ),
        ],
      ),
    );
  }
}

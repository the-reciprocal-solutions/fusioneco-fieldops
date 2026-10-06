import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/snag/snag_send_state.dart';
import '../../../domain/snag.dart';
import '../../../state/snag_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/fe_status_tokens.dart';
import '../../../theme/theme_extensions.dart';
import 'snag_region_overlay.dart';

/// Translates [key] and fills its `%a` slots. Arguments are stringified here
/// so call sites can pass counts directly.
String snagTr(BuildContext context, String key, [List<Object> args = const []]) {
  final text = key.getString(context);
  return args.isEmpty ? text : context.formatString(text, args.map((a) => '$a').toList());
}

/// One place that turns the snag vocabulary into icons, colours and words,
/// so the walk camera, the cards and the detail screen can never disagree.

abstract final class SnagVisuals {
  static IconData tradeIcon(String trade) => switch (trade) {
    'civil' => LucideIcons.brickWall,
    'finishes' => LucideIcons.paintRoller,
    'joinery' => LucideIcons.hammer,
    'doors-windows' => LucideIcons.doorOpen,
    'electrical' => LucideIcons.plugZap,
    'plumbing' => LucideIcons.droplets,
    'hvac' => LucideIcons.fan,
    'fire' => LucideIcons.flame,
    'lifts' => LucideIcons.arrowUpDown,
    'facade-roof' => LucideIcons.house,
    'external' => LucideIcons.trees,
    'low-current' => LucideIcons.cctv,
    'cleaning' => LucideIcons.sparkles,
    _ => LucideIcons.wrench,
  };

  static String tradeLabel(BuildContext context, String trade) =>
      'snags.trade.$trade'.getString(context);

  static String issueLabel(BuildContext context, String issue) =>
      'snags.issue.$issue'.getString(context);

  /// Severity rides the app's existing priority hues, so a critical snag and
  /// a critical work order read identically anywhere in the app.
  static Color priorityColor(SnagPriority p) => switch (p) {
    SnagPriority.critical => FeStatusHues.priorityCritical,
    SnagPriority.major => FeStatusHues.priorityHigh,
    SnagPriority.minor => FeStatusHues.priorityMedium,
    SnagPriority.cosmetic => FeStatusHues.priorityLow,
  };

  static String priorityLabel(BuildContext context, SnagPriority p) =>
      'snags.priority.${p.wire}'.getString(context);

  static Color statusColor(SnagStatus s) => switch (s) {
    SnagStatus.open => FeStatusHues.open,
    SnagStatus.inProgress => FeStatusHues.inProgress,
    SnagStatus.ready => FeStatusHues.onHold,
    SnagStatus.closed => FeStatusHues.completed,
    SnagStatus.waived => FeStatusHues.cancelled,
  };

  static String statusLabel(BuildContext context, SnagStatus s) =>
      'snags.status.${s.wire}'.getString(context);

  static String contextLabel(BuildContext context, SnagContext c) =>
      'snags.context.${c.wire}'.getString(context);

  static IconData contextIcon(SnagContext c) => switch (c) {
    SnagContext.construction => LucideIcons.hardHat,
    SnagContext.fmTakeover => LucideIcons.keyRound,
    SnagContext.dlp => LucideIcons.shieldCheck,
    SnagContext.operations => LucideIcons.wrench,
    SnagContext.fitout => LucideIcons.armchair,
  };

  static IconData sendIcon(SnagSendState state) => switch (state) {
    SnagSendState.synced => LucideIcons.cloudCheck,
    SnagSendState.sending => LucideIcons.cloudUpload,
    SnagSendState.notSent => LucideIcons.cloudAlert,
    _ => LucideIcons.clock,
  };

  static Color sendColor(SnagSendState state) => switch (state) {
    SnagSendState.synced => FeColors.success,
    SnagSendState.sending => FeColors.info,
    SnagSendState.notSent => FeColors.danger,
    _ => FeColors.warning,
  };

  static FeChipStyle chip(Color hue) => FeChipStyle(
    background: Color.alphaBlend(hue.withValues(alpha: 0.12), Colors.white),
    foreground: hue,
    border: hue.withValues(alpha: 0.28),
  );
}

/// A snag photo from the best source available: this device's own copy,
/// then a downloaded copy, then the network. Offline with none of those, a
/// quiet placeholder rather than a broken-image icon.
///
/// Speed (2026-10-06): the file lookup is memoised per evidence (it used to
/// restart on every rebuild, and every snag write rebuilds the list, so each
/// thumbnail flashed blank), a known file paints on the first frame, and the
/// image is decoded at the size it is shown (`cacheWidth`) instead of the
/// full 1600 px capture — a 76 px list thumbnail no longer costs a full
/// decode each.
class SnagPhoto extends ConsumerStatefulWidget {
  const SnagPhoto({
    super.key,
    required this.evidence,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.radius = 0,
    this.dark = false,
    this.showRegions = false,
    this.compactRegions = false,
  });

  final SnagEvidence? evidence;
  final BoxFit fit;
  final double? width;
  final double? height;
  final double radius;
  final bool dark;

  /// Draw the evidence's kept defect highlights (2026-10-06) over the photo.
  final bool showRegions;

  /// Thumbnail style: outlines only, no chips.
  final bool compactRegions;

  @override
  ConsumerState<SnagPhoto> createState() => _SnagPhotoState();
}

class _SnagPhotoState extends ConsumerState<SnagPhoto> {
  Future<File?>? _file;
  String? _for;

  String? _keyOf(SnagEvidence? e) => e == null ? null : '${e.id}|${e.localPath}|${e.url}';

  Future<File?>? _lookup() {
    final e = widget.evidence;
    final key = _keyOf(e);
    if (key != _for || _file == null) {
      _for = key;
      _file = e == null ? null : ref.read(snagMediaProvider).localFile(e);
    }
    return _file;
  }

  int? _decodeWidth(BuildContext context) {
    final w = widget.width;
    if (w == null || !w.isFinite) return null;
    // ×2: with BoxFit.cover a landscape photo fills a square box by height,
    // so it needs up to ~1.8× the box width in pixels (16:9) to stay sharp.
    return (w * MediaQuery.devicePixelRatioOf(context) * 2).round();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.evidence;
    final width = widget.width;
    final height = widget.height;
    final placeholder = Container(
      width: width,
      height: height,
      color: widget.dark ? FeColors.ink : FeColors.line,
      alignment: Alignment.center,
      child: Icon(LucideIcons.imageOff, color: widget.dark ? Colors.white38 : FeColors.ink2, size: 20),
    );
    if (e == null) return _clip(placeholder);
    final cacheWidth = _decodeWidth(context);
    final known = ref.read(snagMediaProvider).peek(e);
    return _clip(
      FutureBuilder<File?>(
        future: _lookup(),
        initialData: known,
        builder: (context, snap) {
          final file = snap.data;
          final url = e.url;
          if (file == null && snap.connectionState != ConnectionState.done) {
            return SizedBox(width: width, height: height);
          }
          if (file == null && url == null) return placeholder;
          // One provider for the picture and for the highlight layer's size
          // lookup, so the photo is decoded once (same as Image.file /
          // Image.network with cacheWidth).
          final ImageProvider provider = ResizeImage.resizeIfNeeded(
            cacheWidth,
            null,
            file != null ? FileImage(file) : NetworkImage(url!) as ImageProvider,
          );
          final image = Image(
            image: provider,
            width: width,
            height: height,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
          if (!widget.showRegions || e.regions.isEmpty) return image;
          return SnagRegionLayer(
            image: provider,
            regions: e.regions,
            fit: widget.fit,
            compact: widget.compactRegions,
            child: image,
          );
        },
      ),
    );
  }

  Widget _clip(Widget child) =>
      widget.radius == 0 ? child : ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: child);
}

/// Four-way severity picker: coloured pills, big enough for a gloved thumb.
class SeveritySelector extends StatelessWidget {
  const SeveritySelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.dark = false,
    this.suggested,
  });

  final SnagPriority value;
  final ValueChanged<SnagPriority> onChanged;
  final bool dark;

  /// Marked with a ✨ when the assistant proposed it.
  final SnagPriority? suggested;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final p in SnagPriority.values) ...[
          Expanded(
            child: _SeverityPill(
              priority: p,
              selected: p == value,
              suggested: p == suggested,
              dark: dark,
              onTap: () => onChanged(p),
            ),
          ),
          if (p != SnagPriority.values.last) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _SeverityPill extends StatelessWidget {
  const _SeverityPill({
    required this.priority,
    required this.selected,
    required this.suggested,
    required this.dark,
    required this.onTap,
  });

  final SnagPriority priority;
  final bool selected;
  final bool suggested;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hue = SnagVisuals.priorityColor(priority);
    final idle = dark ? Colors.white.withValues(alpha: 0.08) : FeColors.page;
    return Semantics(
      button: true,
      selected: selected,
      label: SnagVisuals.priorityLabel(context, priority),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion.fast,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? hue : idle,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? hue : hue.withValues(alpha: 0.35), width: 1.4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : hue,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (suggested) ...[
                    const SizedBox(width: 3),
                    Icon(LucideIcons.sparkles, size: 10, color: selected ? Colors.white : hue),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                SnagVisuals.priorityLabel(context, priority),
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : (dark ? Colors.white : FeColors.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontally scrolling trade chips. [ordered] lets the caller put this
/// walk's most recent trades first — the next snag in a room is usually the
/// same trade as the last one.
class TradeChipRail extends StatelessWidget {
  const TradeChipRail({
    super.key,
    required this.value,
    required this.onChanged,
    this.ordered,
    this.dark = false,
    this.suggested,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final List<String>? ordered;
  final bool dark;
  final String? suggested;

  @override
  Widget build(BuildContext context) {
    final trades = ordered ?? kSnagTrades;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: trades.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final t = trades[i];
          final selected = t == value;
          final fg = selected ? Colors.white : (dark ? Colors.white : FeColors.ink);
          return GestureDetector(
            onTap: () => onChanged(t),
            child: AnimatedContainer(
              duration: context.motion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? FeColors.primary
                    : (dark ? Colors.white.withValues(alpha: 0.1) : FeColors.panel),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected ? FeColors.primary : (dark ? Colors.white24 : FeColors.line),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(SnagVisuals.tradeIcon(t), size: 16, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    SnagVisuals.tradeLabel(context, t),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                  ),
                  if (t == suggested) ...[
                    const SizedBox(width: 4),
                    Icon(LucideIcons.sparkles, size: 12, color: selected ? Colors.white : FeColors.warning),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Before/after with a draggable divider. The fastest way for a verifier to
/// see whether the crack is actually gone: drag across the same frame.
class CompareSlider extends StatefulWidget {
  const CompareSlider({super.key, required this.before, required this.after, this.height = 320});

  final SnagEvidence? before;
  final SnagEvidence? after;
  final double height;

  @override
  State<CompareSlider> createState() => _CompareSliderState();
}

class _CompareSliderState extends State<CompareSlider> {
  double _split = 0.5;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) =>
                setState(() => _split = (d.localPosition.dx / w).clamp(0.02, 0.98)),
            onTapDown: (d) => setState(() => _split = (d.localPosition.dx / w).clamp(0.02, 0.98)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SnagPhoto(evidence: widget.after, dark: true),
                  ClipRect(
                    clipper: _LeftClipper(_split),
                    child: SnagPhoto(evidence: widget.before, dark: true),
                  ),
                  Positioned(
                    left: w * _split - 1.5,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 3, color: Colors.white),
                  ),
                  Positioned(
                    left: w * _split - 18,
                    top: box.maxHeight / 2 - 18,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: FeElevation.md,
                      ),
                      child: const Icon(LucideIcons.chevronsLeftRight, size: 18, color: FeColors.ink),
                    ),
                  ),
                  Positioned(left: 10, top: 10, child: _Tag('snags.before'.getString(context))),
                  Positioned(right: 10, top: 10, child: _Tag('snags.after'.getString(context))),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  _LeftClipper(this.split);
  final double split;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * split, size.height);
  @override
  bool shouldReclip(_LeftClipper old) => old.split != split;
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
    child: Text(
      label.toUpperCase(),
      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8),
    ),
  );
}

/// Raised → Fixing → Ready → Verified, with the reopen loop shown as a
/// counter on the first step — `reopenedCount` is the number that ends
/// arguments about workmanship.
class SnagStatusStepper extends StatelessWidget {
  const SnagStatusStepper({super.key, required this.snag});
  final Snag snag;

  @override
  Widget build(BuildContext context) {
    final reached = switch (snag.status) {
      SnagStatus.open => 0,
      SnagStatus.inProgress => 1,
      SnagStatus.ready => 2,
      SnagStatus.closed => 3,
      SnagStatus.waived => 3,
    };
    final labels = [
      'snags.step_raised'.getString(context),
      'snags.step_fixing'.getString(context),
      'snags.step_ready'.getString(context),
      snag.status == SnagStatus.waived
          ? 'snags.status.waived'.getString(context)
          : 'snags.step_verified'.getString(context),
    ];
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 3,
                        color: i == 0 ? Colors.transparent : (i <= reached ? FeColors.primary : FeColors.line),
                      ),
                    ),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i <= reached ? FeColors.primary : FeColors.panel,
                            border: Border.all(color: i <= reached ? FeColors.primary : FeColors.line, width: 2),
                          ),
                          child: i < reached || (i == 3 && reached == 3)
                              ? const Icon(LucideIcons.check, size: 12, color: Colors.white)
                              : null,
                        ),
                        if (i == 0 && snag.reopenedCount > 0)
                          Positioned(
                            right: -12,
                            top: -8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: FeColors.danger,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '↺${snag.reopenedCount}',
                                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                      ],
                    ),
                    Expanded(
                      child: Container(
                        height: 3,
                        color: i == 3 ? Colors.transparent : (i < reached ? FeColors.primary : FeColors.line),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: i == reached ? FontWeight.w800 : FontWeight.w600,
                    color: i <= reached ? FeColors.ink : FeColors.ink2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

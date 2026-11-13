import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';

/// Press feedback for a tappable card/row: scales down on tap-down, springs
/// back on release or cancel. Layered *underneath* the widget's own
/// [InkWell]/[Material] so the ripple still shows — this only adds the
/// physical "it gave a little" feel the ripple alone doesn't convey.
///
/// Kept to `transform` (scale) only, never width/height, so it never
/// triggers a layout pass mid-animation (Quick Reference §7:
/// `transform-performance`).
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.enabled = true,
  });

  final Widget child;
  final double scale;

  /// Set false to render the plain child with no gesture layer at all — used
  /// where the caller already knows there is no [onTap] and a
  /// [GestureDetector] would otherwise swallow taps meant for children below.
  final bool enabled;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1.0,
        duration: context.motion.press,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Fade-up entrance for one item in a list, staggered by [index]. Every item
/// after the first `maxStaggerItems` fires at the same delay as that cap —
/// a 40-row list must not take a visible second to finish revealing itself
/// (Quick Reference §7: `excessive-motion`, `stagger-sequence`).
///
/// Runs once per mount; a rebuild of an already-visible item does not replay
/// it, so scrolling a `ListView` back into view never re-triggers the fade.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.maxStaggerItems = 8,
  });

  final int index;
  final Widget child;
  final int maxStaggerItems;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  // Matches FeMotion.entranceItem/staggerStep/spring. Not read via
  // `context.motion` here: initState() builds the AnimationController before
  // this element has finished mounting, and Theme.of(context) — which that
  // accessor wraps — throws if reached that early. These three tokens are
  // fixed constants that never actually vary by theme, so a literal copy
  // costs nothing and avoids the whole class of bug.
  static const _itemDuration = Duration(milliseconds: 380);
  static const _stepMs = 45;
  static const _springCurve = Cubic(0.16, 1, 0.3, 1);

  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _itemDuration);
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: _springCurve));

    final step = _stepMs * widget.index.clamp(0, widget.maxStaggerItems);
    Future.delayed(Duration(milliseconds: step), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _slide, child: widget.child),
  );
}

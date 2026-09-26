import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/fe_colors.dart';
import 'ar_engine.dart';
import 'channel_ar_engine.dart';

/// The AR camera surface. With a supported engine it hosts the native view
/// (`fusioneco/ar/view`: ARCore + Filament on Android, ARKit + Filament on
/// iOS; docs/ar-bim-overlay.md §6.3). Otherwise — Demo mode, a device
/// without AR, or a build without the plugin — it draws a calm stand-in
/// "camera" surface: a dark room with a perspective floor grid, so the
/// Flutter HUD on top reads exactly as it would over a real camera.
///
/// It carries no text: every string is the screen's (`ar.*` keys), and the
/// screen shows the Demo banner.
class ArView extends StatelessWidget {
  const ArView({
    super.key,
    this.supported = false,
    this.demo = false,
    this.creationParams,
    this.onPlatformViewCreated,
    this.child,
  });

  /// Convenience: native when [capabilities] says AR is supported.
  factory ArView.forCapabilities(
    ArCapabilities capabilities, {
    Key? key,
    bool demo = false,
    Map<String, dynamic>? creationParams,
    void Function(int id)? onPlatformViewCreated,
    Widget? child,
  }) =>
      ArView(
        key: key,
        supported: capabilities.supported && capabilities.platform != 'demo',
        demo: demo,
        creationParams: creationParams,
        onPlatformViewCreated: onPlatformViewCreated,
        child: child,
      );

  /// The native engine is available on this device.
  final bool supported;

  /// Force the stand-in surface even when AR is supported (Demo mode).
  final bool demo;

  /// Passed to the native view on creation.
  final Map<String, dynamic>? creationParams;
  final void Function(int id)? onPlatformViewCreated;

  /// Drawn on the stand-in surface only (Demo mode's simulated overlay).
  final Widget? child;

  bool get _native => supported && !demo && !kIsWeb;

  @override
  Widget build(BuildContext context) {
    if (_native) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          // AndroidView (texture-layer composition) + fe_ar's TextureView — the
          // only combination that shows the camera. Tried on device 2026-09-26:
          // Hybrid Composition merges Flutter's raster thread into the main
          // thread, which then owns the GL context every frame, and ARCore's
          // session.update fails with MissingGlContextException (black view);
          // HC + SurfaceView also stayed black. The EGL_BAD_ALLOC logged on a
          // window resize here did not stop rendering.
          return AndroidView(
            viewType: ChannelArEngine.viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: onPlatformViewCreated,
          );
        case TargetPlatform.iOS:
          return UiKitView(
            viewType: ChannelArEngine.viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: onPlatformViewCreated,
          );
        default:
          break;
      }
    }
    return _StandInSurface(child: child);
  }
}

class _StandInSurface extends StatelessWidget {
  const _StandInSurface({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            FeColors.ink,
            Color.alphaBlend(FeColors.primary.withValues(alpha: 0.18), FeColors.ink),
            FeColors.ink,
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const RepaintBoundary(child: CustomPaint(painter: _FloorGridPainter())),
          if (child != null) child!,
        ],
      ),
    );
  }
}

/// A perspective floor grid under a soft horizon, with a vignette.
class _FloorGridPainter extends CustomPainter {
  const _FloorGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final horizon = size.height * 0.42;
    final centreX = size.width / 2;
    final line = Paint()
      ..color = FeColors.primaryLight.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    // Lines running away from the viewer, converging on the horizon.
    const rays = 14;
    for (var i = -rays; i <= rays; i++) {
      final bottomX = centreX + i * size.width / 6;
      canvas.drawLine(Offset(centreX + i * 6, horizon), Offset(bottomX, size.height), line);
    }
    // Cross lines, closer together toward the horizon.
    for (var k = 1; k <= 12; k++) {
      final t = k / 12;
      final y = horizon + (size.height - horizon) * t * t;
      final fade = Paint()
        ..color = FeColors.primaryLight.withValues(alpha: 0.05 + 0.13 * t)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), fade);
    }

    // Horizon glow.
    final glow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          FeColors.primaryLight.withValues(alpha: 0),
          FeColors.primaryLight.withValues(alpha: 0.10),
          FeColors.primaryLight.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, horizon - 40, size.width, 80));
    canvas.drawRect(Rect.fromLTWH(0, horizon - 40, size.width, 80), glow);

    // Vignette, so HUD text at the edges stays legible.
    final vignette = Paint()
      ..shader = RadialGradient(
        radius: 0.9,
        colors: [
          FeColors.ink.withValues(alpha: 0),
          FeColors.ink.withValues(alpha: 0.55),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  @override
  bool shouldRepaint(covariant _FloorGridPainter oldDelegate) => false;
}

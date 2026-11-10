import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/capture/capture_services.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';

/// FR-3.10 — an in-app camera with a torch toggle and a bubble-level
/// overlay, for photographing equipment in dark plant rooms and framing
/// consistent shots square to the wall/panel. `PhotoCapture.takeJobPhoto`
/// (used everywhere else in the app) launches the OS's own camera app via
/// `image_picker` and hands back a finished photo — the app never sees a
/// live frame, so it has no way to draw a torch button or a level on top of
/// one. Both require owning the preview ourselves, hence a dedicated screen
/// built on the `camera` package instead of `image_picker`.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  var _torchOn = false;
  var _capturing = false;

  StreamSubscription<AccelerometerEvent>? _tiltSub;
  double _rollX = 0;
  double _pitchZ = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _tiltSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen((event) {
      if (!mounted) return;
      setState(() {
        _rollX = event.x;
        _pitchZ = event.z;
      });
    });
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _error = 'no camera');
        return;
      }
      final rear = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        rear,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // Android/iOS reclaim the camera hardware the moment the app goes
  // background — holding the controller open past that throws on the next
  // frame. Rebuilding it on resume is the same fix `camera`'s own docs
  // recommend for any screen that can be backgrounded mid-shot.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      setState(() => _controller = null);
    } else if (state == AppLifecycleState.resumed) {
      _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tiltSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    final next = !_torchOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {
      // No flash unit on this camera (e.g. the front lens) — nothing to
      // toggle, and not worth surfacing as an error.
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      final rawBytes = await file.readAsBytes();
      // FR-3.4 — downscale to 1600px on the long edge, same as every other
      // capture path in the app (see downscaleJpeg's doc comment for why
      // this one needs its own step). Off the main isolate: decoding and
      // re-encoding a full-res photo is real CPU work.
      final bytes = await compute(downscaleJpeg, rawBytes);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(CapturedPhoto(bytes: bytes, fileName: 'photo.jpg'));
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildPreview(context)),
            if (_controller != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: _LevelOverlay(rollX: _rollX, pitchZ: _pitchZ),
                ),
              ),
            PositionedDirectional(
              top: 4,
              start: 4,
              child: IconButton(
                icon: const Icon(LucideIcons.x, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            PositionedDirectional(
              top: 4,
              end: 4,
              child: IconButton(
                tooltip: _torchOn
                    ? 'fieldVerify.torch_off'.getString(context)
                    : 'fieldVerify.torch_on'.getString(context),
                icon: Icon(
                  _torchOn ? LucideIcons.flashlight : LucideIcons.flashlightOff,
                  color: _torchOn
                      ? FeColors.warning
                      : Colors.white.withValues(alpha: 0.8),
                ),
                onPressed: _controller == null ? null : _toggleTorch,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: GestureDetector(
                  onTap: (_capturing || _controller == null) ? null : _capture,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: _capturing ? 0.4 : 1),
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: _capturing
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: FeColors.primary,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppText(
            'fieldVerify.camera_unavailable'.getString(context),
            align: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: 1 / controller.value.aspectRatio,
        child: CameraPreview(controller),
      ),
    );
  }
}

/// A simple bubble level: the dot drifts off-centre as the phone tilts and
/// turns green within a few degrees of flat, matching the physical bubble
/// levels a crew would otherwise carry to frame a shot square to a panel.
class _LevelOverlay extends StatelessWidget {
  const _LevelOverlay({required this.rollX, required this.pitchZ});

  final double rollX;
  final double pitchZ;

  /// m/s², roughly six degrees off vertical — tight enough to mean
  /// something, loose enough that a steady hand can actually hit it.
  static const _levelThreshold = 1.0;

  @override
  Widget build(BuildContext context) {
    final level =
        rollX.abs() < _levelThreshold && pitchZ.abs() < _levelThreshold;
    return Center(
      child: SizedBox(
        width: 120,
        height: 120,
        child: CustomPaint(
          painter: _LevelPainter(rollX: rollX, pitchZ: pitchZ, level: level),
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({
    required this.rollX,
    required this.pitchZ,
    required this.level,
  });

  final double rollX;
  final double pitchZ;
  final bool level;

  /// Roughly free-fall g — well past any tilt a hand-held shot would ever
  /// produce, so it just bounds the dot to stay within the ring.
  static const _maxTilt = 9.8;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radius, ringPaint);
    canvas.drawLine(
      Offset(center.dx - 10, center.dy),
      Offset(center.dx + 10, center.dy),
      ringPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 10),
      Offset(center.dx, center.dy + 10),
      ringPaint,
    );

    final dx = (rollX / _maxTilt).clamp(-1.0, 1.0) * (radius - 10);
    final dy = (-pitchZ / _maxTilt).clamp(-1.0, 1.0) * (radius - 10);

    final bubblePaint = Paint()..color = level ? FeColors.success : Colors.white;
    canvas.drawCircle(center + Offset(dx, dy), 8, bubblePaint);
  }

  @override
  bool shouldRepaint(covariant _LevelPainter oldDelegate) =>
      oldDelegate.rollX != rollX ||
      oldDelegate.pitchZ != pitchZ ||
      oldDelegate.level != level;
}

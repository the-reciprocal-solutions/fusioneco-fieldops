import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../core/ar/marker_code.dart';
import '../../core/c2o/c2o_asset_resolver.dart';
import '../../core/c2o/route_pack.dart';
import '../../core/permit/permit_gas.dart';
import '../../core/utils/qr_payload.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/fe_header.dart';

/// Reads the QR stickers on assets, work orders and material bins, plus the
/// c2o field-verification tags — those resolve offline against the local
/// cache first (FR-1.1) rather than always opening the web asset page.
///
/// The two families behave differently on purpose. A general Asset/WorkOrder
/// hit never navigates on its own — it shows what it found and waits for a
/// deliberate tap, because jumping into an unrelated record mid-job loses
/// whatever the technician was doing. A c2o tag has nowhere disruptive to
/// jump to, so it runs in continuous mode instead (FR-1.2): the camera never
/// stops, each tag flashes its outcome and joins a running session log, and
/// the technician just keeps sweeping — that is the actual speed win over
/// the web page's one-scan-per-page-load flow.
class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key, this.activeRouteScope, this.activeRouteId});

  /// FR-5.4 — when set (reached via [Routes.scanForRoute]), a resolved c2o
  /// asset outside this route's downloaded asset ids is marked off-route
  /// instead of a plain resolve. Null for the ordinary entry points (the
  /// dashboard's Scan QR card, the scanner's own header icon) — off-route
  /// only means something once there is a specific route being walked.
  final RouteScope? activeRouteScope;
  final String? activeRouteId;

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  /// 400 ms between detections. QR for the general and c2o schemes, plus
  /// Code 128/39 for the older asset plates that predate QR tagging
  /// (FR-1.3) — those decode to a bare reference id, handled the same
  /// tokenless way as the general Asset label (see `c2o_scan_payload.dart`).
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 400,
    formats: const [
      BarcodeFormat.qrCode,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
    ],
  );

  /// Only our own codes are held on screen; external content is acted on and
  /// forgotten, so this is never a [ScannedExternal].
  ScannedRecord? _result;
  String? _resultRaw;

  /// FR-1.2 — every c2o tag scanned this session, most recent first. Unlike
  /// [_result] this never blocks the camera; it is a running log, not a
  /// pending confirmation.
  final _c2oHistory = <_C2oScanEntry>[];

  /// The most recent c2o outcome, shown briefly and cleared automatically —
  /// continuous mode means no tap is required to keep scanning.
  C2oResolution? _c2oFlash;

  /// FR-5.4 — whether [_c2oFlash] resolved outside the active route.
  var _c2oFlashOffRoute = false;
  Timer? _c2oFlashTimer;

  var _paused = false;
  var _processing = false;

  /// FR-5.4 — this route's downloaded asset ids, once loaded. Null while
  /// loading or when [ScannerScreen.activeRouteScope] is null — in either
  /// case off-route detection is simply off, never a false positive.
  Set<String>? _activeRouteAssetIds;

  /// The last value read, held for four seconds. A QR code sitting in frame
  /// re-decodes many times a second; without this the same sticker would fire
  /// the handler over and over.
  String? _lastScanned;
  Timer? _cooldown;

  @override
  void initState() {
    super.initState();
    _loadActiveRoute();
  }

  Future<void> _loadActiveRoute() async {
    final scope = widget.activeRouteScope;
    final id = widget.activeRouteId;
    if (scope == null || id == null) return;
    final routes = await ref.read(offlineDbProvider).listRoutePacks();
    final route = routes.where((r) => r.scope == scope && r.id == id).firstOrNull;
    if (mounted && route != null) {
      setState(() => _activeRouteAssetIds = route.assetIds.toSet());
    }
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _c2oFlashTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleRaw(String raw) async {
    if (_processing || raw == _lastScanned) return;

    setState(() {
      _processing = true;
      _lastScanned = raw;
    });
    _cooldown?.cancel();
    _cooldown = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _lastScanned = null);
    });

    // AR boards (docs/ar-markers-and-qr.md §5.1) come before C2O and the
    // general scheme: `HTTPS://<host>/M/<code>` opens the board's floor and
    // model. URL form only here — a bare 7-character plate passes the check
    // character by chance 1 time in 32, so bare codes are tried last, below,
    // after nothing else has claimed the value.
    final markerCode = MarkerCode.fromScan(raw, allowBare: false);
    if (markerCode != null) {
      await _buzz();
      if (!mounted) return;
      setState(() => _processing = false);
      // Replace, not push: back from the board sheet goes where the scan
      // came from, and the scanner can't re-read the same board behind it.
      context.pushReplacement(Routes.arMarker(markerCode));
      return;
    }

    // Permit to Work worksite QR (docs/permit-to-work.md): a URL scheme like
    // AR boards, so it is checked the same place, before C2O and the general
    // scheme claim the value. `permitCheckTokenFromScan` only matches
    // `/permit-check/<token>` — anything else falls through untouched, same
    // C2O/AR scan precedence CLAUDE.md documents.
    final permitToken = permitCheckTokenFromScan(raw);
    if (permitToken != null) {
      await _buzz();
      if (!mounted) return;
      setState(() => _processing = false);
      context.pushReplacement(Routes.permitByToken(permitToken));
      return;
    }

    // c2o tags are checked first — offline, against the local cache — before
    // falling through to the general scheme, which currently only ever opens
    // a web page and so cannot answer with the radio off (see FR-1.1).
    final c2oResult = await ref.read(c2oAssetResolverProvider).resolve(raw);
    if (!mounted) return;
    if (c2oResult != null) {
      await _buzz();
      if (!mounted) return;
      // FR-5.4 — still verifies normally; this only changes how it's shown.
      // A route with nothing loaded yet ([_activeRouteAssetIds] null) never
      // flags anything, so a plain scan (no active route) is unaffected.
      final offRoute = _activeRouteAssetIds != null &&
          c2oResult is C2oResolved &&
          !_activeRouteAssetIds!.contains(c2oResult.assetId);
      // Continuous mode (FR-1.2): join the session log and flash the
      // outcome, but never block — the camera keeps looking immediately.
      _c2oFlashTimer?.cancel();
      setState(() {
        _c2oHistory.insert(
          0,
          _C2oScanEntry(outcome: c2oResult, at: DateTime.now(), offRoute: offRoute),
        );
        _c2oFlash = c2oResult;
        _c2oFlashOffRoute = offRoute;
        _resultRaw = raw;
        _processing = false;
      });
      _c2oFlashTimer = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _c2oFlash = null);
      });
      return;
    }

    final resolution = resolveScannedValue(raw);
    await _buzz();
    if (!mounted) return;

    switch (resolution) {
      case final ScannedRecord record:
        // One of ours. Hold it on screen behind a confirm tap.
        setState(() {
          _result = record;
          _resultRaw = raw;
          _processing = false;
        });
      case ScannedExternal(:final value, :final isUrl):
        setState(() => _processing = false);
        if (isUrl) {
          await launchUrl(Uri.parse(value), mode: LaunchMode.externalApplication);
          if (mounted) _toast('scanner.opened_in_browser'.getString(context));
        } else {
          // A board's code typed or printed on its own ("7K3QX9-R"): only
          // now, after the C2O and general schemes passed on it.
          final bareMarker = MarkerCode.fromScan(value);
          if (bareMarker != null) {
            context.pushReplacement(Routes.arMarker(bareMarker));
            return;
          }
          // Not a link and not ours — show the text and let the person read it.
          _toast(value);
        }
    }
  }

  Future<void> _buzz() async {
    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(duration: 200);
      }
    } catch (_) {
      // A missing motor is not worth reporting.
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText(message)),
      );

  Future<void> _togglePause() async {
    if (_paused) {
      await _controller.start();
    } else {
      await _controller.stop();
    }
    if (mounted) setState(() => _paused = !_paused);
  }

  /// Decoding a photo covers the code that is behind a guard, above head
  /// height, or on a panel the camera cannot be held steady against.
  Future<void> _scanFromGallery() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;

    setState(() => _processing = true);
    try {
      final capture = await _controller.analyzeImage(file.path);
      final raw = capture?.barcodes
          .map((barcode) => barcode.rawValue)
          .whereType<String>()
          .firstOrNull;
      if (raw == null) {
        if (mounted) {
          setState(() => _processing = false);
          _toast('scanner.no_qr_in_picture'.getString(context));
        }
        return;
      }
      // A picked image is a deliberate act, so it bypasses the cooldown.
      _lastScanned = null;
      if (mounted) setState(() => _processing = false);
      await _handleRaw(raw);
    } catch (error) {
      if (mounted) {
        setState(() => _processing = false);
        _toast('scanner.picture_unreadable'.getString(context));
      }
    }
  }

  void _openResult() {
    final result = _result;
    if (result == null) return;

    if (result.isPublic) {
      // Asset and material sheets are web pages; there is no native screen.
      context.pushReplacement(
        Routes.webPage(
          '${Env.webBaseUrl}${result.path}',
          title: result.label,
        ),
      );
    } else {
      context.pushReplacement(result.path);
    }
  }

  void _resume() {
    setState(() {
      _result = null;
      _resultRaw = null;
    });
  }

  /// FR-2 — opens the native detail screen for a resolved scan. `push`, not
  /// `pushReplacement`, so continuous mode (FR-1.2) is still there, scanning,
  /// when the technician backs out.
  void _openAssetDetail(String assetId, String? name) {
    context.push(Routes.assetDetail(assetId));
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final flash = _c2oFlash;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: FeHeader(
        showBack: true,
        titleWidget: Row(
          children: [
            Container(
              height: 36,
              width: 36,
              decoration: BoxDecoration(
                color: FeColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(LucideIcons.qrCode, size: 18, color: FeColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppText.titleSmall(
                    'scanner.title'.getString(context),
                    weight: FontWeight.w700,
                    overflow: TextOverflow.ellipsis,
                  ),
                  AppText.caption(
                    _paused
                        ? 'scanner.paused'.getString(context)
                        : 'scanner.looking_for_code'.getString(context),
                    color: FeColors.ink2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable) {
                return const SizedBox.shrink();
              }
              final on = state.torchState == TorchState.on;
              // Ink, not white — this sits in the light header like the
              // search and route buttons beside it. White here rendered the
              // button invisible on device (FR-3.10).
              return IconButton(
                tooltip: on
                    ? 'scanner.torch_off'.getString(context)
                    : 'scanner.torch_on'.getString(context),
                icon: Icon(
                  on ? LucideIcons.flashlight : LucideIcons.flashlightOff,
                  size: 18,
                  color: on ? FeColors.warning : FeColors.ink,
                ),
                onPressed: _controller.toggleTorch,
              );
            },
          ),
          // FR-1.6 — reachable from the same screen a technician already
          // opens to identify an asset, for the case where there is no tag
          // left to point the camera at. FeHeader here is the light
          // `.standard` variant (only the body below it goes black for the
          // camera), so this needs an ink-coloured icon, not white.
          IconButton(
            tooltip: 'scanner.search'.getString(context),
            icon: const Icon(LucideIcons.search, size: 18, color: FeColors.ink),
            onPressed: () => context.push(Routes.c2oSearch),
          ),
          // FR-5.1 — download a route pack for offline use before walking
          // in; same screen as the scan/search entry points since all three
          // answer "what's my worklist" before signal is lost.
          IconButton(
            tooltip: 'scanner.routes'.getString(context),
            icon: const Icon(LucideIcons.mapPin, size: 18, color: FeColors.ink),
            onPressed: () => context.push(Routes.c2oRoutes),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(context.radii.scanner),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MobileScanner(
                            controller: _controller,
                            errorBuilder: (context, error) => _CameraError(
                              message: _describe(context, error),
                            ),
                            onDetect: (capture) {
                              // Only the general Asset/WorkOrder hit blocks
                              // detection — a c2o flash never does, that is
                              // the whole point of continuous mode (FR-1.2).
                              if (_paused || _processing || result != null) {
                                return;
                              }
                              final raw = capture.barcodes
                                  .map((barcode) => barcode.rawValue)
                                  .whereType<String>()
                                  .firstOrNull;
                              if (raw != null) _handleRaw(raw);
                            },
                          ),
                          const _Brackets(),
                          if (result != null)
                            _HitOverlay(
                              label: result.label,
                              detail: result.path,
                            ),
                          if (flash != null)
                            _C2oOutcomeOverlay(outcome: flash, offRoute: _c2oFlashOffRoute),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (result != null)
                _OpenButton(
                  label: context.formatString(
                    'scanner.open_result'.getString(context),
                    [result.label.toLowerCase()],
                  ),
                  onOpen: _openResult,
                  onDismiss: _resume,
                )
              else
                _Controls(
                  paused: _paused,
                  onTogglePause: _togglePause,
                  onGallery: _scanFromGallery,
                  onNameplate: () => context.push(Routes.nameplateOcr),
                ),
              if (result != null && _resultRaw != null) ...[
                const SizedBox(height: 12),
                AppText.caption(
                  _resultRaw!,
                  align: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ],
              if (result == null && _c2oHistory.isNotEmpty) ...[
                const SizedBox(height: 16),
                _C2oSessionStrip(history: _c2oHistory, onOpenDetail: _openAssetDetail),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _describe(BuildContext context, MobileScannerException error) =>
      switch (error.errorCode) {
        MobileScannerErrorCode.permissionDenied =>
          'scanner.camera_permission_denied'.getString(context),
        MobileScannerErrorCode.unsupported =>
          'scanner.camera_unsupported'.getString(context),
        _ => 'scanner.camera_start_failed'.getString(context),
      };
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.cameraOff,
                  size: 40, color: Colors.white.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              AppText(
                message,
                align: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
              ),
            ],
          ),
        ),
      );
}

/// The four corner marks that tell the technician where to aim.
class _Brackets extends StatelessWidget {
  const _Brackets();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Stack(
            children: [
              for (final corner in _corners)
                Align(
                  alignment: corner,
                  child: Container(
                    height: 40,
                    width: 40,
                    decoration: BoxDecoration(
                      border: Border(
                        top: corner.y < 0 ? _side : BorderSide.none,
                        bottom: corner.y > 0 ? _side : BorderSide.none,
                        left: corner.x < 0 ? _side : BorderSide.none,
                        right: corner.x > 0 ? _side : BorderSide.none,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  static const _side = BorderSide(color: Color(0x4DFFFFFF), width: 4);

  static const _corners = [
    Alignment.topLeft,
    Alignment.topRight,
    Alignment.bottomLeft,
    Alignment.bottomRight,
  ];
}

class _HitOverlay extends StatelessWidget {
  const _HitOverlay({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) => Container(
        color: FeColors.primary.withValues(alpha: 0.85),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(LucideIcons.circleCheck,
                  size: 36, color: FeColors.primary),
            ),
            const SizedBox(height: 16),
            AppText(
              '$label found',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            AppText(
              detail,
              align: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11),
            ),
          ],
        ),
      );
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.paused,
    required this.onTogglePause,
    required this.onGallery,
    required this.onNameplate,
  });

  final bool paused;
  final VoidCallback onTogglePause;
  final VoidCallback onGallery;
  final VoidCallback onNameplate;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: onTogglePause,
                style: FilledButton.styleFrom(
                  backgroundColor:
                      paused ? FeColors.primary : FeColors.panel,
                  foregroundColor:
                      paused ? Colors.white : FeColors.ink,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: Icon(paused ? LucideIcons.play : LucideIcons.pause,
                    size: 16),
                label: AppText(
                  paused
                      ? 'scanner.resume'.getString(context)
                      : 'scanner.pause'.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: onGallery,
                style: OutlinedButton.styleFrom(
                  // The app theme fills outlined buttons white for the light
                  // screens; on this dark one that hides the label entirely.
                  backgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0x33FFFFFF)),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                icon: const Icon(LucideIcons.image, size: 16),
                label: AppText(
                  'scanner.photo'.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // FR-1.5 — the fallback when a tag can't be read at all: read the
          // physical nameplate instead. Icon-only so three controls still
          // fit the row without crowding the two more common actions.
          SizedBox(
            height: 52,
            width: 52,
            child: OutlinedButton(
              onPressed: onNameplate,
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0x33FFFFFF)),
                padding: EdgeInsets.zero,
              ),
              child: Tooltip(
                message: 'scanner.nameplate'.getString(context),
                child: const Icon(LucideIcons.scanLine, size: 18),
              ),
            ),
          ),
        ],
      );
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({
    required this.label,
    required this.onOpen,
    required this.onDismiss,
  });

  final String label;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SizedBox(
            height: 60,
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onOpen,
              style: FilledButton.styleFrom(
                backgroundColor: FeColors.primary,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              icon: const Icon(LucideIcons.externalLink, size: 20),
              label: AppText(label),
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            child: AppText(
              'scanner.scan_something_else'.getString(context),
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
        ],
      );
}

/// FR-1.1's four outcomes, each with its own colour so a technician glancing
/// up from the tag can tell resolved (blue), an honest network gap (amber),
/// and something actually wrong (red) apart without reading the text. Shared
/// by the full-screen flash ([_C2oOutcomeOverlay]) and the session log
/// ([_C2oSessionStrip]) so the two never drift out of sync.
class _C2oVisual {
  const _C2oVisual(this.color, this.icon, this.title, this.detail);

  final Color color;
  final IconData icon;
  final String title;
  final String detail;
}

_C2oVisual _c2oVisual(BuildContext context, C2oResolution outcome) => switch (outcome) {
  C2oResolved(:final claims, :final fromCache) => _C2oVisual(
    FeColors.primary,
    LucideIcons.circleCheck,
    (claims['asset'] is Map ? claims['asset']['assetName'] as String? : null) ??
        'scanner.c2o_resolved'.getString(context),
    fromCache
        ? 'scanner.c2o_resolved_offline'.getString(context)
        : 'scanner.c2o_resolved_online'.getString(context),
  ),
  C2oTokenMismatch() => _C2oVisual(
    FeColors.danger,
    LucideIcons.shieldAlert,
    'scanner.c2o_token_mismatch'.getString(context),
    'scanner.c2o_token_mismatch_detail'.getString(context),
  ),
  C2oNotFound() => _C2oVisual(
    FeColors.danger,
    LucideIcons.circleX,
    'scanner.c2o_not_found'.getString(context),
    'scanner.c2o_not_found_detail'.getString(context),
  ),
  C2oNeedsSignal() => _C2oVisual(
    FeColors.warning,
    LucideIcons.wifiOff,
    'scanner.c2o_needs_signal'.getString(context),
    'scanner.c2o_needs_signal_detail'.getString(context),
  ),
};

class _C2oOutcomeOverlay extends StatelessWidget {
  const _C2oOutcomeOverlay({required this.outcome, this.offRoute = false});

  final C2oResolution outcome;

  /// FR-5.4 — resolved, but not part of the route being walked. Still a
  /// real verify (the asset name/detail below is unchanged); only the
  /// colour and the subtitle change, so it reads as "noted" rather than
  /// "wrong".
  final bool offRoute;

  @override
  Widget build(BuildContext context) {
    var visual = _c2oVisual(context, outcome);
    if (offRoute && outcome is C2oResolved) {
      visual = _C2oVisual(
        FeColors.warning,
        LucideIcons.mapPinOff,
        visual.title,
        'scanner.c2o_off_route_detail'.getString(context),
      );
    }

    return Container(
      color: visual.color.withValues(alpha: 0.9),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Icon(visual.icon, size: 36, color: visual.color),
          ),
          const SizedBox(height: 16),
          AppText(
            visual.title,
            align: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          AppText(
            visual.detail,
            align: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// One c2o tag scanned this session (FR-1.2) — the running log a continuous
/// walk builds up instead of a per-tag confirm screen.
class _C2oScanEntry {
  const _C2oScanEntry({required this.outcome, required this.at, this.offRoute = false});

  final C2oResolution outcome;
  final DateTime at;

  /// FR-5.4 — resolved, but not part of the route being walked.
  final bool offRoute;
}

/// Compact, always-visible tally of the session so far — a dot per scan,
/// most recent first, plus a running count. Never blocks the camera; this is
/// what "queues without returning to a list" (FR-1.2) looks like without a
/// separate list screen.
class _C2oSessionStrip extends StatelessWidget {
  const _C2oSessionStrip({required this.history, required this.onOpenDetail});

  final List<_C2oScanEntry> history;

  /// Opens a resolved entry's FR-2 detail screen. Only ever called for a
  /// [C2oResolved] entry — there is nothing to open for a mismatch, a
  /// not-found, or a needs-signal outcome.
  final void Function(String assetId, String? name) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final resolved = history.where((e) => e.outcome is C2oResolved).length;
    final flagged = history.length - resolved;
    final offRoute = history.where((e) => e.offRoute).length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          AppText(
            context.formatString(
              'scanner.c2o_session_count'.getString(context),
              [history.length.toString()],
            ),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (flagged > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: FeColors.warning.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
              child: AppText(
                context.formatString(
                  'scanner.c2o_session_flagged'.getString(context),
                  [flagged.toString()],
                ),
                style: const TextStyle(
                  color: FeColors.warning,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          if (offRoute > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: FeColors.warning.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
              child: AppText(
                context.formatString(
                  'scanner.c2o_session_off_route'.getString(context),
                  [offRoute.toString()],
                ),
                style: const TextStyle(
                  color: FeColors.warning,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          // A horizontal ListView needs a bounded width from its parent —
          // without Expanded here, Row hands it unbounded width and the
          // rendering library throws mid-layout, silently failing to paint
          // the whole strip (caught live: no error dialog, just nothing).
          Expanded(
            child: SizedBox(
              height: 24,
              child: ListView.separated(
                reverse: true,
                scrollDirection: Axis.horizontal,
                itemCount: history.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final outcome = history[index].outcome;
                  final visual = _c2oVisual(context, outcome);
                  final dot = Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: visual.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  );
                  return Tooltip(
                    message: visual.title,
                    child: outcome is C2oResolved
                        ? GestureDetector(
                            // A bit more than the 14px dot itself, so a
                            // gloved thumb can actually hit it.
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onOpenDetail(
                              outcome.assetId,
                              outcome.claims['asset'] is Map
                                  ? outcome.claims['asset']['assetName']?.toString()
                                  : null,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: dot,
                            ),
                          )
                        : dot,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

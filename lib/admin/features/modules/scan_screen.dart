import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// Opens [ScanScreen]; the scanned text, or null. Overridden in tests.
final scanCodeProvider = Provider<Future<String?> Function(BuildContext context)>(
  (ref) => (context) => Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen())),
);

/// The camera, popping the first code it reads (QR, or Code 128/39 on the
/// older asset plates, as in FieldOps' scanner). Null when backed out.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.code128, BarcodeFormat.code39],
  );
  bool _popped = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_popped) return;
    final raw = capture.barcodes.map((b) => b.rawValue?.trim()).whereType<String>().where((v) => v.isNotEmpty).firstOrNull;
    if (raw == null) return;
    _popped = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FeHeader(title: 'scan.title'.getString(context)),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: TechEmptyState(
                    icon: LucideIcons.cameraOff,
                    title: (error.errorCode == MobileScannerErrorCode.permissionDenied ? 'scan.no_permission' : 'scan.no_camera').getString(context),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: AppText.body('scan.hint'.getString(context), align: TextAlign.center, color: Colors.white),
            ),
          ],
        ),
      );
}

/// An asset's id from a scanned code: the sticker JSON `{"type":"Asset","id":..}`
/// (FieldOps qr_payload.dart) or a link ending `/assets/<id>` (the web's
/// public asset page). Anything else (a bare reference on a barcode) is null:
/// the caller searches for it.
String? assetIdFromScan(String raw) {
  final t = raw.trim();
  final json = RegExp(r'"type"\s*:\s*"Asset"').hasMatch(t) ? RegExp(r'"id"\s*:\s*"([^"]+)"').firstMatch(t) : null;
  if (json != null) return json.group(1);
  final uri = Uri.tryParse(t);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
  final seg = uri.pathSegments;
  final i = seg.lastIndexOf('assets');
  return i >= 0 && i + 1 < seg.length && seg[i + 1].isNotEmpty ? seg[i + 1] : null;
}

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:signature/signature.dart';

import '../../../domain/permit.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/tech_popup.dart';
import 'permit_sheet.dart';

/// What the sheet hands back — the drawn signature only. `briefingAck` is
/// always true by the time this returns: the confirm button stays disabled
/// until the "I understand" box is ticked, so there is nothing else to carry.
class SignOnResult {
  const SignOnResult({required this.signaturePng});
  final Uint8List signaturePng;
}

/// Sign on (docs/permit-to-work.md): the briefing — hazards, controls and
/// PPE this permit requires — plus an acknowledgement and a signature. The
/// server records the actual sign-on; this sheet only collects what it needs.
Future<SignOnResult?> showSignOnSheet(
  BuildContext context, {
  required PermitDetail permit,
  required PermitCatalog catalog,
}) => showPermitSheet<SignOnResult>(context, _SignOnSheet(permit: permit, catalog: catalog), tall: true);

class _SignOnSheet extends StatefulWidget {
  const _SignOnSheet({required this.permit, required this.catalog});
  final PermitDetail permit;
  final PermitCatalog catalog;

  @override
  State<_SignOnSheet> createState() => _SignOnSheetState();
}

class _SignOnSheetState extends State<_SignOnSheet> {
  late final SignatureController _sig = SignatureController(
    penColor: FeColors.ink,
    penStrokeWidth: 3,
    exportBackgroundColor: Colors.white,
    onDrawEnd: () => setState(() {}),
  );
  bool _ack = false;

  @override
  void dispose() {
    _sig.dispose();
    super.dispose();
  }

  bool get _canConfirm => _ack && !_sig.isEmpty;

  Future<void> _confirm() async {
    final bytes = await _sig.toPngBytes();
    if (bytes == null) {
      if (mounted) {
        showTechPopup(context, message: 'permits.signature_required'.getString(context), isError: true);
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(SignOnResult(signaturePng: bytes));
  }

  @override
  Widget build(BuildContext context) {
    final permit = widget.permit;
    final catalog = widget.catalog;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PermitSheetGrabber(),
            AppText.titleMedium('permits.sign_on_title'.getString(context), weight: FontWeight.w800),
            const SizedBox(height: 4),
            AppText.bodySmall(permit.title, color: FeColors.ink2, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 14),
            if (permit.hazards.isNotEmpty) ...[
              AppText.labelMedium('permits.section_hazards'.getString(context), color: FeColors.ink2),
              const SizedBox(height: 6),
              _list(permit.hazards.map(catalog.hazardLabel), LucideIcons.triangleAlert, FeColors.danger),
              const SizedBox(height: 12),
            ],
            if (permit.controls.isNotEmpty) ...[
              AppText.labelMedium('permits.section_controls'.getString(context), color: FeColors.ink2),
              const SizedBox(height: 6),
              _list(permit.controls.map(catalog.controlLabel), LucideIcons.shieldCheck, FeColors.info),
              const SizedBox(height: 12),
            ],
            if (permit.ppe.isNotEmpty) ...[
              AppText.labelMedium('permits.section_ppe'.getString(context), color: FeColors.ink2),
              const SizedBox(height: 6),
              _list(permit.ppe.map(catalog.ppeLabel), LucideIcons.hardHat, FeColors.success),
              const SizedBox(height: 12),
            ],
            InkWell(
              onTap: () => setState(() => _ack = !_ack),
              borderRadius: BorderRadius.circular(context.radii.md),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 28,
                      width: 28,
                      child: Checkbox(value: _ack, onChanged: (v) => setState(() => _ack = v ?? false)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppText.bodyMedium('permits.briefing_ack'.getString(context), weight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            AppText.labelMedium('permits.signature'.getString(context), color: FeColors.ink2),
            const SizedBox(height: 6),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(context.radii.md),
                border: Border.all(color: FeColors.line),
              ),
              child: Signature(controller: _sig, height: 160, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: AppText.caption('permits.signature_required'.getString(context), color: FeColors.ink2),
                ),
                SizedBox(
                  height: 44,
                  child: TextButton.icon(
                    onPressed: () => setState(_sig.clear),
                    icon: const Icon(LucideIcons.rotateCcw, size: 14),
                    label: AppText('permits.clear_signature'.getString(context)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: context.metrics.buttonCta,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: FeColors.primary),
                onPressed: _canConfirm ? _confirm : null,
                child: AppText.bodyMedium('permits.sign_on_confirm'.getString(context), color: Colors.white, weight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(Iterable<String> items, IconData icon, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(child: AppText.bodySmall(item)),
            ],
          ),
        ),
    ],
  );
}

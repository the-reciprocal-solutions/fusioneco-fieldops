import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/capture/capture_services.dart';
import '../../../domain/permit.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/app_text.dart';
import 'permit_sheet.dart';

/// Isolate / verify / restore (docs/permit-to-work.md, LOTO). The photo
/// travels inline as a data URL, not through the offline-upload queue —
/// see `data/permit_repository.dart`'s doc comment for why.
class IsolateDraft {
  const IsolateDraft({this.lockNo, this.tagNo, this.note, this.photo});
  final String? lockNo;
  final String? tagNo;
  final String? note;
  final CapturedPhoto? photo;
}

class VerifyDraft {
  const VerifyDraft({required this.tryOut, this.note});
  final bool tryOut;
  final String? note;
}

Future<IsolateDraft?> showIsolateSheet(BuildContext context, {required PermitIsolation isolation}) =>
    showPermitSheet<IsolateDraft>(context, _IsolateSheet(isolation: isolation));

Future<VerifyDraft?> showVerifyIsolationSheet(BuildContext context, {required PermitIsolation isolation}) =>
    showPermitSheet<VerifyDraft>(context, _VerifySheet(isolation: isolation));

// ============================================================================
// Isolate
// ============================================================================

class _IsolateSheet extends StatefulWidget {
  const _IsolateSheet({required this.isolation});
  final PermitIsolation isolation;

  @override
  State<_IsolateSheet> createState() => _IsolateSheetState();
}

class _IsolateSheetState extends State<_IsolateSheet> {
  final _lockNo = TextEditingController();
  final _tagNo = TextEditingController();
  final _note = TextEditingController();
  CapturedPhoto? _photo;
  bool _capturing = false;

  @override
  void dispose() {
    _lockNo.dispose();
    _tagNo.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    setState(() => _capturing = true);
    try {
      final photo = await PhotoCapture().takeJobPhoto(maxWidth: 1000);
      if (mounted && photo != null) setState(() => _photo = photo);
    } on CaptureFailure {
      // The photo is optional here; a camera failure just leaves it unset.
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PermitSheetGrabber(),
          AppText.titleMedium('permits.isolate_title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodySmall(widget.isolation.pointTag, color: FeColors.ink2),
          const SizedBox(height: 16),
          TextField(
            controller: _lockNo,
            decoration: InputDecoration(
              labelText: 'permits.lock_no'.getString(context),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tagNo,
            decoration: InputDecoration(
              labelText: 'permits.tag_no'.getString(context),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'permits.note_optional'.getString(context),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _capturing ? null : _takePhoto,
              icon: Icon(_photo == null ? LucideIcons.camera : LucideIcons.checkCheck, size: 18),
              label: AppText.bodySmall(
                _photo == null
                    ? 'permits.add_photo'.getString(context)
                    : 'permits.photo_added'.getString(context),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: context.metrics.buttonCta,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: FeColors.primary),
              onPressed: () => Navigator.of(context).pop(
                IsolateDraft(
                  lockNo: _lockNo.text.trim().isEmpty ? null : _lockNo.text.trim(),
                  tagNo: _tagNo.text.trim().isEmpty ? null : _tagNo.text.trim(),
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                  photo: _photo,
                ),
              ),
              child: AppText.bodyMedium('permits.isolate_confirm'.getString(context), color: Colors.white, weight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );
}

// ============================================================================
// Verify
// ============================================================================

class _VerifySheet extends StatefulWidget {
  const _VerifySheet({required this.isolation});
  final PermitIsolation isolation;

  @override
  State<_VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends State<_VerifySheet> {
  bool _tryOut = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PermitSheetGrabber(),
          AppText.titleMedium('permits.verify_title'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodySmall(widget.isolation.pointTag, color: FeColors.ink2),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _tryOut,
            onChanged: (v) => setState(() => _tryOut = v),
            title: AppText.bodyMedium('permits.try_out'.getString(context), weight: FontWeight.w700),
            subtitle: AppText.bodySmall('permits.try_out_hint'.getString(context), color: FeColors.ink2),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'permits.note_optional'.getString(context),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: context.metrics.buttonCta,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _tryOut ? FeColors.primary : FeColors.ink2),
              onPressed: !_tryOut
                  ? null
                  : () => Navigator.of(context).pop(
                      VerifyDraft(tryOut: _tryOut, note: _note.text.trim().isEmpty ? null : _note.text.trim()),
                    ),
              child: AppText.bodyMedium('permits.verify_confirm'.getString(context), color: Colors.white, weight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );
}

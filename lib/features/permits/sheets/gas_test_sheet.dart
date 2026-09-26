import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/permit/permit_gas.dart';
import '../../../domain/permit.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/app_text.dart';
import '../widgets/permit_visuals.dart';
import 'permit_sheet.dart';

/// What the sheet hands back to `permit_detail_screen.dart`; the actual
/// `POST /gas-tests` call — and the real pass/fail verdict — is the
/// repository's and the server's, never this sheet's.
class GasTestDraft {
  const GasTestDraft({this.o2, this.lel, this.h2s, this.co, this.instrumentId, this.calibrationDue, this.location, this.note});

  final double? o2;
  final double? lel;
  final double? h2s;
  final double? co;
  final String? instrumentId;
  final DateTime? calibrationDue;
  final String? location;
  final String? note;
}

/// Gas test (docs/permit-to-work.md): O2 → LEL → H2S → CO, judged live
/// against [PermitDetail.gasProfile] as the technician types — the one rule
/// this app computes on the device (see `core/permit/permit_gas.dart`).
Future<GasTestDraft?> showGasTestSheet(BuildContext context, {required PermitDetail permit}) =>
    showPermitSheet<GasTestDraft>(context, _GasTestSheet(permit: permit), tall: true);

class _GasTestSheet extends StatefulWidget {
  const _GasTestSheet({required this.permit});
  final PermitDetail permit;

  @override
  State<_GasTestSheet> createState() => _GasTestSheetState();
}

class _GasTestSheetState extends State<_GasTestSheet> {
  static const _order = ['o2', 'lel', 'h2s', 'co'];

  final _controllers = {for (final g in _order) g: TextEditingController()};
  final _instrument = TextEditingController();
  final _location = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _instrument.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  Map<String, double?> get _readings =>
      {for (final g in _order) g: double.tryParse(_controllers[g]!.text.trim())};

  @override
  Widget build(BuildContext context) {
    final profile = widget.permit.gasProfile;
    final readings = _readings;
    final results = PermitGas.evaluateAll(profile, readings);
    final anyEntered = readings.values.any((v) => v != null);
    final hasFailure = results.values.any((r) => r.isFail);
    final warn = widget.permit.isActive && anyEntered && hasFailure;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PermitSheetGrabber(),
            AppText.titleMedium('permits.gas_test_title'.getString(context), weight: FontWeight.w800),
            const SizedBox(height: 4),
            AppText.bodySmall('permits.gas_test_subtitle'.getString(context), color: FeColors.ink2),
            const SizedBox(height: 16),
            // All four fields always show — a multi-gas detector reads all
            // four regardless of what this permit type requires — but only
            // the gases in [profile.limits] get a live pass/fail colour.
            for (final g in _order)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _GasField(
                  gas: g,
                  limit: profile.limitFor(g),
                  controller: _controllers[g]!,
                  result: results[g],
                  onChanged: () => setState(() {}),
                ),
              ),
            if (warn) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: FeColors.dangerSoft, borderRadius: BorderRadius.circular(context.radii.md)),
                child: Row(
                  children: [
                    const Icon(LucideIcons.triangleAlert, color: FeColors.danger, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppText.bodySmall(
                        'permits.gas_test_will_suspend'.getString(context),
                        color: FeColors.danger,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            TextField(
              controller: _instrument,
              decoration: InputDecoration(
                labelText: 'permits.instrument_id'.getString(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _location,
              decoration: InputDecoration(
                labelText: 'permits.gas_test_location'.getString(context),
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
            const SizedBox(height: 16),
            SizedBox(
              height: context.metrics.buttonCta,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: FeColors.primary),
                onPressed: () => Navigator.of(context).pop(
                  GasTestDraft(
                    o2: readings['o2'],
                    lel: readings['lel'],
                    h2s: readings['h2s'],
                    co: readings['co'],
                    instrumentId: _instrument.text.trim().isEmpty ? null : _instrument.text.trim(),
                    location: _location.text.trim().isEmpty ? null : _location.text.trim(),
                    note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                  ),
                ),
                child: AppText.bodyMedium(
                  'permits.gas_test_save'.getString(context),
                  color: Colors.white,
                  weight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GasField extends StatelessWidget {
  const _GasField({required this.gas, required this.limit, required this.controller, required this.result, required this.onChanged});

  final String gas;
  final GasLimit? limit;
  final TextEditingController controller;
  final GasReadingResult? result;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final color = result == null ? FeColors.ink2 : PermitDisplay.gasVerdictColor(result!.verdict);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: AppText.bodyMedium(limit?.label ?? gas.toUpperCase(), weight: FontWeight.w700),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              isDense: true,
              suffixText: limit?.unit,
              filled: true,
              fillColor: color.withValues(alpha: 0.08),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: color.withValues(alpha: 0.4)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: color, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 84,
          child: AppText.caption(
            result == null || result!.isUnknown
                ? ''
                : result!.isPass
                ? 'permits.gas_pass'.getString(context)
                : 'permits.gas_fail'.getString(context),
            color: color,
            weight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

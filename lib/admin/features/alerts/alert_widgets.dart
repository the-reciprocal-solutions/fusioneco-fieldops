import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../../domain/alert.dart';
import '../../theme/fe_status_tokens.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/common.dart';

/// Soft pill from one hue — the same recipe as FeStatusColors' private one.
FeChipStyle _pill(Color hue) => FeChipStyle(
      background: Color.alphaBlend(hue.withValues(alpha: 0.12), Colors.white),
      foreground: hue,
      border: hue.withValues(alpha: 0.28),
    );

/// Severity uses the shared priority palette (critical/high/medium/low).
FeChipStyle severityStyle(BuildContext context, String severity) => context.chips.priority(severity);

/// Active = needs attention (red), acknowledged = being handled (amber),
/// resolved = done (green).
FeChipStyle alertStatusStyle(String status) => switch (status) {
      'active' => _pill(FeStatusHues.overdue),
      'acknowledged' => _pill(FeStatusHues.inProgress),
      'resolved' => _pill(FeStatusHues.completed),
      _ => _pill(FeStatusHues.draft),
    };

class SeverityChip extends StatelessWidget {
  const SeverityChip(this.severity, {super.key});
  final String severity;

  @override
  Widget build(BuildContext context) =>
      TechChip(label: 'alerts.severity_$severity'.getString(context), style: severityStyle(context, severity));
}

class AlertStatusChip extends StatelessWidget {
  const AlertStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) =>
      TechChip(label: 'alerts.status_$status'.getString(context), style: alertStatusStyle(status));
}

/// Label for one history event; unknown actions fall back to plain words.
String eventLabel(BuildContext context, AlertEvent e) {
  final key = 'alerts.event_${e.action}';
  final label = key.getString(context);
  // flutter_localization answers "<key> not found" for a missing key.
  return label.endsWith(' not found') ? e.action.replaceAll('_', ' ') : label;
}

/// The severity, as the colour of a card's top accent.
Color severityHue(String severity) => switch (severity) {
      'critical' => FeStatusHues.priorityCritical,
      'high' => FeStatusHues.priorityHigh,
      'medium' => FeStatusHues.priorityMedium,
      _ => FeStatusHues.priorityLow,
    };

/// Shown when [AlertItem] list or detail can't load.
String alertsErrorText(BuildContext context) => 'alerts.load_error'.getString(context);

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/push/push_service.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

const pushSeverities = ['critical', 'high', 'medium', 'low'];

/// The user's own alert-push settings: on/off and the lowest severity that
/// buzzes the phone. Saved to their config (`POST /api/auth/config`; these
/// keys are not `is*`, so anyone may change their own). The server reads them
/// when it fans an alert out (services/alerts/mobilePush.ts).
class PushSettingsScreen extends ConsumerStatefulWidget {
  const PushSettingsScreen({super.key});

  @override
  ConsumerState<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends ConsumerState<PushSettingsScreen> {
  bool? _on;
  String? _min;
  bool _saving = false;

  Future<void> _save({bool? on, String? min}) async {
    final boot = ref.read(loadedCatalogProvider);
    final prevOn = _on ?? boot?.pushAlerts ?? true;
    final prevMin = _min ?? boot?.pushMinSeverity ?? 'high';
    setState(() => (_on = on ?? prevOn, _min = min ?? prevMin, _saving = true));
    final messenger = ScaffoldMessenger.of(context);
    final failed = 'push.save_failed'.getString(context);
    try {
      await ref.read(apiClientProvider).post('/api/auth/config', body: {'mobilePushAlerts': _on, 'mobilePushMinSeverity': _min});
      ref.invalidate(catalogProvider);
    } on ApiFailure catch (e) {
      // Put the switch back: the server still has the old value.
      if (mounted) setState(() => (_on = prevOn, _min = prevMin));
      messenger.showSnackBar(SnackBar(content: AppText('$failed ${e.message}')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(loadedCatalogProvider);
    final on = _on ?? boot?.pushAlerts ?? true;
    final min = _min ?? boot?.pushMinSeverity ?? 'high';
    final available = ref.watch(pushServiceProvider).available;
    return Scaffold(
      appBar: FeHeader(title: 'push.title'.getString(context)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (!available)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TechCard(child: AppText.bodySmall('push.unavailable'.getString(context), color: FeColors.warning)),
            ),
          TechCard(
            padding: EdgeInsets.zero,
            // Own Material: the card's background would hide the tiles' ripple.
            child: Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                value: on,
                onChanged: _saving ? null : (v) => _save(on: v),
                title: AppText.body('push.alerts'.getString(context)),
                subtitle: AppText.caption('push.alerts_hint'.getString(context)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: AppText.caption('push.min_severity'.getString(context).toUpperCase(), weight: FontWeight.w700),
          ),
          TechCard(
            padding: EdgeInsets.zero,
            child: Material(
              type: MaterialType.transparency,
              child: RadioGroup<String>(
                groupValue: min,
                onChanged: (v) {
                  if (v != null && on && !_saving) _save(min: v);
                },
                child: Column(
                  children: [for (final s in pushSeverities) RadioListTile<String>(value: s, enabled: on && !_saving, title: AppText.body('push.sev_$s'.getString(context)))],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          AppText.caption('push.footer'.getString(context)),
        ],
      ),
    );
  }
}

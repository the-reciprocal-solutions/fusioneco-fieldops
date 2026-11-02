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

/// The i18n key that explains a test push's outcome (server notificationController.testPush).
String testPushMessage({required bool configured, required int devices, required int sent}) {
  if (!configured) return 'push.test_off';
  if (devices == 0) return 'push.test_no_device';
  if (sent == 0) return 'push.test_failed';
  return 'push.test_sent';
}

/// The user's own alert-push settings: on/off and the lowest severity that
/// buzzes the phone. Saved to their config (`POST /api/auth/config`; these
/// keys are not `is*`, so anyone may change their own). The server reads them
/// when it fans an alert out (services/alerts/mobilePush.ts).
///
/// "Send a test notification" asks the server to push to this user's own
/// devices (`POST /api/notifications/test-push` → {configured, devices, sent})
/// and says what happened, so a missing push can be told apart from a
/// missing device registration or a server without Firebase.
class PushSettingsScreen extends ConsumerStatefulWidget {
  const PushSettingsScreen({super.key});

  @override
  ConsumerState<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends ConsumerState<PushSettingsScreen> {
  bool? _on;
  String? _min;
  bool _saving = false;
  bool _testing = false;

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

  Future<void> _test() async {
    setState(() => _testing = true);
    final messenger = ScaffoldMessenger.of(context);
    String key;
    var args = <Object>[];
    try {
      final body = await ref.read(apiClientProvider).post('/api/notifications/test-push');
      final d = body is Map && body['data'] is Map ? body['data'] as Map : const {};
      final devices = (d['devices'] as num?)?.toInt() ?? 0;
      final sent = (d['sent'] as num?)?.toInt() ?? 0;
      key = testPushMessage(configured: d['configured'] != false, devices: devices, sent: sent);
      args = [sent];
    } on HttpFailure catch (e) {
      key = e.status == 404 ? 'push.test_old' : 'push.test_error';
    } on ApiFailure {
      key = 'push.test_error';
    }
    if (!mounted) return;
    setState(() => _testing = false);
    final text = key.getString(context);
    messenger.showSnackBar(SnackBar(content: AppText(args.isEmpty ? text : context.formatString(text, args))));
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
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing ? const TechSpinner(size: 16) : const Icon(Icons.notifications_active_outlined, size: 18),
            label: AppText('push.test'.getString(context)),
          ),
          const SizedBox(height: 6),
          AppText.caption('push.test_hint'.getString(context)),
        ],
      ),
    );
  }
}

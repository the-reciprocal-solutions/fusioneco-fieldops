import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../admin/state/auth_controller.dart' as admin;
import '../../app/env.dart';
import '../../app/router.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/technician_loading.dart';
import '../../widgets/dir_icon.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  /// The admin login is running (after "Technician not found").
  bool _adminBusy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final ok = await ref
        .read(authControllerProvider.notifier)
        .login(_username.text.trim(), _password.text);
    if (!mounted) return;

    // Not a technician: maybe an admin-panel user. On success AppRoot swaps
    // to the admin side by itself; on failure its message (e.g. "Invalid
    // Credentials" for an admin's wrong password) replaces ours.
    if (!ok && ref.read(authControllerProvider).notTechnician) {
      setState(() => _adminBusy = true);
      final adminAuth = ref.read(admin.authControllerProvider.notifier);
      await adminAuth.login(_username.text.trim(), _password.text);
      if (!mounted) return;
      setState(() => _adminBusy = false);
      final a = ref.read(admin.authControllerProvider);
      if (a.isAuthenticated) {
        ref.read(authControllerProvider.notifier).clearError();
      } else if (a.error != null) {
        ref.read(authControllerProvider.notifier).showError(a.error!);
      }
      return;
    }

    if (ok) {
      final session = ref.read(authControllerProvider).session;
      if (session != null && !session.isInHouse) {
        await ref.read(authControllerProvider.notifier).logout();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AppText(
              'login.partner_account_message'.getString(context),
            ),
          ),
        );
        return;
      }
      context.go(Routes.dashboard);
    }
  }

  void _showServerSettingsDialog() {
    final store = ref.read(sessionStoreProvider);
    final currentUrl = store.readBaseUrlOverride() ?? Env.defaultApiBaseUrl;
    final controller = TextEditingController(text: currentUrl);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(LucideIcons.server, size: 20, color: FeColors.primary),
            const SizedBox(width: 8),
            AppText.title('login.connection_settings_title'.getString(ctx)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText.bodySmall(
              'login.connection_settings_hint'.getString(ctx),
              color: FeColors.ink2,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'login.server_address_label'.getString(ctx),
                hintText: 'login.server_address_hint'.getString(ctx),
                prefixIcon: const Icon(LucideIcons.globe, size: 16),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await store.writeBaseUrlOverride(null);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: AppText(
              'login.reset_to_default'.getString(ctx),
              color: FeColors.ink2,
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final val = controller.text.trim();
              await store.writeBaseUrlOverride(val.isEmpty ? null : val);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: AppText('common.save'.getString(ctx)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final adminExpired = ref.watch(admin.authControllerProvider.select((s) => s.sessionExpired));

    return Scaffold(
      backgroundColor: FeColors.page,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero branding emblem
                  Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Soft glow halo
                        Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: FeColors.primaryLight.withValues(
                              alpha: 0.12,
                            ),
                          ),
                        ),
                        // Outer bordered badge ring
                        Container(
                          width: 74,
                          height: 74,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [FeColors.ink, FeColors.primary],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: FeColors.primary.withValues(alpha: 0.25),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                            border: Border.all(
                              color: FeColors.primaryLight.withValues(
                                alpha: 0.4,
                              ),
                              width: 2,
                            ),
                          ),
                          // A building, not a hard hat: admins sign in here
                          // too since 2026-10-31 (docs/admin-side.md).
                          child: const Icon(
                            LucideIcons.building2,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Session badge
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: FeColors.infoSoft,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: FeColors.primaryLight.withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            LucideIcons.shieldCheck,
                            size: 13,
                            color: FeColors.primary,
                          ),
                          const SizedBox(width: 6),
                          AppText.caption(
                            'login.secure_sign_in_badge'.getString(context),
                            color: FeColors.ink,
                            weight: FontWeight.w600,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  AppText.title(
                    context.formatString(
                      'login.title_with_brand'.getString(context),
                      [Env.brandName],
                    ),
                    align: TextAlign.center,
                    weight: FontWeight.w700,
                  ),
                  const SizedBox(height: 4),
                  AppText.bodySmall(
                    'login.tagline'.getString(context),
                    align: TextAlign.center,
                    color: FeColors.ink2,
                  ),
                  const SizedBox(height: 24),

                  // Session-ended banner (the server refused to renew the session)
                  if (auth.sessionExpired || adminExpired) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: FeColors.warningSoft,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: FeColors.warning.withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            LucideIcons.clockAlert,
                            color: FeColors.warning,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AppText.bodySmall(
                              'login.session_expired_message'.getString(
                                context,
                              ),
                              color: FeColors.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Login Form Card
                  TechCard(
                    padding: const EdgeInsets.all(24),
                    radius: 16,
                    child: auth.isBusy || _adminBusy
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: TechnicianLoadingView(
                              message: 'login.signing_in_message'.getString(
                                context,
                              ),
                              submessage: 'login.signing_in_submessage'
                                  .getString(context),
                              showBrand: false,
                            ),
                          )
                        : Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                AppText.label(
                                  'login.technician_sign_in_label'.getString(
                                    context,
                                  ),
                                  color: FeColors.ink2,
                                  weight: FontWeight.w700,
                                ),
                                const SizedBox(height: 16),

                                TextFormField(
                                  controller: _username,
                                  autocorrect: false,
                                  textInputAction: TextInputAction.next,
                                  decoration: InputDecoration(
                                    labelText: 'login.technician_id_label'
                                        .getString(context),
                                    hintText: 'login.technician_id_hint'
                                        .getString(context),
                                    prefixIcon: const Icon(
                                      LucideIcons.userCheck,
                                      size: 18,
                                      color: FeColors.primary,
                                    ),
                                  ),
                                  validator: (value) =>
                                      (value == null || value.trim().isEmpty)
                                      ? 'login.technician_id_required'
                                            .getString(context)
                                      : null,
                                ),
                                const SizedBox(height: 16),

                                TextFormField(
                                  controller: _password,
                                  obscureText: _obscure,
                                  textInputAction: TextInputAction.done,
                                  onFieldSubmitted: (_) => _submit(),
                                  decoration: InputDecoration(
                                    labelText: 'common.password'.getString(
                                      context,
                                    ),
                                    prefixIcon: const Icon(
                                      LucideIcons.keyRound,
                                      size: 18,
                                      color: FeColors.primary,
                                    ),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscure
                                            ? LucideIcons.eye
                                            : LucideIcons.eyeOff,
                                        size: 18,
                                        color: FeColors.ink2,
                                      ),
                                      onPressed: () =>
                                          setState(() => _obscure = !_obscure),
                                    ),
                                  ),
                                  validator: (value) =>
                                      (value == null || value.isEmpty)
                                      ? 'login.password_required'.getString(
                                          context,
                                        )
                                      : null,
                                ),

                                if (auth.error != null) ...[
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: FeColors.dangerSoft,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: FeColors.danger.withValues(
                                          alpha: 0.3,
                                        ),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          LucideIcons.circleAlert,
                                          color: FeColors.danger,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: AppText.bodySmall(
                                            auth.error!,
                                            color: FeColors.danger,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 24),

                                SizedBox(
                                  height: 48,
                                  child: ElevatedButton(
                                    onPressed: _submit,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: FeColors.primary,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const DirIcon(
                                          LucideIcons.logIn,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        AppText(
                                          'login.sign_in_button'.getString(
                                            context,
                                          ),
                                          color: Colors.white,
                                          weight: FontWeight.w600,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 20),

                  // Bottom Technical Security Info & Server Configuration
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        LucideIcons.lock,
                        size: 12,
                        color: FeColors.ink2,
                      ),
                      const SizedBox(width: 4),
                      AppText.caption(
                        'login.stays_signed_in'.getString(context),
                        color: FeColors.ink2,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'login.connection_settings_title'.getString(
                          context,
                        ),
                        icon: const Icon(
                          LucideIcons.settings2,
                          size: 15,
                          color: FeColors.ink2,
                        ),
                        onPressed: _showServerSettingsDialog,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

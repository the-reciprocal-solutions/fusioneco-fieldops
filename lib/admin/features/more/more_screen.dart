import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:go_router/go_router.dart';

import '../../app/locale_config.dart';
import '../../catalog/catalog_guard.dart';
import '../../catalog/module_icons.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/auth_controller.dart';
import '../../state/locale_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'push_settings_screen.dart';

/// The catalog group (server moduleCatalog.ts) shown inside the Account section.
const _accountGroup = 'Account';

/// Profile, every visible module without a tab of its own (grouped like the
/// web sidebar), language, sign out, and the "on web" footer.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final language = ref.watch(localeControllerProvider);

    return Scaffold(
      appBar: FeHeader(title: 'nav.more'.getString(context)),
      body: CatalogView(
        builder: (context, boot) => ModuleGroupList(
          // The catalog's "Account" modules (Notifications) join this
          // screen's own Account section instead of a second one.
          modules: boot.forTab(NavTab.more).where((m) => m.group != _accountGroup).toList(),
          header: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: TechCard(
                dark: true,
                child: Row(
                  children: [
                    const CircleAvatar(radius: 22, backgroundColor: FeColors.primary, foregroundColor: Colors.white, child: Icon(LucideIcons.user, size: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText.titleSmall(user?.name ?? '', color: Colors.white, maxLines: 1, overflow: TextOverflow.ellipsis),
                          AppText.bodySmall([user?.role, user?.email].whereType<String>().join(' · '), color: Colors.white70, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          footer: [
            RowGroup(
              label: 'common.account'.getString(context),
              rows: [
                for (final m in boot.forTab(NavTab.more).where((m) => m.group == _accountGroup)) NavRow(title: m.label, icon: moduleIcon(m.icon), onTap: () => context.push(modulePath(m.id))),
                if (boot.has('alerts'))
                  NavRow(
                    title: 'push.title'.getString(context),
                    icon: LucideIcons.slidersHorizontal,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PushSettingsScreen())),
                  ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: IconBadge(icon: LucideIcons.languages, style: context.accents.slate, size: 36, iconSize: 16),
                  title: AppText.body('common.language'.getString(context)),
                  trailing: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [for (final e in AppLocales.languageNames.entries) ButtonSegment(value: e.key, label: AppText.caption(e.value))],
                    selected: {language},
                    onSelectionChanged: (s) => ref.read(localeControllerProvider.notifier).choose(s.first),
                  ),
                ),
                NavRow(title: 'common.log_out'.getString(context), icon: LucideIcons.logOut, badge: context.accents.rose, onTap: () => _confirmLogout(context, ref)),
              ],
            ),
            if (boot.webOnly.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [SectionLabel('more.on_web_title'.getString(context)), AppText.bodySmall('${'more.on_web_hint'.getString(context)} ${boot.webOnly.join(' · ')}')],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: AppText.title('common.sign_out_title'.getString(ctx)),
        content: AppText.bodyMedium('more.sign_out_message'.getString(ctx)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: AppText('common.cancel'.getString(ctx))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: AppText('common.log_out'.getString(ctx), color: FeColors.danger),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(authControllerProvider.notifier).logout();
  }
}

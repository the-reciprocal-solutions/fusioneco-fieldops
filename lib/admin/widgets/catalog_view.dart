import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalog/catalog_guard.dart';
import '../catalog/module_icons.dart';
import '../core/i18n/server_text.dart';
import '../core/network/api_exception.dart';
import '../domain/mobile_catalog.dart';
import '../state/catalog_controller.dart';
import '../theme/fe_colors.dart';
import '../theme/theme_extensions.dart';
import 'app_text.dart';
import 'common.dart';
import '../../widgets/dir_icon.dart';

/// Draws [builder] once the catalog is loaded; loading, error and
/// license-locked states otherwise. Pull-to-refresh refetches the catalog.
class CatalogView extends ConsumerWidget {
  const CatalogView({super.key, required this.builder});

  final Widget Function(BuildContext context, MobileBootstrap boot) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    return catalog.when(
      // Keep the last good catalog on screen while a refetch runs.
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const TechSpinner(),
      error: (e, _) => _Message(
        icon: LucideIcons.circleAlert,
        title: e is HttpFailure && e.isLicenseLocked
            ? 'catalog.license_locked'.getString(context)
            : 'catalog.load_error'.getString(context),
        body: e is ApiFailure ? e.message : null,
        onRetry: () => ref.invalidate(catalogProvider),
      ),
      data: (boot) {
        if (boot == null) return const SizedBox.shrink();
        if (boot.license.isLocked) {
          return _Message(
            icon: LucideIcons.lock,
            title: 'catalog.license_locked'.getString(context),
            onRetry: () => ref.invalidate(catalogProvider),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(catalogProvider.future),
          child: builder(context, boot),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, this.body, this.onRetry});

  final IconData icon;
  final String title;
  final String? body;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TechEmptyState(icon: icon, title: title, subtitle: body),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: AppText('catalog.retry'.getString(context)),
                ),
              ],
            ],
          ),
        ),
      );
}

/// A titled group of rows in one [TechCard], the list pattern used across
/// technician_portal.
class RowGroup extends StatelessWidget {
  const RowGroup({super.key, required this.label, required this.rows, this.dividerIndent = 68});

  final String label;
  final List<Widget> rows;

  /// Where row dividers start: under the title text. 68 = padding 16 +
  /// badge 36 + gap 16 for icon rows; pass 16 for rows without an icon.
  final double dividerIndent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (label.isNotEmpty) SectionLabel(label),
            TechCard(
              padding: EdgeInsets.zero,
              // ListTile paints its ripple on the nearest Material; without
              // this layer the card's decoration would hide it.
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0) Divider(height: 1, indent: dividerIndent),
                      rows[i],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

/// One tappable row: optional leading icon badge, title, optional subtitle.
class NavRow extends StatelessWidget {
  const NavRow({super.key, required this.title, this.subtitle, this.icon, this.badge, this.color, this.onTap});

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// Badge colours; defaults to [color]'s tile, else the blue accent.
  final FeBadgeStyle? badge;

  /// The icon tile's colour (the redesign gives each row its own).
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: icon == null ? null : IconBadge(icon: icon!, style: badge ?? (color == null ? FeBadgeStyle.of(FeColors.primary) : FeBadgeStyle.of(color!)), size: 38, iconSize: 18),
        title: AppText.body(title, weight: FontWeight.w600),
        subtitle: subtitle == null ? null : AppText.bodySmall(subtitle!),
        trailing: onTap == null ? null : const DirIcon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
        onTap: onTap,
      );
}

/// Modules grouped like the web sidebar, each opening its module screen.
class ModuleGroupList extends StatelessWidget {
  const ModuleGroupList({super.key, required this.modules, this.header = const [], this.footer = const [], this.grid = false});

  final List<MobileModule> modules;
  final List<Widget> header;
  final List<Widget> footer;

  /// Two-up coloured tiles (Operations) instead of rows (More).
  final bool grid;

  @override
  Widget build(BuildContext context) {
    // The names below come from the models: redraw when the language changes.
    Localizations.localeOf(context);
    final groups = <String, List<MobileModule>>{};
    for (final m in modules) {
      groups.putIfAbsent(m.group, () => []).add(m);
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      children: [
        ...header,
        for (final g in groups.entries)
          if (grid)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionLabel(catalogGroup(g.key)),
                  TwoUpGrid(children: [
                    for (var i = 0; i < g.value.length; i++)
                      MenuTile(label: g.value[i].label, icon: moduleIcon(g.value[i].icon), color: FeColors.tile(i), onTap: () => context.push(modulePath(g.value[i].id))),
                  ]),
                ],
              ),
            )
          else
            RowGroup(
              label: catalogGroup(g.key),
              rows: [
                for (var i = 0; i < g.value.length; i++)
                  NavRow(title: g.value[i].label, icon: moduleIcon(g.value[i].icon), color: FeColors.tile(i), onTap: () => context.push(modulePath(g.value[i].id))),
              ],
            ),
        ...footer,
      ],
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: AppText.titleSmall(label),
      );
}

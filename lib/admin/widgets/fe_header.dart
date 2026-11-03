import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/fe_colors.dart';
import 'app_text.dart';

/// `.standard` — panel background, ink text/icons — is the only look every
/// screen except the full-screen photo viewer needs. `.immersive` is that
/// one deliberate exception, kept as a real tokenized variant instead of a
/// one-off hand-rolled dark bar.
enum FeHeaderVariant { standard, immersive }

/// The app's one header component. Replaces the old split between
/// `TechHeader` (always dark), the default `AppBarTheme` (silently
/// inherited dark by a couple of screens that never opted in), and the
/// `FeLightAppBar` override kit that four screens used to hand-copy — that
/// kit needed three separate properties (`foregroundColor`, `titleTextStyle`,
/// `systemOverlayStyle`) set together or it "failed invisibly" (white text
/// on a white bar). `FeHeader` sets all of them from one `variant`, so that
/// failure mode isn't reachable from a call site anymore.
class FeHeader extends StatelessWidget implements PreferredSizeWidget {
  const FeHeader({
    super.key,
    this.title,
    this.titleWidget,
    this.variant = FeHeaderVariant.standard,
    bool? showBack,
    this.leading,
    this.actions = const [],
    this.bottom,
    this.subtitle,
  }) : _showBack = showBack, // ignore: prefer_initializing_formals — public `showBack` name must stay, field is deliberately private
       assert(
         title != null || titleWidget != null,
         'FeHeader needs a title or a titleWidget',
       );

  /// Plain single-line title. Ignored if [titleWidget] is set.
  final String? title;

  /// Custom title content (e.g. the two-line asset/scan titles on the Twin
  /// and Scanner screens). Inherits the header's title color/weight via
  /// [AppBar.titleTextStyle] unless a child sets its own style.
  final Widget? titleWidget;

  final FeHeaderVariant variant;

  /// Defaults to whether the current route can pop.
  final bool? _showBack;

  /// Overrides the automatic back button — e.g. a close "X" on a
  /// full-screen modal like the photo viewer, where "back" isn't the right
  /// affordance. Takes precedence over [showBack] when set.
  final Widget? leading;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;

  /// A second, smaller line under the title — the tab screens' large header
  /// ("Operations" / "Manage facility operations").
  final String? subtitle;

  static const _height = 56.0;
  static const _tallHeight = 76.0;

  @override
  Size get preferredSize => Size.fromHeight(
      (subtitle == null ? _height : _tallHeight) + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final immersive = variant == FeHeaderVariant.immersive;
    final background = immersive ? Colors.black : FeColors.panel;
    final foreground = immersive ? Colors.white : FeColors.ink;
    final showBack = _showBack ?? Navigator.of(context).canPop();

    final theme = Theme.of(context).textTheme;
    final tall = subtitle != null && !immersive;
    final Widget titleChild = titleWidget ??
        (tall
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText(title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: foreground)),
                  const SizedBox(height: 2),
                  AppText.bodySmall(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              )
            : AppText(title!, overflow: TextOverflow.ellipsis));

    return AppBar(
      toolbarHeight: tall ? _tallHeight : _height,
      backgroundColor: immersive ? background : Colors.transparent,
      // The soft blue → lavender wash of the redesign (2026-11-03).
      flexibleSpace: immersive
          ? null
          : const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [FeColors.headerTop, FeColors.headerBottom],
                ),
              ),
            ),
      foregroundColor: foreground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      automaticallyImplyLeading: false,
      titleSpacing: showBack || leading != null ? 0 : 20,
      leading: leading ??
          (showBack
              ? IconButton(
                  icon: const Icon(LucideIcons.arrowLeft),
                  tooltip: 'common.back'.getString(context),
                  onPressed: () => context.pop(),
                )
              : null),
      title: titleChild,
      titleTextStyle: theme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: foreground),
      actions: [...actions, if (actions.isNotEmpty) const SizedBox(width: 8)],
      systemOverlayStyle: immersive
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      bottom: bottom,
    );
  }
}

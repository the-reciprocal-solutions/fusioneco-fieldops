import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../features/web/web_screen.dart';
import '../theme/fe_colors.dart';
import 'app_text.dart';
import 'common.dart';

/// Opens a page of the web admin panel inside the app, already signed in
/// (FE-mobile.md 0.6, lib/features/web/web_screen.dart). Only for a web
/// *form* the phone has no copy of (an alert's new work order). Pages the
/// phone summarises show [DesktopNote] instead (owner, 2026-11-02).
Future<void> openOnWeb(BuildContext context, String path, {String? title}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WebScreen(path: path, title: title)));

/// "The phone shows a summary; the full view is on a desktop." Shown where
/// the web has more than the phone (3D, full charts, the PDF report, placing
/// pins, running reports). [textKey] is an i18n key naming what's there.
class DesktopNote extends StatelessWidget {
  const DesktopNote({super.key, this.textKey = 'desktop.note'});
  final String textKey;

  @override
  Widget build(BuildContext context) => TechCard(
        tint: FeColors.infoSoft,
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(LucideIcons.monitor, size: 18, color: FeColors.info),
            const SizedBox(width: 10),
            Expanded(child: AppText.bodySmall(textKey.getString(context), color: FeColors.ink)),
          ],
        ),
      );
}

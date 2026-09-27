import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../core/ar/marker_code.dart';
import '../../state/ar_catalog_controller.dart';
import '../../state/ar_permissions.dart';
import '../../state/ar_view_models.dart';
import '../../theme/fe_ar_colors.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import 'ar_ui.dart';
import 'widgets/ar_chrome.dart';
import 'widgets/ar_demo_scene.dart';

/// `/ar/marker/:code` — M1 Scan: one scan decides building, floor and model
/// (§7 rule 1). The sheet says where the board is, that it's your site, and
/// what the model costs to bring down ("3 MB around you first"). One
/// button: **Open AR here**. Every §3.3 error has a next step.
class ArMarkerScreen extends ConsumerWidget {
  const ArMarkerScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canonical = MarkerCode.normalize(code);
    final resolved = canonical == null
        ? const AsyncValue<ArResolveResult>.data(ArResolveFailed(code: 'NOT_A_MARKER'))
        : ref.watch(arResolveProvider(canonical));
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ArSunlightHost(
        child: Scaffold(
        backgroundColor: FeArColors.cameraFloor,
        body: Stack(
          children: [
            const Positioned.fill(child: ArDemoScene(scene: ArDemoSceneState(showModel: false))),
            const Positioned.fill(child: ColoredBox(color: Colors.black26)),
            Center(child: _GreenBrackets(ok: resolved.valueOrNull is ArResolved)),
            PositionedDirectional(
              top: MediaQuery.paddingOf(context).top + 12,
              start: 12,
              end: 12,
              child: Row(
                children: [
                  ArGlassButton(icon: ArIcons.back, label: 'ar.common.back'.getString(context), onTap: () => context.pop()),
                  Expanded(
                    child: Center(
                      child: AppText.titleMedium('ar.scan.title'.getString(context), color: Colors.white, weight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Container(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.paddingOf(context).bottom),
                    decoration: const BoxDecoration(
                      color: FeColors.panel,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 5,
                            decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(3)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          child: resolved.when(
                            loading: () => _Resolving(code: canonical ?? code),
                            error: (e, _) => _Failed(result: const ArResolveFailed(code: 'OFFLINE'), code: canonical ?? code),
                            data: (r) => switch (r) {
                              ArResolved() => _Resolved(result: r),
                              ArResolveFailed() => _Failed(result: r, code: canonical ?? code),
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _GreenBrackets extends StatelessWidget {
  const _GreenBrackets({required this.ok});
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, -120),
      child: SizedBox(
        width: 150,
        height: 190,
        child: CustomPaint(painter: _BracketPainter(color: ok ? FeColors.success : Colors.white)),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  _BracketPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const l = 25.0;
    final w = size.width;
    final h = size.height;
    canvas.drawPath(Path()..moveTo(0, l)..lineTo(0, 0)..lineTo(l, 0), p);
    canvas.drawPath(Path()..moveTo(w - l, 0)..lineTo(w, 0)..lineTo(w, l), p);
    canvas.drawPath(Path()..moveTo(w, h - l)..lineTo(w, h)..lineTo(w - l, h), p);
    canvas.drawPath(Path()..moveTo(l, h)..lineTo(0, h)..lineTo(0, h - l), p);
  }

  @override
  bool shouldRepaint(covariant _BracketPainter old) => old.color != color;
}

class _Resolving extends StatelessWidget {
  const _Resolving({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArEyebrow('ar.scan.eyebrow'.getString(context)),
        const SizedBox(height: 4),
        AppText.headlineSmall(MarkerCode.display(code), weight: FontWeight.w800),
        const SizedBox(height: 14),
        const LinearProgressIndicator(color: FeColors.primary, backgroundColor: FeColors.line),
        const SizedBox(height: 10),
        AppText.bodySmall('ar.scan.resolving'.getString(context), color: FeColors.ink2),
      ],
    );
  }
}

class _Resolved extends StatelessWidget {
  const _Resolved({required this.result});
  final ArResolved result;

  @override
  Widget build(BuildContext context) {
    final m = result.marker;
    final firstBuild = result.builds.isEmpty ? null : result.builds.first;
    final where = [result.building.name, result.floorName, if (m.locationText != null) m.locationText!].join(' · ');
    final sizeText = result.onDevice || result.fromCache
        ? 'ar.scan.on_phone'.getString(context)
        : arTr(context, 'ar.scan.download', [arMegabytes(context, result.focusBytes), arMegabytes(context, result.totalBytes)]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArEyebrow('ar.scan.eyebrow'.getString(context)),
        const SizedBox(height: 2),
        AppText.headlineSmall(m.label, weight: FontWeight.w800),
        AppText.bodyMedium(where, color: FeColors.ink2),
        const SizedBox(height: 14),
        _Check(
          icon: ArIcons.check,
          title: 'ar.scan.your_site'.getString(context),
          sub: arTr(context, 'ar.scan.your_site_sub', [result.building.name]),
        ),
        if (firstBuild != null)
          _Check(
            icon: ArIcons.box,
            title: arTr(context, 'ar.scan.build', [firstBuild.version ?? '-', result.floorName]),
            sub: sizeText,
          ),
        // The server's badge is `MODEL_OLDER_THAN_LATEST_UPLOAD`
        // (resolveService.ts RESOLVE_BADGE.modelOlder); the other spellings
        // are the demo gateway's.
        if (result.badges.contains('MODEL_OLDER_THAN_LATEST_UPLOAD') ||
            result.badges.contains('older-build') ||
            result.badges.contains('olderBuild')) ...[
          const SizedBox(height: 6),
          ArHintRow(text: 'ar.scan.older_build'.getString(context)),
        ],
        if (result.fromCache) ...[
          const SizedBox(height: 6),
          ArSuccessRow(text: 'ar.scan.offline_ok'.getString(context), icon: ArIcons.offline),
        ],
        const SizedBox(height: 16),
        ArPrimaryButton(
          label: 'ar.scan.open'.getString(context),
          icon: ArIcons.box,
          onPressed: () => context.pushReplacement(
            Routes.arSession(floorId: result.floorId, focus: m.code, method: 'board'),
          ),
        ),
        const SizedBox(height: 8),
        ArSecondaryButton(
          label: 'ar.fallback.floor_plan'.getString(context),
          icon: ArIcons.plan,
          onPressed: () => context.push(Routes.floorPlan(result.floorId, assetId: '')),
        ),
      ],
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.icon, required this.title, required this.sub});
  final IconData icon;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(color: FeArColors.lockedBg, shape: BoxShape.circle),
            child: Icon(icon, size: 15, color: FeArColors.lockedIcon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium(title, weight: FontWeight.w700),
                AppText.bodySmall(sub, color: FeColors.ink2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// §3.3: every failure names the next step.
class _Failed extends ConsumerWidget {
  const _Failed({required this.result, required this.code});
  final ArResolveFailed result;
  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (titleKey, bodyKey) = switch (result.code) {
      'NO_ACCESS' => ('ar.resolve.no_access_title', 'ar.resolve.no_access'),
      'RETIRED' => ('ar.resolve.retired_title', 'ar.resolve.retired'),
      'SPARE_UNBOUND' => ('ar.resolve.spare_title', 'ar.resolve.spare'),
      'NO_PUBLISHED_BUILD' => ('ar.resolve.no_build_title', 'ar.resolve.no_build'),
      'OFFLINE' || 'NEEDS_SIGNAL' => ('ar.resolve.offline_title', 'ar.resolve.offline'),
      'NOT_A_MARKER' => ('ar.resolve.not_marker_title', 'ar.resolve.not_marker'),
      'UNKNOWN_CODE' => ('ar.resolve.unknown_title', 'ar.resolve.unknown'),
      _ => ('ar.resolve.error_title', 'ar.error.generic'),
    };
    var body = bodyKey.getString(context);
    if (result.code == 'RETIRED' && result.nearestLabel != null) {
      final date = result.retiredAt == null ? '' : MaterialLocalizations.of(context).formatShortMonthDay(result.retiredAt!);
      body = arTr(context, 'ar.resolve.retired_nearest', [
        date,
        result.nearestLabel!,
        result.nearestDistanceM == null ? '' : arMetres(context, result.nearestDistanceM!),
      ]);
    } else if (result.code == 'NO_PUBLISHED_BUILD' && result.buildingName != null) {
      body = arTr(context, 'ar.resolve.no_build_named', [result.buildingName!]);
    }
    final actions = <Widget>[];
    if (result.code == 'RETIRED' && result.nearestCode != null) {
      actions.add(ArPrimaryButton(
        label: arTr(context, 'ar.resolve.open_nearest', [result.nearestLabel ?? MarkerCode.display(result.nearestCode!)]),
        onPressed: () => context.pushReplacement(Routes.arMarker(result.nearestCode!)),
      ));
    } else if (result.code == 'SPARE_UNBOUND' && ref.watch(arInstallAllowedProvider)) {
      // Registering a spare is an install action (P-007 `isArInstall`).
      actions.add(ArPrimaryButton(
        label: 'ar.resolve.spare_bind'.getString(context),
        icon: ArIcons.board,
        onPressed: () => context.pushReplacement(Routes.arSpare(code)),
      ));
    } else if (result.code == 'OFFLINE' || result.code == 'NEEDS_SIGNAL' || result.code == 'ERROR') {
      actions.add(ArPrimaryButton(
        label: 'ar.common.retry'.getString(context),
        icon: ArIcons.sync,
        onPressed: () => ref.invalidate(arResolveProvider(code)),
      ));
    }
    actions.add(const SizedBox(height: 8));
    actions.add(ArSecondaryButton(
      label: 'ar.resolve.scan_again'.getString(context),
      icon: ArIcons.board,
      onPressed: () => context.pushReplacement(Routes.scan),
    ));
    if (result.code == 'UNKNOWN_CODE' || result.code == 'RETIRED') {
      actions.add(TextButton(
        onPressed: () => context.push(Routes.webPage('${Env.webBaseUrl}/m/${MarkerCode.display(code)}', title: MarkerCode.display(code))),
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: AppText.label('ar.resolve.report'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArEyebrow(MarkerCode.display(code)),
        const SizedBox(height: 4),
        AppText.title(titleKey.getString(context), weight: FontWeight.w800),
        const SizedBox(height: 6),
        AppText.bodyMedium(body, color: FeColors.ink2),
        const SizedBox(height: 16),
        ...actions,
      ],
    );
  }
}

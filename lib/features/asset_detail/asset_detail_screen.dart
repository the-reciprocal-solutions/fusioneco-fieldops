import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../core/c2o/asset_detail.dart';
import '../../core/c2o/route_walk_context.dart';
import '../ar/widgets/ar_entry_widgets.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/fe_header.dart';

/// FR-2 — what the technician sees before judging. Reads the same
/// `resolveScan()` payload FR-1.1 already fetched and cached against
/// [widget.assetId] (via a scan) and lays it out as identity, location
/// walk, nameplate claims, warranty verdict, status chips and last check —
/// the register's current claim, shown on purpose, per the plan: hiding it
/// would turn a verification into a data-entry exercise.
///
/// Prefers the real scan cache, offline. Falls back to the full asset
/// record (`AssetRepository`, offline-first via the sync cache) when there
/// is no scan cache entry yet — reached from FR-1.6 search rather than a
/// scan. That endpoint is strictly richer than the work-order payload
/// search itself works from (it has manufacturer/model/serial/warranty/
/// description that the thin embedded work-order asset sub-object does
/// not), so it is worth the extra request rather than reusing search's
/// already-fetched data.
class AssetDetailScreen extends ConsumerStatefulWidget {
  const AssetDetailScreen({super.key, required this.assetId, this.route});

  final String assetId;

  /// FR-5.4 — handed on to the verify screen; null when not from a route.
  final RouteWalkContext? route;

  @override
  ConsumerState<AssetDetailScreen> createState() => _AssetDetailScreenState();
}

class _AssetDetailScreenState extends ConsumerState<AssetDetailScreen> {
  AssetDetail? _detail;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = await ref.read(offlineDbProvider).getC2oAsset(widget.assetId);

    var detail = cached == null ? null : AssetDetail.fromClaims(cached.claims);

    if (detail == null) {
      try {
        final page = await ref.read(assetRepositoryProvider).get(widget.assetId);
        detail = AssetDetail.fromAssetRecord(page.asset);
      } catch (_) {
        // No scan cache and no signal for the full-record fallback either —
        // falls through to the not-found state below.
      }
    }

    if (mounted) {
      setState(() {
        _detail = detail;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        showBack: true,
        title: detail?.assetName ?? 'assetDetail.title'.getString(context),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : detail == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: AppText(
                        'assetDetail.not_found'.getString(context),
                        align: TextAlign.center,
                        color: FeColors.ink2,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _IdentityBlock(detail: detail),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'assetDetail.last_check'.getString(context),
                        icon: LucideIcons.clock,
                        accent: FeColors.primary,
                        child: _LastCheckCard(detail: detail),
                      ),
                      if (detail.openFindings.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SectionCard(
                          title: 'assetDetail.open_findings'.getString(context),
                          icon: LucideIcons.alertTriangle,
                          accent: FeColors.warning,
                          child: _OpenFindings(findings: detail.openFindings),
                        ),
                      ],
                      if (detail.locationPath.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SectionCard(
                          title: 'search.location'.getString(context),
                          icon: LucideIcons.mapPin,
                          accent: FeColors.info,
                          child: _LocationWalk(steps: detail.locationPath),
                        ),
                      ] else if (detail.flatLocation != null) ...[
                        const SizedBox(height: 16),
                        _SectionCard(
                          title: 'search.location'.getString(context),
                          icon: LucideIcons.mapPin,
                          accent: FeColors.info,
                          child: AppText.bodyMedium(detail.flatLocation!, weight: FontWeight.w600),
                        ),
                      ],
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'assetDetail.nameplate'.getString(context),
                        icon: LucideIcons.tag,
                        accent: FeColors.dashboardAccent,
                        child: _NameplateClaims(detail: detail),
                      ),
                      if (detail.description != null) ...[
                        const SizedBox(height: 16),
                        _SectionCard(
                          title: 'assetDetail.description'.getString(context),
                          icon: LucideIcons.fileText,
                          accent: FeColors.ink2,
                          child: AppText.bodyMedium(detail.description!),
                        ),
                      ],
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'assetDetail.details'.getString(context),
                        icon: LucideIcons.slidersHorizontal,
                        accent: FeColors.primary,
                        child: _StatusChips(detail: detail),
                      ),
                      const SizedBox(height: 16),
                      // FR-3 — the capture form itself. Primary action on
                      // this screen: bold, full-width, above the secondary
                      // 3D/floor-plan wayfinding buttons below it.
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _VerifyAssetButton(detail: detail, route: widget.route),
                      ),
                      // FR-2.9 — a full native 3D renderer was ruled "Won't
                      // (v1)" in the plan; TwinScreen already hosts the web's
                      // real xeokit viewer in a WebView instead (same gate,
                      // same route used from order_detail_screen), so this is
                      // just the entry point into that existing screen.
                      // != false (not == true): an unset/null flag keeps the
                      // button visible, matching web's ViewInTwinButton.
                      if (ref.watch(authControllerProvider).permissions.isDigitalTwin !=
                          false)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ViewIn3DButton(detail: detail),
                        ),
                      // The in-app 2D/3D model viewer (docs/bim-viewer.md):
                      // the floor's model and plan, offline from the floor
                      // pack. Added next to the xeokit twin button above,
                      // not instead of it. Needs a floor, like AR.
                      if (detail.floorId != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ModelViewerButton(detail: detail),
                        ),
                      // AR Locate (docs/ar-bim-overlay.md §1.1): the asset
                      // drawn through walls where it really is. An extra door
                      // beside the 3D / model-viewer buttons above, never a
                      // replacement: it draws itself only when this client has
                      // AR and the floor has a published AR model.
                      if (detail.floorId != null)
                        ShowInArButton(
                          assetId: detail.id,
                          floorId: detail.floorId,
                          margin: const EdgeInsets.only(bottom: 12),
                        ),
                      // FR-2.8 — hidden rather than shown-and-empty when the
                      // register has no floor recorded for this asset at
                      // all; a missing plan image or pin is instead handled
                      // inside FloorPlanScreen itself, since those are
                      // per-floor facts worth surfacing, not per-asset ones.
                      if (detail.floorId != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ViewFloorPlanButton(detail: detail),
                        ),
                      // UC-5 — raise a snag against this asset (Snag Assistant).
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RaiseSnagButton(detail: detail),
                      ),
                      Center(
                        child: TextButton.icon(
                          onPressed: () => context.push(
                            Routes.webPage(
                              '${Env.webBaseUrl}/public/assets/${detail.id}',
                              title: detail.assetName,
                            ),
                          ),
                          icon: const Icon(LucideIcons.externalLink, size: 14),
                          label: AppText('search.open_in_browser'.getString(context)),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

/// FR-3 — entry point into [FieldVerificationScreen] (`Routes.verifyAsset`).
/// Carries the register's claimed serial/tag along so FR-3.2's "same as
/// claimed" shortcut has something to fill in, and the floor id so a
/// completed verification can offer the floor plan next without re-scanning.
class _VerifyAssetButton extends StatelessWidget {
  const _VerifyAssetButton({required this.detail, this.route});

  final AssetDetail detail;
  final RouteWalkContext? route;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => context.push(
          Routes.verifyAsset(
            detail.id,
            assetName: detail.assetName ?? detail.assetReferenceId ?? detail.id,
            claimedSerial: detail.serialNumber,
            claimedTag: detail.assetReferenceId ?? detail.supplierTagNumber,
            floorId: detail.floorId,
            route: route,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: FeColors.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        icon: const Icon(LucideIcons.clipboardCheck, size: 16),
        label: AppText.label(
          'assetDetail.verify_asset'.getString(context),
          color: Colors.white,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Entry point into [TwinScreen] (`Routes.twin`) — mirrors
/// `order_detail_screen.dart`'s `_ActionPillButton` trigger and the web's
/// `ViewInTwinButton`, just styled to this screen's bolder card language.
class _ViewIn3DButton extends ConsumerWidget {
  const _ViewIn3DButton({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => context.push(
          '${Routes.twin(detail.id)}'
          '?name=${Uri.encodeComponent(detail.assetName ?? detail.assetReferenceId ?? detail.id)}',
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: FeColors.ink,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        icon: const Icon(LucideIcons.box, size: 16),
        label: AppText.label(
          'order_detail.view_in_3d'.getString(context),
          color: Colors.white,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Entry point into the 2D/3D model viewer (`Routes.bimViewer`), opened on
/// this asset. Outlined like the floor-plan button: wayfinding, secondary
/// to verifying the asset.
class _ModelViewerButton extends StatelessWidget {
  const _ModelViewerButton({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => context.push(
          Routes.bimViewer(
            detail.floorId!,
            assetId: detail.id,
            assetName: detail.assetName ?? detail.assetReferenceId ?? detail.id,
          ),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: FeColors.ink,
          side: const BorderSide(color: FeColors.ink, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(LucideIcons.columns2, size: 16),
        label: AppText.label(
          'bim_viewer.open_button'.getString(context),
          color: FeColors.ink,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// FR-2.8 — entry point into [FloorPlanScreen] (`Routes.floorPlan`). A
/// secondary/outline style deliberately, not the same bold black as
/// [_ViewIn3DButton]: the plan is a nice-to-have wayfinding aid, not the
/// primary action this screen exists for, and two identical full-bleed
/// black buttons stacked would read as equally important when they are not.
class _ViewFloorPlanButton extends StatelessWidget {
  const _ViewFloorPlanButton({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => context.push(
          Routes.floorPlan(
            detail.floorId!,
            assetId: detail.id,
            assetName: detail.assetName ?? detail.assetReferenceId ?? detail.id,
            assetReferenceId: detail.assetReferenceId,
            assetType: detail.type,
          ),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: FeColors.primary,
          side: const BorderSide(color: FeColors.primary, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(LucideIcons.map, size: 16),
        label: AppText.label(
          'assetDetail.view_floor_plan'.getString(context),
          color: FeColors.primary,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// UC-5 (docs/snag-assistant.md) — opens the raise form with this asset,
/// and its floor when the register has one, already filled in.
class _RaiseSnagButton extends StatelessWidget {
  const _RaiseSnagButton({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => context.push(
          Routes.snagNew(
            assetId: detail.id,
            assetName: detail.assetName ?? detail.assetReferenceId,
            assetReferenceId: detail.assetReferenceId,
            floorId: detail.floorId,
          ),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: FeColors.danger,
          side: const BorderSide(color: FeColors.danger, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(LucideIcons.flag, size: 16),
        label: AppText.label(
          'snags.raise_snag'.getString(context),
          color: FeColors.danger,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// FR-2.1 — identity block: name, reference id, type, and the reference
/// photo when the asset has one. The photo was once removed because most
/// records carry no `imageUrl` and the tile rendered as an empty box; it is
/// now shown only when there is a real link ([referencePhotoUrl]), from the
/// on-device copy when there is one (route downloads prefetch them), and
/// says so plainly when it was never downloaded. The type icon stays as the
/// fallback for the many assets with no photo.
class _IdentityBlock extends StatelessWidget {
  const _IdentityBlock({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FeColors.primary, FeColors.primaryLight],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: FeColors.primary.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_typeIcon(detail.type), color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.titleMedium(
                      detail.assetName ?? detail.assetReferenceId ?? detail.id,
                      color: Colors.white,
                      weight: FontWeight.w800,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: AppText.caption(
                        detail.assetReferenceId ?? detail.id,
                        color: Colors.white,
                        weight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (detail.imageUrl case final String url) ...[
            const SizedBox(height: 16),
            _ReferencePhoto(url: url, title: detail.assetName ?? detail.assetReferenceId ?? detail.id),
          ],
          if (detail.type != null || detail.category != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(LucideIcons.layers, size: 14, color: Colors.white70),
                const SizedBox(width: 6),
                Expanded(
                  child: AppText.bodySmall(
                    [detail.type, detail.category].where((v) => v != null && v.isNotEmpty).join(' · '),
                    color: Colors.white.withValues(alpha: 0.92),
                    weight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _typeIcon(String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('electric')) return LucideIcons.zap;
    if (t.contains('hvac') || t.contains('air')) return LucideIcons.wind;
    if (t.contains('plumb') || t.contains('water')) return LucideIcons.droplets;
    if (t.contains('fire')) return LucideIcons.flame;
    if (t.contains('security') || t.contains('access')) return LucideIcons.shieldCheck;
    if (t.contains('it') || t.contains('network') || t.contains('server')) return LucideIcons.server;
    if (t.contains('elevator') || t.contains('lift')) return LucideIcons.moveVertical;
    return LucideIcons.box;
  }
}

/// FR-2.6 — last check: date, who, result.
class _LastCheckCard extends StatelessWidget {
  const _LastCheckCard({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    final check = detail.lastCheck;
    return check == null
        ? AppText.bodyMedium('assetDetail.last_check_none'.getString(context), color: FeColors.ink2)
        : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _resultColor(check.result).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: AppText.bodySmall(
                    _resultLabel(check.result),
                    color: _resultColor(check.result),
                    weight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                if (check.verifiedByName != null)
                  _Row(label: 'assetDetail.checked_by'.getString(context), value: check.verifiedByName!),
                if (check.verifiedAt != null)
                  _Row(label: 'assetDetail.checked_at'.getString(context), value: _formatDate(check.verifiedAt!)),
              ],
            );
  }

  String _resultLabel(String result) =>
      result.isEmpty ? result : result[0].toUpperCase() + result.substring(1);

  Color _resultColor(String result) => switch (result.toLowerCase()) {
        'verified' => FeColors.success,
        'mismatch' || 'discrepancy' || 'failed' => FeColors.danger,
        _ => FeColors.info,
      };

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// FR-2.7 — open findings already raised against this asset, so a
/// technician does not file a duplicate report for something already known.
class _OpenFindings extends StatelessWidget {
  const _OpenFindings({required this.findings});

  final List<AssetFinding> findings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final f in findings)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_severityIcon(f.severity), size: 14, color: _severityColor(f.severity)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText.bodySmall(f.message),
                      if (f.ruleName != null)
                        AppText.caption(f.ruleName!, color: FeColors.ink2),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _severityIcon(String severity) => switch (severity) {
        'blocker' => LucideIcons.circleX,
        'warning' => LucideIcons.triangleAlert,
        _ => LucideIcons.info,
      };

  Color _severityColor(String severity) => switch (severity) {
        'blocker' => FeColors.danger,
        'warning' => FeColors.warning,
        _ => FeColors.info,
      };
}

/// FR-2.2 — the location walk, name and code kept as separate elements.
/// Rendered as a connected vertical timeline (dot-and-line per rung) so the
/// path from site down to the asset's exact spot reads as a single journey
/// rather than a flat, hard-to-scan list — with the final rung (where the
/// asset actually is) visually called out as the destination.
class _LocationWalk extends StatelessWidget {
  const _LocationWalk({required this.steps});

  final List<LocationStep> steps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          _LocationStepRow(step: steps[i], isLast: i == steps.length - 1),
      ],
    );
  }
}

class _LocationStepRow extends StatelessWidget {
  const _LocationStepRow({required this.step, required this.isLast});

  final LocationStep step;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final dotColor = isLast ? FeColors.primary : FeColors.ink2;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: isLast ? 16 : 10,
                height: isLast ? 16 : 10,
                margin: EdgeInsets.only(top: isLast ? 0 : 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isLast ? FeColors.primary : FeColors.panel,
                  border: Border.all(color: dotColor, width: 2),
                ),
                child: isLast
                    ? const Icon(LucideIcons.mapPin, size: 10, color: Colors.white)
                    : null,
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: FeColors.line,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.caption(
                    step.level.toUpperCase(),
                    color: FeColors.ink2,
                    weight: FontWeight.w700,
                  ),
                  const SizedBox(height: 2),
                  AppText.bodyMedium(
                    [step.label, step.code].where((v) => v != null && v.isNotEmpty).join(' · '),
                    weight: isLast ? FontWeight.w800 : FontWeight.w600,
                    color: isLast ? FeColors.primary : FeColors.ink,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// FR-2.3 — nameplate claims: manufacturer, model, serial, supplier tag, barcode.
class _NameplateClaims extends StatelessWidget {
  const _NameplateClaims({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (detail.manufacturer != null || detail.model != null) {
      rows.add(_Row(
        label: 'search.manufacturer_model'.getString(context),
        value: [detail.manufacturer, detail.model].where((v) => v != null && v.isNotEmpty).join(' · '),
      ));
    }
    if (detail.serialNumber != null && detail.serialNumber!.isNotEmpty) {
      rows.add(_Row(label: 'search.serial'.getString(context), value: detail.serialNumber!));
    }
    if (detail.supplierTagNumber != null && detail.supplierTagNumber!.isNotEmpty) {
      rows.add(_Row(label: 'assetDetail.supplier_tag'.getString(context), value: detail.supplierTagNumber!));
    }
    if (detail.barcode != null && detail.barcode!.isNotEmpty) {
      rows.add(_Row(label: 'assetDetail.barcode'.getString(context), value: detail.barcode!));
    }
    if (rows.isEmpty) {
      return AppText.bodySmall('—', color: FeColors.ink2);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

/// FR-2.4 (warranty verdict) + FR-2.5 (status chips) together as one
/// "Details" section — both are small, glanceable facts, unlike the
/// paragraph-style sections above.
class _StatusChips extends StatelessWidget {
  const _StatusChips({required this.detail});

  final AssetDetail detail;

  @override
  Widget build(BuildContext context) {
    final verdict = warrantyVerdict(detail.warrantyExpiryDate);
    final warrantyText = switch (verdict.status) {
      WarrantyStatus.none => 'assetDetail.warranty_none'.getString(context),
      WarrantyStatus.expired =>
        context.formatString('assetDetail.warranty_expired'.getString(context), [verdict.formattedDate!]),
      WarrantyStatus.expiresToday => 'assetDetail.warranty_expires_today'.getString(context),
      WarrantyStatus.active => context.formatString(
          (verdict.daysRemaining == 1
              ? 'assetDetail.warranty_day'
              : 'assetDetail.warranty_days')
              .getString(context),
          [verdict.daysRemaining.toString()],
        ),
    };

    final chips = <Widget>[
      _Chip(
        icon: LucideIcons.shieldCheck,
        label: warrantyText,
        color: verdict.status == WarrantyStatus.expired ? FeColors.danger : FeColors.info,
      ),
      if (detail.systemCode != null)
        _Chip(icon: LucideIcons.cpu, label: detail.systemCode!, color: FeColors.ink2),
      if (detail.isMaintainable != null)
        _Chip(
          icon: LucideIcons.wrench,
          label: (detail.isMaintainable!
                  ? 'assetDetail.maintainable'
                  : 'assetDetail.non_maintainable')
              .getString(context),
          color: detail.isMaintainable! ? FeColors.success : FeColors.ink2,
        ),
      if (detail.condition != null)
        _Chip(icon: LucideIcons.activity, label: detail.condition!, color: _conditionColor(detail.condition!)),
      if (detail.physicalTagStatus != null)
        _Chip(icon: LucideIcons.tag, label: detail.physicalTagStatus!, color: FeColors.ink2),
    ];

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }

  Color _conditionColor(String condition) => switch (condition.toLowerCase()) {
        'excellent' || 'good' => FeColors.success,
        'fair' => FeColors.warning,
        'poor' || 'critical' => FeColors.danger,
        _ => FeColors.ink2,
      };
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          AppText.caption(label, color: color, weight: FontWeight.w600),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.icon,
    this.accent = FeColors.primary,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FeColors.line),
        boxShadow: [
          BoxShadow(
            color: FeColors.ink.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 14, color: accent),
                ),
                const SizedBox(width: 8),
              ],
              AppText.labelMedium(
                title.toUpperCase(),
                color: FeColors.ink,
                weight: FontWeight.w800,
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText.caption(label, color: FeColors.ink2),
          AppText(value),
        ],
      ),
    );
  }
}

/// FR-2.1 — the reference photo: the on-device copy first (works offline),
/// else a download that also keeps the copy for next time. Tap for full
/// screen with pinch-zoom — a technician compares it against the real kit.
class _ReferencePhoto extends ConsumerStatefulWidget {
  const _ReferencePhoto({required this.url, required this.title});

  final String url;
  final String title;

  @override
  ConsumerState<_ReferencePhoto> createState() => _ReferencePhotoState();
}

class _ReferencePhotoState extends ConsumerState<_ReferencePhoto> {
  late Future<File?> _file = _load();

  Future<File?> _load() async {
    final cache = ref.read(assetPhotoCacheProvider);
    try {
      return await cache.cached(widget.url) ?? await cache.getOrDownload(widget.url);
    } catch (_) {
      return null; // offline and never downloaded
    }
  }

  @override
  void didUpdateWidget(_ReferencePhoto old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _file = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _file,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            height: 160,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
            ),
          );
        }
        if (file == null) {
          return Row(
            children: [
              const Icon(LucideIcons.imageOff, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              Expanded(
                child: AppText.bodySmall(
                  'assetDetail.photo_not_downloaded'.getString(context),
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ],
          );
        }
        return Semantics(
          button: true,
          label: 'assetDetail.photo_open'.getString(context),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => _PhotoViewer(file: file, title: widget.title),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.file(
                file,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
                // A corrupt or non-image file must not break the screen.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.file, required this.title});

  final File file;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      // The app theme's title style and status bar are for light screens;
      // both read dark-on-black here without these (seen on device).
      systemOverlayStyle: SystemUiOverlayStyle.light,
      title: AppText.title(title, color: Colors.white, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: Center(
      child: InteractiveViewer(maxScale: 5, child: Image.file(file)),
    ),
  );
}

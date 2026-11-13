import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/utils/dates.dart';
import '../../core/utils/external_launch.dart';
import '../../domain/asset_document.dart';
import '../../state/asset_documents_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/dir_icon.dart';

/// Documents attached to the record's asset — Warranty / O&M / Datasheet /
/// Certificates etc. Shared as-is between the Work Order detail screen and
/// the Maintenance Record (Preventive/Reactive/Annual) detail screen: both
/// are the same [OrderDetailScreen] parameterized by [OrderType], so mounting
/// this once in that screen's tab bar covers both places the task asks for.
///
/// Renders as a plain, non-scrolling column — same as the admin attachments
/// list right below it in [OrderDetailScreen] — so it's part of that page's
/// single scroll, not a second independently-scrollable region nested inside
/// it (a fixed-height box around an inner `ListView` used to make this its
/// own scrollable island, capturing drags instead of letting them move the
/// whole page).
class DocumentsTab extends ConsumerWidget {
  const DocumentsTab({super.key, required this.assetId});

  /// Null when the record carries no asset reference at all — a state the
  /// server allows for some reactive tickets.
  final String? assetId;

  Future<void> _open(BuildContext context, AssetDocument doc) async {
    if (doc.url.isEmpty) return;
    if (doc.isImage) {
      await showPhotoViewer(context, urls: [doc.url], initial: doc.url);
      return;
    }
    // PDFs and Office files (doc/docx/xls/xlsx) never render inside
    // WebPageScreen's plain WebViewWidget — Android's WebView ships with no
    // built-in renderer for them, so pushing that screen is a guaranteed
    // dead end: an infinite spinner with no escape. Skip it entirely and go
    // straight to the same "open in system app" path WebPageScreen's own
    // external-open button already uses, so the technician lands directly in
    // whatever PDF/Office viewer the device has.
    if (doc.isExternalViewerOnly) {
      await launchExternalUrl(doc.url);
      return;
    }
    if (!context.mounted) return;
    // Reuses the app's one in-app browser (used for the /public/* asset and
    // material sheets a QR sticker points at) rather than standing up a
    // second webview screen — it already has the "open in system browser"
    // fallback for whatever this in-app viewer still cannot render.
    context.push(Routes.webPage(doc.url, title: doc.name));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = assetId;
    if (id == null || id.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: TechEmptyState(
          icon: LucideIcons.fileX,
          title: 'order_detail.documents_empty_title'.getString(context),
          subtitle:
              'order_detail.documents_no_asset_subtitle'.getString(context),
        ),
      );
    }

    final state = ref.watch(assetDocumentsControllerProvider(id));

    return state.when(
      loading: () => const TechSpinner(),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: TechEmptyState(
          icon: LucideIcons.cloudOff,
          title: 'order_detail.documents_offline_title'.getString(context),
          subtitle:
              'order_detail.documents_offline_subtitle'.getString(context),
        ),
      ),
      data: (data) {
        final docs = data.documents;
        if (docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: TechEmptyState(
              icon: LucideIcons.fileText,
              title: 'order_detail.documents_empty_title'.getString(context),
              subtitle: 'order_detail.documents_empty_subtitle'
                  .getString(context),
            ),
          );
        }
        return Column(
          children: [
            if (data.fromCache) ...[
              const _CachedNotice(),
              const SizedBox(height: 12),
            ],
            for (final doc in docs) ...[
              _DocumentRow(doc: doc, onTap: () => _open(context, doc)),
              if (doc != docs.last) const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

class _CachedNotice extends StatelessWidget {
  const _CachedNotice();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: FeColors.warningSoft,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const Icon(LucideIcons.cloudOff, size: 14, color: FeColors.warning),
        const SizedBox(width: 8),
        Expanded(
          child: AppText.caption(
            'order_detail.documents_cached_notice'.getString(context),
            color: FeColors.warning,
            weight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({required this.doc, required this.onTap});

  final AssetDocument doc;
  final VoidCallback onTap;

  static const _iconsByType = {
    'PDF': LucideIcons.fileText,
    'DOC': LucideIcons.fileText,
    'DOCX': LucideIcons.fileText,
    'XLS': LucideIcons.fileSpreadsheet,
    'XLSX': LucideIcons.fileSpreadsheet,
    'CSV': LucideIcons.fileSpreadsheet,
    'PPT': LucideIcons.presentation,
    'PPTX': LucideIcons.presentation,
    'LINK': LucideIcons.link,
  };

  IconData get _icon =>
      doc.isImage ? LucideIcons.image : (_iconsByType[doc.type] ?? LucideIcons.file);

  String get _meta {
    final parts = <String>[
      doc.type,
      if (doc.size != null) _formatBytes(doc.size!),
      if (doc.uploadedAt != null) formatDate(doc.uploadedAt!),
    ];
    return parts.join(' · ');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) => TechCard(
    onTap: onTap,
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: FeColors.infoSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(_icon, size: 18, color: FeColors.info),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.bodyMedium(
                doc.name,
                weight: FontWeight.w600,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              AppText.caption(_meta, color: FeColors.ink2),
              if (doc.uploadedBy != null && doc.uploadedBy!.isNotEmpty) ...[
                const SizedBox(height: 2),
                AppText.caption(
                  context.formatString(
                    'order_detail.uploaded_by'.getString(context),
                    [doc.uploadedBy],
                  ),
                  color: FeColors.ink2,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        const DirIcon(LucideIcons.chevronRight, size: 16, color: FeColors.ink2),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/offline/prefetch.dart';
import '../../domain/technician_profile.dart';
import '../../state/auth_controller.dart';
import '../../state/profile_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/progress_ring.dart';
import '../../widgets/tech_header.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final pending = await ref.read(pendingMutationCountProvider.future);
    if (!context.mounted) return;
    if (!await showLogoutDialog(context, pendingCount: pending)) return;
    await ref.read(authControllerProvider.notifier).logout();
    if (context.mounted) context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).session;
    final permissions = ref.watch(authControllerProvider).permissions;
    final page = ref.watch(technicianProfileProvider);

    final profile = page.valueOrNull?.profile;
    final metrics = page.valueOrNull?.metrics;
    final name = profile?.name.isNotEmpty == true
        ? profile!.name
        : (session?.name ?? 'Balaji');

    return Scaffold(
      backgroundColor: FeColors.page,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async => ref.invalidate(technicianProfileProvider),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Top Bar with Profile Title and Sign Out action button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'profile.title'.getString(context),
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: FeColors.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Material(
                    color: FeColors.panel,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _logout(context, ref),
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          LucideIcons.logOut,
                          size: 18,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // Hero Identity Card with soft airy sky-blue wave
              _ProfileHeroCard(
                name: name,
                email: profile?.email ?? session?.email ?? 'balaji@eco.com',
                phone: profile?.phone,
                department: profile?.department ?? session?.department,
                status: profile?.status,
                experienceYears: profile?.experienceYears,
                specialization: profile?.specialization ?? const [],
              ),
              const SizedBox(height: 22),

              // Performance Section
              Text(
                'profile.performance_section'.getString(context),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: FeColors.ink,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 12),

              if (page.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: TechSpinner(),
                )
              else if (metrics == null)
                TechEmptyState(
                  icon: LucideIcons.chartColumn,
                  title: 'profile.metrics_unavailable_title'.getString(
                    context,
                  ),
                  subtitle: 'common.pull_down_to_retry'.getString(context),
                )
              else
                _PerformanceMetrics(metrics: metrics),

              if (profile != null && profile.certifications.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text(
                  'profile.certifications_section'.getString(context),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: FeColors.ink,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 12),
                _CertificationsCard(certifications: profile.certifications),
              ],
              const SizedBox(height: 18),

              // My schedules (docs/conversations-and-schedules.md) —
              // reminders and checks asked for with "@agent remind me…".
              const _MySchedulesLink(),
              const SizedBox(height: 16),

              // Download My Work Card
              const _DownloadMyWorkCard(),
              const SizedBox(height: 16),

              // Account & System Info Card
              _AccountDetailsCard(
                technicianId: session?.technicianId ?? '—',
                partnerRole:
                    session?.partnerRole ??
                    'profile.partner_role_default'.getString(context),
                aiAssistant: permissions.isAiAgent
                    ? 'common.enabled'.getString(context)
                    : 'common.disabled'.getString(context),
              ),
              const SizedBox(height: 18),

              // Big Sign Out Button
              PressableScale(
                scale: 0.98,
                child: Material(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _logout(context, ref),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            LucideIcons.logOut,
                            size: 18,
                            color: Color(0xFFEF4444),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'common.sign_out_title'.getString(context),
                            style: const TextStyle(
                              color: Color(0xFFEF4444),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hero Profile Identity Card
class _ProfileHeroCard extends StatelessWidget {
  const _ProfileHeroCard({
    required this.name,
    required this.email,
    required this.phone,
    required this.department,
    required this.status,
    required this.experienceYears,
    required this.specialization,
  });

  final String name;
  final String? email;
  final String? phone;
  final String? department;
  final String? status;
  final double? experienceYears;
  final List<String> specialization;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFDBEAFE), Color(0xFFEFF6FF), Color(0xFFE0F2FE)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0284C7).withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFF0284C7),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x330284C7),
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Text(
                      name.isEmpty ? '?' : name[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: FeColors.ink,
                            letterSpacing: -0.3,
                          ),
                        ),
                        if (email != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            email!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                        if (phone != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            phone!,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                height: 1,
                color: const Color(0xFFBFDBFE).withValues(alpha: 0.6),
              ),
              const SizedBox(height: 14),

              // Facts Grid
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _FactPill(
                    label: 'profile.department_label'.getString(context),
                    value:
                        department ??
                        'profile.department_default'.getString(context),
                  ),
                  _FactPill(
                    label: 'profile.status_label'.getString(context),
                    value:
                        status ?? 'profile.status_default'.getString(context),
                    isStatus: true,
                  ),
                  _FactPill(
                    label: 'profile.experience_label'.getString(context),
                    value: context.formatString(
                      'profile.experience_years_value'.getString(context),
                      [_trimZero(experienceYears ?? 0)],
                    ),
                  ),
                  _FactPill(
                    label: 'profile.specialization_label'.getString(context),
                    value: specialization.isEmpty
                        ? 'profile.specialization_default'.getString(context)
                        : specialization.join(', '),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FactPill extends StatelessWidget {
  const _FactPill({
    required this.label,
    required this.value,
    this.isStatus = false,
  });

  final String label;
  final String value;
  final bool isStatus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF64748B),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: isStatus ? const Color(0xFF10B981) : FeColors.ink,
          ),
        ),
      ],
    );
  }
}

/// Performance Metrics View
class _PerformanceMetrics extends StatelessWidget {
  const _PerformanceMetrics({required this.metrics});

  final TechnicianMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Completion Rate Hero Card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: FeColors.panel,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFF1F5F9)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              ProgressRing(
                value: (metrics.completionRate / 100).clamp(0.0, 1.0),
                size: 80,
                strokeWidth: 8,
                colors: const [Color(0xFF0284C7), Color(0xFF38BDF8)],
                child: Text(
                  '${_trimZero(metrics.completionRate)}%',
                  style: const TextStyle(
                    color: FeColors.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'profile.total_orders_label'.getString(context),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Icon(
                          LucideIcons.trendingUp,
                          size: 18,
                          color: Color(0xFF0284C7),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${metrics.totalOrders}',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: FeColors.ink,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'profile.all_time_completed'.getString(context),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 2x2 Metric Tiles Grid
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: 'profile.completed_label'.getString(context),
                value: '${metrics.completedOrders}',
                caption: 'profile.finished_tasks_caption'.getString(context),
                icon: LucideIcons.circleCheck,
                iconColor: const Color(0xFF10B981),
                badgeBg: const Color(0xFFDCFCE7),
                tintColor: const Color(0xFFDCFCE7),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                label: 'profile.avg_resolution_label'.getString(context),
                value: context.formatString(
                  'profile.avg_resolution_value'.getString(context),
                  [_trimZero(metrics.avgResolutionTime)],
                ),
                caption: 'profile.per_order_caption'.getString(context),
                icon: LucideIcons.clock,
                iconColor: const Color(0xFF0284C7),
                badgeBg: const Color(0xFFDBEAFE),
                tintColor: const Color(0xFFDBEAFE),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: 'profile.quality_score_label'.getString(context),
                value: context.formatString(
                  'profile.score_out_of_5'.getString(context),
                  [_trimZero(metrics.qualityScore)],
                ),
                caption: 'profile.rating_caption'.getString(context),
                icon: LucideIcons.star,
                iconColor: const Color(0xFFF59E0B),
                badgeBg: const Color(0xFFFEF3C7),
                tintColor: const Color(0xFFFEF3C7),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                label: 'profile.satisfaction_label'.getString(context),
                value: context.formatString(
                  'profile.score_out_of_5'.getString(context),
                  [_trimZero(metrics.customerSatisfaction)],
                ),
                caption: 'profile.customer_feedback_caption'.getString(
                  context,
                ),
                icon: LucideIcons.smile,
                iconColor: const Color(0xFF8B5CF6),
                badgeBg: const Color(0xFFEDE9FE),
                tintColor: const Color(0xFFEDE9FE),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.iconColor,
    required this.badgeBg,
    required this.tintColor,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color iconColor;
  final Color badgeBg;
  final Color tintColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, tintColor],
          stops: const [0.0, 0.72, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: badgeBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 15, color: iconColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: FeColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}

/// Certifications Card
class _CertificationsCard extends StatelessWidget {
  const _CertificationsCard({required this.certifications});

  final List<String> certifications;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < certifications.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == certifications.length - 1 ? 0 : 10,
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFEF3C7),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.award,
                      size: 17,
                      color: Color(0xFFD97706),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      certifications[i],
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: FeColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Download My Work Card
class _DownloadMyWorkCard extends ConsumerStatefulWidget {
  const _DownloadMyWorkCard();

  @override
  ConsumerState<_DownloadMyWorkCard> createState() =>
      _DownloadMyWorkCardState();
}

class _DownloadMyWorkCardState extends ConsumerState<_DownloadMyWorkCard> {
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  Future<void> _download() async {
    final session = ref.read(authControllerProvider).session;
    if (session == null || session.userId.isEmpty) return;

    setState(() {
      _busy = true;
      _done = 0;
      _total = 0;
    });
    final result = await prefetchOfflineBundle(
      ref.read(syncClientProvider),
      session.userId,
      force: true,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);

    final message = result.offline
        ? 'profile.download_offline_message'.getString(context)
        : result.failed > 0
        ? context.formatString(
            'profile.download_partial_message'.getString(context),
            [result.saved, result.failed],
          )
        : context.formatString(
            'profile.download_success_message'.getString(context),
            [result.saved],
          );
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                LucideIcons.cloudDownload,
                size: 20,
                color: Color(0xFF0284C7),
              ),
              const SizedBox(width: 10),
              Text(
                'profile.download_my_work_title'.getString(context),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: FeColors.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'profile.download_my_work_description'.getString(context),
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF64748B),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          PressableScale(
            scale: 0.98,
            child: Material(
              color: const Color(0xFFF0F9FF),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _busy ? null : _download,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFBAE6FD)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(
                                  Color(0xFF0284C7),
                                ),
                              ),
                            )
                          : const Icon(
                              LucideIcons.download,
                              size: 16,
                              color: Color(0xFF0284C7),
                            ),
                      const SizedBox(width: 8),
                      Text(
                        _busy
                            ? _total > 0
                                ? '${'profile.downloading_label'.getString(context)} ${(_done / _total * 100).round()}%'
                                : 'profile.downloading_label'.getString(context)
                            : 'profile.download_button_label'.getString(
                                context,
                              ),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0284C7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_busy && _total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _done / _total,
                  minHeight: 6,
                  backgroundColor: const Color(0xFFE0F2FE),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF0284C7)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Account & System Details
class _AccountDetailsCard extends StatelessWidget {
  const _AccountDetailsCard({
    required this.technicianId,
    required this.partnerRole,
    required this.aiAssistant,
  });

  final String technicianId;
  final String partnerRole;
  final String aiAssistant;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          _DetailRow(
            label: 'profile.reference_id_label'.getString(context),
            value: technicianId,
          ),
          const Divider(height: 16, color: Color(0xFFF1F5F9)),
          _DetailRow(
            label: 'profile.partner_role_label'.getString(context),
            value: partnerRole,
          ),
          const Divider(height: 16, color: Color(0xFFF1F5F9)),
          _DetailRow(
            label: 'profile.ai_assistant_label'.getString(context),
            value: aiAssistant,
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13.5,
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13.5,
            color: FeColors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

String _trimZero(num value) {
  final asDouble = value.toDouble();
  return asDouble == asDouble.roundToDouble()
      ? asDouble.round().toString()
      : asDouble.toStringAsFixed(1);
}

class _MySchedulesLink extends StatelessWidget {
  const _MySchedulesLink();

  @override
  Widget build(BuildContext context) => TechCard(
    onTap: () => context.push(Routes.schedules()),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: FeColors.aiSoft, shape: BoxShape.circle),
          child: const Icon(LucideIcons.calendarClock, size: 20, color: FeColors.ai),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.titleSmall('schedules.title'.getString(context)),
              const SizedBox(height: 2),
              AppText.bodySmall('schedules.profile_sub'.getString(context), color: FeColors.ink2),
            ],
          ),
        ),
        const Icon(LucideIcons.chevronRight, size: 18, color: FeColors.ink2),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/snag_estimate_repository.dart';
import '../../../domain/snag.dart';
import '../../../domain/snag_estimate.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/tech_popup.dart';
import 'snag_visuals.dart';

/// "Estimate & quote" on the snag detail screen — the main AI help on a
/// snag since 2026-10-10 (owner: photo analysis is not the headline; the AI
/// should work out the materials, the approximate cost and help with a
/// quote). Server: documentation/snag-assistant.md §4c.
///
/// On open it asks the server with `ai:false`: quick, no AI wait, and it
/// brings back a cached estimate if one exists plus the parts that need no
/// AI (who pays, DLP / warranty, fix-by, similar past snags). "Work out scope
/// & cost" asks the AI (~15–25 s). Every amount is the server's; a material
/// it can't price shows "Price needed", never a guess.
///
/// Writes (draft quote, reserve / request materials, work order) happen only
/// from their review sheets, after the technician taps the named button.
/// Online-only: offline the card says so and nothing is queued.
class SnagEstimateCard extends ConsumerStatefulWidget {
  const SnagEstimateCard({super.key, required this.snag, this.onChanged});
  final Snag snag;

  /// Something changed on the server (a quote, materials, a work order, an
  /// applied priority / due date): the screen re-reads the snag.
  final VoidCallback? onChanged;

  @override
  ConsumerState<SnagEstimateCard> createState() => _SnagEstimateCardState();
}

class _SnagEstimateCardState extends ConsumerState<SnagEstimateCard> {
  SnagEstimate? _est;
  var _loading = true;
  var _running = false;
  var _offline = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    if (!widget.snag.localOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(ai: false);
      });
    }
  }

  Future<void> _load({required bool ai, bool fresh = false}) async {
    setState(() {
      if (ai) _running = true;
      _failed = false;
    });
    try {
      final e = await ref.read(snagEstimateRepositoryProvider).estimate(widget.snag.id, ai: ai, fresh: fresh);
      if (!mounted) return;
      setState(() {
        _est = e;
        _offline = false;
      });
    } on SnagEstimateFailure catch (f) {
      if (!mounted) return;
      setState(() {
        _offline = f.offline;
        _failed = !f.offline;
      });
    } catch (_) {
      // Anything else (an answer we couldn't read, no API client in a test
      // rig): the card says "couldn't do it" — the rest of the screen is unaffected.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _running = false;
        });
      }
    }
  }

  String _money(double v, String cur) => NumberFormat.simpleCurrency(name: cur).format(v);
  String _range(MoneyRange r, String cur) => r.low == r.high ? _money(r.low, cur) : '${_money(r.low, cur)} – ${_money(r.high, cur)}';

  @override
  Widget build(BuildContext context) {
    final s = widget.snag;
    final e = _est;
    final live = s.status != SnagStatus.closed && s.status != SnagStatus.waived;
    return Container(
      key: const ValueKey('snag-estimate-card'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FeColors.aiLine),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.calculator, size: 18, color: FeColors.ai),
              const SizedBox(width: 8),
              Expanded(child: AppText.titleSmall('snags.est.title'.getString(context))),
              if (!s.localOnly && !_running && e != null && e.hasScope)
                TextButton(
                  onPressed: () => _load(ai: true, fresh: true),
                  style: TextButton.styleFrom(foregroundColor: FeColors.ai, visualDensity: VisualDensity.compact),
                  child: Text('snags.est.again'.getString(context)),
                ),
            ],
          ),
          const SizedBox(height: 2),
          AppText.bodySmall('snags.est.subtitle'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 10),
          if (s.localOnly)
            AppText.bodySmall('snags.est.local_only'.getString(context), color: FeColors.ink2)
          else if (_offline && e == null)
            _Note(icon: LucideIcons.cloudOff, text: 'snags.est.offline'.getString(context))
          else if (_loading && e == null)
            const LinearProgressIndicator(minHeight: 2, color: FeColors.ai, backgroundColor: FeColors.aiSoft)
          else ...[
            if (_failed) _Note(icon: LucideIcons.circleAlert, text: 'snags.est.failed'.getString(context)),
            if (_running) ...[
              Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: FeColors.ai)),
                  const SizedBox(width: 8),
                  Expanded(child: AppText.bodySmall('snags.est.working'.getString(context), color: FeColors.ai)),
                ],
              ),
              const SizedBox(height: 10),
            ],
            if (e != null && e.aiFailed && !_running) _Note(icon: LucideIcons.cloudOff, text: 'snags.est.ai_offline'.getString(context)),
            if (e != null && !e.hasScope && !_running)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('snag-estimate-run'),
                  onPressed: () => _load(ai: true),
                  style: FilledButton.styleFrom(backgroundColor: FeColors.ai, foregroundColor: Colors.white),
                  icon: const Icon(LucideIcons.sparkles, size: 16),
                  label: Text('snags.est.run'.getString(context)),
                ),
              ),
            if (e != null && e.hasScope) ..._estimateBody(context, e),
            if (e != null) ...[const SizedBox(height: 10), ..._facts(context, e, live)],
            if (e != null && live) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('snag-estimate-quote'),
                    onPressed: e.hasScope ? () => _openQuote(e) : null,
                    icon: const Icon(LucideIcons.fileText, size: 16),
                    label: Text('snags.est.prepare_quote'.getString(context)),
                  ),
                  if (e.hasCatalogueItems)
                    OutlinedButton.icon(
                      onPressed: () => _openMaterials(e),
                      icon: const Icon(LucideIcons.packageCheck, size: 16),
                      label: Text('snags.est.reserve'.getString(context)),
                    ),
                  if (s.workOrderId == null && e.workOrderId == null)
                    OutlinedButton.icon(
                      onPressed: () => _openWorkOrder(e),
                      icon: const Icon(LucideIcons.wrench, size: 16),
                      label: Text('snags.est.create_wo'.getString(context)),
                    ),
                ],
              ),
            ],
            if (e != null && e.linked.isNotEmpty) ...[
              const SizedBox(height: 12),
              AppText.caption('snags.est.done_from'.getString(context), color: FeColors.ink2),
              for (final l in e.linked)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.circleCheck, size: 14, color: FeColors.success),
                      const SizedBox(width: 6),
                      Expanded(child: AppText.bodySmall(l.note ?? l.number ?? '—')),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  List<Widget> _estimateBody(BuildContext context, SnagEstimate e) {
    final cur = e.currency;
    return [
      // cost headline
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: FeColors.aiSoft, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText.caption('snags.est.cost'.getString(context), color: FeColors.ink2),
            AppText.title(_range(e.total, cur)),
            if (!e.complete) AppText.bodySmall(snagTr(context, 'snags.est.needs_price_count', [e.unpricedCount]), color: FeColors.warning),
            const SizedBox(height: 6),
            if (e.labour != null)
              _Line(
                label: 'snags.est.labour'.getString(context),
                value: _range(e.labour!, cur),
                sub: e.crewSize == null || e.labourRate == null
                    ? null
                    : snagTr(context, 'snags.est.labour_line', [e.crewSize!, _h(e.durationLow), _h(e.durationHigh), _money(e.labourRate!, cur)]),
              ),
            _Line(label: 'snags.est.materials'.getString(context), value: _range(e.materialsCost, cur)),
            _Line(label: snagTr(context, 'snags.est.contingency', [_h(e.contingencyPct)]), value: _money(e.contingency, cur)),
          ],
        ),
      ),
      if (e.summary != null || e.steps.isNotEmpty) ...[
        const SizedBox(height: 10),
        AppText.caption('snags.est.scope'.getString(context), color: FeColors.ink2),
        if (e.summary != null) AppText.bodyMedium(e.summary!),
        for (var i = 0; i < e.steps.length; i++) AppText.bodySmall('${i + 1}. ${e.steps[i]}'),
        if (e.trades.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: AppText.bodySmall(e.trades.map((t) => SnagVisuals.tradeLabel(context, t)).join(' · '), color: FeColors.ink2),
          ),
      ],
      if (e.materials.isNotEmpty) ...[
        const SizedBox(height: 10),
        AppText.caption('snags.est.materials'.getString(context), color: FeColors.ink2),
        for (final m in e.materials) _MaterialRow(m: m, money: (v) => _money(v, cur), range: (r) => _range(r, cur)),
      ],
      if (e.assumptions.isNotEmpty) ...[
        const SizedBox(height: 10),
        // Its own transparent Material: the card's white box sits between the
        // page's Material and this tile, which hides ink splashes otherwise.
        Material(
          type: MaterialType.transparency,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              dense: true,
              title: AppText.caption('snags.est.assumptions'.getString(context), color: FeColors.ink2),
              children: [
                for (final a in e.assumptions)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppText.bodySmall('• $a', color: FeColors.ink2),
                  ),
              ],
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _facts(BuildContext context, SnagEstimate e, bool live) {
    final cur = e.currency;
    return [
      _Fact(
        label: 'snags.est.who_pays'.getString(context),
        value: e.responsibleParty,
        trailing: e.backCharge ? 'snags.est.back_charge'.getString(context) : null,
        sub: e.responsibilityBasis.isEmpty ? null : e.responsibilityBasis.first,
      ),
      _Fact(
        label: 'snags.est.warranty'.getString(context),
        value: 'snags.est.warranty.${e.warrantyStatus}'.getString(context),
        sub: e.warrantyUntil != null ? DateFormat.yMMMd().format(e.warrantyUntil!) : e.warrantyBasis,
      ),
      if (e.suggestedPriority != null)
        _Fact(
          label: 'snags.est.priority'.getString(context),
          value: SnagVisuals.priorityLabel(context, e.suggestedPriority!),
          sub: e.priorityReason,
          action: live && e.priorityChanged
              ? TextButton(
                  onPressed: _applying ? null : () => _apply(priority: e.suggestedPriority),
                  child: Text('snags.est.apply'.getString(context)),
                )
              : null,
        ),
      if (e.slaDue != null)
        _Fact(
          label: 'snags.est.fix_by'.getString(context),
          value: DateFormat.yMMMd().format(e.slaDue!),
          sub: e.slaBasis,
          action: live && !_sameDay(widget.snag.dueDate, e.slaDue)
              ? TextButton(
                  onPressed: _applying ? null : () => _apply(dueDate: e.slaDue),
                  child: Text('snags.est.set_due'.getString(context)),
                )
              : null,
        ),
      _Fact(
        label: 'snags.est.similar'.getString(context),
        value: e.benchmarkCount == 0
            ? e.benchmarkNote
            : [
                snagTr(context, 'snags.est.similar_line', [e.benchmarkCount, e.benchmarkDays == null ? '—' : _h(e.benchmarkDays)]),
                if (e.benchmarkCost != null) _range(e.benchmarkCost!, cur),
              ].join(' · '),
      ),
    ];
  }

  var _applying = false;

  /// "Apply" on the suggested priority / "Set as due" on the fix-by date — a
  /// normal edit under the technician's name, made only on that tap.
  Future<void> _apply({SnagPriority? priority, DateTime? dueDate}) async {
    final saved = 'snags.saved'.getString(context);
    final failed = 'snags.est.failed'.getString(context);
    setState(() => _applying = true);
    try {
      await ref.read(snagEstimateRepositoryProvider).applySuggestion(widget.snag.id, priority: priority, dueDate: dueDate);
      if (!mounted) return;
      showTechPopup(context, message: saved);
      _afterWrite();
    } on SnagEstimateFailure catch (f) {
      if (mounted) showTechPopup(context, message: f.offline || f.message.isEmpty ? failed : f.message, isError: true);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  static bool _sameDay(DateTime? a, DateTime? b) => a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;

  // ── review sheets ──────────────────────────────────────────────────────────

  Future<void> _openQuote(SnagEstimate e) async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SnagQuoteSheet(snag: widget.snag, estimate: e),
    );
    if (created == true) _afterWrite();
  }

  Future<void> _openMaterials(SnagEstimate e) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _MaterialsSheet(snag: widget.snag, estimate: e),
    );
    if (done == true) _afterWrite();
  }

  Future<void> _openWorkOrder(SnagEstimate e) async {
    final repo = ref.read(snagEstimateRepositoryProvider);
    final requestId = SnagEstimateRepository.newRequestId();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => _ConfirmSheet(
        title: 'snags.est.create_wo'.getString(ctx),
        body: 'snags.est.wo_body'.getString(ctx),
        confirm: 'snags.est.create_wo'.getString(ctx),
        run: () async {
          // Words read before the await: the sheet's context may be gone after it.
          final linked = 'snags.est.wo_linked'.getString(ctx);
          final created = 'snags.est.wo_done'.getString(ctx);
          final r = await repo.workOrder(widget.snag.id, requestId: requestId, dueDate: e.slaDue, estimatedHours: e.personHoursHigh);
          return (r.alreadyLinked ? linked : created).replaceFirst('%a', r.workOrderId);
        },
      ),
    );
    if (ok == true) _afterWrite();
  }

  void _afterWrite() {
    widget.onChanged?.call();
    _load(ai: false);
  }
}

String _h(double? v) => v == null ? '—' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1));

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: FeColors.ink2),
        const SizedBox(width: 6),
        Expanded(child: AppText.bodySmall(text, color: FeColors.ink2)),
      ],
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.sub});
  final String label;
  final String value;
  final String? sub;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.bodySmall(label),
              if (sub != null) AppText.caption(sub!, color: FeColors.ink2),
            ],
          ),
        ),
        const SizedBox(width: 8),
        AppText.bodySmall(value, weight: FontWeight.w600),
      ],
    ),
  );
}

class _MaterialRow extends StatelessWidget {
  const _MaterialRow({required this.m, required this.money, required this.range});
  final EstimateMaterial m;
  final String Function(double) money;
  final String Function(MoneyRange) range;
  @override
  Widget build(BuildContext context) {
    final where = m.inCatalogue ? 'snags.est.in_catalogue'.getString(context) : 'snags.est.not_in_catalogue'.getString(context);
    final stock = m.available == null
        ? null
        : (m.shortBy ?? 0) > 0
        ? snagTr(context, 'snags.est.stock_short', [_h(m.shortBy)])
        : snagTr(context, 'snags.est.stock_free', [_h(m.available)]);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodySmall('${m.displayName} · ${_h(m.quantity)} ${m.unit ?? ''}'.trim(), weight: FontWeight.w600),
                AppText.caption([where, ?stock, ?m.vendorName].join(' · '), color: (m.shortBy ?? 0) > 0 ? FeColors.warning : FeColors.ink2),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (m.lineCost != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AppText.bodySmall(range(m.lineCost!), weight: FontWeight.w600),
                if (m.priceSource == 'past-quote') AppText.caption('snags.est.past_quotes'.getString(context), color: FeColors.ink2),
              ],
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: FeColors.warningSoft, borderRadius: BorderRadius.circular(999)),
              child: Text(
                'snags.est.price_needed'.getString(context),
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: FeColors.ink),
              ),
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.sub, this.trailing, this.action});
  final String label;
  final String value;
  final String? sub;
  final String? trailing;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 96, child: AppText.caption(label, color: FeColors.ink2)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  AppText.bodySmall(value, weight: FontWeight.w600),
                  if (trailing != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: FeColors.warningSoft, borderRadius: BorderRadius.circular(999)),
                      child: Text(
                        trailing!,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: FeColors.ink),
                      ),
                    ),
                  // Inside the Wrap, not a trailing Row child: a long label
                  // (Arabic "Set as due") must wrap, not overflow the row.
                  ?action,
                ],
              ),
              if (sub != null && sub!.isNotEmpty) AppText.caption(sub!, color: FeColors.ink2, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Review the draft-quote lines: fill in missing prices, untick lines, then
/// "Create draft quote". One requestId per opening of the sheet, reused on
/// retry, so the server returns the first quote on a double tap.
class SnagQuoteSheet extends ConsumerStatefulWidget {
  const SnagQuoteSheet({super.key, required this.snag, required this.estimate});
  final Snag snag;
  final SnagEstimate estimate;
  @override
  ConsumerState<SnagQuoteSheet> createState() => _SnagQuoteSheetState();
}

class _SnagQuoteSheetState extends ConsumerState<SnagQuoteSheet> {
  late final List<QuoteLineDraft> _lines = quoteLinesFrom(widget.estimate);
  late final List<TextEditingController> _price = [for (final l in _lines) TextEditingController(text: l.unitPrice == null ? '' : _h(l.unitPrice))];
  final _requestId = SnagEstimateRepository.newRequestId();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _price) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ready => _lines.any((l) => l.include) && _lines.where((l) => l.include).every((l) => l.unitPrice != null && l.quantity > 0);

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final e = widget.estimate;
    try {
      final r = await ref
          .read(snagEstimateRepositoryProvider)
          .draftQuote(
            widget.snag.id,
            requestId: _requestId,
            lines: _lines.where((l) => l.include).toList(),
            contingencyPct: e.contingencyPct,
            subject: 'Snag repair — ${widget.snag.reference != null ? '${widget.snag.reference} ' : ''}${widget.snag.title}',
            scope: [?e.summary, for (var i = 0; i < e.steps.length; i++) '${i + 1}. ${e.steps[i]}'].join('\n'),
            assumptions: e.assumptions,
          );
      if (!mounted) return;
      showTechPopup(context, message: snagTr(context, 'snags.est.quote_done', [r.quoteNumber]));
      Navigator.of(context).pop(true);
    } on SnagEstimateFailure catch (f) {
      if (mounted) setState(() => _error = f.offline || f.message.isEmpty ? 'snags.est.failed'.getString(context) : f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.estimate.currency;
    final fmt = NumberFormat.simpleCurrency(name: cur);
    final base = _lines.where((l) => l.include).fold<double>(0, (s, l) => s + l.quantity * (l.unitPrice ?? 0));
    final total = base * (1 + widget.estimate.contingencyPct / 100);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: AppText.titleMedium('snags.est.quote_title'.getString(context))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AppText.bodySmall('snags.est.quote_hint'.getString(context), color: FeColors.ink2),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              children: [
                for (var i = 0; i < _lines.length; i++)
                  Row(
                    children: [
                      Checkbox(value: _lines[i].include, onChanged: _busy ? null : (v) => setState(() => _lines[i].include = v ?? false)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppText.bodySmall(_lines[i].name, weight: FontWeight.w600, maxLines: 2, overflow: TextOverflow.ellipsis),
                            AppText.caption('${_h(_lines[i].quantity)} ${_lines[i].unit ?? ''}'.trim(), color: FeColors.ink2),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 104,
                        child: TextField(
                          key: ValueKey('snag-quote-price-$i'),
                          controller: _price[i],
                          enabled: !_busy && _lines[i].include,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.end,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'snags.est.price_needed'.getString(context),
                            filled: _lines[i].include && _lines[i].unitPrice == null,
                            fillColor: FeColors.warningSoft,
                          ),
                          onChanged: (v) => setState(() => _lines[i].unitPrice = double.tryParse(v.replaceAll(',', ''))),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AppText.bodySmall(snagTr(context, 'snags.est.quote_total', [fmt.format(total), _h(widget.estimate.contingencyPct)]), color: FeColors.ink2),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: AppText.bodySmall(_error!, color: FeColors.danger),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              key: const ValueKey('snag-quote-create'),
              onPressed: _ready && !_busy ? _submit : null,
              icon: _busy
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white))
                  : const Icon(LucideIcons.fileText, size: 16),
              label: Text('snags.est.create_quote'.getString(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MaterialsSheet extends ConsumerStatefulWidget {
  const _MaterialsSheet({required this.snag, required this.estimate});
  final Snag snag;
  final SnagEstimate estimate;
  @override
  ConsumerState<_MaterialsSheet> createState() => _MaterialsSheetState();
}

class _MaterialsSheetState extends ConsumerState<_MaterialsSheet> {
  late final List<EstimateMaterial> _items = widget.estimate.materials.where((m) => m.inCatalogue).toList();
  late final List<bool> _include = [for (final _ in _items) true];
  late final List<String> _action = [for (final m in _items) (m.available ?? 0) >= m.quantity.ceil() ? 'reserve' : 'request'];
  final _requestId = SnagEstimateRepository.newRequestId();
  var _busy = false;
  List<({String name, bool ok, String message})>? _result;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(snagEstimateRepositoryProvider)
          .materials(
            widget.snag.id,
            requestId: _requestId,
            lines: [
              for (var i = 0; i < _items.length; i++)
                if (_include[i]) (materialId: _items[i].materialId!, quantity: _items[i].quantity.ceil(), action: _action[i], vendorId: _items[i].vendorId),
            ],
          );
      if (mounted) setState(() => _result = r);
    } on SnagEstimateFailure catch (f) {
      if (mounted) setState(() => _error = f.offline || f.message.isEmpty ? 'snags.est.failed'.getString(context) : f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: AppText.titleMedium('snags.est.materials_title'.getString(context))),
          for (var i = 0; i < _items.length; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
              child: Row(
                children: [
                  Checkbox(value: _include[i], onChanged: _busy || r != null ? null : (v) => setState(() => _include[i] = v ?? false)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.bodySmall('${_items[i].displayName} · ${_items[i].quantity.ceil()} ${_items[i].unit ?? ''}'.trim(), weight: FontWeight.w600),
                        if (r != null && i < r.length)
                          AppText.caption(r[i].message, color: r[i].ok ? FeColors.success : FeColors.danger)
                        else if (_items[i].available != null)
                          AppText.caption(snagTr(context, 'snags.est.stock_free', [_h(_items[i].available)]), color: FeColors.ink2),
                      ],
                    ),
                  ),
                  DropdownButton<String>(
                    value: _action[i],
                    isDense: true,
                    onChanged: _busy || r != null ? null : (v) => setState(() => _action[i] = v ?? _action[i]),
                    items: [
                      DropdownMenuItem(value: 'reserve', child: Text('snags.est.reserve_action'.getString(context))),
                      DropdownMenuItem(value: 'request', child: Text('snags.est.request_action'.getString(context))),
                    ],
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AppText.bodySmall(_error!, color: FeColors.danger),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: r != null
                ? OutlinedButton(onPressed: () => Navigator.of(context).pop(true), child: Text('common.ok'.getString(context)))
                : FilledButton(
                    onPressed: _busy || !_include.contains(true) ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white))
                        : Text('snags.est.confirm'.getString(context)),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmSheet extends StatefulWidget {
  const _ConfirmSheet({required this.title, required this.body, required this.confirm, required this.run});
  final String title;
  final String body;
  final String confirm;

  /// Does the write; returns the line to show once it's done.
  final Future<String> Function() run;
  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  var _busy = false;
  String? _error;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await widget.run();
      if (!mounted) return;
      showTechPopup(context, message: msg);
      Navigator.of(context).pop(true);
    } on SnagEstimateFailure catch (f) {
      if (mounted) setState(() => _error = f.offline || f.message.isEmpty ? 'snags.est.failed'.getString(context) : f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleMedium(widget.title),
          const SizedBox(height: 6),
          AppText.bodySmall(widget.body, color: FeColors.ink2),
          if (_error != null) ...[const SizedBox(height: 8), AppText.bodySmall(_error!, color: FeColors.danger)],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _go,
            child: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white))
                : Text(widget.confirm),
          ),
        ],
      ),
    ),
  );
}

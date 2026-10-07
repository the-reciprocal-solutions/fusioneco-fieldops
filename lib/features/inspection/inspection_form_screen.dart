import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:signature/signature.dart';
import 'package:uuid/uuid.dart';

import '../../core/capture/capture_services.dart';
import '../../core/inspection/conditional_logic.dart';
import '../../core/inspection/inspection_send_state.dart';
import '../../core/network/api_exception.dart';
import '../../data/inspection_repository.dart';
import '../../domain/inspection.dart';
import '../../state/inspection_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/tech_header.dart';

/// Bundles every field-level action callback so `_FieldCard` and its media
/// sub-widgets don't need a dozen separate constructor params.
class _FieldActions {
  const _FieldActions({
    required this.onChanged,
    required this.onCapturePhoto,
    required this.onRetryMedia,
    required this.onDeleteMedia,
    required this.onCaptureFile,
    required this.onDeleteFile,
    required this.onCaptureSignature,
    required this.onRetrySignature,
  });

  final void Function(InspectionField field, dynamic value) onChanged;
  final void Function(InspectionField field, {required bool fromCamera}) onCapturePhoto;
  final void Function(InspectionField field, int index) onRetryMedia;
  final void Function(InspectionField field, int index) onDeleteMedia;
  final void Function(InspectionField field, {required bool fromCamera}) onCaptureFile;
  final void Function(InspectionField field, int index) onDeleteFile;
  final void Function(InspectionField field) onCaptureSignature;
  final void Function(InspectionField field) onRetrySignature;
}

Color _parseHexColor(String hex, {Color fallback = FeColors.ink}) {
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  final value = int.tryParse(h, radix: 16);
  return value == null ? fallback : Color(value);
}

String _stripHtml(String html) =>
    html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String pad(int v) => v.toString().padLeft(2, '0');
  return '${pad(h)}:${pad(m)}:${pad(s)}';
}

List<Map<String, dynamic>> _mediaItemsOf(Map<String, dynamic> answers, String key) {
  final value = answers[key];
  if (value is Map && value['values'] is List) {
    return (value['values'] as List)
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
        .toList();
  }
  return [];
}

class InspectionFormScreen extends ConsumerStatefulWidget {
  const InspectionFormScreen({super.key, required this.assignmentId});

  final String assignmentId;

  @override
  ConsumerState<InspectionFormScreen> createState() => _InspectionFormScreenState();
}

class _InspectionFormScreenState extends ConsumerState<InspectionFormScreen> {
  final _answers = <String, dynamic>{};
  final _textControllers = <String, TextEditingController>{};
  final _pendingBytes = <String, Uint8List>{};
  final _pendingNames = <String, String>{};
  final _uuid = const Uuid();
  final _photoCapture = PhotoCapture();
  final _locationCapture = LocationCapture();
  final _scrollController = ScrollController();
  final _gpsKey = GlobalKey();
  final _supervisorKey = GlobalKey();

  bool _seeded = false;
  bool _submitting = false;

  /// The server's answer to the last Submit tap, shown in the banner.
  InspectionRefused? _refusal;
  bool _fetchingLocation = false;
  final _uploadingKeys = <String>{};

  final _timerSessions = <Map<String, String?>>[];
  bool _isTimerRunning = false;
  Duration _elapsed = Duration.zero;
  Timer? _tickTimer;

  static const _supervisorUploadKey = '_supervisor';

  @override
  void initState() {
    super.initState();
    unawaited(_restoreKeptAnswers());
  }

  /// A submit the server does not have yet (waiting in the queue, or
  /// refused) keeps its answers on the phone. Reopening the form shows those
  /// answers rather than the server's older copy, so a technician who left
  /// after "Waiting to send" never has to fill it in again.
  Future<void> _restoreKeptAnswers() async {
    final repo = ref.read(inspectionRepositoryProvider);
    final draft = await repo.readDraft(widget.assignmentId);
    if (draft == null || !mounted) return;
    final queue = await ref.read(pendingMutationsProvider.future);
    final queued = queuedSubmitId(queue, widget.assignmentId) != null;
    if (!queued && draft.issue?.dropped != true) return;
    if (!mounted) return;
    setState(() {
      _answers.addAll(draft.answers);
      for (final entry in draft.answers.entries) {
        final c = _textControllers[entry.key];
        if (c != null && entry.value is String) c.text = entry.value as String;
      }
    });
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    _tickTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _seedFrom(InspectionAssignmentDetail detail) {
    if (_seeded) return;
    _seeded = true;
    // putIfAbsent: kept answers restored by [_restoreKeptAnswers] win.
    for (final entry in detail.responseData.entries) {
      _answers.putIfAbsent(entry.key, () => entry.value);
    }
    for (final field in detail.schema.components) {
      final existing = _answers[field.key];
      if (existing is String &&
          (field.type == InspectionFieldType.text ||
              field.type == InspectionFieldType.textarea ||
              field.type == InspectionFieldType.number)) {
        _textControllers[field.key] = TextEditingController(text: existing);
      }
    }
    final sessions = detail.responseData['_timerSessions'];
    if (sessions is List) {
      _timerSessions.addAll(
        sessions.whereType<Map>().map(
          (s) => {'start': s['start']?.toString(), 'end': s['end']?.toString()},
        ),
      );
      _recomputeElapsed();
    }
  }

  TextEditingController _controllerFor(String key) =>
      _textControllers.putIfAbsent(key, TextEditingController.new);

  // ── GPS ────────────────────────────────────────────────────────────────

  Future<void> _fetchGpsLocation() async {
    setState(() => _fetchingLocation = true);
    try {
      final loc = await _locationCapture.current();
      setState(() {
        _answers['_gpsLocation'] = {
          'latitude': loc.latitude,
          'longitude': loc.longitude,
          'city': loc.city,
          'district': loc.district,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        };
      });
    } on CaptureFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not get your location.')));
      }
    } finally {
      if (mounted) setState(() => _fetchingLocation = false);
    }
  }

  // ── Timer ──────────────────────────────────────────────────────────────

  void _recomputeElapsed() {
    var total = Duration.zero;
    for (final session in _timerSessions) {
      final start = DateTime.tryParse(session['start'] ?? '');
      if (start == null) continue;
      final endStr = session['end'];
      final end = endStr == null ? DateTime.now().toUtc() : DateTime.tryParse(endStr);
      if (end != null) total += end.difference(start);
    }
    if (mounted) setState(() => _elapsed = total);
  }

  void _startTimer() {
    setState(() {
      _timerSessions.add({'start': DateTime.now().toUtc().toIso8601String(), 'end': null});
      _isTimerRunning = true;
    });
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _recomputeElapsed());
  }

  void _stopTimer() {
    _tickTimer?.cancel();
    _tickTimer = null;
    setState(() {
      if (_timerSessions.isNotEmpty && _timerSessions.last['end'] == null) {
        _timerSessions[_timerSessions.length - 1]['end'] =
            DateTime.now().toUtc().toIso8601String();
      }
      _isTimerRunning = false;
    });
    _recomputeElapsed();
  }

  // ── Photo / file media (shared append/retry/delete over a `values` array) ──

  Future<void> _capturePhoto(InspectionField field, {required bool fromCamera}) async {
    final existing = _mediaItemsOf(_answers, field.key);
    if (existing.length >= field.maxPhotos) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Limit reached for this field.')));
      return;
    }

    setState(() => _uploadingKeys.add(field.key));
    try {
      final photo = fromCamera
          ? await _photoCapture.takeJobPhoto(maxWidth: field.compressToWidth.toDouble())
          : await _photoCapture.pickFromGallery(maxWidth: field.compressToWidth.toDouble());
      if (photo == null) return;

      Map<String, double>? geo;
      if (field.requireGeotag) {
        try {
          final loc = await _locationCapture.current();
          geo = {'lat': loc.latitude, 'lng': loc.longitude};
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Location required — this photo field requires a geotag. Enable location access and try again.',
                ),
              ),
            );
          }
          return;
        }
      }

      await _uploadAndAppendMedia(field, photo.bytes, photo.fileName, geo: geo);
    } finally {
      if (mounted) setState(() => _uploadingKeys.remove(field.key));
    }
  }

  Future<void> _uploadAndAppendMedia(
    InspectionField field,
    Uint8List bytes,
    String fileName, {
    Map<String, double>? geo,
  }) async {
    try {
      final url = await ref.read(inspectionRepositoryProvider).uploadMedia(bytes, fileName);
      setState(() {
        final items = _mediaItemsOf(_answers, field.key);
        items.add({
          'url': url,
          'uploadStatus': 'uploaded',
          'takenAt': DateTime.now().toUtc().toIso8601String(),
          'geo': ?geo,
        });
        _answers[field.key] = {'values': items};
      });
    } catch (_) {
      final pendingId = _uuid.v4();
      _pendingBytes[pendingId] = bytes;
      _pendingNames[pendingId] = fileName;
      setState(() {
        final items = _mediaItemsOf(_answers, field.key);
        items.add({'uploadStatus': 'pending', 'pendingId': pendingId, 'geo': ?geo});
        _answers[field.key] = {'values': items};
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('inspection.media_not_uploaded'.getString(context))),
        );
      }
    }
  }

  Future<void> _retryMedia(InspectionField field, int index) async {
    final items = _mediaItemsOf(_answers, field.key);
    if (index >= items.length) return;
    final item = items[index];
    final pendingId = item['pendingId'] as String?;
    final bytes = pendingId == null ? null : _pendingBytes[pendingId];
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please retake — this item can't be retried in this session.")),
      );
      return;
    }

    setState(() => _uploadingKeys.add(field.key));
    try {
      final url = await ref
          .read(inspectionRepositoryProvider)
          .uploadMedia(bytes, _pendingNames[pendingId] ?? 'attachment.jpg');
      setState(() {
        items[index] = {...item, 'url': url, 'uploadStatus': 'uploaded'}..remove('pendingId');
        _answers[field.key] = {'values': items};
        _pendingBytes.remove(pendingId);
        _pendingNames.remove(pendingId);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Still couldn't upload — check your connection and try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingKeys.remove(field.key));
    }
  }

  void _deleteMedia(InspectionField field, int index) {
    final items = _mediaItemsOf(_answers, field.key);
    if (index >= items.length) return;
    final pendingId = items[index]['pendingId'] as String?;
    setState(() {
      items.removeAt(index);
      _answers[field.key] = {'values': items};
    });
    if (pendingId != null) {
      _pendingBytes.remove(pendingId);
      _pendingNames.remove(pendingId);
    }
  }

  // ── `file` field (raw, uncompressed, base64 data-URLs — no upload) ──────

  Future<void> _captureFile(InspectionField field, {required bool fromCamera}) async {
    // Downscaled like a photo field (1600 px, JPEG 80) since 2026-10-06. The
    // raw original rode inline as a base64 data URL inside the submit body:
    // an iPhone camera original is 3–8 MB (×1.33 as base64), so a few of
    // them made a submit that crawled over mobile data, timed out, or hit
    // the server's 30 MB body limit (413).
    final photo = fromCamera
        ? await _photoCapture.takeJobPhoto()
        : await _photoCapture.pickFromGallery();
    if (photo == null) return;

    setState(() {
      final current = _answers[field.key];
      if (field.multiple) {
        final list = current is List ? List<String>.from(current) : <String>[];
        list.add(photo.dataUrl);
        _answers[field.key] = list;
      } else {
        _answers[field.key] = photo.dataUrl;
      }
    });
  }

  void _deleteFile(InspectionField field, int index) {
    setState(() {
      final current = _answers[field.key];
      if (field.multiple && current is List) {
        final list = List<String>.from(current)..removeAt(index);
        _answers[field.key] = list;
      } else {
        _answers.remove(field.key);
      }
    });
  }

  // ── Per-field signature ──────────────────────────────────────────────

  Future<void> _captureFieldSignature(InspectionField field) async {
    final existingName = _answers[field.key] is Map
        ? (_answers[field.key] as Map)['signerName']?.toString() ?? ''
        : '';
    final nameController = TextEditingController(text: existingName);
    final sigController = SignatureController(
      penColor: _parseHexColor(field.penColor),
      penStrokeWidth: 3,
      exportBackgroundColor: Colors.white,
    );

    final bytes = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      backgroundColor: FeColors.panel,
      builder: (sheetContext) {
        // Declared outside `builder:` deliberately — a local var declared
        // inside a StatefulBuilder's builder callback is re-initialized to
        // null on every rebuild the callback itself triggers, so
        // `setSheetState(() => nameError = ...)` would set a value the very
        // next rebuild throws away before the error text ever paints.
        String? nameError;
        return StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText.titleSmall(field.label),
                if (field.signerNameField) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: 'Printed name',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: nameError,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: FeColors.line),
                  ),
                  child: Signature(
                    controller: sigController,
                    height: 160,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: sigController.clear,
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          if (field.requireName && nameController.text.trim().isEmpty) {
                            setSheetState(() => nameError = 'Name required');
                            return;
                          }
                          if (sigController.isEmpty) return;
                          final png = await sigController.toPngBytes();
                          if (sheetContext.mounted) Navigator.of(sheetContext).pop(png);
                        },
                        child: const Text('Lock Signature'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
        );
      },
    );
    sigController.dispose();
    if (bytes == null) return;

    final signerName = nameController.text.trim();
    setState(() => _uploadingKeys.add(field.key));
    try {
      final url = await ref.read(inspectionRepositoryProvider).uploadMedia(bytes, 'signature.png');
      setState(() {
        _answers[field.key] = {
          'values': [
            {'url': url, 'uploadStatus': 'uploaded', 'takenAt': DateTime.now().toUtc().toIso8601String()},
          ],
          if (signerName.isNotEmpty) 'signerName': signerName,
        };
      });
    } catch (_) {
      final pendingId = _uuid.v4();
      _pendingBytes[pendingId] = bytes;
      _pendingNames[pendingId] = 'signature.png';
      setState(() {
        _answers[field.key] = {
          'values': [
            {'uploadStatus': 'pending', 'pendingId': pendingId},
          ],
          if (signerName.isNotEmpty) 'signerName': signerName,
        };
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('inspection.media_not_uploaded'.getString(context))),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingKeys.remove(field.key));
    }
  }

  Future<void> _retryFieldSignature(InspectionField field) async {
    final items = _mediaItemsOf(_answers, field.key);
    if (items.isEmpty) return;
    final pendingId = items.first['pendingId'] as String?;
    final bytes = pendingId == null ? null : _pendingBytes[pendingId];
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please redraw — this signature can't be retried in this session.")),
      );
      return;
    }

    setState(() => _uploadingKeys.add(field.key));
    try {
      final url = await ref.read(inspectionRepositoryProvider).uploadMedia(bytes, 'signature.png');
      final existing = _answers[field.key];
      final signerName = existing is Map ? existing['signerName'] : null;
      setState(() {
        _answers[field.key] = {
          'values': [
            {'url': url, 'uploadStatus': 'uploaded', 'takenAt': DateTime.now().toUtc().toIso8601String()},
          ],
          'signerName': ?signerName,
        };
        _pendingBytes.remove(pendingId);
        _pendingNames.remove(pendingId);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Still couldn't upload — check your connection and try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingKeys.remove(field.key));
    }
  }

  // ── Supervisor signature (form-level, plain URL, separate from any
  // per-field signature) ──────────────────────────────────────────────

  Future<void> _captureSupervisorSignature() async {
    final sigController = SignatureController(
      penColor: FeColors.ink,
      penStrokeWidth: 3,
      exportBackgroundColor: Colors.white,
    );

    final bytes = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      backgroundColor: FeColors.panel,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppText.titleSmall('Supervisor Signature'),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: FeColors.line),
              ),
              child: Signature(
                controller: sigController,
                height: 160,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: sigController.clear, child: const Text('Clear')),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      if (sigController.isEmpty) return;
                      final png = await sigController.toPngBytes();
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop(png);
                    },
                    child: const Text('Lock Signature'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    sigController.dispose();
    if (bytes == null) return;

    setState(() => _uploadingKeys.add(_supervisorUploadKey));
    try {
      final url = await ref.read(inspectionRepositoryProvider).uploadMedia(bytes, 'signature.png');
      setState(() => _answers['_supervisorSignature'] = url);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not upload the signature. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingKeys.remove(_supervisorUploadKey));
    }
  }

  void _clearSupervisorSignature() => setState(() => _answers.remove('_supervisorSignature'));

  // ── Submit ────────────────────────────────────────────────────────────

  void _scrollTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
  }

  Future<void> _submit(InspectionSchema schema) async {
    if (schema.details.gpsRequired && _answers['_gpsLocation'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GPS location is required before submission.')),
      );
      _scrollTo(_gpsKey);
      return;
    }

    final notifier = ref.read(inspectionDetailControllerProvider(widget.assignmentId).notifier);
    final missing = notifier.missingRequiredFields(_answers);
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Missing required: ${missing.join(", ")}')));
      return;
    }

    if (schema.details.supervisorSignature && _answers['_supervisorSignature'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Supervisor signature is required before submission.')),
      );
      _scrollTo(_supervisorKey);
      return;
    }

    // A photo/signature that failed to upload is only in this screen's
    // memory; submitting now would send `{uploadStatus:'pending'}` with no
    // file and lose it for good.
    if (_hasPendingMedia()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('inspection.media_pending_block'.getString(context))),
      );
      return;
    }

    if (schema.details.timerEnabled) {
      _answers['_timerSessions'] = _timerSessions;
      _answers['_totalDurationMs'] = _elapsed.inMilliseconds;
    }

    setState(() {
      _submitting = true;
      _refusal = null;
    });
    final outcome = await notifier.submit(Map<String, dynamic>.from(_answers));
    if (!mounted) return;
    setState(() => _submitting = false);

    switch (outcome) {
      case InspectionSubmitted():
        _showResult(queued: null);
      case InspectionQueued(:final status):
        _showResult(queued: status);
      case InspectionRefused():
        setState(() => _refusal = outcome);
        _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  bool _hasPendingMedia() {
    for (final value in _answers.values) {
      if (value is Map && value['values'] is List) {
        for (final item in value['values'] as List) {
          if (item is Map && item['uploadStatus'] == 'pending') return true;
        }
      }
    }
    return false;
  }

  /// Retry from the banner: nudge the queue when the submit is queued, or
  /// send the kept answers again when the server refused them.
  Future<void> _retrySend(InspectionSchema schema, InspectionSendStatus status) async {
    if (status.state.isQueued) {
      final queue = await ref.read(pendingMutationsProvider.future);
      final id = queuedSubmitId(queue, widget.assignmentId);
      await ref.read(syncClientProvider).flushQueue(stopAfterId: id);
      ref.read(inspectionSendTickProvider.notifier).state++;
      return;
    }
    await _submit(schema);
  }

  String _refusalText(BuildContext context, InspectionRefused refusal) {
    final reason = refusal.reasonKey.getString(context);
    if (refusal.missing.isEmpty) return reason;
    return '$reason ${refusal.missing.join(', ')}';
  }

  /// [queued] null: the server has it. Otherwise it is waiting in the queue.
  void _showResult({required InspectionSendStatus? queued}) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: FeColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              queued != null ? LucideIcons.cloudUpload : LucideIcons.circleCheck,
              color: queued != null ? FeColors.warning : FeColors.success,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                queued != null
                    ? 'inspection.send.waiting'.getString(dialogContext)
                    : 'inspection.send.submitted'.getString(dialogContext),
              ),
            ),
          ],
        ),
        content: Text(
          queued != null
              ? '${'inspection.send.kept_on_phone'.getString(dialogContext)} '
                    '${(queued.reasonKey ?? 'inspection.send.waiting_hint').getString(dialogContext)}'
              : 'inspection.send.submitted_body'.getString(dialogContext),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              context.pop();
            },
            child: Text('inspection.send.back'.getString(dialogContext)),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(inspectionDetailControllerProvider(widget.assignmentId));

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: const TechHeader(title: 'Inspection', showBack: true),
      body: SafeArea(
        top: false,
        child: detailAsync.when(
          loading: () => const Center(child: TechSpinner()),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: TechEmptyState(
              icon: LucideIcons.circleAlert,
              title: 'Unable to open this inspection',
              subtitle: switch (error) {
                NetworkFailure() => 'inspection.open_offline'.getString(context),
                HttpFailure(status: 410) => error.message,
                _ => 'inspection.open_failed'.getString(context),
              },
              iconColor: FeColors.danger,
            ),
          ),
          data: (detail) {
            _seedFrom(detail);
            final readOnly = detail.status == 'expired';
            final schema = detail.schema;
            final visible = [
              for (final field in visibleFieldsFor(schema, _answers))
                if (field.type != InspectionFieldType.button) field,
            ];
            final actions = _FieldActions(
              onChanged: (field, value) => setState(() => _answers[field.key] = value),
              onCapturePhoto: _capturePhoto,
              onRetryMedia: _retryMedia,
              onDeleteMedia: _deleteMedia,
              onCaptureFile: _captureFile,
              onDeleteFile: _deleteFile,
              onCaptureSignature: _captureFieldSignature,
              onRetrySignature: _retryFieldSignature,
            );

            return ListView(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              children: [
                TechCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(LucideIcons.clipboardCheck, size: 16, color: FeColors.info),
                          const SizedBox(width: 6),
                          const AppText.bodySmall(
                            'INSPECTION',
                            weight: FontWeight.w800,
                            color: FeColors.info,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      AppText.titleMedium(detail.templateName, weight: FontWeight.w800),
                      if (detail.templateDescription != null) ...[
                        const SizedBox(height: 4),
                        AppText.bodySmall(detail.templateDescription!),
                      ],
                      const SizedBox(height: 8),
                      AppText.bodySmall('Ref: ${detail.referenceId}', color: FeColors.ink2),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SendBanner(
                  assignmentId: widget.assignmentId,
                  serverStatus: detail.status,
                  refusal: _refusal,
                  refusalText: _refusal == null ? null : _refusalText(context, _refusal!),
                  busy: _submitting,
                  onRetry: (status) => _retrySend(schema, status),
                ),
                if (readOnly)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TechCard(
                      tint: FeColors.dangerSoft,
                      child: const AppText.bodySmall(
                        'This inspection has expired and can no longer be edited.',
                        color: FeColors.danger,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (schema.details.gpsRequired || schema.details.timerEnabled)
                  Padding(
                    key: _gpsKey,
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildGpsTimerCard(schema, readOnly),
                  ),
                for (final field in visible) ...[
                  _FieldCard(field: field, readOnly: readOnly, answers: _answers, actions: actions, uploading: _uploadingKeys.contains(field.key), textControllerFor: _controllerFor),
                  const SizedBox(height: 12),
                ],
                if (schema.details.supervisorSignature)
                  Padding(
                    key: _supervisorKey,
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildSupervisorSignatureCard(readOnly),
                  ),
                const SizedBox(height: 8),
                if (!readOnly)
                  ElevatedButton(
                    onPressed: (_submitting || _isTimerRunning) ? null : () => _submit(schema),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: FeColors.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _submitting
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation(Colors.white),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'inspection.send.submitting'.getString(context),
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ],
                          )
                        : Text(
                            _isTimerRunning
                                ? 'Stop Timer to Submit'
                                : (schema.submitButtonLabel ?? 'Submit Inspection'),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                if (!readOnly && _isTimerRunning)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: AppText.bodySmall(
                      'Stop the timer before submitting.',
                      color: FeColors.warning,
                      align: TextAlign.center,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGpsTimerCard(InspectionSchema schema, bool readOnly) {
    final gps = _answers['_gpsLocation'];
    final gpsCaptured = gps is Map;

    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (schema.details.gpsRequired) ...[
            Row(
              children: [
                const Icon(LucideIcons.mapPin, size: 16, color: FeColors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: RichText(
                    text: const TextSpan(
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: FeColors.ink),
                      children: [
                        TextSpan(text: 'Location Verification'),
                        TextSpan(text: ' *', style: TextStyle(color: FeColors.danger)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_fetchingLocation)
              const TechSpinner(size: 24)
            else if (gpsCaptured)
              Row(
                children: [
                  const Icon(LucideIcons.circleCheck, size: 16, color: FeColors.success),
                  const SizedBox(width: 6),
                  AppText.bodySmall(
                    'Captured: ${(gps['city'] as String?) ?? 'Verified'}',
                    color: FeColors.success,
                  ),
                ],
              )
            else if (readOnly)
              const AppText.bodySmall('Not Captured', color: FeColors.ink2)
            else
              OutlinedButton.icon(
                onPressed: _fetchGpsLocation,
                icon: const Icon(LucideIcons.mapPin, size: 16),
                label: const Text('Fetch GPS Location'),
              ),
            if (schema.details.timerEnabled) const SizedBox(height: 16),
          ],
          if (schema.details.timerEnabled) ...[
            Row(
              children: [
                const Icon(LucideIcons.clock, size: 16, color: FeColors.primary),
                const SizedBox(width: 6),
                const AppText.bodySmall('TIMER', weight: FontWeight.w800, color: FeColors.ink2),
                const Spacer(),
                if (_timerSessions.isNotEmpty)
                  AppText.bodySmall(
                    '${_timerSessions.length} session${_timerSessions.length == 1 ? '' : 's'}',
                    color: FeColors.ink2,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_elapsed),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (!readOnly)
                  _isTimerRunning
                      ? ElevatedButton.icon(
                          onPressed: _stopTimer,
                          style: ElevatedButton.styleFrom(backgroundColor: FeColors.danger),
                          icon: const Icon(LucideIcons.square, size: 16),
                          label: const Text('Stop'),
                        )
                      : ElevatedButton.icon(
                          onPressed: _startTimer,
                          style: ElevatedButton.styleFrom(backgroundColor: FeColors.success),
                          icon: const Icon(LucideIcons.play, size: 16),
                          label: const Text('Start'),
                        ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSupervisorSignatureCard(bool readOnly) {
    final url = _answers['_supervisorSignature'] as String?;
    final uploading = _uploadingKeys.contains(_supervisorUploadKey);

    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.penTool, size: 16, color: FeColors.ink),
              const SizedBox(width: 6),
              const AppText.bodySmall('SUPERVISOR SIGNATURE', weight: FontWeight.w800),
            ],
          ),
          const SizedBox(height: 10),
          if (uploading)
            const TechSpinner(size: 24)
          else if (url != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, height: 100, fit: BoxFit.contain),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(LucideIcons.circleCheck, size: 14, color: FeColors.success),
                const SizedBox(width: 4),
                const AppText.bodySmall(
                  'Signature verified and captured',
                  color: FeColors.success,
                ),
                const Spacer(),
                if (!readOnly)
                  IconButton(
                    icon: const Icon(LucideIcons.rotateCcw, size: 16, color: FeColors.danger),
                    onPressed: _clearSupervisorSignature,
                  ),
              ],
            ),
          ] else if (readOnly)
            const AppText.bodySmall('No signature provided', color: FeColors.ink2)
          else
            OutlinedButton.icon(
              onPressed: _captureSupervisorSignature,
              icon: const Icon(LucideIcons.penLine, size: 16),
              label: const Text('Add Signature'),
            ),
        ],
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.field,
    required this.readOnly,
    required this.answers,
    required this.actions,
    required this.uploading,
    required this.textControllerFor,
  });

  final InspectionField field;
  final bool readOnly;
  final Map<String, dynamic> answers;
  final _FieldActions actions;
  final bool uploading;
  final TextEditingController Function(String key) textControllerFor;

  static const _noLabelTypes = {
    InspectionFieldType.checkbox,
    InspectionFieldType.html,
    InspectionFieldType.panel,
  };

  @override
  Widget build(BuildContext context) {
    final showLabel = !_noLabelTypes.contains(field.type);
    return TechCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLabel) ...[
            RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: FeColors.ink),
                children: [
                  TextSpan(text: field.label),
                  if (field.required)
                    const TextSpan(text: ' *', style: TextStyle(color: FeColors.danger)),
                ],
              ),
            ),
            if (field.description != null && field.description!.isNotEmpty) ...[
              const SizedBox(height: 2),
              AppText.bodySmall(field.description!, color: FeColors.ink2),
            ],
            const SizedBox(height: 10),
          ],
          _buildInput(context),
        ],
      ),
    );
  }

  Widget _buildInput(BuildContext context) {
    void onChanged(dynamic value) => actions.onChanged(field, value);

    switch (field.type) {
      case InspectionFieldType.text:
        return TextField(
          controller: textControllerFor(field.key),
          enabled: !readOnly,
          decoration: InputDecoration(
            hintText: field.placeholder,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: onChanged,
        );
      case InspectionFieldType.textarea:
        return TextField(
          controller: textControllerFor(field.key),
          enabled: !readOnly,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: field.placeholder,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: onChanged,
        );
      case InspectionFieldType.number:
        return TextField(
          controller: textControllerFor(field.key),
          enabled: !readOnly,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: field.placeholder,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: onChanged,
        );
      case InspectionFieldType.checkbox:
        final value = answers[field.key] == true;
        return CheckboxListTile(
          value: value,
          onChanged: readOnly ? null : (v) => onChanged(v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: FeColors.ink),
              children: [
                TextSpan(text: field.label),
                if (field.required)
                  const TextSpan(text: ' *', style: TextStyle(color: FeColors.danger)),
              ],
            ),
          ),
        );
      case InspectionFieldType.select:
        final value = answers[field.key]?.toString();
        return DropdownButtonFormField<String>(
          initialValue: field.options.any((o) => o.value == value) ? value : null,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            for (final option in field.options)
              DropdownMenuItem(value: option.value, child: Text(option.label)),
          ],
          onChanged: readOnly ? null : onChanged,
        );
      case InspectionFieldType.radio:
        final value = answers[field.key]?.toString();
        return RadioGroup<String>(
          groupValue: value,
          onChanged: (v) {
            if (!readOnly) onChanged(v);
          },
          child: Column(
            children: [
              for (final option in field.options)
                RadioListTile<String>(
                  value: option.value,
                  contentPadding: EdgeInsets.zero,
                  title: Text(option.label),
                ),
            ],
          ),
        );
      case InspectionFieldType.date:
        final value = answers[field.key]?.toString();
        final parsed = value == null ? null : DateTime.tryParse(value);
        return OutlinedButton.icon(
          onPressed: readOnly
              ? null
              : () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: parsed ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) onChanged(picked.toIso8601String());
                },
          icon: const Icon(LucideIcons.calendar, size: 16),
          label: Text(parsed == null ? 'Select date' : '${parsed.month}/${parsed.day}/${parsed.year}'),
        );
      case InspectionFieldType.selectboxes:
        final raw = answers[field.key];
        final selected = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in field.options)
              FilterChip(
                label: Text(option.label),
                selected: selected[option.value] == true,
                onSelected: readOnly
                    ? null
                    : (v) {
                        final next = Map<String, dynamic>.from(selected)..[option.value] = v;
                        onChanged(next);
                      },
              ),
          ],
        );
      case InspectionFieldType.rating:
        final value = answers[field.key] is int ? answers[field.key] as int : 0;
        return Row(
          children: [
            for (var i = 0; i < field.starCount; i++)
              IconButton(
                onPressed: readOnly ? null : () => onChanged(i + 1),
                icon: Icon(
                  i < value ? Icons.star_rounded : Icons.star_border_rounded,
                  color: i < value ? Colors.amber.shade700 : FeColors.ink2,
                ),
              ),
          ],
        );
      case InspectionFieldType.survey:
        final raw = answers[field.key];
        final value = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 20,
            columns: [
              const DataColumn(label: Text('')),
              for (final col in field.surveyColumns) DataColumn(label: Text(col.label)),
            ],
            rows: [
              for (final row in field.surveyRows)
                DataRow(
                  cells: [
                    DataCell(Text(row.label)),
                    for (final col in field.surveyColumns)
                      DataCell(
                        RadioGroup<String>(
                          groupValue: value[row.value]?.toString(),
                          onChanged: (v) {
                            if (readOnly) return;
                            final next = Map<String, dynamic>.from(value)..[row.value] = v;
                            onChanged(next);
                          },
                          child: Radio<String>(value: col.value),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      case InspectionFieldType.file:
        return _FileGrid(field: field, answers: answers, readOnly: readOnly, actions: actions);
      case InspectionFieldType.photo:
        return _MediaGrid(
          field: field,
          answers: answers,
          readOnly: readOnly,
          uploading: uploading,
          actions: actions,
        );
      case InspectionFieldType.signature:
        return _SignatureBlock(
          field: field,
          answers: answers,
          readOnly: readOnly,
          uploading: uploading,
          actions: actions,
        );
      case InspectionFieldType.panel:
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: FeColors.line),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                field.panelTitle?.isNotEmpty == true ? field.panelTitle! : field.label,
                style: const TextStyle(fontWeight: FontWeight.w700, color: FeColors.ink),
              ),
              const SizedBox(height: 6),
              const AppText.bodySmall(
                'Static panels are not supported in the app yet.',
                color: FeColors.ink2,
              ),
            ],
          ),
        );
      case InspectionFieldType.html:
        final text = _stripHtml(field.htmlContent ?? '');
        return text.isEmpty ? const SizedBox.shrink() : AppText.bodySmall(text);
      case InspectionFieldType.button:
        // Never rendered — its label only feeds the real submit button.
        return const SizedBox.shrink();
      case InspectionFieldType.unsupported:
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: FeColors.warningSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const AppText.bodySmall(
            "This field isn't supported in the app yet — please fill it in on the emailed web form instead.",
            color: FeColors.warning,
          ),
        );
    }
  }
}

class _FileGrid extends StatelessWidget {
  const _FileGrid({
    required this.field,
    required this.answers,
    required this.readOnly,
    required this.actions,
  });

  final InspectionField field;
  final Map<String, dynamic> answers;
  final bool readOnly;
  final _FieldActions actions;

  List<String> get _items {
    final raw = answers[field.key];
    if (raw is List) return List<String>.from(raw);
    if (raw is String && raw.isNotEmpty) return [raw];
    return const [];
  }

  Uint8List? _decode(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma == -1) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (items.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < items.length; i++)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: () {
                          final bytes = _decode(items[i]);
                          return bytes == null
                              ? Container(color: FeColors.line)
                              : Image.memory(bytes, fit: BoxFit.cover);
                        }(),
                      ),
                    ),
                    if (!readOnly)
                      Positioned(
                        top: -6,
                        right: -6,
                        child: GestureDetector(
                          onTap: () => actions.onDeleteFile(field, i),
                          child: const Icon(Icons.cancel, size: 18, color: FeColors.danger),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        if (items.isNotEmpty) const SizedBox(height: 8),
        if (!readOnly)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => actions.onCaptureFile(field, fromCamera: true),
                  icon: const Icon(LucideIcons.camera, size: 16),
                  label: const Text('Camera'),
                ),
              ),
              if (!field.aiAnalyse || field.aiAllowGallery) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => actions.onCaptureFile(field, fromCamera: false),
                    icon: const Icon(LucideIcons.image, size: 16),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({
    required this.field,
    required this.answers,
    required this.readOnly,
    required this.uploading,
    required this.actions,
  });

  final InspectionField field;
  final Map<String, dynamic> answers;
  final bool readOnly;
  final bool uploading;
  final _FieldActions actions;

  @override
  Widget build(BuildContext context) {
    final items = _mediaItemsOf(answers, field.key);
    final atLimit = items.length >= field.maxPhotos;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (items.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < items.length; i++) _mediaTile(context, items[i], i),
            ],
          ),
        if (items.isNotEmpty) const SizedBox(height: 8),
        AppText.bodySmall('${items.length}/${field.maxPhotos} photos', color: FeColors.ink2),
        const SizedBox(height: 8),
        if (uploading)
          const TechSpinner(size: 24)
        else if (!readOnly && !atLimit)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => actions.onCapturePhoto(field, fromCamera: true),
                  icon: const Icon(LucideIcons.camera, size: 16),
                  label: const Text('Camera'),
                ),
              ),
              if (field.allowGallery) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => actions.onCapturePhoto(field, fromCamera: false),
                    icon: const Icon(LucideIcons.image, size: 16),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _mediaTile(BuildContext context, Map<String, dynamic> item, int index) {
    final status = item['uploadStatus'];
    final url = item['url'] as String?;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 72,
            height: 72,
            child: status == 'uploaded' && url != null && url.isNotEmpty
                ? Image.network(url, fit: BoxFit.cover)
                : Container(
                    color: FeColors.warningSoft,
                    alignment: Alignment.center,
                    child: const Icon(LucideIcons.clock, size: 20, color: FeColors.warning),
                  ),
          ),
        ),
        if (!readOnly)
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: () => actions.onDeleteMedia(field, index),
              child: const Icon(Icons.cancel, size: 18, color: FeColors.danger),
            ),
          ),
        if (!readOnly && status == 'pending')
          Positioned(
            bottom: -6,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () => actions.onRetryMedia(field, index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: FeColors.warning,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SignatureBlock extends StatelessWidget {
  const _SignatureBlock({
    required this.field,
    required this.answers,
    required this.readOnly,
    required this.uploading,
    required this.actions,
  });

  final InspectionField field;
  final Map<String, dynamic> answers;
  final bool readOnly;
  final bool uploading;
  final _FieldActions actions;

  @override
  Widget build(BuildContext context) {
    if (uploading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: TechSpinner(size: 24),
      );
    }

    final items = _mediaItemsOf(answers, field.key);
    final item = items.isNotEmpty ? items.first : null;
    final signerName = answers[field.key] is Map
        ? (answers[field.key] as Map)['signerName']?.toString()
        : null;

    if (item != null && item['uploadStatus'] == 'uploaded') {
      final url = item['url'] as String?;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (url != null && url.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, height: 90, fit: BoxFit.contain),
            ),
          if (signerName != null && signerName.isNotEmpty) ...[
            const SizedBox(height: 4),
            AppText.bodySmall(signerName, color: FeColors.ink2),
          ],
          if (!readOnly) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => actions.onCaptureSignature(field),
              icon: const Icon(LucideIcons.rotateCcw, size: 14),
              label: const Text('Redo'),
            ),
          ],
        ],
      );
    }

    if (item != null && item['uploadStatus'] == 'pending') {
      return Row(
        children: [
          const Icon(LucideIcons.clock, size: 14, color: FeColors.warning),
          const SizedBox(width: 6),
          const Expanded(
            child: AppText.bodySmall('Upload failed. Saved on this device.', color: FeColors.warning),
          ),
          TextButton(
            onPressed: () => actions.onRetrySignature(field),
            child: const Text('Retry'),
          ),
        ],
      );
    }

    if (readOnly) {
      return const AppText.bodySmall('No signature captured', color: FeColors.ink2);
    }

    return OutlinedButton.icon(
      onPressed: () => actions.onCaptureSignature(field),
      icon: const Icon(LucideIcons.penLine, size: 16),
      label: const Text('Add Signature'),
    );
  }
}

/// Where this inspection's last submit is, with a plain reason and Retry:
/// "Waiting to send — check in your location…", "Not sent — …". Hidden when
/// there is nothing to say.
class _SendBanner extends ConsumerWidget {
  const _SendBanner({
    required this.assignmentId,
    required this.serverStatus,
    required this.refusal,
    required this.refusalText,
    required this.busy,
    required this.onRetry,
  });

  final String assignmentId;
  final String serverStatus;
  final InspectionRefused? refusal;
  final String? refusalText;
  final bool busy;
  final void Function(InspectionSendStatus status) onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A refusal from the tap just made says exactly what the server said
    // (with the missing fields); otherwise show the kept submit's state.
    final InspectionSendStatus? status = refusal != null
        ? InspectionSendStatus(InspectionSendState.notSent, reasonKey: refusal!.reasonKey)
        : ref
              .watch(inspectionSendStatusProvider((id: assignmentId, serverStatus: serverStatus)))
              .valueOrNull;
    if (status == null) return const SizedBox.shrink();

    final notSent = status.state == InspectionSendState.notSent;
    final sending = status.state == InspectionSendState.sending;
    final color = notSent ? FeColors.danger : FeColors.warning;
    final reason = refusalText ?? status.reasonKey?.getString(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TechCard(
        tint: notSent ? FeColors.dangerSoft : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              notSent ? LucideIcons.circleAlert : LucideIcons.cloudUpload,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.bodySmall(
                    status.labelKey.getString(context),
                    weight: FontWeight.w700,
                    color: color,
                  ),
                  if (reason != null) ...[
                    const SizedBox(height: 2),
                    AppText.bodySmall(reason, color: FeColors.ink2),
                  ],
                ],
              ),
            ),
            if (!sending && refusal == null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : () => onRetry(status),
                child: Text('inspection.send.retry'.getString(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

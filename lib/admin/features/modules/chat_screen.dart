import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/media/photo_picker.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/catalog_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../module/module_screen.dart';
import 'module_spec.dart';
import '../../../widgets/dir_icon.dart';

/// Ask FlowAI on the phone (FE-mobile.md 3c): the web's chat
/// (components/fu-agent/fu-agent.tsx) over the same calls:
///   POST /api/utility/ai/chat-v2/stream {message, sessionId, env,
///        images?: [data URL], isCreateAsset?: true, isAssetReport?: true} → SSE:
///     step {title|description}, delta {text}, stream_reset,
///     final {content, actions, context}, error {error}
///     (server utilityAiController.ts chatWithUtilityAgentV2Stream)
///   POST /api/utility/ai/chat-v2 (same body) → {content, actions, context},
///     when the stream fails before any event (an older server, a buffering proxy)
///   GET  /api/utility/ai/chat/sessions                      past chats
///   GET  /api/utility/ai/chat/history?sessionId&page&limit   one chat
/// The session id is minted here, as the web does (crypto.randomUUID()).
///
/// Photos go inline as `data:image/…;base64,` URLs (the server drops anything
/// else), up to 5, about 1024 px like the web's compressImage. The two modes
/// are the web's chips, shown only when the user has them (bootstrap prefs
/// `aiCreateAsset` / `aiAssetReport`): "Create asset" answers with a draft in
/// `context.assetData`, saved here with `POST /api/fm/assets` after a building
/// is picked (admins: live at once; others: sent for approval, server
/// assetCreationService.ts). "Inspection report" answers in markdown, which
/// can be shared — the web's PDF is built in the browser.
class ChatSessionsScreen extends ConsumerStatefulWidget {
  const ChatSessionsScreen({super.key, required this.module});
  final MobileModule module;

  @override
  ConsumerState<ChatSessionsScreen> createState() => _ChatSessionsScreenState();
}

class _ChatSessionsScreenState extends ConsumerState<ChatSessionsScreen> {
  late Future<List<Json>> _sessions = _load();

  Future<List<Json>> _load() async {
    final body = await ref.read(apiClientProvider).get('/api/utility/ai/chat/sessions');
    return body is Map ? rowsOf({'data': body['sessions']}) : rowsOf(body);
  }

  Future<void> _open(String sessionId, {String? title}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(module: widget.module, sessionId: sessionId, title: title),
      ),
    );
    if (mounted) setState(() => _sessions = _load());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: FeHeader(title: widget.module.label),
    floatingActionButton: FloatingActionButton.extended(
      // The theme leaves the FAB on a pale container; the label is white.
      backgroundColor: FeColors.primary,
      foregroundColor: Colors.white,
      onPressed: () => _open(newSessionId()),
      icon: const Icon(LucideIcons.messageSquarePlus, size: 18),
      label: AppText('chat.new'.getString(context), color: Colors.white),
    ),
    body: FutureBuilder<List<Json>>(
      future: _sessions,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const TechSpinner();
        if (snap.hasError) {
          return Center(
            child: TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context)),
          );
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return Center(
            child: TechEmptyState(icon: LucideIcons.bot, title: 'chat.empty'.getString(context), subtitle: 'chat.empty_hint'.getString(context)),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TechCard(
                  onTap: () => _open('${r['sessionId']}', title: s(r['title']) ?? s(r['preview'])),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText.titleSmall(s(r['title']) ?? s(r['preview']) ?? '–', maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      AppText.caption([s(r['module']), fmtDate(r['timestamp'])].whereType<String>().join(' · ')),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// A v4 UUID from a secure random source (the server keys history by it).
String newSessionId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// The web's two FlowAI modes. `report` is "inspectionReport" in the web UI
/// and `isAssetReport` on the wire.
enum ChatMode { createAsset, report }

/// A photo as the server reads it: `data:<mime>;base64,<bytes>`. The mime
/// follows the bytes (PNG stays PNG); anything else is sent as JPEG, which is
/// what the picker writes when it re-encodes.
String photoDataUrl(Uint8List bytes) {
  final png = bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
  return 'data:${png ? 'image/png' : 'image/jpeg'};base64,${base64Encode(bytes)}';
}

/// The bytes of a data URL, or null for anything else (a file URL from history).
Uint8List? dataUrlBytes(String url) {
  final m = RegExp(r'^data:[^;]+;base64,(.+)$', dotAll: true).firstMatch(url);
  if (m == null) return null;
  try {
    return base64Decode(m.group(1)!);
  } catch (_) {
    return null;
  }
}

/// The request body for one turn. The server needs some text even with a
/// photo only, so [fallbackText] stands in for an empty message.
Map<String, dynamic> chatRequest({
  required String text,
  required String sessionId,
  required String env,
  List<String> images = const [],
  ChatMode? mode,
  String fallbackText = '',
}) => {
  'message': text.isEmpty ? fallbackText : text,
  'sessionId': sessionId,
  'env': env,
  if (images.isNotEmpty) 'images': images,
  if (mode == ChatMode.createAsset) 'isCreateAsset': true,
  if (mode == ChatMode.report) 'isAssetReport': true,
};

const _maxPhotos = 5;

Widget _brokenPhoto(BuildContext context, Object error, StackTrace? stack) =>
    Container(width: 56, height: 56, color: FeColors.line, child: const Icon(LucideIcons.imageOff, size: 18, color: FeColors.ink2));

/// Lower than the 1600 px the rest of the app uses: the web's compressImage
/// fits 1024 × 1024, and every photo rides inside the chat request.
final chatPhotoPickerProvider = Provider<Future<PickedPhoto?> Function(BuildContext context)>((ref) => (context) => pickPhoto(context, maxWidth: 1024));

class ChatMessage {
  const ChatMessage({required this.fromUser, required this.text, this.images = const [], this.actions = const [], this.context = const {}});
  final bool fromUser;
  final String text;

  /// Data URLs the user attached.
  final List<String> images;

  /// The agent's `actions` / `context` (a Create asset draft, a report).
  final List<Json> actions;
  final Json context;

  Json? get assetDraft => context['assetData'] is Map ? (context['assetData'] as Map).cast<String, dynamic>() : null;

  /// An inspection report (or any answer the server offers to turn into a report).
  bool get isReport => context['reportType'] != null || actions.any((a) => a['type'] == 'generateReport');
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.module, required this.sessionId, this.title});
  final MobileModule module;
  final String sessionId;
  final String? title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <ChatMessage>[];
  final _photos = <String>[];
  ChatMode? _mode;
  bool _loading = true;
  bool _sending = false;

  /// The answer so far while it streams in, and what the agent is doing.
  String? _partial;
  String? _step;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final body = await ref.read(apiClientProvider).get('/api/utility/ai/chat/history', query: {'sessionId': widget.sessionId, 'page': '1', 'limit': '50'});
      final msgs = body is Map ? rowsOf({'data': body['messages']}) : const <Json>[];
      if (mounted) {
        setState(
          () => _messages.addAll([
            for (final m in msgs)
              if (s(m['content']) != null)
                ChatMessage(
                  fromUser: m['type'] == 'user',
                  text: s(m['content'])!,
                  images: [for (final i in m['images'] is List ? m['images'] as List : const []) if (i is String) i],
                  actions: rowsOf({'data': m['actions']}),
                  context: m['context'] is Map ? (m['context'] as Map).cast<String, dynamic>() : const {},
                ),
          ]),
        );
      }
    } catch (_) {
      // A brand-new session has no history; any other failure leaves the chat usable.
    } finally {
      if (mounted) setState(() => _loading = false);
      _toEnd();
    }
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  Future<void> _addPhoto() async {
    if (_photos.length >= _maxPhotos) {
      _toast('chat.max_photos'.getString(context));
      return;
    }
    final p = await ref.read(chatPhotoPickerProvider)(context);
    if (p != null && mounted) setState(() => _photos.add(photoDataUrl(p.bytes)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _photos.isEmpty) || _sending) return;
    final images = List<String>.of(_photos);
    final mode = _mode;
    final req = chatRequest(
      text: text,
      sessionId: widget.sessionId,
      // Same provider env the web sends (proxyEnvFromPermissions = dashboardEnv rule).
      env: ref.read(loadedCatalogProvider)?.dashboardEnv ?? 'test',
      images: images,
      mode: mode,
      fallbackText: 'chat.photo_default'.getString(context),
    );
    _input.clear();
    setState(() {
      _messages.add(ChatMessage(fromUser: true, text: req['message'] as String, images: images));
      _photos.clear();
      _sending = true;
    });
    _toEnd();
    final noAnswer = 'chat.no_answer'.getString(context);
    final api = ref.read(apiClientProvider);
    String? reply;
    var actions = const <Json>[];
    var ctx = const <String, dynamic>{};
    String? failed;
    var heard = false; // any event came: the server has the message, never re-send it
    void readFinal(Object? e) {
      if (e is! Map) return;
      reply = s(e['content']);
      actions = rowsOf({'data': e['actions']});
      if (e['context'] is Map) ctx = (e['context'] as Map).cast<String, dynamic>();
    }

    try {
      try {
        await for (final e in api.postEvents('/api/utility/ai/chat-v2/stream', body: req)) {
          heard = true;
          if (!mounted) return;
          switch (e['type']) {
            case 'step':
              final label = s(e['title']) ?? s(e['description']);
              if (label != null) setState(() => _step = label);
            case 'delta':
              setState(() => _partial = '${_partial ?? ''}${e['text'] ?? ''}');
              _toEnd();
            case 'stream_reset':
              setState(() => _partial = null);
            case 'final':
              readFinal(e);
            case 'error':
              failed = s(e['error']) ?? noAnswer;
          }
        }
        // The server ends the stream right after an error event.
        if (failed != null) throw UnknownFailure(failed);
      } on ApiFailure {
        if (heard) rethrow;
        // The stream never started: ask once without it.
        readFinal(await api.post('/api/utility/ai/chat-v2', body: req));
      }
      reply ??= _partial;
      if (mounted) setState(() => _messages.add(ChatMessage(fromUser: false, text: reply ?? noAnswer, actions: actions, context: ctx)));
    } on ApiFailure catch (e) {
      if (mounted) setState(() => _messages.add(ChatMessage(fromUser: false, text: _partial ?? e.message)));
    } finally {
      if (mounted) setState(() => (_sending = false, _partial = null, _step = null));
      _toEnd();
    }
  }

  Future<void> _saveDraft(Json draft) async {
    final ref0 = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AssetDraftSheet(draft: draft),
    );
    if (ref0 != null && mounted) _toast(ref0);
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: AppText(text)));

  Future<void> _share(ChatMessage m) => SharePlus.instance.share(ShareParams(text: m.text, subject: widget.title ?? widget.module.label));

  @override
  Widget build(BuildContext context) {
    // Pushed with Navigator, so the router guard never re-runs: re-check here
    // in case Ask FlowAI is switched off while the chat is open.
    final boot = ref.watch(loadedCatalogProvider);
    if (boot != null && !boot.has(widget.module.id)) return const UnavailableScreen();
    final modes = [
      if (boot?.aiCreateAsset == true) (ChatMode.createAsset, 'chat.mode_asset', LucideIcons.packagePlus),
      if (boot?.aiAssetReport == true) (ChatMode.report, 'chat.mode_report', LucideIcons.clipboardList),
    ];
    return Scaffold(
      appBar: FeHeader(title: widget.title ?? widget.module.label),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const TechSpinner()
                : _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: TechEmptyState(icon: LucideIcons.bot, title: 'chat.welcome'.getString(context)),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length + (_sending ? 1 : 0),
                    itemBuilder: (context, i) => i < _messages.length
                        ? _Bubble(_messages[i], onSaveDraft: _saveDraft, onShare: _share)
                        : _partial != null && _partial!.isNotEmpty
                            ? _Bubble(ChatMessage(fromUser: false, text: _partial!))
                            : Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const TechSpinner(size: 22),
                                      if (_step != null) ...[
                                        const SizedBox(width: 10),
                                        Flexible(child: AppText.caption(_step!, maxLines: 2, overflow: TextOverflow.ellipsis)),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (modes.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final (mode, key, icon) in modes)
                          FilterChip(
                            avatar: Icon(icon, size: 16),
                            label: AppText(key.getString(context)),
                            selected: _mode == mode,
                            onSelected: _sending ? null : (on) => setState(() => _mode = on ? mode : null),
                          ),
                      ],
                    ),
                  if (_mode != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(top: 2, bottom: 4, start: 4),
                      child: AppText.caption((_mode == ChatMode.createAsset ? 'chat.hint_asset' : 'chat.hint_report').getString(context)),
                    ),
                  if (_photos.isNotEmpty)
                    SizedBox(
                      height: 64,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (var i = 0; i < _photos.length; i++)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 8, top: 4),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(dataUrlBytes(_photos[i])!, width: 56, height: 56, fit: BoxFit.cover, errorBuilder: _brokenPhoto)),
                                  PositionedDirectional(
                                    end: -8,
                                    top: -8,
                                    child: IconButton(
                                      visualDensity: VisualDensity.compact,
                                      tooltip: 'chat.remove_photo'.getString(context),
                                      icon: const Icon(LucideIcons.circleX, size: 18, color: FeColors.ink2),
                                      onPressed: () => setState(() => _photos.removeAt(i)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'chat.attach'.getString(context),
                        onPressed: _sending ? null : _addPhoto,
                        icon: const Icon(LucideIcons.camera, size: 20),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(hintText: 'chat.hint'.getString(context)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(onPressed: _sending ? null : _send, icon: const DirIcon(LucideIcons.send, size: 18)),
                    ],
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

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {this.onSaveDraft, this.onShare});
  final ChatMessage m;
  final void Function(Json draft)? onSaveDraft;
  final void Function(ChatMessage m)? onShare;

  @override
  Widget build(BuildContext context) {
    final draft = m.assetDraft;
    return Align(
      alignment: m.fromUser ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: m.fromUser ? FeColors.primary : FeColors.panel,
          borderRadius: BorderRadius.circular(16),
          border: m.fromUser ? null : Border.all(color: FeColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final i in m.images)
                      if (dataUrlBytes(i) case final bytes?)
                        ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(bytes, width: 96, height: 96, fit: BoxFit.cover, errorBuilder: _brokenPhoto)),
                  ],
                ),
              ),
            // Answers are markdown (lists, bold, tables), as on the web; the
            // user's own text is shown as typed.
            if (m.fromUser)
              SelectableText(m.text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white))
            else
              MarkdownBody(
                data: m.text,
                selectable: true,
                softLineBreak: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: Theme.of(context).textTheme.bodyMedium?.copyWith(color: FeColors.ink, height: 1.4),
                  tableBorder: TableBorder.all(color: FeColors.line),
                ),
                onTapLink: (_, href, _) {
                  final uri = href == null ? null : Uri.tryParse(href);
                  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) launchUrl(uri, mode: LaunchMode.externalApplication);
                },
              ),
            if (draft != null && onSaveDraft != null) ...[
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: () => onSaveDraft!(draft),
                icon: const Icon(LucideIcons.packagePlus, size: 16),
                label: AppText('chat.create_asset'.getString(context)),
              ),
            ],
            if (!m.fromUser && m.isReport && onShare != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => onShare!(m),
                icon: const Icon(LucideIcons.share2, size: 16),
                label: AppText('chat.share_report'.getString(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The AI's asset draft, a building to put it in, then `POST /api/fm/assets`
/// (the web's useAssetCreation: the draft is the body; the server fills type /
/// category names from their ids and the org from the building). Pops with
/// the message to show.
class AssetDraftSheet extends ConsumerStatefulWidget {
  const AssetDraftSheet({super.key, required this.draft});
  final Json draft;

  @override
  ConsumerState<AssetDraftSheet> createState() => _AssetDraftSheetState();
}

class _AssetDraftSheetState extends ConsumerState<AssetDraftSheet> {
  late final _name = TextEditingController(text: s(widget.draft['name']) ?? '');
  List<Json>? _buildings;
  String? _building;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBuildings();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadBuildings() async {
    try {
      final body = await ref.read(apiClientProvider).get('/api/fm/bs/building-systems', query: {'page': '1', 'limit': '200'});
      final rows = rowsOf(body);
      if (mounted) setState(() => (_buildings = rows, _building = rows.length == 1 ? '${rows.single['id']}' : null));
    } catch (e) {
      if (mounted) setState(() => (_buildings = const [], _error = e is ApiFailure ? e.message : '$e'));
    }
  }

  Future<void> _save() async {
    if (_building == null || _name.text.trim().isEmpty) return;
    setState(() => (_saving = true, _error = null));
    try {
      final body = await ref.read(apiClientProvider).post('/api/fm/assets', body: {
        ...widget.draft,
        'name': _name.text.trim(),
        'assetName': _name.text.trim(),
        'buildingID': _building,
      });
      final data = body is Map && body['data'] is Map ? body['data'] as Map : const {};
      final tag = s(data['assetReferenceId']) ?? _name.text.trim();
      if (!mounted) return;
      final key = data['isAccepted'] == false ? 'chat.asset_pending' : 'chat.asset_created';
      Navigator.pop(context, context.formatString(key.getString(context), [tag]));
    } on ApiFailure catch (e) {
      if (mounted) setState(() => (_saving = false, _error = e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final facts = [
      ('fact.type', s(d['type'])),
      ('fact.category', s(d['category'])),
      ('fact.manufacturer', s(d['manufacturer'])),
      ('fact.model', s(d['model'])),
      ('fact.serial', s(d['serialNumber'])),
      ('fact.condition', s(d['assetConditions'])),
      ('fact.description', s(d['description'])),
    ].where((f) => f.$2 != null && f.$2!.isNotEmpty).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppText.titleMedium('chat.asset_draft'.getString(context)),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: InputDecoration(labelText: 'fact.name'.getString(context))),
            const SizedBox(height: 12),
            for (final (k, v) in facts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 110, child: AppText.caption(k.getString(context))),
                    Expanded(child: AppText.bodySmall(v!)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (_buildings == null)
              const TechSpinner(size: 24)
            else
              DropdownButtonFormField<String>(
                initialValue: _building,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'chat.asset_building'.getString(context)),
                items: [for (final b in _buildings!) DropdownMenuItem(value: '${b['id']}', child: AppText(s(b['name']) ?? '–', maxLines: 1, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _building = v),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: AppText.bodySmall(_error!, color: FeColors.danger)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _saving || _building == null ? null : _save,
              child: _saving ? const TechSpinner(size: 18) : AppText('chat.create_asset'.getString(context)),
            ),
          ],
        ),
      ),
    );
  }
}

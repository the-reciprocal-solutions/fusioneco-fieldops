import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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

/// Ask FlowAI on the phone (FE-mobile.md 3c): the web's chat
/// (components/fu-agent/fu-agent.tsx) over the same non-streaming call:
///   POST /api/utility/ai/chat-v2 {message, sessionId, env} → {content}
///   GET  /api/utility/ai/chat/sessions                      past chats
///   GET  /api/utility/ai/chat/history?sessionId&page&limit   one chat
/// The session id is minted here, as the web does (crypto.randomUUID()).
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

class ChatMessage {
  const ChatMessage({required this.fromUser, required this.text});
  final bool fromUser;
  final String text;
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
  bool _loading = true;
  bool _sending = false;

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
              if (s(m['content']) != null) ChatMessage(fromUser: m['type'] == 'user', text: s(m['content'])!),
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

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() {
      _messages.add(ChatMessage(fromUser: true, text: text));
      _sending = true;
    });
    _toEnd();
    try {
      final body = await ref
          .read(apiClientProvider)
          .post(
            '/api/utility/ai/chat-v2',
            body: {
              'message': text,
              'sessionId': widget.sessionId,
              // Same provider env the web sends (proxyEnvFromPermissions = dashboardEnv rule).
              'env': ref.read(loadedCatalogProvider)?.dashboardEnv ?? 'test',
            },
          );
      final reply = body is Map ? s(body['content']) : null;
      if (mounted) setState(() => _messages.add(ChatMessage(fromUser: false, text: reply ?? 'chat.no_answer'.getString(context))));
    } on ApiFailure catch (e) {
      if (mounted) setState(() => _messages.add(ChatMessage(fromUser: false, text: e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
      _toEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pushed with Navigator, so the router guard never re-runs: re-check here
    // in case Ask FlowAI is switched off while the chat is open.
    final boot = ref.watch(loadedCatalogProvider);
    if (boot != null && !boot.has(widget.module.id)) return const UnavailableScreen();
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
                    itemBuilder: (context, i) => i == _messages.length
                        ? const Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Padding(padding: EdgeInsets.all(8), child: TechSpinner(size: 22)),
                          )
                        : _Bubble(_messages[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
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
                  IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(LucideIcons.send, size: 18)),
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
  const _Bubble(this.m);
  final ChatMessage m;

  @override
  Widget build(BuildContext context) => Align(
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
      // The answer can be markdown; shown as plain text in v1 (PENDING).
      child: SelectableText(m.text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: m.fromUser ? Colors.white : FeColors.ink)),
    ),
  );
}

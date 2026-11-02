import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/env.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// A page of the web admin panel inside the app, already signed in
/// (FE-mobile.md 0.6): 3D views, Trends, the efficiency PDF report, and
/// every "open on web" button.
///
/// The web keeps its session in `localStorage` (app/login/page.tsx), which is
/// empty in a fresh WebView. So, as FieldOps' TwinScreen does: open the web's
/// own /login (a cheap same-origin page), write the keys the web's sign-in
/// writes, then load the page. The web's login page redirects itself as soon
/// as it sees a token, and a page whose token ran out lands back on /login:
/// both are "seed again and re-ask", capped so a page that never loads
/// cannot loop.
///
/// Downloads (the PDF report is a Blob the page "clicks" — reportPdf.ts
/// saveBlob) can't be saved by a WebView, so an injected hook hands the
/// file's bytes to the app, which offers the phone's share sheet.
class WebScreen extends ConsumerStatefulWidget {
  const WebScreen({super.key, required this.path, this.title});

  /// A path of the web app, e.g. `/hvac/efficiency/report`.
  final String path;
  final String? title;

  @override
  ConsumerState<WebScreen> createState() => _WebScreenState();
}

/// Same origin as the web app (scheme, host, port). Pure.
bool sameOrigin(Uri? target, Uri? base) =>
    target != null && base != null && target.scheme == base.scheme && target.host == base.host && target.port == base.port;

/// The localStorage the web's sign-in writes (app/login/page.tsx), for this user. Pure.
Map<String, String> webSessionEntries(String token, Map<String, dynamic> user) => {
      'token': token,
      'isAuthenticated': 'true',
      'role': '${user['role'] ?? ''}',
      'userId': '${user['id'] ?? ''}',
      'userName': '${user['name'] ?? ''}',
      if (user['username'] != null) 'username': '${user['username']}',
      'meta': jsonEncode({'username': user['username']}),
      'userDetails': jsonEncode(user),
    };

/// Hides the web's side navigation (components/side-navigation.tsx: the
/// `<aside>` with the width transition): this screen has its own header and
/// back button, and on a phone the open rail covers most of the page. A
/// stylesheet, not inline styles, so React re-renders don't bring it back.
const _hideWebChrome = '''
(function () {
  if (document.getElementById('fe-native-chrome')) return;
  var s = document.createElement('style');
  s.id = 'fe-native-chrome';
  s.textContent = 'aside[class*="transition-[width]"]{display:none!important}';
  document.head.appendChild(s);
})();
''';

/// Hands a Blob download (an `<a download href="blob:…">` click) to the app.
const _downloadHook = '''
(function () {
  if (window.__feDownloadHook) return;
  window.__feDownloadHook = true;
  var click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    var href = this.href || '';
    if (this.hasAttribute('download') && (href.indexOf('blob:') === 0 || href.indexOf('data:') === 0)) {
      var name = this.getAttribute('download') || 'download';
      fetch(href).then(function (r) { return r.blob(); }).then(function (b) {
        var fr = new FileReader();
        fr.onload = function () { FeDownload.postMessage(JSON.stringify({ name: name, data: String(fr.result) })); };
        fr.readAsDataURL(b);
      });
      return;
    }
    return click.apply(this, arguments);
  };
})();
''';

class _WebScreenState extends ConsumerState<WebScreen> {
  static const _maxAttempts = 3;

  WebViewController? _controller;
  bool _loading = true;
  bool _asked = false; // the target has been requested (after a seed)
  int _attempts = 0;
  String? _error;

  Uri get _target => Uri.parse('${Env.webBaseUrl}${widget.path}');

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final user = ref.read(authControllerProvider).user;
    final token = await ref.read(apiClientProvider).freshToken();
    if (!mounted) return;
    if (user == null || token == null || token.isEmpty) {
      setState(() => (_loading = false, _error = 'web.sign_in_required'.getString(context)));
      return;
    }

    final base = Uri.tryParse(Env.webBaseUrl);
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(FeColors.page)
      ..addJavaScriptChannel('FeDownload', onMessageReceived: (m) => _saveDownload(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) {
          final t = Uri.tryParse(r.url);
          if (sameOrigin(t, base) || t?.scheme == 'blob' || t?.scheme == 'data' || t?.scheme == 'about') return NavigationDecision.navigate;
          // Files, other sites: the phone's browser, so this view never strands the user.
          if (t != null) launchUrl(t, mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: _onPageFinished,
        onWebResourceError: (e) {
          if (e.isForMainFrame == false) return;
          // A load we replaced ourselves (iOS -999) or one we sent to the browser (102).
          if (e.errorCode == -999 || e.errorCode == 102) return;
          if (mounted) setState(() => (_loading = false, _error = 'web.load_error'.getString(context)));
        },
      ));
    setState(() => _controller = c);
    await c.loadRequest(Uri.parse('${Env.webBaseUrl}/login'));
  }

  Future<void> _onPageFinished(String url) async {
    final c = _controller;
    if (c == null) return;
    final at = Uri.tryParse(url);
    final onLogin = at?.path == '/login';
    // The bootstrap page, or the page signed itself out (token ran out):
    // seed and re-ask. Anywhere else after the ask is the page (or where it
    // redirected to) — fine.
    if (onLogin || !_asked) {
      if (_attempts >= _maxAttempts) {
        if (mounted) setState(() => (_loading = false, _error = 'web.load_error'.getString(context)));
        return;
      }
      _attempts++;
      final user = ref.read(authControllerProvider).user;
      final token = await ref.read(apiClientProvider).freshToken();
      if (user == null || token == null) return;
      final js = StringBuffer();
      for (final e in webSessionEntries(token, user.toJson()).entries) {
        js.write('localStorage.setItem(${jsonEncode(e.key)}, ${jsonEncode(e.value)});');
      }
      await c.runJavaScript(js.toString());
      _asked = true;
      await c.loadRequest(_target);
      return;
    }
    _attempts = 0;
    await c.runJavaScript(_hideWebChrome);
    await c.runJavaScript(_downloadHook);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveDownload(String message) async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = 'web.download_failed'.getString(context);
    // iPad shows the share sheet as a popover and needs an anchor, or
    // share_plus fails there; iPhone and Android ignore it.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      final m = jsonDecode(message) as Map;
      final dataUrl = '${m['data']}';
      final name = '${m['name']}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
      final file = File('${(await getTemporaryDirectory()).path}/$name');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], title: name, sharePositionOrigin: origin));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(failed)));
    }
  }

  void _retry() {
    setState(() => (_controller = null, _error = null, _loading = true, _asked = false, _attempts = 0));
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: widget.title ?? 'web.title'.getString(context),
        actions: [
          IconButton(tooltip: 'web.reload'.getString(context), icon: const Icon(LucideIcons.rotateCw, size: 18), onPressed: c == null ? null : () => c.reload()),
          IconButton(
            tooltip: 'web.open_in_browser'.getString(context),
            icon: const Icon(LucideIcons.externalLink, size: 18),
            onPressed: () => launchUrl(_target, mode: LaunchMode.externalApplication),
          ),
        ],
      ),
      body: _error != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TechEmptyState(icon: LucideIcons.wifiOff, title: _error!),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _retry, child: AppText('common.try_again'.getString(context))),
                ],
              ),
            )
          : Stack(
              children: [
                if (c != null) WebViewWidget(controller: c),
                // Hides the web's own login page while we seed it.
                if (_loading) Container(color: FeColors.page, child: const TechSpinner()),
              ],
            ),
    );
  }
}

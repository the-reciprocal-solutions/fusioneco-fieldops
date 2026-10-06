import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/env.dart';
import '../../core/bim_viewer/web_view_errors.dart';
import '../../core/storage/session_store.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// The 3D asset view, shown by loading the portal's own twin page.
///
/// The viewer is xeokit rendering an XKT model in WebGL — thousands of lines
/// of loader, mapping store and camera work that exist and are maintained on
/// the web. Reimplementing that natively would buy nothing a technician can
/// see, so this screen hosts the real page instead.
///
/// The page expects a signed-in browser: it reads its bearer token out of
/// `localStorage`, which is empty in a fresh webview. So the token is written
/// into that origin first, and only then is the twin loaded.
class TwinScreen extends ConsumerStatefulWidget {
  const TwinScreen({super.key, required this.assetId, this.assetName});

  final String assetId;
  final String? assetName;

  @override
  ConsumerState<TwinScreen> createState() => _TwinScreenState();
}

class _TwinScreenState extends ConsumerState<TwinScreen> {
  WebViewController? _controller;
  var _loading = true;

  /// How many times the screen has tried to reach the twin. The bootstrap page
  /// is the portal's own login screen, which redirects itself to the dashboard
  /// the moment it sees the token appear — and that client-side navigation can
  /// land after our own request for the twin. So arriving anywhere other than
  /// the twin is treated as "seed again and re-ask", with a cap so a page that
  /// genuinely refuses to load cannot spin forever.
  var _attempts = 0;
  static const _maxAttempts = 3;
  String? _error;

  String get _twinUrl {
    final query = widget.assetName == null
        ? ''
        : '?name=${Uri.encodeComponent(widget.assetName!)}';
    return '${Env.webBaseUrl}/technician/twin/${widget.assetId}$query';
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// The error state's next step: a fresh WebView, from the top.
  void _retry() {
    setState(() {
      _error = null;
      _loading = true;
      _attempts = 0;
      _controller = null;
    });
    _start();
  }

  Future<void> _start() async {
    if (ref.read(authControllerProvider).permissions.isDigitalTwin == false) {
      // Denied — build() renders the access-denied state instead. Skip the
      // token read and webview load entirely.
      return;
    }

    // Renewed first if it has run out: the web twin only gets this one copy.
    final token = await ref.read(apiClientProvider).freshToken();
    final session = ref.read(authControllerProvider).session;

    if (!mounted) return;
    if (token == null || token.isEmpty || session == null) {
      setState(() {
        _loading = false;
        _error = 'twin.sign_in_required'.getString(context);
      });
      return;
    }

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final target = Uri.tryParse(request.url);
            final base = Uri.tryParse(Env.webBaseUrl);
            final sameOrigin = target != null &&
                base != null &&
                target.scheme == base.scheme &&
                target.host == base.host &&
                target.port == base.port;
            if (sameOrigin) return NavigationDecision.navigate;

            // Attachment/document links point at a different host (file
            // storage, not the web app) — this WebView isn't a browser, it
            // has nowhere to show them and no back button of its own, so
            // loading one here just strands the technician. Hand it to the
            // device's real browser instead and keep the twin page as-is.
            if (target != null) {
              launchUrl(target, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          },
          onPageFinished: (url) async {
            if (!url.startsWith(_twinUrl.split('?').first)) {
              if (_attempts >= _maxAttempts) {
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _error = 'twin.redirect_loop'.getString(context);
                  });
                }
                return;
              }
              _attempts++;
              // Same origin as the twin, so what is written here is what the
              // twin page reads. Re-seeding is harmless — it writes the same
              // values — and it covers the case where the redirect landed on a
              // page that cleared them.
              await _seedSession(token, session);
              await _controller?.loadRequest(Uri.parse(_twinUrl));
              return;
            }
            // Strip the portal's own chrome so only the viewer shows: its
            // header (this screen already has one), the mobile bottom nav, and
            // the floating AI bubble. Injected as a stylesheet rather than
            // inline styles because React re-renders the layout and would
            // otherwise put them straight back.
            await _controller?.runJavaScript('''
              (function () {
                if (document.getElementById('fe-native-chrome')) return;
                var s = document.createElement('style');
                s.id = 'fe-native-chrome';
                s.textContent =
                  'header,nav{display:none!important}' +
                  '[class*="z-[100]"]{display:none!important}' +
                  '[class~="pb-16"]{padding-bottom:0!important}';
                document.head.appendChild(s);
              })();
            ''');
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // 2026-10-06 (iPhone): WKWebView reports a load the app itself
            // replaced (-999) and a link this screen hands to the browser
            // (102, "frame load interrupted") as main-frame errors. Both
            // used to swap a working twin for an error page; neither is a
            // failure. A killed web process is: reload it.
            switch (classifyWebViewError(error)) {
              case WebViewErrorKind.benign:
                return;
              case WebViewErrorKind.processGone:
                _controller?.reload();
                return;
              case WebViewErrorKind.failed:
                if (mounted) {
                  setState(() {
                    _loading = false;
                    // Plain words only: the raw description is WebKit's
                    // ("NSURLErrorDomain error -1004"), never for a screen.
                    _error = 'twin.load_error_subtitle'.getString(context);
                  });
                }
            }
          },
        ),
      );

    setState(() => _controller = controller);
    // A cheap same-origin page to get a storage context; the twin replaces it
    // as soon as the token is in place.
    await controller.loadRequest(Uri.parse('${Env.webBaseUrl}/login'));
  }

  /// Writes exactly the keys the web login writes, because the twin's data
  /// calls and the pages it links to read them by name.
  Future<void> _seedSession(String token, Session session) async {
    final entries = <String, String>{
      'token': token,
      'isAuthenticated': 'true',
      'role': 'Technician',
      'userId': session.userId,
      'userName': session.name,
      if (session.username != null) 'username': session.username!,
      if (session.technicianId != null) 'technicianId': session.technicianId!,
    };

    final script = StringBuffer();
    for (final entry in entries.entries) {
      script.write(
        'localStorage.setItem(${jsonEncode(entry.key)}, '
        '${jsonEncode(entry.value)});',
      );
    }
    await _controller?.runJavaScript(script.toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    // Route-level gate: a button-hide alone doesn't stop a QR scan or deep
    // link from reaching this screen directly, so check again here. Explicit
    // `false` only — unset stays allowed, same polarity as the trigger button
    // in order_detail_screen.dart.
    if (ref.watch(authControllerProvider).permissions.isDigitalTwin == false) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: FeHeader(showBack: true),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: TechEmptyState(
            icon: LucideIcons.shieldAlert,
            title: 'twin.access_denied_title'.getString(context),
            subtitle: 'twin.access_denied_subtitle'.getString(context),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: FeHeader(
        showBack: true,
        titleWidget: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppText.titleSmall(
              widget.assetName ?? 'twin.asset_location_title'.getString(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              weight: FontWeight.w700,
            ),
            AppText(
              'twin.view_label'.getString(context),
              style: theme.textTheme.labelSmall?.copyWith(
                color: FeColors.ink2,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      body: _error != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TechEmptyState(
                    icon: LucideIcons.box,
                    title: 'twin.load_error_title'.getString(context),
                    subtitle: _error,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _retry,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
                    ),
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
                    label: AppText.label('common.retry'.getString(context), color: Colors.white),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                if (controller != null) WebViewWidget(controller: controller),
                if (_loading)
                  const ColoredBox(
                    color: Colors.black,
                    child: SizedBox.expand(
                      child: TechSpinner(color: Colors.white),
                    ),
                  ),
              ],
            ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/bim_viewer/bim_view_engine.dart';
import '../../core/bim_viewer/viewer_asset_server.dart';
import '../../core/bim_viewer/web_view_errors.dart';

/// [BimViewEngine] over `assets/bim_viewer` (three.js, MIT) in a WebView,
/// served by a [ViewerAssetServer] on 127.0.0.1 (docs/bim-viewer.md §4).
///
/// Not the xeokit twin page `TwinScreen` shows: that one is the web
/// portal's own page, online only, AGPL. This page ships inside the app,
/// works offline from the floor pack's tiles, and is licence-free. Both
/// stay (the user asked for this viewer *alongside* the existing twin).
///
/// 2026-10-06, the owner's iPhone: "Verify in 3D shows a broken page, and
/// none of the actions work". Root cause: the WebView was configured with a
/// cascade (`WebViewController()..addJavaScriptChannel(...)`), dropping the
/// returned futures, and `loadRequest` ran straight after. On WKWebView
/// `addJavaScriptChannel` first awaits a platform round trip
/// (`getUserContentController`) and only then adds the document-start
/// script that defines `window.FeViewer`, so the page could load without
/// it. viewer.js then posted `ready` into nothing: Dart never saw the engine
/// come up, the 3D pane spun forever and every command (layers, reset,
/// select, fly-to) was held back waiting for a `ready` that never came.
/// Now: every setup call is awaited before the load, viewer.js falls back
/// to `webkit.messageHandlers.FeViewer`, the app says `hello` when the page
/// has loaded (a missed `ready` is repeated), and a watchdog turns a page
/// that still never answers into a plain "3D couldn't start" with Retry
/// instead of an endless spinner.
class WebViewBimViewEngine implements BimViewEngine {
  WebViewBimViewEngine({
    ViewerAssetServer? server,
    Color background = const Color(0xFFF1F3F5),
    this.readyTimeout = const Duration(seconds: 20),
  })  : _server = server ?? ViewerAssetServer(loadAsset: _loadBundled),
        _background = background;

  /// How long the page may take to report `ready` before the screen says
  /// 3D couldn't start (`NOT_READY`). A cold WebView plus the WASM decoder
  /// is ~1–3 s on a mid-range phone; 20 s only trips on a page that is dead.
  final Duration readyTimeout;

  final ViewerAssetServer _server;
  final Color _background;
  final _events = StreamController<BimViewEvent>.broadcast();
  final _pending = <BimViewCommand>[];
  WebViewController? _controller;
  var _pageUp = false;
  var _disposed = false;
  Future<void>? _starting;
  Timer? _watchdog;
  AppLifecycleListener? _lifecycle;

  /// The server base the current page was loaded from. If the server comes
  /// back on another port after a suspend, the page must be reloaded.
  String? _loadedBase;

  /// Page reloads after iOS killed the WebView's process. Capped: a page that
  /// keeps dying (a floor too big for this phone) stops at plan-only.
  var _reloads = 0;
  static const _maxReloads = 2;

  static Future<List<int>?> _loadBundled(String path) async {
    try {
      final data = await rootBundle.load('assets/bim_viewer/$path');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<BimViewEvent> get events => _events.stream;

  @override
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    try {
      await _server.start();
    } catch (e) {
      _emit(BimViewerError(code: 'LOAD_FAILED', message: 'viewer server: $e'));
      return;
    }
    if (_disposed) return;
    final c = WebViewController();
    try {
      // Awaited one by one, BEFORE loadRequest — see the class comment.
      await c.setJavaScriptMode(JavaScriptMode.unrestricted);
      await c.setBackgroundColor(_background);
      await c.addJavaScriptChannel('FeViewer', onMessageReceived: (m) => _onMessage(m.message));
      await c.setNavigationDelegate(NavigationDelegate(
        // The page never navigates; anything else (a stray link) stays out.
        onNavigationRequest: (r) =>
            r.url.startsWith(_server.base) ? NavigationDecision.navigate : NavigationDecision.prevent,
        onPageFinished: (_) => unawaited(_hello()),
        onWebResourceError: _onWebError,
      ));
    } catch (e) {
      _emit(BimViewerError(code: 'LOAD_FAILED', message: 'webview setup: $e'));
      return;
    }
    if (_disposed) return;
    _controller = c;
    _lifecycle = AppLifecycleListener(
      onPause: () => unawaited(_server.suspend()),
      onResume: () => unawaited(_resume()),
    );
    await _load();
  }

  Future<void> _load() async {
    final c = _controller;
    if (c == null || _disposed) return;
    _pageUp = false;
    _armWatchdog();
    try {
      _loadedBase = _server.base;
      await c.loadRequest(_server.appUri);
    } catch (e) {
      _emit(BimViewerError(code: 'LOAD_FAILED', message: 'load: $e'));
    }
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(readyTimeout, () {
      if (!_pageUp && !_disposed) _emit(const BimViewerError(code: 'NOT_READY'));
    });
  }

  /// The handshake after every page load: make sure `window.FeViewer`
  /// exists (iOS) and ask the page to repeat `ready` if it already sent it.
  Future<void> _hello() async {
    final c = _controller;
    if (c == null || _disposed) return;
    try {
      await c.runJavaScript(_helloJs);
    } catch (_) {
      // A page that can't run this can't draw either; the watchdog says so.
    }
  }

  static const _helloJs = '(function(){'
      'var h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.FeViewer;'
      'if(!window.FeViewer&&h){window.FeViewer=h;}'
      'if(window.feViewer&&typeof window.feViewer.hello==="function"){window.feViewer.hello();}'
      '})();';

  void _onWebError(WebResourceError e) {
    switch (classifyWebViewError(e)) {
      case WebViewErrorKind.benign:
        return;
      case WebViewErrorKind.processGone:
        // iOS killed the WebView's process (memory, long background): the
        // page is blank. Reload it; the controller re-sends the floor when
        // the new page reports ready.
        if (_reloads < _maxReloads) {
          _reloads++;
          _emit(const BimViewerError(code: 'RELOADING'));
          unawaited(_load());
        } else {
          _emit(const BimViewerError(code: 'CONTEXT_LOST', message: 'web content process keeps terminating'));
        }
      case WebViewErrorKind.failed:
        _emit(BimViewerError(code: 'LOAD_FAILED', message: '${e.errorCode} ${e.description}'));
    }
  }

  /// Back from the background: re-open the server (it was closed on pause)
  /// on the same port when possible. On another port the page's URLs are
  /// dead, so it is reloaded and the floor re-sent.
  Future<void> _resume() async {
    if (_disposed) return;
    try {
      await _server.start();
    } catch (e) {
      _emit(BimViewerError(code: 'LOAD_FAILED', message: 'viewer server: $e'));
      return;
    }
    if (_disposed || _controller == null) return;
    if (_server.base != _loadedBase) {
      _emit(const BimViewerError(code: 'RELOADING'));
      await _load();
    }
  }

  void _onMessage(String raw) {
    final e = BimViewEvent.parse(raw);
    if (e == null) return;
    if (e is BimReady && !_pageUp) {
      _pageUp = true;
      _watchdog?.cancel();
      final queued = List.of(_pending);
      _pending.clear();
      for (final c in queued) {
        unawaited(_run(c));
      }
    }
    _emit(e);
  }

  void _emit(BimViewEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Future<void> send(BimViewCommand command) async {
    if (_disposed) return;
    // Before the page reports ready, JavaScript would run in whatever
    // document is loading (or about:blank) and be lost: keep it here.
    if (!_pageUp) {
      _pending.add(command);
      return;
    }
    await _run(command);
  }

  Future<void> _run(BimViewCommand command) async {
    final c = _controller;
    if (c == null || _disposed) return;
    try {
      await c.runJavaScript(command.toJavaScript());
    } catch (e) {
      if (kDebugMode) debugPrint('bim viewer: ${command.name} failed: $e');
    }
  }

  @override
  String exposeTiles(Map<String, String> pathsByHash) {
    _server.setTiles(pathsByHash);
    return _server.isRunning ? _server.tilesBase : '';
  }

  @override
  Widget buildView(BuildContext context) {
    final c = _controller;
    if (c == null) return const SizedBox.expand();
    return WebViewWidget(
      controller: c,
      // Orbit, pinch and the walk joystick are handled by the page: it must
      // win every gesture over any Flutter parent.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    _lifecycle?.dispose();
    _pending.clear();
    await _server.close();
    await _events.close();
  }
}

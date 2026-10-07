import 'package:webview_flutter/webview_flutter.dart';

/// How the app's two 3D WebViews (the model viewer's three.js page and the
/// xeokit twin, `TwinScreen`) read a `WebResourceError`. Pure, so the rule is
/// tested without a WebView.
///
/// Why this exists (2026-10-06, the owner's iPhone): WKWebView reports
/// errors Android never does. A navigation the app itself replaced (a new
/// `loadRequest` while a page was still loading) ends in `NSURLErrorCancelled`
/// (-999), and a navigation the app's own `onNavigationRequest` refused (the
/// twin hands document links to the real browser) ends in "frame load
/// interrupted" (WebKitErrorDomain 102). Both arrive as main-frame errors,
/// and the twin screen used to replace a perfectly good 3D view with that
/// raw message. Neither is a failure.
enum WebViewErrorKind {
  /// Nothing went wrong from the user's point of view: ignore it.
  benign,

  /// iOS killed the page's process (memory pressure, a long background):
  /// the page is blank but reloading it brings it back.
  processGone,

  /// The page really didn't load.
  failed,
}

/// NSURLErrorCancelled: a load superseded by another one.
const kNsUrlErrorCancelled = -999;

/// WebKitErrorFrameLoadInterruptedByPolicyChange: our navigation delegate
/// said "prevent", or the response became a download.
const kWebKitFrameLoadInterrupted = 102;

WebViewErrorKind classifyWebViewError(WebResourceError e) {
  if (e.errorType == WebResourceErrorType.webContentProcessTerminated) {
    return WebViewErrorKind.processGone;
  }
  // Sub-resources (an image, a script on another host) don't decide
  // whether the page works; the page reports its own failures.
  if (e.isForMainFrame == false) return WebViewErrorKind.benign;
  if (e.errorCode == kNsUrlErrorCancelled || e.errorCode == kWebKitFrameLoadInterrupted) {
    return WebViewErrorKind.benign;
  }
  return WebViewErrorKind.failed;
}

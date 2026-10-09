import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// `fieldops/push_actions` — see lib/core/push/native_push_actions.dart.
  private var pushChannel: FlutterMethodChannel?

  /// Button taps on alerts iOS drew itself (the server's APNs copy, while the
  /// app was in the background or closed), waiting for Dart to take them.
  private var pendingActions: [[String: Any]] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Without a notification-center delegate iOS never presents a
    // notification while the app is in the foreground, and never reports a
    // tap on one. LocalNotifications.show draws every FCM data message itself
    // (lib/core/push/local_notifications.dart), so a push that arrives with
    // the app open would otherwise show nothing on iOS (Android needs no
    // equivalent). FlutterAppDelegate forwards these callbacks to every
    // plugin (flutter_local_notifications, firebase_messaging). It must be
    // set before super, because firebase_messaging only keeps an existing
    // delegate that is a FlutterAppLifeCycleProvider. If none is set, it
    // installs itself instead.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FieldOpsPushActions") else { return }
    let channel = FlutterMethodChannel(name: "fieldops/push_actions", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "takePending":
        result(self.pendingActions)
        self.pendingActions.removeAll()
      case "setBadge":
        self.setBadge((call.arguments as? Int) ?? 0)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    pushChannel = channel
  }

  /// A button on a REMOTE alert (one iOS drew from the server's APNs
  /// payload; its `category` is one the app registered, see
  /// LocalNotifications._darwinCategories). firebase_messaging reports such
  /// a tap only as a plain open and drops the button and the typed reply, so
  /// those are caught here and handed to Dart. Body taps, dismissals and
  /// every notification the app drew itself go to the plugins as before.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let action = response.actionIdentifier
    let isRemote = response.notification.request.trigger is UNPushNotificationTrigger
    guard isRemote,
          action != UNNotificationDefaultActionIdentifier,
          action != UNNotificationDismissActionIdentifier else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }

    var data: [String: String] = [:]
    for (key, value) in response.notification.request.content.userInfo {
      guard let k = key as? String, k != "aps", !k.hasPrefix("gcm."), !k.hasPrefix("google.") else { continue }
      if let s = value as? String { data[k] = s } else { data[k] = "\(value)" }
    }

    // "Mark read" never opens the app: park the id for Dart to send on its
    // next start or resume (lib/core/push/pending_push_actions.dart reads the
    // same shared_preferences key).
    if action == "mark_read" {
      if let id = data["notificationId"], !id.isEmpty { AppDelegate.parkRead(id) }
      completionHandler()
      return
    }

    var item: [String: Any] = ["uid": UUID().uuidString, "actionId": action, "data": data]
    if let text = (response as? UNTextInputNotificationResponse)?.userText { item["input"] = text }
    pendingActions.append(item)
    // Running Dart takes it now; a cold start takes it with "takePending".
    let uid = item["uid"] as? String
    pushChannel?.invokeMethod("action", arguments: item) { [weak self] result in
      if result is FlutterError { return }
      if let r = result as? NSObject, r === FlutterMethodNotImplemented { return }
      self?.pendingActions.removeAll { ($0["uid"] as? String) == uid }
    }
    completionHandler()
  }

  /// The same comma list `PendingPushActions` (Dart) keeps under the
  /// shared_preferences key `fe_pending_push_reads` (stored by the plugin as
  /// `flutter.fe_pending_push_reads` in standard UserDefaults).
  static func parkRead(_ id: String) {
    let key = "flutter.fe_pending_push_reads"
    let defaults = UserDefaults.standard
    var ids = (defaults.string(forKey: key) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    if !ids.contains(id) { ids.append(id) }
    defaults.set(ids.suffix(200).joined(separator: ","), forKey: key)
  }

  private func setBadge(_ count: Int) {
    let n = max(0, count)
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    } else {
      UIApplication.shared.applicationIconBadgeNumber = n
    }
  }
}

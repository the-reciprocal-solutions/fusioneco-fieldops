import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
  }
}

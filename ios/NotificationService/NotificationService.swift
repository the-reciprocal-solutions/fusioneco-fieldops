import UserNotifications

/// Notification Service Extension (bundle id
/// `com.fusionapps.fieldops.NotificationService`): adds the photo a push
/// names (`imageUrl` in the FCM data, see the server's
/// services/push/pushPayload.ts) to an alert iOS draws itself while the app
/// is in the background or closed. The server sets `mutable-content: 1`
/// only when there is a photo.
///
/// NOT WIRED INTO THE XCODE PROJECT YET. The target, its signing and its App
/// ID must be added on a Mac with Xcode — steps in docs/push-notifications.md
/// ("Notification Service Extension"). Until then iOS shows the alert
/// without the photo (the app's own foreground banners already attach it).
///
/// Rules: never slower than the system allows (about 30 s; this gives the
/// download 8 s), never fail the alert — any problem delivers it unchanged.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?
  private var task: URLSessionDownloadTask?

  override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttempt = content

    guard let raw = content.userInfo["imageUrl"] as? String,
          let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      contentHandler(content)
      return
    }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 8
    task = URLSession(configuration: config).downloadTask(with: url) { [weak self] location, response, _ in
      guard let self = self else { return }
      defer { self.deliver() }
      guard let location = location,
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            (http.mimeType ?? "image/").hasPrefix("image/") else { return }
      // iOS only attaches a file with a known image extension.
      let ext: String
      switch http.mimeType ?? "" {
      case "image/png": ext = "png"
      case "image/gif": ext = "gif"
      case "image/heic": ext = "heic"
      default: ext = "jpg"
      }
      let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(ext)
      do {
        try FileManager.default.moveItem(at: location, to: file)
        let attachment = try UNNotificationAttachment(identifier: "photo", url: file, options: nil)
        self.bestAttempt?.attachments = [attachment]
      } catch {
        // Deliver without the photo.
      }
    }
    task?.resume()
  }

  /// The system is about to give up: deliver what there is (no photo).
  override func serviceExtensionTimeWillExpire() {
    task?.cancel()
    deliver()
  }

  private func deliver() {
    guard let handler = contentHandler, let content = bestAttempt else { return }
    contentHandler = nil
    handler(content)
  }
}

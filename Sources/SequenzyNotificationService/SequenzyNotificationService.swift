@_exported import SequenzyCore

#if canImport(UserNotifications) && !os(macOS)
    import Foundation
    import UserNotifications

    /// Notification Service Extension base class: attaches the push image and
    /// reports the notification as delivered.
    ///
    /// In your extension target:
    ///
    /// ```swift
    /// import SequenzyNotificationService
    ///
    /// class NotificationService: SequenzyNotificationServiceExtension {}
    /// ```
    ///
    /// Pushes from other senders pass through unchanged.
    open class SequenzyNotificationServiceExtension: UNNotificationServiceExtension {
        private var contentHandler: ((UNNotificationContent) -> Void)?
        private var bestAttempt: UNMutableNotificationContent?
        /// complete() runs from the download task and from the system's
        /// timeout callback; the handler must be called exactly once.
        private let lock = NSLock()

        open override func didReceive(
            _ request: UNNotificationRequest,
            withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
        ) {
            self.contentHandler = contentHandler
            let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
            bestAttempt = content

            guard let payload = PushPayload.parse(userInfo: request.content.userInfo) else {
                contentHandler(content)
                return
            }

            Task {
                async let delivered: Void = Self.reportDelivered(payload)
                if let raw = payload.imageUrl, let url = URL(string: raw),
                    let attachment = await Self.downloadAttachment(from: url)
                {
                    content.attachments = [attachment]
                }
                await delivered
                self.complete()
            }
        }

        open override func serviceExtensionTimeWillExpire() {
            complete()
        }

        private func complete() {
            lock.lock()
            let handler = contentHandler
            let content = bestAttempt
            contentHandler = nil
            lock.unlock()
            guard let handler, let content else { return }
            handler(content)
        }

        private static func reportDelivered(_ payload: PushPayload) async {
            // The click token authenticates the report, so no key or app
            // configuration is needed inside the extension.
            let body: [String: String] = [
                "pushSendId": payload.pushSendId,
                "deviceId": payload.deviceId,
                "token": payload.clickToken,
                "type": PushEventType.delivered.rawValue,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            let request = SequenzyHTTPRequest(
                url: payload.eventsUrl,
                headers: [
                    "content-type": "application/json",
                    "user-agent": "sequenzy-swift/\(sequenzySDKVersion)",
                ],
                body: data)
            _ = try? await URLSessionTransport(timeout: 10).send(request)
        }

        private static func downloadAttachment(from url: URL) async -> UNNotificationAttachment? {
            guard url.scheme == "https" else { return nil }
            return await withCheckedContinuation { continuation in
                URLSession.shared.downloadTask(with: url) { location, response, _ in
                    guard let location else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let fileExtension = Self.fileExtension(for: response?.mimeType, url: url)
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(fileExtension)
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: try UNNotificationAttachment(identifier: "image", url: destination))
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }.resume()
            }
        }

        private static func fileExtension(for mimeType: String?, url: URL) -> String {
            switch mimeType {
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/jpeg", "image/jpg": return "jpg"
            default: return url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            }
        }
    }
#endif

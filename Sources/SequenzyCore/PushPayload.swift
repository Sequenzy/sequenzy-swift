import Foundation

/// The `sequenzy` object Sequenzy adds to every push: next to `aps` on APNs,
/// flattened into string data fields on FCM.
public struct PushPayload: Equatable, Sendable {
    public let title: String
    public let body: String
    /// https link or app deep link to open on tap.
    public let url: String?
    public let imageUrl: String?
    public let pushSendId: String
    public let deviceId: String
    /// Authenticates `delivered` / `clicked` reports for this device.
    public let clickToken: String
    public let eventsUrl: URL

    public init(
        title: String, body: String, url: String?, imageUrl: String?, pushSendId: String,
        deviceId: String, clickToken: String, eventsUrl: URL
    ) {
        self.title = title
        self.body = body
        self.url = url
        self.imageUrl = imageUrl
        self.pushSendId = pushSendId
        self.deviceId = deviceId
        self.clickToken = clickToken
        self.eventsUrl = eventsUrl
    }

    /// Reads an APNs `userInfo` dictionary. Returns nil for pushes from other
    /// senders, so the host app can pass every notification through.
    public static func parse(userInfo: [AnyHashable: Any]) -> PushPayload? {
        guard let sequenzy = userInfo["sequenzy"] as? [String: Any] else { return nil }
        var strings: [String: String] = [:]
        for (key, value) in sequenzy {
            if let string = value as? String {
                strings[key] = string
            } else if let number = value as? NSNumber {
                strings[key] = number.stringValue
            }
        }
        return parse(data: strings)
    }

    /// Reads flat string fields, the shape FCM data messages use.
    public static func parse(data: [String: String]) -> PushPayload? {
        func value(_ key: String) -> String? {
            guard let raw = data[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                return nil
            }
            return raw
        }
        guard
            let pushSendId = value("pushSendId"),
            let deviceId = value("deviceId"),
            let clickToken = value("clickToken"),
            let events = value("eventsUrl"),
            let eventsUrl = URL(string: events),
            eventsUrl.scheme == "https" || eventsUrl.scheme == "http"
        else { return nil }
        return PushPayload(
            title: value("title") ?? "",
            body: value("body") ?? "",
            url: value("url"),
            imageUrl: value("imageUrl"),
            pushSendId: pushSendId,
            deviceId: deviceId,
            clickToken: clickToken,
            eventsUrl: eventsUrl
        )
    }
}

public enum PushEventType: String, Sendable { case delivered, clicked }

/// APNs hands the token over as raw bytes; Sequenzy stores the hex string.
public func apnsTokenString(_ deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
}

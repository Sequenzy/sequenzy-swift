import Foundation

/// An ActivityKit push token reported to Sequenzy.
///
/// - `pushToStart`: one per ActivityAttributes type (iOS 17.2+). Sequenzy
///   starts activities of that type remotely with it.
/// - `update`: one per running activity, tagged with the activity id your
///   backend uses to update and end it.
public struct LiveActivityToken: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pushToStart = "push_to_start"
        case update
    }

    public let kind: Kind
    /// The Swift ActivityAttributes type name, e.g. `DeliveryAttributes`.
    public let activityType: String
    /// Set for update tokens; nil for push-to-start tokens.
    public let activityId: String?
    /// Lowercase hex of the token data.
    public let token: String

    public init(kind: Kind, activityType: String, activityId: String? = nil, token: String) {
        self.kind = kind
        self.activityType = activityType
        self.activityId = kind == .update ? activityId : nil
        self.token = token.lowercased()
    }

    public init(kind: Kind, activityType: String, activityId: String? = nil, token: Data) {
        self.init(
            kind: kind, activityType: activityType, activityId: activityId,
            token: token.map { String(format: "%02x", $0) }.joined())
    }

    /// Whether Sequenzy accepts this token: hex token, Swift type name and,
    /// for update tokens, an activity id.
    public var isValid: Bool {
        guard token.count >= 64, token.count <= 200,
            token.allSatisfy({ $0.isHexDigit }),
            Self.isTypeName(activityType)
        else { return false }
        guard kind == .update else { return true }
        guard let activityId else { return false }
        return Self.isActivityId(activityId)
    }

    /// Two reports describe the same slot when a newer token replaces the
    /// older one: one push-to-start token per type, one update token per
    /// activity.
    func replaces(_ other: LiveActivityToken) -> Bool {
        guard kind == other.kind, activityType == other.activityType else { return false }
        return kind == .pushToStart || activityId == other.activityId
    }

    static func isTypeName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.count <= 128,
            first.isASCII, first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return value.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    static func isActivityId(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.count <= 128,
            first.isASCII, CharacterSet.alphanumerics.contains(first)
        else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".:-_".unicodeScalars.contains($0))
        }
    }
}

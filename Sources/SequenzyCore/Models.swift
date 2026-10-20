import Foundation

/// An item in the contact's in-app feed: a message (shown over the app) or a
/// content card (listed inside it). Mirrors `InAppMessageView` on the server.
public struct InAppMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case message, card }
    public enum Format: String, Codable, Sendable { case modal, banner, fullscreen }
    /// Banners: top or bottom. Modals: bottom (a sheet) or center.
    public enum Position: String, Codable, Sendable { case top, bottom, center }
    public enum ImagePlacement: String, Codable, Sendable { case top, background }

    public let id: String
    public let kind: Kind
    public let format: Format?
    public let position: Position?
    /// Short line above the title; empty when there is none.
    public let eyebrow: String
    public let title: String
    public let body: String
    public let imageUrl: String?
    /// Modals and full screens with an image.
    public let imagePlacement: ImagePlacement?
    public let buttons: [InAppButton]
    public let data: [String: String]
    public let style: InAppStyle
    public let pinned: Bool
    public let createdAt: String
    public let expiresAt: String?
    public let displayedAt: String?
    public let readAt: String?
    public let dismissedAt: String?

    /// Messages default to a modal; banners and modals default to the bottom.
    public var resolvedFormat: Format { format ?? .modal }
    public var resolvedPosition: Position { position ?? .bottom }
    public var isRead: Bool { readAt != nil }

    public init(
        id: String, kind: Kind, format: Format?, position: Position?, eyebrow: String = "", title: String,
        body: String, imageUrl: String?, imagePlacement: ImagePlacement? = nil, buttons: [InAppButton],
        data: [String: String], style: InAppStyle, pinned: Bool, createdAt: String, expiresAt: String?,
        displayedAt: String?, readAt: String?, dismissedAt: String?
    ) {
        self.id = id
        self.kind = kind
        self.format = format
        self.position = position
        self.eyebrow = eyebrow
        self.title = title
        self.body = body
        self.imageUrl = imageUrl
        self.imagePlacement = imagePlacement
        self.buttons = buttons
        self.data = data
        self.style = style
        self.pinned = pinned
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.displayedAt = displayedAt
        self.readAt = readAt
        self.dismissedAt = dismissedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, format, position, eyebrow, title, body, imageUrl, imagePlacement, buttons, data, style
        case pinned, createdAt, expiresAt, displayedAt, readAt, dismissedAt
    }

    /// Unknown enum values from a newer server decode as nil instead of
    /// failing the whole feed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func lenient<T: RawRepresentable>(_ key: CodingKeys) -> T? where T.RawValue == String {
            (try? container.decodeIfPresent(String.self, forKey: key)).flatMap(T.init(rawValue:))
        }
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        format = lenient(.format)
        position = lenient(.position)
        eyebrow = (try? container.decodeIfPresent(String.self, forKey: .eyebrow)) ?? ""
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        body = (try? container.decodeIfPresent(String.self, forKey: .body)) ?? ""
        imageUrl = try? container.decodeIfPresent(String.self, forKey: .imageUrl)
        imagePlacement = lenient(.imagePlacement)
        buttons = try container.decodeIfPresent([InAppButton].self, forKey: .buttons) ?? []
        data = try container.decodeIfPresent([String: String].self, forKey: .data) ?? [:]
        style = try container.decode(InAppStyle.self, forKey: .style)
        pinned = (try? container.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        createdAt = (try? container.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        expiresAt = try? container.decodeIfPresent(String.self, forKey: .expiresAt)
        displayedAt = try? container.decodeIfPresent(String.self, forKey: .displayedAt)
        readAt = try? container.decodeIfPresent(String.self, forKey: .readAt)
        dismissedAt = try? container.decodeIfPresent(String.self, forKey: .dismissedAt)
    }
}

public struct InAppButton: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case openUrl = "open_url", dismiss }

    public let label: String
    public let action: Action
    /// Null for dismiss buttons.
    public let url: String?

    public init(label: String, action: Action, url: String?) {
        self.label = label
        self.action = action
        self.url = url
    }
}

/// Resolved colors (`#rrggbb`), radii in points and the brand font stack.
public struct InAppStyle: Codable, Equatable, Sendable {
    public let backgroundColor: String
    public let textColor: String
    public let mutedTextColor: String
    public let buttonColor: String
    public let buttonTextColor: String
    public let cornerRadius: Double
    public let buttonRadius: Double
    public let fontFamily: String

    public init(
        backgroundColor: String, textColor: String, mutedTextColor: String,
        buttonColor: String, buttonTextColor: String, cornerRadius: Double,
        buttonRadius: Double, fontFamily: String
    ) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.mutedTextColor = mutedTextColor
        self.buttonColor = buttonColor
        self.buttonTextColor = buttonTextColor
        self.cornerRadius = cornerRadius
        self.buttonRadius = buttonRadius
        self.fontFamily = fontFamily
    }

    /// Font families from the CSS stack, without quotes or generic names.
    public var fontFamilies: [String] {
        let generic: Set<String> = ["serif", "sans-serif", "monospace", "system-ui", "cursive"]
        return fontFamily.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty && !generic.contains($0.lowercased()) }
    }
}

public enum InAppEventType: String, Codable, Sendable {
    case displayed, clicked, dismissed, read
}

/// Parses a `#rrggbb` color into 0...1 components, or nil.
public func parseHexColor(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
    var value = hex.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
    return (
        Double((number >> 16) & 0xFF) / 255,
        Double((number >> 8) & 0xFF) / 255,
        Double(number & 0xFF) / 255
    )
}

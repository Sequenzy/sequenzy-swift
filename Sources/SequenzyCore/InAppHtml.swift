import Foundation

/// A call from a custom HTML in-app message to the app, sent by the Sequenzy
/// JS bridge the server injects into every document (`window.sequenzy`, plus
/// Braze's `brazeBridge` / `appboyBridge` for documents written for Braze).
/// Wire shape (protocol v1): `{ "__sequenzyInApp": 1, "method": ..., "args": {...} }`.
public enum InAppHtmlBridgeMessage: Equatable, Sendable {
    /// Close the message (reported as dismissed).
    case close
    /// Open a link through the app (reported as a click), then close.
    case openUrl(url: String, external: Bool, buttonId: String?)
    /// Report a click without closing (Braze `logClick`).
    case logClick(buttonId: String?)
    /// A custom event on the contact (`Sequenzy.track`).
    case track(name: String, properties: [String: JSONValue])
    /// Custom attributes on the contact (`Sequenzy.setProfile`).
    case setAttributes([String: JSONValue])
    /// The contact's name (`Sequenzy.setProfile`).
    case setName(firstName: String?, lastName: String?)

    /// Messages larger than this are dropped, as the bridge itself does.
    public static let maxMessageBytes = 32 * 1024
    /// Bridge calls honored per display; the rest are dropped.
    public static let maxCallsPerDisplay = 50

    /// Parses one bridge message; nil for anything malformed or unknown.
    public static func parse(json data: Data) -> InAppHtmlBridgeMessage? {
        guard data.count <= maxMessageBytes,
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return parse(value)
    }

    /// Parses a message already decoded (e.g. a WKScriptMessage body).
    public static func parse(_ value: JSONValue) -> InAppHtmlBridgeMessage? {
        guard case .object(let object) = value, object["__sequenzyInApp"] == .number(1),
            case .string(let method)? = object["method"]
        else { return nil }
        var args: [String: JSONValue] = [:]
        if case .object(let raw)? = object["args"] { args = raw }
        func string(_ key: String, max: Int = 255) -> String? {
            guard case .string(let text)? = args[key], !text.isEmpty else { return nil }
            return String(text.prefix(max))
        }
        func buttonId() -> String? {
            guard let id = string("buttonId"), isValidButtonId(id) else { return nil }
            return id
        }
        switch method {
        case "close":
            return .close
        case "openUrl":
            guard let url = string("url", max: 2048) else { return nil }
            return .openUrl(url: url, external: args["external"] == .bool(true), buttonId: buttonId())
        case "logClick":
            return .logClick(buttonId: buttonId())
        case "track":
            guard let name = string("name") else { return nil }
            var properties: [String: JSONValue] = [:]
            if case .object(let raw)? = args["properties"] { properties = raw }
            return .track(name: name, properties: properties)
        case "setAttributes":
            guard case .object(let attributes)? = args["attributes"] else { return nil }
            return .setAttributes(attributes)
        case "setName":
            let first = string("firstName")
            let last = string("lastName")
            guard first != nil || last != nil else { return nil }
            return .setName(firstName: first, lastName: last)
        default:
            return nil
        }
    }

    /// Braze's logClick id rule: 1-255 letters, numbers, spaces, dashes or
    /// underscores.
    public static func isValidButtonId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 255 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122) || scalar == " " || scalar == "-" || scalar == "_"
        }
    }

    /// Links a message may open: https, or an app scheme (myapp://, mailto:,
    /// tel:). Never script, data, file or plain-http URLs.
    public static func isAllowedUrl(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        let scheme = raw[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first),
            scheme.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "." || $0 == "-"
            })
        else { return false }
        if scheme == "https" { return true }
        return !["http", "javascript", "data", "vbscript", "file", "blob", "about", "filesystem"].contains(scheme)
    }
}

/// Where custom HTML documents load: a fixed https origin Sequenzy owns, so
/// the document has a real origin (local storage works for survey scripts)
/// that is never the app's own web content.
public let sequenzyInAppHtmlBaseURL = URL(string: "https://in-app.sequenzy.com/")!

import Foundation

public let sequenzySDKVersion = "0.1.0"

public struct SequenzyConfiguration: Sendable {
    public static let defaultAPIBaseURL = URL(string: "https://api.sequenzy.com")!

    /// Publishable key (`seq_pk_...`) restricted to this app's ID.
    public let publicKey: String
    public let companyId: String
    /// Bundle ID or package name, sent as `x-sequenzy-app-id`.
    public let appId: String
    public let apiBaseURL: URL
    /// `ios` or `android`; the push platform tokens are registered for.
    public let platform: String
    /// Identifies the SDK in the User-Agent header, e.g. `sequenzy-swift/0.1.0`.
    public let userAgent: String

    public init(
        publicKey: String,
        companyId: String,
        appId: String,
        apiBaseURL: URL = SequenzyConfiguration.defaultAPIBaseURL,
        platform: String = "ios",
        userAgent: String = "sequenzy-swift/\(sequenzySDKVersion)"
    ) {
        self.publicKey = publicKey
        self.companyId = companyId
        self.appId = appId
        self.apiBaseURL = apiBaseURL
        self.platform = platform
        self.userAgent = userAgent
    }
}

/// Optional device details sent with push registration.
public struct DeviceInfo: Sendable, Equatable {
    public var appVersion: String?
    public var osVersion: String?
    public var deviceName: String?
    public var locale: String?
    public var timezone: String?

    public init(
        appVersion: String? = nil, osVersion: String? = nil, deviceName: String? = nil,
        locale: String? = Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
        timezone: String? = TimeZone.current.identifier
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceName = deviceName
        self.locale = locale
        self.timezone = timezone
    }
}

/// Asks the host app's backend for a fresh identity token for `email`.
public typealias IdentityTokenProvider = @Sendable (_ email: String) async throws -> String

public enum SequenzyLogLevel: Int, Comparable, Sendable {
    case none = 0, error, info, debug
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public typealias SequenzyLogHandler = @Sendable (SequenzyLogLevel, String) -> Void

public enum SequenzyError: Error, Equatable {
    case notIdentified
    case identityRejected
    case http(status: Int, message: String?)
}

struct QueuedEvent: Codable, Equatable, Sendable {
    let name: String
    let eventId: String
    let properties: [String: JSONValue]
    let occurredAt: String
    /// `screen` or `commerce`; nil for custom events.
    var type: String? = nil

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "eventId": .string(eventId),
            "properties": .object(properties),
            "occurredAt": .string(occurredAt),
        ]
        if let type { object["type"] = .string(type) }
        return .object(object)
    }
}

/// The platform-independent SDK engine. One instance per app; the UIKit
/// `Sequenzy` facade owns it. Every method is safe to call from any task.
public actor SequenzyClient {
    public static let maxQueuedEvents = 100
    public static let maxBatchSize = 20
    public static let maxEventAge: TimeInterval = 24 * 60 * 60
    public static let pushRefreshInterval: TimeInterval = 24 * 60 * 60
    static let maxBackoff: TimeInterval = 300
    /** Server limit for one event's properties, serialized. */
    public static let maxPropertiesBytes = 8 * 1024
    static let providerRetryInterval: TimeInterval = 60
    static let providerTimeout: TimeInterval = 20

    private enum Key {
        static let anonymousId = "anonymousId"
        static let email = "email"
        static let identityToken = "identityToken"
        static let events = "events"
        static let pushToken = "pushToken"
        static let pushRegistration = "pushRegistration"
        static let profile = "profile"
    }

    private struct PushRegistration: Codable {
        let token: String
        let email: String
        let registeredAt: Date
    }

    public let configuration: SequenzyConfiguration
    private let transport: SequenzyTransport
    private let store: SequenzyStore
    private var device: DeviceInfo
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var identityTokenProvider: IdentityTokenProvider?
    private var logLevel: SequenzyLogLevel
    private var logHandler: SequenzyLogHandler

    private var events: [QueuedEvent]
    private var isFlushing = false
    private var backoff: TimeInterval = 0
    private var nextAttemptAt: Date?
    private var retryTask: Task<Void, Never>?
    /// Set when the stored token was rejected and no provider could replace
    /// it; cleared by the next `identify`.
    private var identityBlocked = false
    /// After a failed provider call, don't ask again before this time.
    private var providerRetryAt: Date?

    public init(
        configuration: SequenzyConfiguration,
        transport: SequenzyTransport = URLSessionTransport(),
        store: SequenzyStore = UserDefaultsStore(),
        device: DeviceInfo = DeviceInfo(),
        identityTokenProvider: IdentityTokenProvider? = nil,
        logLevel: SequenzyLogLevel = .error,
        logHandler: SequenzyLogHandler? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.device = device
        self.identityTokenProvider = identityTokenProvider
        self.logLevel = logLevel
        self.logHandler = logHandler ?? { level, message in print("[Sequenzy] \(level): \(message)") }
        self.now = now
        self.sleep = sleep
        if let raw = store.string(forKey: Key.events), let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([QueuedEvent].self, from: data)
        {
            events = decoded
        } else {
            events = []
        }
    }

    // MARK: - Settings

    public func setIdentityTokenProvider(_ provider: IdentityTokenProvider?) {
        identityTokenProvider = provider
    }

    public func setLogLevel(_ level: SequenzyLogLevel) {
        logLevel = level
    }

    public func setDeviceInfo(_ info: DeviceInfo) {
        device = info
    }

    // MARK: - Identity

    /// Stable per installation until `reset()`.
    public var anonymousId: String {
        if let existing = store.string(forKey: Key.anonymousId), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        store.set(created, forKey: Key.anonymousId)
        return created
    }

    public var email: String? { store.string(forKey: Key.email) }

    public var queuedEventCount: Int { events.count }

    /// Links this installation to a contact. Pass the identity token your
    /// backend minted, or rely on the identity token provider.
    public func identify(email rawEmail: String, identityToken: String? = nil) async {
        let normalized = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), !normalized.contains(" ") else {
            log(.error, "identify was called with an invalid email address")
            return
        }
        let previous = email
        if previous != normalized {
            if previous != nil {
                // Events queued for the previous user must not be sent as
                // the new one. Anonymous events carry over to the first
                // identified user, which is the point of queueing them.
                events.removeAll()
                persistEvents()
                store.set(nil, forKey: Key.profile)
            }
            store.set(normalized, forKey: Key.email)
            store.set(nil, forKey: Key.identityToken)
        }
        if let identityToken, !identityToken.isEmpty {
            store.set(identityToken, forKey: Key.identityToken)
        }
        identityBlocked = false
        providerRetryAt = nil
        await registerPushIfNeeded(force: previous != normalized)
        await flush()
    }

    /// Forgets the user: unregisters the push token, clears identity, queued
    /// events and the anonymous id.
    public func reset() async {
        // Clear everything before the first await: the actor is reentrant, so
        // an identify() that runs while the remove request is in flight must
        // find the reset already done, not have its new state wiped after.
        let token = store.string(forKey: Key.pushToken)
        store.set(nil, forKey: Key.email)
        store.set(nil, forKey: Key.identityToken)
        store.set(nil, forKey: Key.pushRegistration)
        store.set(UUID().uuidString.lowercased(), forKey: Key.anonymousId)
        store.set(nil, forKey: Key.profile)
        events.removeAll()
        persistEvents()
        retryTask?.cancel()
        retryTask = nil
        backoff = 0
        nextAttemptAt = nil
        identityBlocked = false
        providerRetryAt = nil

        guard let token else { return }
        let body: JSONValue = [
            "companyId": .string(configuration.companyId),
            "publicKey": .string(configuration.publicKey),
            "platform": .string(configuration.platform),
            "token": .string(token),
        ]
        do {
            let response = try await post(path: "/api/v1/push/app-devices/remove", body: body)
            if !(200..<300).contains(response.status) {
                log(.error, "Could not unregister the push token (HTTP \(response.status))")
            }
        } catch {
            log(.error, "Could not unregister the push token: \(error)")
        }
        // Someone signed in while the remove was in flight; their registration
        // may have reached the server first, so register the device again.
        if email != nil {
            await registerPushIfNeeded(force: true)
        }
    }

    // MARK: - Events

    /// Queues a custom event. It is sent once the user is identified; events
    /// older than 24 hours are dropped.
    public func track(_ name: String, properties: [String: JSONValue] = [:]) async {
        await enqueue(type: nil, name: name, properties: properties)
    }

    /// Records that the user opened a screen, as the built-in "Screen Viewed"
    /// event that segments and sequences can use.
    public func screen(_ name: String, properties: [String: JSONValue] = [:]) async {
        var properties = properties
        properties["screen"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        await enqueue(type: "screen", name: "screen", properties: properties)
    }

    /// Browse abandonment and product interest, like the web SDK.
    public func viewedProduct(_ product: CommerceProduct) async {
        await enqueue(type: "commerce", name: "product_viewed", properties: ["product": .object(product.json)])
    }

    public func addedToCart(_ line: CommerceCartLine) async {
        await enqueue(
            type: "commerce", name: "product_added_to_cart",
            properties: ["product": .object(line.json), "cartLine": .object(line.json)])
    }

    public func removedFromCart(_ line: CommerceCartLine) async {
        await enqueue(
            type: "commerce", name: "product_removed_from_cart",
            properties: ["product": .object(line.json), "cartLine": .object(line.json)])
    }

    /// The whole cart, for cart abandonment.
    public func viewedCart(_ cart: CommerceCart) async {
        await enqueue(type: "commerce", name: "cart_viewed", properties: ["cart": .object(cart.json)])
    }

    public func viewedCollection(_ collection: CommerceCollection) async {
        await enqueue(type: "commerce", name: "collection_viewed", properties: ["collection": .object(collection.json)])
    }

    public func searched(_ query: String) async {
        await enqueue(
            type: "commerce", name: "search_submitted",
            properties: ["searchQuery": .string(query.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    private func enqueue(type: String?, name: String, properties: [String: JSONValue]) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "screen", properties["screen"] == .string("") || properties["screen"] == nil {
            log(.error, "screen was called without a screen name")
            return
        }
        guard !trimmed.isEmpty else {
            log(.error, "track was called without an event name")
            return
        }
        // An event that cannot be sent must be dropped now: queued, it would
        // fail every batch it is in (NaN does not encode; over 8 KB is a 413).
        guard let encoded = try? encode(.object(properties)) else {
            log(.error, "Dropped \"\(trimmed)\": properties contain a value that is not valid JSON, such as NaN")
            return
        }
        guard encoded.count <= Self.maxPropertiesBytes else {
            log(.error, "Dropped \"\(trimmed)\": properties are larger than 8 KB")
            return
        }
        events.append(
            QueuedEvent(
                name: trimmed,
                eventId: UUID().uuidString.lowercased(),
                properties: properties,
                occurredAt: iso8601(now()),
                type: type
            ))
        if events.count > Self.maxQueuedEvents {
            events.removeFirst(events.count - Self.maxQueuedEvents)
        }
        persistEvents()
        await flush()
    }

    /// Sends queued events now. Called after `track`, `identify` and when the
    /// app comes to the foreground.
    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        // A profile change made while this flush awaits the network (the
        // actor is reentrant) lands in the store; loop until none is left.
        repeat {
            while let profile = pendingProfile {
                guard email != nil, !identityBlocked else { return }
                if let nextAttemptAt, nextAttemptAt > now() { return }
                let sent = store.string(forKey: Key.profile)
                switch await sendProfile(profile) {
                case .retryLater:
                    scheduleRetry()
                    return
                case .stop:
                    return
                case .delivered, .dropped:
                    backoff = 0
                    nextAttemptAt = nil
                    // Only clear what was sent: a newer merge stays pending.
                    if store.string(forKey: Key.profile) == sent {
                        store.set(nil, forKey: Key.profile)
                    }
                }
            }
            dropStaleEvents()
            while !events.isEmpty {
                guard email != nil, !identityBlocked else { return }
                if let nextAttemptAt, nextAttemptAt > now() { return }

                let batch = Array(events.prefix(Self.maxBatchSize))
                let outcome = await sendBatch(batch)
                switch outcome {
                case .delivered:
                    backoff = 0
                    nextAttemptAt = nil
                    remove(batch)
                case .dropped:
                    remove(batch)
                case .retryLater:
                    scheduleRetry()
                    return
                case .stop:
                    return
                }
            }
        } while pendingProfile != nil
    }

    private enum BatchOutcome { case delivered, dropped, retryLater, stop }

    private func sendBatch(_ batch: [QueuedEvent]) async -> BatchOutcome {
        let result = await withIdentity { email, token in
            let body: JSONValue = [
                "companyId": .string(self.configuration.companyId),
                "publicKey": .string(self.configuration.publicKey),
                "email": .string(email),
                "identityToken": .string(token),
                "events": .array(batch.map(\.json)),
            ]
            return try await self.post(path: "/api/v1/app-events", body: body)
        }
        switch result {
        case .notIdentified, .identityRejected, .userChanged:
            return .stop
        case .failed(let error):
            log(.info, "Event delivery failed, will retry: \(error)")
            return .retryLater
        case .response(let response):
            if (200..<300).contains(response.status) {
                logRejectedEvents(response.body)
                return .delivered
            }
            if Self.isRetryable(response.status) {
                log(.info, "Event delivery got HTTP \(response.status), will retry")
                return .retryLater
            }
            log(.error, "Dropping \(batch.count) events: HTTP \(response.status) \(errorMessage(response.body) ?? "")")
            return .dropped
        }
    }

    // MARK: - Profile and signup

    private var pendingProfile: [String: JSONValue]? {
        guard let raw = store.string(forKey: Key.profile), let data = raw.data(using: .utf8),
            case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return object
    }

    /// Sets the signed-in contact's name and custom attributes. Changes are
    /// kept on the device and sent once identified, like events; later calls
    /// merge into a pending update.
    public func setProfile(_ update: ProfileUpdate) async {
        let incoming = update.json
        if case .object(let attributes)? = incoming["attributes"],
            let encoded = try? encode(.object(attributes)), encoded.count > Self.maxPropertiesBytes
        {
            log(.error, "setProfile attributes are larger than 8 KB")
            return
        }
        var merged = pendingProfile ?? [:]
        let previousAttributes: [String: JSONValue]
        if case .object(let object)? = merged["attributes"] { previousAttributes = object } else { previousAttributes = [:] }
        for (key, value) in incoming { merged[key] = value }
        if case .object(let attributes)? = incoming["attributes"] {
            merged["attributes"] = .object(previousAttributes.merging(attributes) { _, new in new })
        }
        guard let data = try? encode(.object(merged)) else {
            log(.error, "setProfile was called with values that are not JSON, such as NaN")
            return
        }
        store.set(String(data: data, encoding: .utf8), forKey: Key.profile)
        await flush()
    }

    private func sendProfile(_ profile: [String: JSONValue]) async -> BatchOutcome {
        let result = await withIdentity { email, token in
            var body = profile
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body["email"] = .string(email)
            body["identityToken"] = .string(token)
            return try await self.post(path: "/api/v1/app-attributes", body: .object(body))
        }
        switch result {
        case .notIdentified, .identityRejected, .userChanged:
            return .stop
        case .failed:
            return .retryLater
        case .response(let response):
            if (200..<300).contains(response.status) { return .delivered }
            if Self.isRetryable(response.status) { return .retryLater }
            log(.error, "Profile update rejected: HTTP \(response.status) \(errorMessage(response.body) ?? "")")
            return .dropped
        }
    }

    /// Subscribes an email through a published form, for people who are not
    /// signed in (newsletter or waitlist screens). Does not identify the device.
    public func subscribe(_ request: SubscribeRequest) async -> SubscribeResult {
        let email = request.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !email.contains(where: { $0.isWhitespace }) else {
            return .failure(error: "Enter a valid email address", retryable: false)
        }
        var body: [String: JSONValue] = [
            "companyId": .string(configuration.companyId),
            "publicKey": .string(configuration.publicKey),
            "formId": .string(request.formId),
            "email": .string(email),
        ]
        if let firstName = request.firstName { body["firstName"] = .string(firstName) }
        if let lastName = request.lastName { body["lastName"] = .string(lastName) }
        if let phone = request.phone { body["phone"] = .string(phone) }
        if let attributes = request.attributes { body["attributes"] = .object(attributes) }
        do {
            let response = try await post(path: "/api/v1/app-subscribe", body: .object(body))
            if (200..<300).contains(response.status) { return .success }
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            let message = object?["message"] as? String ?? object?["error"] as? String ?? "HTTP \(response.status)"
            return .failure(error: message, retryable: Self.isRetryable(response.status))
        } catch {
            return .failure(error: "\(error)", retryable: true)
        }
    }

    private func logRejectedEvents(_ body: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let rejected = object["rejected"] as? [[String: Any]], !rejected.isEmpty
        else { return }
        for entry in rejected {
            log(.error, "Event rejected: \(entry["error"] as? String ?? "unknown error")")
        }
    }

    static func isRetryable(_ status: Int) -> Bool {
        status == 0 || status == 408 || status == 425 || status == 429 || status >= 500
    }

    private func remove(_ batch: [QueuedEvent]) {
        let ids = Set(batch.map(\.eventId))
        events.removeAll { ids.contains($0.eventId) }
        persistEvents()
    }

    private func dropStaleEvents() {
        let cutoff = now().addingTimeInterval(-Self.maxEventAge)
        let before = events.count
        events.removeAll { event in
            guard let date = parseISO8601(event.occurredAt) else { return true }
            return date < cutoff
        }
        if events.count != before {
            log(.info, "Dropped \(before - events.count) events older than 24 hours")
            persistEvents()
        }
    }

    private func scheduleRetry() {
        backoff = min(max(1, backoff * 2), Self.maxBackoff)
        let delay = backoff
        nextAttemptAt = now().addingTimeInterval(delay)
        retryTask?.cancel()
        retryTask = Task { [sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self.retryFlush()
        }
    }

    private func retryFlush() async {
        nextAttemptAt = nil
        await flush()
    }

    private func persistEvents() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        store.set(String(data: data, encoding: .utf8), forKey: Key.events)
    }

    // MARK: - Push

    /// Stores the APNs or FCM token and registers it with Sequenzy.
    public func setPushToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let changed = store.string(forKey: Key.pushToken) != trimmed
        store.set(trimmed, forKey: Key.pushToken)
        await registerPushIfNeeded(force: changed)
    }

    public var pushToken: String? { store.string(forKey: Key.pushToken) }

    /// Registers the stored token when it, or the identified user, changed,
    /// or the last registration is more than a day old.
    public func registerPushIfNeeded(force: Bool = false) async {
        guard let token = store.string(forKey: Key.pushToken) else { return }
        let identity = email ?? ""
        if !force, let raw = store.string(forKey: Key.pushRegistration),
            let data = raw.data(using: .utf8),
            let last = try? JSONDecoder().decode(PushRegistration.self, from: data),
            last.token == token, last.email == identity,
            now().timeIntervalSince(last.registeredAt) < Self.pushRefreshInterval
        {
            return
        }

        var base: [String: JSONValue] = [
            "companyId": .string(configuration.companyId),
            "publicKey": .string(configuration.publicKey),
            "platform": .string(configuration.platform),
            "token": .string(token),
            "anonymousId": .string(anonymousId),
        ]
        for (key, value) in [
            ("appVersion", device.appVersion), ("osVersion", device.osVersion),
            ("deviceName", device.deviceName), ("locale", device.locale),
            ("timezone", device.timezone),
        ] {
            if let value, !value.isEmpty { base[key] = .string(value) }
        }

        let anonymousBody = base
        let response: SequenzyHTTPResponse
        if email != nil {
            let result = await withIdentity { email, identityToken in
                var body = anonymousBody
                body["email"] = .string(email)
                body["identityToken"] = .string(identityToken)
                return try await self.post(path: "/api/v1/push/app-devices", body: .object(body))
            }
            switch result {
            case .response(let identified):
                response = identified
            case .userChanged:
                // The new user's identify registers the device for them.
                return
            case .notIdentified, .identityRejected:
                // Keep the device reachable for anonymous sends; it links on
                // the next identify with a valid token.
                guard let anonymous = await postIgnoringErrors("/api/v1/push/app-devices", .object(anonymousBody)) else { return }
                response = anonymous
            case .failed(let error):
                log(.info, "Push registration failed: \(error)")
                return
            }
        } else {
            guard let anonymous = await postIgnoringErrors("/api/v1/push/app-devices", .object(anonymousBody)) else { return }
            response = anonymous
        }

        guard (200..<300).contains(response.status) else {
            log(.error, "Push registration failed: HTTP \(response.status) \(errorMessage(response.body) ?? "")")
            return
        }
        let identified = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["identified"] as? Bool ?? false
        let registration = PushRegistration(
            token: token, email: identified ? identity : "", registeredAt: now())
        if let data = try? JSONEncoder().encode(registration) {
            store.set(String(data: data, encoding: .utf8), forKey: Key.pushRegistration)
        }
        if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            object["pushConfigured"] as? Bool == false
        {
            log(.info, "Device registered, but \(configuration.platform) push credentials are not set up in Sequenzy yet")
        }
    }

    /// Reports a push as delivered or clicked to the payload's events URL.
    /// The click token in the payload authenticates the report.
    public func reportPush(_ type: PushEventType, payload: PushPayload) async {
        let body: JSONValue = [
            "pushSendId": .string(payload.pushSendId),
            "deviceId": .string(payload.deviceId),
            "token": .string(payload.clickToken),
            "type": .string(type.rawValue),
        ]
        do {
            let request = SequenzyHTTPRequest(
                url: payload.eventsUrl,
                headers: ["content-type": "application/json", "user-agent": configuration.userAgent],
                body: try encode(body))
            let response = try await transport.send(request)
            if !(200..<300).contains(response.status) {
                log(.error, "Push \(type.rawValue) report failed: HTTP \(response.status)")
            }
        } catch {
            log(.error, "Push \(type.rawValue) report failed: \(error)")
        }
    }

    // MARK: - In-app

    /// Open messages or cards for the identified contact, in server order.
    public func fetchFeed(kind: InAppMessage.Kind? = nil, limit: Int? = nil) async throws -> [InAppMessage] {
        let result = await withIdentity { email, token in
            var body: [String: JSONValue] = [
                "companyId": .string(self.configuration.companyId),
                "publicKey": .string(self.configuration.publicKey),
                "email": .string(email),
                "identityToken": .string(token),
            ]
            if let kind { body["kind"] = .string(kind.rawValue) }
            if let limit { body["limit"] = .number(Double(limit)) }
            return try await self.post(path: "/api/v1/in-app/feed", body: .object(body))
        }
        switch result {
        case .notIdentified, .userChanged: throw SequenzyError.notIdentified
        case .identityRejected: throw SequenzyError.identityRejected
        case .failed(let error): throw error
        case .response(let response):
            guard (200..<300).contains(response.status) else {
                throw SequenzyError.http(status: response.status, message: errorMessage(response.body))
            }
            struct Feed: Decodable { let messages: [InAppMessage] }
            return try JSONDecoder().decode(Feed.self, from: response.body).messages
        }
    }

    /// Reports `displayed`, `clicked`, `dismissed` or `read` for a feed item.
    @discardableResult
    public func report(_ type: InAppEventType, messageId: String) async -> Bool {
        let result = await withIdentity { email, token in
            let body: JSONValue = [
                "companyId": .string(self.configuration.companyId),
                "publicKey": .string(self.configuration.publicKey),
                "email": .string(email),
                "identityToken": .string(token),
                "messageId": .string(messageId),
                "type": .string(type.rawValue),
            ]
            return try await self.post(path: "/api/v1/in-app/feed/events", body: body)
        }
        if case .response(let response) = result, (200..<300).contains(response.status) {
            return true
        }
        log(.error, "Could not report in-app \(type.rawValue) for \(messageId)")
        return false
    }

    // MARK: - Identity tokens

    private enum IdentifiedResult {
        case response(SequenzyHTTPResponse)
        case notIdentified
        /// The user changed while the request was in flight.
        case userChanged
        case identityRejected
        case failed(Error)
    }

    /// Runs `operation` with the stored email and identity token, fetching a
    /// token from the provider when none is stored, and once more when the
    /// server rejects the stored one.
    private func withIdentity(
        _ operation: @Sendable (String, String) async throws -> SequenzyHTTPResponse
    ) async -> IdentifiedResult {
        guard let email, !identityBlocked else { return .notIdentified }
        var usedProvider = false
        var token = store.string(forKey: Key.identityToken)
        if token == nil {
            token = await tokenFromProvider(email: email)
            usedProvider = true
        }
        guard var current = token else {
            log(.info, "No identity token yet; call identify(email:identityToken:) or set an identity token provider")
            return .notIdentified
        }

        while true {
            let response: SequenzyHTTPResponse
            do {
                response = try await operation(email, current)
            } catch {
                return .failed(error)
            }
            guard isIdentityRejection(response) else { return .response(response) }
            // The user changed while this request was in flight: its rejection
            // is about the previous user and must not touch the new one.
            guard self.email == email else { return .userChanged }

            store.set(nil, forKey: Key.identityToken)
            if !usedProvider, let fresh = await tokenFromProvider(email: email) {
                usedProvider = true
                current = fresh
                continue
            }
            identityBlocked = true
            log(.error, "The identity token was rejected; call identify(email:identityToken:) with a fresh token")
            return .identityRejected
        }
    }

    private func tokenFromProvider(email: String) async -> String? {
        guard let identityTokenProvider else { return nil }
        if let providerRetryAt, providerRetryAt > now() { return nil }
        do {
            // Calls run in order, so a provider that never returns would stall
            // every later call without the timeout.
            let token = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await identityTokenProvider(email) }
                group.addTask { [sleep] in
                    await sleep(Self.providerTimeout)
                    throw SequenzyError.http(status: 0, message: "The identity token provider timed out")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
            guard !token.isEmpty, self.email == email else { return nil }
            store.set(token, forKey: Key.identityToken)
            return token
        } catch {
            providerRetryAt = now().addingTimeInterval(Self.providerRetryInterval)
            log(.error, "The identity token provider failed: \(error); retrying in a minute")
            return nil
        }
    }

    private func isIdentityRejection(_ response: SequenzyHTTPResponse) -> Bool {
        guard response.status == 401 || response.status == 403,
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { return false }
        return object["code"] as? String == "invalid_web_tracking_identity"
    }

    // MARK: - HTTP

    private func post(path: String, body: JSONValue) async throws -> SequenzyHTTPResponse {
        let request = SequenzyHTTPRequest(
            url: configuration.apiBaseURL.appendingPathComponent(String(path.dropFirst())),
            headers: [
                "content-type": "application/json",
                "x-sequenzy-key": configuration.publicKey,
                "x-sequenzy-app-id": configuration.appId,
                "user-agent": configuration.userAgent,
            ],
            body: try encode(body))
        return try await transport.send(request)
    }

    private func postIgnoringErrors(_ path: String, _ body: JSONValue) async -> SequenzyHTTPResponse? {
        do {
            return try await post(path: path, body: body)
        } catch {
            log(.info, "Request to \(path) failed: \(error)")
            return nil
        }
    }

    private func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func errorMessage(_ body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }

    private func log(_ level: SequenzyLogLevel, _ message: String) {
        guard level != .none, level <= logLevel else { return }
        logHandler(level, message)
    }
}

private func makeISO8601Formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

func iso8601(_ date: Date) -> String {
    makeISO8601Formatter().string(from: date)
}

func parseISO8601(_ value: String) -> Date? {
    if let date = makeISO8601Formatter().date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}

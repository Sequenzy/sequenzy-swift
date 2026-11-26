import Foundation

public let sequenzySDKVersion = "0.1.4"

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

/// Asks the host app's backend for a fresh identity token for a user
/// identified with `identifyUser`: mint it for `externalId`, plus `email`
/// when it is set.
public typealias UserIdentityTokenProvider = @Sendable (_ externalId: String, _ email: String?) async throws -> String

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
    /// `screen`, `commerce` or `geofence`; nil for custom events.
    var type: String? = nil
    /// `enter` or `exit`, for geofence events.
    var transition: String? = nil
    var geofenceId: String? = nil

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "eventId": .string(eventId),
            "properties": .object(properties),
            "occurredAt": .string(occurredAt),
        ]
        if let type { object["type"] = .string(type) }
        if let transition { object["transition"] = .string(transition) }
        if let geofenceId { object["geofenceId"] = .string(geofenceId) }
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
    /// Server limit for an external ID (the contact's `externalId`).
    public static let maxExternalIdLength = 255

    private enum Key {
        static let anonymousId = "anonymousId"
        static let email = "email"
        static let externalId = "externalId"
        static let identityToken = "identityToken"
        static let events = "events"
        static let pushToken = "pushToken"
        static let pushRegistration = "pushRegistration"
        static let profile = "profile"
        static let liveActivityTokens = "liveActivityTokens"
    }

    private struct PushRegistration: Codable {
        let token: String
        /// The contact key (see `contactKey`) the device was linked to.
        let email: String
        let registeredAt: Date
        /// Permission sent with this registration; nil when unknown.
        var permission: PushPermissionStatus?
    }

    public let configuration: SequenzyConfiguration
    private let transport: SequenzyTransport
    private let store: SequenzyStore
    private var device: DeviceInfo
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var identityTokenProvider: IdentityTokenProvider?
    private var userIdentityTokenProvider: UserIdentityTokenProvider?
    /// Reads the OS notification permission, sent with every registration.
    private var pushPermissionReader: (@Sendable () async -> PushPermissionStatus?)?
    /// True when the app can ask for permission, so the feed includes push primers.
    private var handlesPushPermission = false
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
        userIdentityTokenProvider: UserIdentityTokenProvider? = nil,
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
        self.userIdentityTokenProvider = userIdentityTokenProvider
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
        if provider != nil {
            identityBlocked = false
            providerRetryAt = nil
        }
    }

    /// Fresh tokens for users identified with `identifyUser`.
    public func setUserIdentityTokenProvider(_ provider: UserIdentityTokenProvider?) {
        userIdentityTokenProvider = provider
        if provider != nil {
            identityBlocked = false
            providerRetryAt = nil
        }
    }

    public func setLogLevel(_ level: SequenzyLogLevel) {
        logLevel = level
    }

    public func setDeviceInfo(_ info: DeviceInfo) {
        device = info
    }

    /// Lets the client read notification permission (sent with registrations)
    /// and receive push primers, which ask for it. The UIKit layer sets this.
    public func setPushPermissionReader(_ reader: (@Sendable () async -> PushPermissionStatus?)?) {
        pushPermissionReader = reader
        handlesPushPermission = reader != nil
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

    /// The user ID passed to `identifyUser`, or nil.
    public var externalId: String? { store.string(forKey: Key.externalId) }

    /// One string per signed-in contact: the external ID when the app
    /// identified the user by it, otherwise the email; nil while anonymous.
    /// Compare it to notice that another user signed in. The space keeps an
    /// external ID from ever equalling an email.
    public var contactKey: String? { Self.contactKey(email: email, externalId: externalId) }

    private static func contactKey(email: String?, externalId: String?) -> String? {
        externalId.map { "external \($0)" } ?? email
    }

    /// The identifiers every identified request carries.
    private var identityFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let email { fields["email"] = .string(email) }
        if let externalId { fields["externalId"] = .string(externalId) }
        return fields
    }

    public var queuedEventCount: Int { events.count }

    /// Links this installation to the contact with this email. Pass the
    /// identity token your backend minted, or rely on the identity token
    /// provider.
    public func identify(email rawEmail: String, identityToken: String? = nil) async {
        let normalized = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), !normalized.contains(" ") else {
            log(.error, "identify was called with an invalid email address")
            return
        }
        await identify(email: normalized, externalId: nil, identityToken: identityToken)
    }

    /// Links this installation to the contact with your own user ID, for
    /// users without an email (Sign in with Apple with a hidden address,
    /// phone login). Pass `email` too when you have it. The identity token
    /// must be minted for exactly these identifiers; without one, the user
    /// identity token provider is asked.
    public func identifyUser(_ rawExternalId: String, email rawEmail: String? = nil, identityToken: String? = nil) async {
        let externalId = rawExternalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !externalId.isEmpty, externalId.count <= Self.maxExternalIdLength else {
            log(.error, "identifyUser needs a user ID of 1 to \(Self.maxExternalIdLength) characters")
            return
        }
        var normalizedEmail: String?
        if let rawEmail, !rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.contains("@"), !normalized.contains(" ") else {
                log(.error, "identifyUser was called with an invalid email address")
                return
            }
            normalizedEmail = normalized
        }
        await identify(email: normalizedEmail, externalId: externalId, identityToken: identityToken)
    }

    private func identify(email nextEmail: String?, externalId nextExternalId: String?, identityToken: String?) async {
        let previous = contactKey
        let nextKey = Self.contactKey(email: nextEmail, externalId: nextExternalId)
        let contactChanged = previous != nextKey
        let identifiersChanged = email != nextEmail || externalId != nextExternalId
        if previous != nil, contactChanged {
            // Events queued for the previous user must not be sent as
            // the new one. Anonymous events carry over to the first
            // identified user, which is the point of queueing them.
            events.removeAll()
            persistEvents()
            store.set(nil, forKey: Key.profile)
        }
        if identifiersChanged {
            // A token verifies only with the exact identifiers it was minted for.
            store.set(nextEmail, forKey: Key.email)
            store.set(nextExternalId, forKey: Key.externalId)
            store.set(nil, forKey: Key.identityToken)
        }
        if contactChanged {
            // Another contact's recent geofence transitions must not
            // suppress this one's.
            store.set(nil, forKey: Self.geofenceTransitionsKey)
        }
        if let identityToken, !identityToken.isEmpty {
            store.set(identityToken, forKey: Key.identityToken)
        }
        identityBlocked = false
        providerRetryAt = nil
        await registerPushIfNeeded(force: identifiersChanged)
        if identifiersChanged {
            if previous != nil, contactChanged {
                // Another user signed in without reset: the previous user's
                // running activities stay theirs, and only the device's
                // push-to-start tokens move to the new contact.
                saveLiveActivityTokens(liveActivityTokens.filter { $0.kind == .pushToStart })
            }
            for token in liveActivityTokens { await sendLiveActivityToken(token) }
        }
        await flush()
    }

    /// Forgets the user: unregisters the push token, clears identity, queued
    /// events and the anonymous id.
    public func reset() async {
        // Clear everything before the first await: the actor is reentrant, so
        // an identify() that runs while the remove request is in flight must
        // find the reset already done, not have its new state wiped after.
        let token = store.string(forKey: Key.pushToken)
        let liveTokens = liveActivityTokens
        // A running activity belongs to the previous user; push-to-start
        // tokens belong to the device and are registered again anonymously.
        saveLiveActivityTokens(liveTokens.filter { $0.kind == .pushToStart })
        store.set(nil, forKey: Key.email)
        store.set(nil, forKey: Key.externalId)
        store.set(nil, forKey: Key.identityToken)
        store.set(nil, forKey: Key.pushRegistration)
        store.set(UUID().uuidString.lowercased(), forKey: Key.anonymousId)
        store.set(nil, forKey: Key.profile)
        store.set(nil, forKey: Self.geofenceTransitionsKey)
        events.removeAll()
        persistEvents()
        retryTask?.cancel()
        retryTask = nil
        backoff = 0
        nextAttemptAt = nil
        identityBlocked = false
        providerRetryAt = nil

        if let token {
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
        }
        for liveToken in liveTokens {
            await removeLiveActivityToken(liveToken.token, unlinkSubscriber: true)
        }
        // Someone signed in while the removes were in flight; their
        // registration may have reached the server first, so register again.
        if contactKey != nil, token != nil {
            await registerPushIfNeeded(force: true)
        }
        // Unlinked push-to-start tokens come back for the new anonymous id
        // (or for whoever signed in meanwhile).
        for liveToken in liveActivityTokens {
            await sendLiveActivityToken(liveToken)
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
                guard contactKey != nil, !identityBlocked else { return }
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
                guard contactKey != nil, !identityBlocked else { return }
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
        let result = await withIdentity { identity, token in
            var body = identity
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body["identityToken"] = .string(token)
            body["events"] = .array(batch.map(\.json))
            return try await self.post(path: "/api/v1/app-events", body: .object(body))
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
        let result = await withIdentity { identity, token in
            var body = profile
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body.merge(identity) { _, new in new }
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
        let identity = contactKey ?? ""
        let permission = await pushPermissionReader?()
        if !force, let raw = store.string(forKey: Key.pushRegistration),
            let data = raw.data(using: .utf8),
            let last = try? JSONDecoder().decode(PushRegistration.self, from: data),
            last.token == token, last.email == identity,
            permission == nil || last.permission == permission,
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
        if let permission { base["permission"] = .string(permission.rawValue) }
        for (key, value) in [
            ("appVersion", device.appVersion), ("osVersion", device.osVersion),
            ("deviceName", device.deviceName), ("locale", device.locale),
            ("timezone", device.timezone),
        ] {
            if let value, !value.isEmpty { base[key] = .string(value) }
        }

        let anonymousBody = base
        let response: SequenzyHTTPResponse
        if contactKey != nil {
            let result = await withIdentity { fields, identityToken in
                var body = anonymousBody
                body.merge(fields) { _, new in new }
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
            token: token, email: identified ? identity : "", registeredAt: now(), permission: permission)
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

    // MARK: - Live Activities

    /// Stored ActivityKit tokens; at most this many are kept, newest last.
    public static let maxLiveActivityTokens = 32
    static let liveActivitiesPath = "/api/v1/push/live-activities"

    /// Tokens reported so far. They are sent again on `identify` so they
    /// link to the contact, and unlinked on `reset`.
    public var liveActivityTokens: [LiveActivityToken] {
        guard let raw = store.string(forKey: Key.liveActivityTokens), let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LiveActivityToken].self, from: data)) ?? []
    }

    private func saveLiveActivityTokens(_ tokens: [LiveActivityToken]) {
        let kept = Array(tokens.suffix(Self.maxLiveActivityTokens))
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else {
            store.set(nil, forKey: Key.liveActivityTokens)
            return
        }
        store.set(String(data: data, encoding: .utf8), forKey: Key.liveActivityTokens)
    }

    /// Registers a push-to-start or update token. A newer token for the same
    /// activity type (push-to-start) or activity (update) replaces the
    /// stored one, so iOS token rotation never leaves a stale copy behind.
    public func registerLiveActivityToken(_ token: LiveActivityToken) async {
        guard token.isValid else {
            log(.error, "Ignoring a Live Activity token for \(token.activityType): it needs a hex token, the Swift type name and, for update tokens, attributes.sequenzy.activityId")
            return
        }
        var tokens = liveActivityTokens.filter { !token.replaces($0) && $0.token != token.token }
        tokens.append(token)
        saveLiveActivityTokens(tokens)
        await sendLiveActivityToken(token)
    }

    /// Reports that an activity ended or was dismissed, so Sequenzy stops
    /// sending to its token.
    public func liveActivityEnded(token rawToken: String) async {
        let token = rawToken.lowercased()
        let tokens = liveActivityTokens
        guard tokens.contains(where: { $0.token == token }) else { return }
        saveLiveActivityTokens(tokens.filter { $0.token != token })
        await removeLiveActivityToken(token, unlinkSubscriber: false)
    }

    private func sendLiveActivityToken(_ token: LiveActivityToken) async {
        var base: [String: JSONValue] = [
            "companyId": .string(configuration.companyId),
            "publicKey": .string(configuration.publicKey),
            "kind": .string(token.kind.rawValue),
            "activityType": .string(token.activityType),
            "token": .string(token.token),
            "anonymousId": .string(anonymousId),
        ]
        if let activityId = token.activityId { base["activityId"] = .string(activityId) }
        // Links the token to this installation's push device, when there is one.
        if let deviceToken = store.string(forKey: Key.pushToken) { base["deviceToken"] = .string(deviceToken) }
        for (key, value) in [("appVersion", device.appVersion), ("osVersion", device.osVersion)] {
            if let value, !value.isEmpty { base[key] = .string(value) }
        }

        let anonymousBody = base
        let response: SequenzyHTTPResponse?
        if contactKey != nil {
            let result = await withIdentity { fields, identityToken in
                var body = anonymousBody
                body.merge(fields) { _, new in new }
                body["identityToken"] = .string(identityToken)
                return try await self.post(path: Self.liveActivitiesPath, body: .object(body))
            }
            switch result {
            case .response(let identified):
                response = identified
            case .userChanged:
                // The new user's identify sends the stored tokens again.
                return
            case .notIdentified, .identityRejected:
                // Store it anonymously; Sequenzy can address it once the next
                // identify links it to the contact.
                response = await postIgnoringErrors(Self.liveActivitiesPath, .object(anonymousBody))
            case .failed(let error):
                log(.info, "Live Activity token registration failed: \(error)")
                return
            }
        } else {
            response = await postIgnoringErrors(Self.liveActivitiesPath, .object(anonymousBody))
        }
        guard let response else { return }
        if !(200..<300).contains(response.status) {
            log(.error, "Live Activity token registration failed: HTTP \(response.status) \(errorMessage(response.body) ?? "")")
        } else if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            object["pushConfigured"] as? Bool == false
        {
            log(.info, "Live Activity token registered, but APNs credentials are not set up in Sequenzy yet")
        }
    }

    private func removeLiveActivityToken(_ token: String, unlinkSubscriber: Bool) async {
        var body: [String: JSONValue] = [
            "companyId": .string(configuration.companyId),
            "publicKey": .string(configuration.publicKey),
            "token": .string(token),
        ]
        if unlinkSubscriber { body["unlinkSubscriber"] = .bool(true) }
        guard let response = await postIgnoringErrors("\(Self.liveActivitiesPath)/remove", .object(body)) else { return }
        if !(200..<300).contains(response.status) {
            log(.error, "Could not report the Live Activity ended (HTTP \(response.status))")
        }
    }

    // MARK: - In-app

    /// Open messages or cards for the identified contact, in server order.
    /// `formats` lists the message formats the caller renders; nil means the
    /// native formats, so `html` messages arrive only when listed.
    public func fetchFeed(
        kind: InAppMessage.Kind? = nil, limit: Int? = nil, formats: [InAppMessage.Format]? = nil
    ) async throws -> [InAppMessage] {
        let includePushPrimers = handlesPushPermission
        let result = await withIdentity { identity, token in
            var body = identity
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body["identityToken"] = .string(token)
            if let kind { body["kind"] = .string(kind.rawValue) }
            if let limit { body["limit"] = .number(Double(limit)) }
            if let formats { body["formats"] = .array(formats.map { .string($0.rawValue) }) }
            // Push primers come only when this app can ask for permission
            if includePushPrimers {
                body["actions"] = [.string(InAppButton.Action.requestPushPermission.rawValue)]
            }
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
    /// `buttonId` names the control clicked in a custom HTML message. A push
    /// primer's click carries the permission read after asking.
    @discardableResult
    public func report(
        _ type: InAppEventType, messageId: String, buttonId: String? = nil,
        pushPermission: PushPermissionStatus? = nil
    ) async -> Bool {
        let result = await withIdentity { identity, token in
            var body = identity
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body["identityToken"] = .string(token)
            body["messageId"] = .string(messageId)
            body["type"] = .string(type.rawValue)
            if let buttonId, type == .clicked, InAppHtmlBridgeMessage.isValidButtonId(buttonId) {
                body["buttonId"] = .string(buttonId)
            }
            if let pushPermission { body["pushPermission"] = .string(pushPermission.rawValue) }
            return try await self.post(path: "/api/v1/in-app/feed/events", body: .object(body))
        }
        if case .response(let response) = result, (200..<300).contains(response.status) {
            return true
        }
        log(.error, "Could not report in-app \(type.rawValue) for \(messageId)")
        return false
    }

    /// Placement keys one request can ask for.
    public static let maxPlacementsPerRequest = 10

    /// Must match `IN_APP_PLACEMENT_KEY_PATTERN` on the API (`^[a-z0-9][a-z0-9_.-]{0,63}$`)
    /// so one invalid key never triggers a 400 that drops sibling placements in the batch.
    public static func isValidPlacementKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        let first = bytes[0]
        let isFirstValid = (first >= 0x61 && first <= 0x7A) || (first >= 0x30 && first <= 0x39)
        guard isFirstValid else { return false }
        for byte in bytes.dropFirst() {
            let valid = (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x5F || byte == 0x2E || byte == 0x2D
            if !valid { return false }
        }
        return true
    }

    /// What each placement shows the identified contact: its highest-priority
    /// open item. Keys missing from the result have nothing to show, so their
    /// slots collapse. Up to `maxPlacementsPerRequest` keys.
    public func fetchPlacements(_ placements: [String]) async throws -> [String: InAppMessage] {
        var seen = Set<String>()
        var keys: [String] = []
        for raw in placements {
            let key = raw.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard Self.isValidPlacementKey(key) else {
                log(.error, "Ignoring invalid placement key \"\(key)\": use 1-64 lowercase letters, numbers, dots, dashes or underscores")
                continue
            }
            keys.append(key)
            if keys.count >= Self.maxPlacementsPerRequest { break }
        }
        guard !keys.isEmpty else { return [:] }
        let includePushPrimers = handlesPushPermission
        let result = await withIdentity { identity, token in
            var body = identity
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body["identityToken"] = .string(token)
            body["placements"] = .array(keys.map { .string($0) })
            if includePushPrimers {
                body["actions"] = [.string(InAppButton.Action.requestPushPermission.rawValue)]
            }
            return try await self.post(path: "/api/v1/in-app/feed/placements", body: .object(body))
        }
        switch result {
        case .notIdentified, .userChanged: throw SequenzyError.notIdentified
        case .identityRejected: throw SequenzyError.identityRejected
        case .failed(let error): throw error
        case .response(let response):
            guard (200..<300).contains(response.status) else {
                throw SequenzyError.http(status: response.status, message: errorMessage(response.body))
            }
            // One malformed item empties its own slot, not every slot.
            struct Entry: Decodable {
                let placement: String
                let message: InAppMessage?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    placement = try container.decode(String.self, forKey: .placement)
                    message = try? container.decodeIfPresent(InAppMessage.self, forKey: .message)
                }
                enum CodingKeys: String, CodingKey { case placement, message }
            }
            struct Placements: Decodable { let placements: [Entry] }
            let requested = Set(keys)
            var items: [String: InAppMessage] = [:]
            for entry in try JSONDecoder().decode(Placements.self, from: response.body).placements
            where requested.contains(entry.placement) {
                items[entry.placement] = entry.message
            }
            return items
        }
    }

    // MARK: - Geofences

    /// The nearest active geofences around a position. The position is
    /// rounded to two decimals here, whatever the caller passes.
    public func fetchNearbyGeofences(latitude: Double, longitude: Double, limit: Int) async throws -> NearbyGeofences {
        let result = await withIdentity { identity, token in
            var body = identity
            body["companyId"] = .string(self.configuration.companyId)
            body["publicKey"] = .string(self.configuration.publicKey)
            body["identityToken"] = .string(token)
            body["latitude"] = .number(Geofencing.roundCoordinate(latitude))
            body["longitude"] = .number(Geofencing.roundCoordinate(longitude))
            body["limit"] = .number(Double(max(1, min(99, limit))))
            return try await self.post(path: "/api/v1/geofences/nearby", body: .object(body))
        }
        switch result {
        case .notIdentified, .userChanged: throw SequenzyError.notIdentified
        case .identityRejected: throw SequenzyError.identityRejected
        case .failed(let error): throw error
        case .response(let response):
            guard (200..<300).contains(response.status) else {
                throw SequenzyError.http(status: response.status, message: errorMessage(response.body))
            }
            return try JSONDecoder().decode(NearbyGeofences.self, from: response.body)
        }
    }

    /// Queues an enter or exit the OS reported. The refresh region and a
    /// repeat of the same transition within a minute are ignored. Returns
    /// whether the transition was queued.
    @discardableResult
    public func trackGeofenceTransition(
        geofenceId rawId: String, transition: GeofenceTransition, at date: Date? = nil
    ) async -> Bool {
        let geofenceId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !geofenceId.isEmpty, geofenceId != GeofenceRegion.refreshRegionId else { return false }
        // Visits belong to a contact; never queue one for whoever signs in next.
        guard contactKey != nil else { return false }
        let occurredAt = date ?? now()
        var recent = (store.string(forKey: Self.geofenceTransitionsKey))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: Data($0.utf8)) } ?? [:]
        let key = "\(geofenceId):\(transition.rawValue)"
        if let last = recent[key], abs(occurredAt.timeIntervalSince1970 - last) < Geofencing.debounceInterval {
            log(.debug, "Ignored repeated geofence \(transition.rawValue) for \(geofenceId)")
            return false
        }
        recent[key] = occurredAt.timeIntervalSince1970
        let cutoff = now().timeIntervalSince1970 - Self.maxEventAge
        recent = recent.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(recent) {
            store.set(String(decoding: data, as: UTF8.self), forKey: Self.geofenceTransitionsKey)
        }
        events.append(
            QueuedEvent(
                name: "geofence",
                eventId: UUID().uuidString.lowercased(),
                properties: [:],
                occurredAt: iso8601(occurredAt),
                type: "geofence",
                transition: transition.rawValue,
                geofenceId: geofenceId
            ))
        if events.count > Self.maxQueuedEvents {
            events.removeFirst(events.count - Self.maxQueuedEvents)
        }
        persistEvents()
        await flush()
        return true
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

    private enum ProviderTokenResult {
        case token(String)
        case retryLater
        case unavailable
        case userChanged
    }

    /// Runs `operation` with the stored identifiers and identity token,
    /// fetching a token from the provider when none is stored, and once more
    /// when the server rejects the stored one.
    private func withIdentity(
        _ operation: @Sendable ([String: JSONValue], String) async throws -> SequenzyHTTPResponse
    ) async -> IdentifiedResult {
        guard let contact = contactKey, !identityBlocked else { return .notIdentified }
        let identity = identityFields
        var usedProvider = false
        var token = store.string(forKey: Key.identityToken)
        if token == nil {
            usedProvider = true
            switch await tokenFromProvider() {
            case .token(let fresh):
                token = fresh
            case .userChanged:
                return .userChanged
            case .retryLater, .unavailable:
                token = nil
            }
        }
        guard var current = token else {
            log(.info, "No identity token yet; pass one to identify or identifyUser, or set an identity token provider")
            return .notIdentified
        }

        while true {
            let response: SequenzyHTTPResponse
            do {
                response = try await operation(identity, current)
            } catch {
                return .failed(error)
            }
            guard isIdentityRejection(response) else { return .response(response) }
            // The user changed while this request was in flight: its rejection
            // is about the previous user and must not touch the new one.
            guard contactKey == contact, identityFields == identity else { return .userChanged }

            store.set(nil, forKey: Key.identityToken)
            if !usedProvider {
                usedProvider = true
                switch await tokenFromProvider() {
                case .token(let fresh):
                    current = fresh
                    continue
                case .retryLater:
                    return .notIdentified
                case .userChanged:
                    return .userChanged
                case .unavailable:
                    break
                }
            }
            identityBlocked = true
            log(.error, "The identity token was rejected; call identify or identifyUser again with a fresh token")
            return .identityRejected
        }
    }

    /// A fresh token for the current identity: from the user identity token
    /// provider for a user identified by external ID, otherwise from the
    /// identity token provider with the email.
    private func tokenFromProvider() async -> ProviderTokenResult {
        let contact = contactKey
        let identity = identityFields
        let request: (@Sendable () async throws -> String)?
        if let externalId {
            let email = email
            request = userIdentityTokenProvider.map { provider in { try await provider(externalId, email) } }
        } else if let email {
            request = identityTokenProvider.map { provider in { try await provider(email) } }
        } else {
            request = nil
        }
        guard let request else { return .unavailable }
        if let providerRetryAt, providerRetryAt > now() { return .retryLater }
        do {
            // Calls run in order, so a provider that never returns would stall
            // every later call without the timeout.
            let token = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await request() }
                group.addTask { [sleep] in
                    await sleep(Self.providerTimeout)
                    throw SequenzyError.http(status: 0, message: "The identity token provider timed out")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
            // The actor can run an identify while the provider is pending: a
            // token minted for other identifiers must not replace the new one.
            guard contactKey == contact, identityFields == identity else { return .userChanged }
            guard !token.isEmpty else { return .unavailable }
            store.set(token, forKey: Key.identityToken)
            identityBlocked = false
            providerRetryAt = nil
            return .token(token)
        } catch {
            providerRetryAt = now().addingTimeInterval(Self.providerRetryInterval)
            log(.error, "The identity token provider failed: \(error); retrying in a minute")
            return .retryLater
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

@_exported import SequenzyCore

#if canImport(UIKit) && canImport(UserNotifications)
    import UIKit
    import UserNotifications

    /// Receives in-app events and lets the app take over URL handling.
    @MainActor
    public protocol SequenzyInAppDelegate: AnyObject {
        /// Return false to keep a message from showing now. It stays in the
        /// feed and is offered again on the next foreground.
        func sequenzyShouldShow(_ message: InAppMessage) -> Bool
        /// Return true when the app handled the URL itself.
        func sequenzyHandle(url: URL, from message: InAppMessage?) -> Bool
    }

    extension SequenzyInAppDelegate {
        public func sequenzyShouldShow(_ message: InAppMessage) -> Bool { true }
        public func sequenzyHandle(url: URL, from message: InAppMessage?) -> Bool { false }
    }

    /// The Sequenzy SDK for iOS.
    ///
    /// ```swift
    /// Sequenzy.configure(publicKey: "seq_pk_...", companyId: "...")
    /// Sequenzy.identify(email: user.email, identityToken: tokenFromYourBackend)
    /// Sequenzy.track("workout_completed", properties: ["minutes": 30])
    /// ```
    @MainActor
    public enum Sequenzy {
        private static var client: SequenzyClient?
        private static var presenter: InAppPresenter?
        private static var observers: [NSObjectProtocol] = []
        private static var lastFeedFetch: Date?
        private static var pollTimer: Timer?
        static var showsInAppMessagesAutomatically = true

        typealias Command = @MainActor @Sendable () async -> Void
        private static var commands: AsyncStream<Command>.Continuation?

        /// identify, reset, track, push registration and feed refreshes run
        /// one at a time in call order: `track(x); reset()` records x for the
        /// signed-in user, and `reset(); identify(b)` leaves b signed in.
        static func enqueue(_ command: @escaping Command) {
            commands?.yield(command)
        }

        public static weak var inAppDelegate: SequenzyInAppDelegate?

        /// How often the feed is fetched while the app is in the foreground.
        public static var feedRefreshInterval: TimeInterval = 60
        /// Show custom HTML in-app messages (surveys, Braze-style custom
        /// HTML) in a sandboxed web view. Set false before `configure` to
        /// leave them in the feed for another app or SDK version.
        public static var showsHtmlMessages = true

        /// Message formats automatic display draws.
        static var displayedFormats: [InAppMessage.Format] {
            showsHtmlMessages ? [.modal, .banner, .fullscreen, .html] : [.modal, .banner, .fullscreen]
        }

        public static var isConfigured: Bool { client != nil }

        /// Call once, early in `application(_:didFinishLaunchingWithOptions:)`.
        ///
        /// - Parameters:
        ///   - appId: Defaults to the bundle ID. Add it to the key's allowed app IDs.
        ///   - identityTokenProvider: Fetches a fresh identity token from your
        ///     backend when the stored one is missing or expired.
        ///   - showInAppMessages: Set false to present messages yourself from
        ///     `fetchMessages()`.
        public static func configure(
            publicKey: String,
            companyId: String,
            appId: String? = Bundle.main.bundleIdentifier,
            apiBaseURL: URL = SequenzyConfiguration.defaultAPIBaseURL,
            identityTokenProvider: IdentityTokenProvider? = nil,
            showInAppMessages: Bool = true,
            logLevel: SequenzyLogLevel = .error
        ) {
            guard client == nil else { return }
            let configuration = SequenzyConfiguration(
                publicKey: publicKey, companyId: companyId, appId: appId ?? "",
                apiBaseURL: apiBaseURL)
            let newClient = SequenzyClient(
                configuration: configuration,
                device: currentDeviceInfo(),
                identityTokenProvider: identityTokenProvider,
                logLevel: logLevel)
            client = newClient
            showsInAppMessagesAutomatically = showInAppMessages
            presenter = InAppPresenter()
            let (stream, continuation) = AsyncStream<Command>.makeStream()
            commands = continuation
            Task { @MainActor in
                for await command in stream { await command() }
            }
            // First in the queue, so the first registration and feed fetch
            // already report permission and ask for push primers.
            enqueue { await newClient.setPushPermissionReader { await currentPushPermission() } }
            // Keep the app's own delegate, if it set one first, for
            // notifications from other senders.
            let center = UNUserNotificationCenter.current()
            if center.delegate !== NotificationCenterProxy.shared {
                NotificationCenterProxy.shared.previous = center.delegate
            }
            center.delegate = NotificationCenterProxy.shared
            observeLifecycle()
        }

        // MARK: Identity and events

        public static func identify(email: String, identityToken: String? = nil) {
            guard let client = requireClient() else { return }
            enqueue {
                await client.identify(email: email, identityToken: identityToken)
                let signedIn = await client.email
                presenter?.signedIn(as: signedIn)
                await refreshMessages(force: true)
            }
        }

        public static func reset() {
            guard let client = requireClient() else { return }
            enqueue {
                #if canImport(ActivityKit)
                    // The previous user's activities leave the Lock Screen
                    // with them; reset then reports their tokens ended.
                    await endLiveActivitiesForReset()
                #endif
                await client.reset()
                // After the reset, so no fetch queued before it can bring the
                // previous user's messages back.
                presenter?.dismissAll()
            }
        }

        public static func track(_ name: String, properties: [String: JSONValue] = [:]) {
            guard let client = requireClient() else { return }
            enqueue { await client.track(name, properties: properties) }
        }

        /// Records a screen view as the built-in "Screen Viewed" event.
        public static func screen(_ name: String, properties: [String: JSONValue] = [:]) {
            guard let client = requireClient() else { return }
            enqueue { await client.screen(name, properties: properties) }
        }

        public static func viewedProduct(_ product: CommerceProduct) {
            guard let client = requireClient() else { return }
            enqueue { await client.viewedProduct(product) }
        }

        public static func addedToCart(_ line: CommerceCartLine) {
            guard let client = requireClient() else { return }
            enqueue { await client.addedToCart(line) }
        }

        public static func removedFromCart(_ line: CommerceCartLine) {
            guard let client = requireClient() else { return }
            enqueue { await client.removedFromCart(line) }
        }

        public static func viewedCart(_ cart: CommerceCart) {
            guard let client = requireClient() else { return }
            enqueue { await client.viewedCart(cart) }
        }

        public static func viewedCollection(_ collection: CommerceCollection) {
            guard let client = requireClient() else { return }
            enqueue { await client.viewedCollection(collection) }
        }

        public static func searched(_ query: String) {
            guard let client = requireClient() else { return }
            enqueue { await client.searched(query) }
        }

        /// Name and custom attributes of the signed-in contact.
        public static func setProfile(_ update: ProfileUpdate) {
            guard let client = requireClient() else { return }
            enqueue { await client.setProfile(update) }
        }

        /// Newsletter or waitlist signup through a published form.
        public static func subscribe(_ request: SubscribeRequest) async -> SubscribeResult {
            guard let client = requireClient() else {
                return .failure(error: "Call Sequenzy.configure first", retryable: false)
            }
            return await client.subscribe(request)
        }

        public static func setIdentityTokenProvider(_ provider: IdentityTokenProvider?) {
            guard let client = requireClient() else { return }
            enqueue { await client.setIdentityTokenProvider(provider) }
        }

        // MARK: Push

        /// Asks for notification permission and registers with APNs. With
        /// `provisional`, iOS skips the prompt and delivers quietly to
        /// Notification Center until the user chooses to keep or turn off
        /// notifications.
        @discardableResult
        public static func requestPushAuthorization(
            options: UNAuthorizationOptions = [.alert, .badge, .sound],
            provisional: Bool = false
        ) async -> Bool {
            let requested = provisional ? options.union(.provisional) : options
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: requested)) ?? false
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            if let client { enqueue { await client.registerPushIfNeeded() } }
            return granted
        }

        /// The notification permission as iOS reports it now.
        nonisolated public static func currentPushPermission() async -> PushPermissionStatus {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized: return .granted
            case .provisional: return .provisional
            case .ephemeral: return .ephemeral
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }

        /// Asks for notification permission the way a push primer does: the
        /// system prompt when iOS still shows one (including upgrading
        /// provisional to full permission), otherwise the app's notification
        /// settings. Returns the permission afterwards.
        @discardableResult
        public static func requestPushPermission() async -> PushPermissionStatus {
            let before = await currentPushPermission()
            if before == .granted || before == .ephemeral {
                UIApplication.shared.registerForRemoteNotifications()
                return before
            }
            if before == .denied {
                // iOS never shows the prompt again; only Settings can turn it on.
                openNotificationSettings()
                return before
            }
            await requestPushAuthorization()
            return await currentPushPermission()
        }

        static func openNotificationSettings() {
            let raw: String
            if #available(iOS 16.0, *) {
                raw = UIApplication.openNotificationSettingsURLString
            } else {
                raw = UIApplication.openSettingsURLString
            }
            if let url = URL(string: raw) { UIApplication.shared.open(url) }
        }

        /// Forward from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
        public static func registerDeviceToken(_ deviceToken: Data) {
            guard let client = requireClient() else { return }
            let token = apnsTokenString(deviceToken)
            enqueue { await client.setPushToken(token) }
        }

        /// Forward from `userNotificationCenter(_:didReceive:withCompletionHandler:)`
        /// when your app owns the notification center delegate. Returns false
        /// for notifications Sequenzy did not send.
        @discardableResult
        public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
            guard
                response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                let payload = PushPayload.parse(userInfo: response.notification.request.content.userInfo)
            else { return false }
            if let client {
                Task { await client.reportPush(.clicked, payload: payload) }
            }
            if let raw = payload.url, let url = URL(string: raw) {
                open(url, from: nil)
            }
            return true
        }

        /// Presentation options for a Sequenzy notification arriving while the
        /// app is open; nil for notifications from other senders.
        public static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
            guard PushPayload.parse(userInfo: notification.request.content.userInfo) != nil else { return nil }
            return [.banner, .list, .sound]
        }

        // MARK: In-app messages and cards

        /// Fetches open messages and shows the next one unless the app opted
        /// out of automatic display.
        public static func refreshMessages(force: Bool = false) async {
            guard let client, showsInAppMessagesAutomatically else { return }
            // 90%: a poll timer firing on the interval must not lose a cycle
            // to a fetch that ran a moment after it was scheduled.
            if !force, let lastFeedFetch, Date().timeIntervalSince(lastFeedFetch) < feedRefreshInterval * 0.9 { return }
            lastFeedFetch = Date()
            let owner = await client.email
            guard let messages = try? await client.fetchFeed(kind: .message, formats: displayedFormats),
                await client.email == owner
            else { return }
            presenter?.enqueue(messages, owner: owner)
        }

        /// Open in-app messages, for apps that present them themselves.
        /// Custom HTML messages are included only with `includeHtml`.
        public static func fetchMessages(includeHtml: Bool = false) async throws -> [InAppMessage] {
            guard let client = requireClient() else { throw SequenzyError.notIdentified }
            return try await client.fetchFeed(
                kind: .message, formats: includeHtml ? [.modal, .banner, .fullscreen, .html] : nil)
        }

        /// Content cards for an inbox or feed screen, pinned cards first.
        public static func fetchCards(limit: Int? = nil) async throws -> [InAppMessage] {
            guard let client = requireClient() else { throw SequenzyError.notIdentified }
            return try await client.fetchFeed(kind: .card, limit: limit)
        }

        /// Reports an event for a message or card you render yourself.
        public static func report(_ type: InAppEventType, for message: InAppMessage) {
            guard let client = requireClient() else { return }
            Task { await client.report(type, messageId: message.id) }
        }

        /// Reports the click and performs the button's action: opens its URL,
        /// or asks for push permission and reports the result with the click.
        public static func handleButtonTap(_ button: InAppButton, in message: InAppMessage) {
            if button.action == .requestPushPermission {
                requestPermissionAndReport(messageId: message.id)
                return
            }
            report(.clicked, for: message)
            if button.action == .openUrl, let raw = button.url, let url = URL(string: raw) {
                open(url, from: message)
            }
        }

        static func requestPermissionAndReport(messageId: String) {
            guard let client = requireClient() else { return }
            Task { @MainActor in
                let status = await requestPushPermission()
                await client.report(.clicked, messageId: messageId, pushPermission: status)
            }
        }

        // MARK: Geofences

        /// The identified contact's email, or nil. Geofencing runs only then.
        public static func identifiedEmail() async -> String? {
            await client?.email
        }

        /// The nearest geofences around a position. `SequenzyGeofences` calls
        /// this; apps with their own location stack can too. The position is
        /// rounded to about 1 km before it is sent.
        public static func fetchNearbyGeofences(latitude: Double, longitude: Double, limit: Int) async throws -> NearbyGeofences {
            guard let client = requireClient() else { throw SequenzyError.notIdentified }
            return try await client.fetchNearbyGeofences(latitude: latitude, longitude: longitude, limit: limit)
        }

        /// Reports a geofence enter or exit and waits until it is sent or
        /// queued, so a background task can end afterwards. For apps with
        /// their own region monitoring; `SequenzyGeofences` calls it too.
        @discardableResult
        public static func trackGeofenceTransition(
            geofenceId: String, transition: GeofenceTransition, at date: Date? = nil
        ) async -> Bool {
            guard let client = requireClient() else { return false }
            return await client.trackGeofenceTransition(geofenceId: geofenceId, transition: transition, at: date)
        }

        // MARK: Internals

        static func reportFromPresenter(_ type: InAppEventType, messageId: String, buttonId: String? = nil) {
            guard let client else { return }
            Task { await client.report(type, messageId: messageId, buttonId: buttonId) }
        }

        static func open(_ url: URL, from message: InAppMessage?) {
            if inAppDelegate?.sequenzyHandle(url: url, from: message) == true { return }
            UIApplication.shared.open(url)
        }

        static func requireClient() -> SequenzyClient? {
            if client == nil {
                print("[Sequenzy] Call Sequenzy.configure(publicKey:companyId:) first")
            }
            return client
        }

        private static func observeLifecycle() {
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        Sequenzy.startPolling()
                        guard let client = Sequenzy.client else { return }
                        Sequenzy.enqueue {
                            // Someone who declined and later turned notifications
                            // on in Settings has no APNs token yet; iOS only
                            // hands one out once the app registers.
                            switch await currentPushPermission() {
                            case .granted, .provisional, .ephemeral:
                                UIApplication.shared.registerForRemoteNotifications()
                            case .denied, .notDetermined:
                                break
                            }
                            await client.flush()
                            await client.registerPushIfNeeded()
                            await Sequenzy.refreshMessages()
                        }
                    }
                })
            observers.append(
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor in Sequenzy.stopPolling() }
                })
        }

        // Poll while in the foreground so a message created by something the
        // user just did (a tracked event starting a sequence) shows up without
        // leaving the app.
        private static func startPolling() {
            guard pollTimer == nil, feedRefreshInterval > 0 else { return }
            pollTimer = Timer.scheduledTimer(withTimeInterval: feedRefreshInterval, repeats: true) { _ in
                Task { @MainActor in Sequenzy.enqueue { await Sequenzy.refreshMessages() } }
            }
        }

        private static func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        private static func currentDeviceInfo() -> DeviceInfo {
            let info = Bundle.main.infoDictionary
            return DeviceInfo(
                appVersion: info?["CFBundleShortVersionString"] as? String,
                osVersion: UIDevice.current.systemVersion,
                deviceName: UIDevice.current.model)
        }
    }

    /// Default notification center delegate: shows Sequenzy pushes while the
    /// app is open and handles taps. Apps with their own delegate call
    /// `Sequenzy.handleNotificationResponse` and
    /// `Sequenzy.presentationOptions(for:)` from it instead.
    final class NotificationCenterProxy: NSObject, UNUserNotificationCenterDelegate {
        static let shared = NotificationCenterProxy()

        /// The app's delegate from before `configure`, which keeps handling
        /// notifications from other senders.
        weak var previous: UNUserNotificationCenterDelegate?

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            guard PushPayload.parse(userInfo: notification.request.content.userInfo) != nil else {
                if let previous, previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                    previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
                } else {
                    completionHandler([])
                }
                return
            }
            completionHandler([.banner, .list, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            guard PushPayload.parse(userInfo: response.notification.request.content.userInfo) != nil else {
                if let previous, previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                    previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
                } else {
                    completionHandler()
                }
                return
            }
            // UIKit calls delegates on the main thread.
            MainActor.assumeIsolated { Sequenzy.handleNotificationResponse(response) }
            completionHandler()
        }
    }
#endif

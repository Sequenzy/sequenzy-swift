#if os(iOS)
    import CoreLocation
    import Sequenzy
    import UIKit

    /// Geofencing for iOS: watches the nearest of your geofences with Core
    /// Location and reports when the signed-in user enters or leaves one.
    ///
    /// ```swift
    /// // application(_:didFinishLaunchingWithOptions:), after Sequenzy.configure
    /// SequenzyGeofences.shared.start()
    /// // once the user agreed to location-based messages
    /// SequenzyGeofences.shared.requestAuthorization()
    /// SequenzyGeofences.shared.enable()
    /// ```
    ///
    /// iOS lets an app watch 20 regions, shared with the app's own. The SDK
    /// registers the nearest geofences plus one region around the device and
    /// fetches again when the device leaves it. Monitoring needs "Always"
    /// location access with precise location; the app needs
    /// `NSLocationWhenInUseUsageDescription` and
    /// `NSLocationAlwaysAndWhenInUseUsageDescription` in its Info.plist.
    @MainActor
    public final class SequenzyGeofences: NSObject {
        public static let shared = SequenzyGeofences()

        /// Regions this SDK may use. Lower it if the app monitors its own.
        public var maxRegions = Geofencing.defaultMaxRegionsIOS

        private let manager = CLLocationManager()
        private let defaults = UserDefaults.standard
        private var started = false
        private var fetchPending = false
        private var lastRefreshRequest: Date?

        private enum Key {
            static let enabled = "sequenzy.geofences.enabled"
            static let regions = "sequenzy.geofences.regions"
            static let lastFetch = "sequenzy.geofences.lastFetch"
        }

        override private init() {
            super.init()
        }

        /// Whether geofencing is on. Kept across launches.
        public private(set) var isEnabled: Bool {
            get { defaults.bool(forKey: Key.enabled) }
            set { defaults.set(newValue, forKey: Key.enabled) }
        }

        /// Attaches the location delegate. Call on every launch, including
        /// background launches iOS makes to deliver a region event.
        public func start() {
            guard !started else { return }
            started = true
            manager.delegate = self
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            if isEnabled, isStale { refresh() }
        }

        /// Asks for "When In Use" access, then "Always" once that is granted.
        public func requestAuthorization() {
            start()
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
            default: break
            }
        }

        /// Turns geofencing on and fetches the nearest geofences.
        public func enable() {
            start()
            isEnabled = true
            refresh(force: true)
        }

        /// Turns geofencing off and stops watching every Sequenzy region.
        /// Call on sign-out, or when the user withdraws consent.
        public func disable() {
            isEnabled = false
            fetchPending = false
            apply([])
            defaults.removeObject(forKey: Key.lastFetch)
        }

        /// Fetches the nearest geofences for the current position.
        public func refresh(force: Bool = false) {
            guard isEnabled else { return }
            if !force, let last = lastRefreshRequest,
                Date().timeIntervalSince(last) < Geofencing.minRefreshInterval
            {
                return
            }
            lastRefreshRequest = Date()
            guard canMonitor else {
                log("Geofencing needs Always location access with precise location")
                return
            }
            fetchPending = true
            manager.requestLocation()
        }

        // MARK: Internals

        private var canMonitor: Bool {
            CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
                && manager.authorizationStatus == .authorizedAlways
                && manager.accuracyAuthorization == .fullAccuracy
        }

        private var isStale: Bool {
            let last = defaults.double(forKey: Key.lastFetch)
            return last == 0 || Date().timeIntervalSince1970 - last > Geofencing.staleAfter
        }

        @objc private func appDidBecomeActive() {
            if isEnabled, isStale { refresh() }
        }

        private var registered: [GeofenceRegion] {
            guard let data = defaults.data(forKey: Key.regions) else { return [] }
            return (try? JSONDecoder().decode([GeofenceRegion].self, from: data)) ?? []
        }

        private func fetch(latitude: Double, longitude: Double) async {
            guard isEnabled else { return }
            guard await Sequenzy.identifiedEmail() != nil else {
                // Visits are recorded on a contact; nobody is signed in.
                apply([])
                return
            }
            do {
                let nearby = try await Sequenzy.fetchNearbyGeofences(
                    latitude: latitude, longitude: longitude,
                    limit: Geofencing.fetchLimit(maxRegions: maxRegions))
                guard isEnabled else { return }
                apply(
                    Geofencing.plan(
                        nearby: nearby, latitude: latitude, longitude: longitude,
                        maxRegions: maxRegions))
                defaults.set(Date().timeIntervalSince1970, forKey: Key.lastFetch)
            } catch {
                log("Could not fetch geofences: \(error)")
            }
        }

        /// Registers `planned` and removes regions that are no longer in it.
        private func apply(_ planned: [GeofenceRegion]) {
            let changes = Geofencing.diff(registered: registered, planned: planned)
            let removed = Set(changes.remove)
            for region in manager.monitoredRegions where removed.contains(region.identifier) {
                manager.stopMonitoring(for: region)
            }
            for region in changes.add {
                let circle = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
                    radius: min(region.radiusMeters, manager.maximumRegionMonitoringDistance),
                    identifier: region.id)
                circle.notifyOnEntry = true
                circle.notifyOnExit = true
                manager.startMonitoring(for: circle)
            }
            defaults.set(try? JSONEncoder().encode(planned), forKey: Key.regions)
        }

        private func handle(regionId: String, transition: GeofenceTransition) {
            if regionId == GeofenceRegion.refreshRegionId {
                guard transition == .exit else { return }
                // The plan no longer covers the device's area: until a fetch
                // succeeds, the next foreground retries it.
                defaults.removeObject(forKey: Key.lastFetch)
                refresh()
                return
            }
            guard registered.contains(where: { $0.id == regionId }) else { return }
            // iOS gives a background launch about ten seconds; keep the app
            // running until the event is sent or safely queued.
            let application = UIApplication.shared
            var task = UIBackgroundTaskIdentifier.invalid
            task = application.beginBackgroundTask(withName: "sequenzy.geofence") {
                application.endBackgroundTask(task)
                task = .invalid
            }
            let occurredAt = Date()
            Task { @MainActor in
                if await Sequenzy.identifiedEmail() != nil {
                    await Sequenzy.trackGeofenceTransition(
                        geofenceId: regionId, transition: transition, at: occurredAt)
                }
                if task != .invalid { application.endBackgroundTask(task) }
            }
        }

        private func log(_ message: String) {
            print("[Sequenzy] \(message)")
        }
    }

    extension SequenzyGeofences: CLLocationManagerDelegate {
        nonisolated public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
            let id = region.identifier
            Task { @MainActor in self.handle(regionId: id, transition: .enter) }
        }

        nonisolated public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
            let id = region.identifier
            Task { @MainActor in self.handle(regionId: id, transition: .exit) }
        }

        nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let coordinate = locations.last?.coordinate else { return }
            let latitude = coordinate.latitude
            let longitude = coordinate.longitude
            Task { @MainActor in
                guard self.fetchPending else { return }
                self.fetchPending = false
                await self.fetch(latitude: latitude, longitude: longitude)
            }
        }

        nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            let message = error.localizedDescription
            Task { @MainActor in
                self.fetchPending = false
                self.log("Location request failed: \(message)")
            }
        }

        nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            Task { @MainActor in
                switch self.manager.authorizationStatus {
                case .authorizedWhenInUse:
                    // The second step of requestAuthorization().
                    self.manager.requestAlwaysAuthorization()
                case .authorizedAlways:
                    if self.isEnabled { self.refresh(force: true) }
                case .denied, .restricted:
                    self.apply([])
                default:
                    break
                }
            }
        }

        nonisolated public func locationManager(
            _ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error
        ) {
            let id = region?.identifier ?? "unknown"
            let message = error.localizedDescription
            Task { @MainActor in
                self.log("Could not monitor region \(id): \(message)")
                self.defaults.set(
                    try? JSONEncoder().encode(self.registered.filter { $0.id != id }),
                    forKey: Key.regions)
            }
        }
    }
#endif

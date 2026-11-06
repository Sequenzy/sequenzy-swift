import Foundation

/// A circular region from `POST /api/v1/geofences/nearby`, or the refresh
/// region the SDK adds around the device.
public struct GeofenceRegion: Codable, Equatable, Sendable {
    /// Id of the region the SDK registers around the device to know when to
    /// fetch again. Its enter/exit are never reported.
    public static let refreshRegionId = "sequenzy.refresh"

    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double

    public init(id: String, latitude: Double, longitude: Double, radiusMeters: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }

    public var isRefreshRegion: Bool { id == Self.refreshRegionId }
}

public enum GeofenceTransition: String, Codable, Sendable {
    case enter
    case exit
}

/// The server's answer: the nearest active geofences and how far the device
/// can move before a geofence that was not returned could come into reach.
public struct NearbyGeofences: Decodable, Equatable, Sendable {
    public let geofences: [GeofenceRegion]
    /// Nil when every geofence of the workspace was returned.
    public let refreshRadiusMeters: Double?

    public init(geofences: [GeofenceRegion], refreshRadiusMeters: Double?) {
        self.geofences = geofences
        self.refreshRadiusMeters = refreshRadiusMeters
    }
}

public enum Geofencing {
    /// iOS lets an app monitor 20 regions; one is the refresh region.
    public static let defaultMaxRegionsIOS = 20
    /// Android allows 100 per app; 50 keeps room for the host app's own.
    public static let defaultMaxRegionsAndroid = 50
    /// Repeats of the same transition for the same geofence within this window
    /// are dropped on the device (the server applies the real cooldown).
    public static let debounceInterval: TimeInterval = 60
    /// Leaving the refresh region fetches again at most this often.
    public static let minRefreshInterval: TimeInterval = 60
    /// A foreground fetch happens when the last one is older than this.
    public static let staleAfter: TimeInterval = 6 * 60 * 60

    /// Two decimals, about 1.1 km: enough to rank geofences, never sent finer.
    public static func roundCoordinate(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// The server `limit` for an app that may monitor `maxRegions` regions.
    public static func fetchLimit(maxRegions: Int) -> Int {
        max(1, min(99, maxRegions - 1))
    }

    /// The regions to monitor: the returned geofences (at most
    /// `maxRegions - 1`) plus, when the server says more exist, a refresh
    /// region centered on the precise device position.
    public static func plan(
        nearby: NearbyGeofences,
        latitude: Double,
        longitude: Double,
        maxRegions: Int
    ) -> [GeofenceRegion] {
        var regions = Array(nearby.geofences.prefix(fetchLimit(maxRegions: maxRegions)))
        if let radius = nearby.refreshRadiusMeters, radius > 0 {
            regions.append(
                GeofenceRegion(
                    id: GeofenceRegion.refreshRegionId,
                    latitude: latitude, longitude: longitude, radiusMeters: radius))
        }
        return regions
    }

    /// Which registered regions to remove and which planned ones to add, so a
    /// re-plan only touches regions that changed.
    public static func diff(
        registered: [GeofenceRegion],
        planned: [GeofenceRegion]
    ) -> (remove: [String], add: [GeofenceRegion]) {
        let current = Dictionary(registered.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let next = Dictionary(planned.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let remove = registered.filter { next[$0.id] != $0 }.map(\.id)
        let add = planned.filter { current[$0.id] != $0 }
        return (remove, add)
    }
}

extension SequenzyClient {
    static let geofenceTransitionsKey = "geofenceTransitions"
}

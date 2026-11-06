import XCTest

@testable import SequenzyCore

final class GeofenceTests: XCTestCase {
    var transport: FakeTransport!
    var store: InMemoryStore!
    var clock: Clock!

    override func setUp() {
        transport = FakeTransport()
        store = InMemoryStore()
        clock = Clock(Date(timeIntervalSince1970: 1_792_000_000))
    }

    func makeClient() -> SequenzyClient {
        let config = Contract.requests["config"] as! [String: String]
        let clock = self.clock!
        return SequenzyClient(
            configuration: SequenzyConfiguration(
                publicKey: config["publicKey"]!, companyId: config["companyId"]!,
                appId: config["appId"]!, apiBaseURL: URL(string: config["apiBaseUrl"]!)!),
            transport: transport, store: store,
            device: DeviceInfo(appVersion: "1.0", osVersion: "18.0", deviceName: "Test", locale: "en-US", timezone: "UTC"),
            identityTokenProvider: nil, logLevel: .none,
            now: { clock.now },
            sleep: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) })
    }

    var geofenceContract: [String: Any] { Contract.requests["geofences"] as! [String: Any] }

    func body(_ request: SequenzyHTTPRequest?) -> [String: Any] {
        guard let request else { return [:] }
        return transport.json(request)
    }

    func testFetchNearbyMatchesTheContractAndRoundsThePosition() async throws {
        let response = try JSONSerialization.data(withJSONObject: geofenceContract["nearbyResponse"]!)
        transport.respond(path: "/api/v1/geofences/nearby", status: 200, json: String(decoding: response, as: UTF8.self))
        let client = makeClient()
        await client.identify(email: "jane@example.com", identityToken: "seq_wid_contract.token")

        let nearby = try await client.fetchNearbyGeofences(
            latitude: 51.513_678, longitude: -0.136_5, limit: Geofencing.fetchLimit(maxRegions: 20))

        let request = transport.requests(to: "/api/v1/geofences/nearby").last
        let expected = Contract.request("fetchNearbyGeofences")["body"] as! [String: Any]
        let sent = body(request)
        for (key, value) in expected {
            XCTAssertJSONEqual(sent[key], value)
        }
        XCTAssertEqual(Set(sent.keys), Set(expected.keys))
        XCTAssertEqual(nearby.geofences.map(\.id), ["geo_1", "geo_2"])
        XCTAssertEqual(nearby.refreshRadiusMeters, 4200)
    }

    func testFetchNearbyNeedsAnIdentity() async {
        let client = makeClient()
        do {
            _ = try await client.fetchNearbyGeofences(latitude: 1, longitude: 2, limit: 19)
            XCTFail("expected notIdentified")
        } catch {
            XCTAssertEqual(error as? SequenzyError, .notIdentified)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTransitionsAreQueuedAsGeofenceEventsAndDebounced() async {
        transport.respond(path: "/api/v1/app-events", status: 202, json: #"{"success":true,"accepted":1,"rejected":[]}"#)
        let client = makeClient()
        await client.identify(email: "jane@example.com", identityToken: "seq_wid_contract.token")

        let queued = await client.trackGeofenceTransition(geofenceId: "geo_1", transition: .enter)
        let repeated = await client.trackGeofenceTransition(geofenceId: "geo_1", transition: .enter)
        let refresh = await client.trackGeofenceTransition(geofenceId: GeofenceRegion.refreshRegionId, transition: .exit)
        clock.advance(61)
        let later = await client.trackGeofenceTransition(geofenceId: "geo_1", transition: .enter)

        XCTAssertEqual([queued, repeated, refresh, later], [true, false, false, true])
        let requests = transport.requests(to: "/api/v1/app-events")
        XCTAssertEqual(requests.count, 2)
        let contract = Contract.request("trackGeofenceTransition")
        let expected = contract["body"] as! [String: Any]
        let sent = body(requests.first)
        for (key, value) in expected where key != "events" {
            XCTAssertJSONEqual(sent[key], value)
        }
        let event = (sent["events"] as! [[String: Any]])[0]
        let expectedEvent = (expected["events"] as! [[String: Any]])[0]
        for (key, value) in expectedEvent {
            XCTAssertJSONEqual(event[key], value)
        }
        XCTAssertFalse((event["eventId"] as? String ?? "").isEmpty)
        XCTAssertFalse((event["occurredAt"] as? String ?? "").isEmpty)
    }

    func testDropsTransitionsWhileNobodyIsIdentified() async {
        let client = makeClient()
        let queued = await client.trackGeofenceTransition(geofenceId: "geo_1", transition: .enter)
        let count = await client.queuedEventCount
        XCTAssertFalse(queued)
        XCTAssertEqual(count, 0)
    }

    func testAnotherContactIsNotDebouncedByThePreviousOne() async {
        transport.respond(path: "/api/v1/app-events", status: 202, json: #"{"success":true,"accepted":1,"rejected":[]}"#)
        let client = makeClient()
        await client.identify(email: "jane@example.com", identityToken: "seq_wid_contract.token")
        let jane = await client.trackGeofenceTransition(geofenceId: "geo_1", transition: .enter)
        await client.identify(email: "sam@example.com", identityToken: "seq_wid_contract.token")
        let sam = await client.trackGeofenceTransition(geofenceId: "geo_1", transition: .enter)
        XCTAssertEqual([jane, sam], [true, true])
    }

    func testPlanAddsARefreshRegionAroundTheDevice() {
        let nearby = NearbyGeofences(
            geofences: (1...25).map { GeofenceRegion(id: "g\($0)", latitude: 0, longitude: 0, radiusMeters: 200) },
            refreshRadiusMeters: 4200)

        let plan = Geofencing.plan(nearby: nearby, latitude: 51.5136, longitude: -0.1365, maxRegions: 20)

        XCTAssertEqual(plan.count, 20)
        XCTAssertEqual(plan.last, GeofenceRegion(id: "sequenzy.refresh", latitude: 51.5136, longitude: -0.1365, radiusMeters: 4200))
        XCTAssertEqual(plan.filter(\.isRefreshRegion).count, 1)

        let complete = Geofencing.plan(
            nearby: NearbyGeofences(geofences: Array(nearby.geofences.prefix(3)), refreshRadiusMeters: nil),
            latitude: 0, longitude: 0, maxRegions: 20)
        XCTAssertEqual(complete.map(\.id), ["g1", "g2", "g3"])
    }

    func testDiffTouchesOnlyChangedRegions() {
        let a = GeofenceRegion(id: "a", latitude: 0, longitude: 0, radiusMeters: 200)
        let b = GeofenceRegion(id: "b", latitude: 0, longitude: 0, radiusMeters: 200)
        let movedB = GeofenceRegion(id: "b", latitude: 1, longitude: 0, radiusMeters: 200)
        let c = GeofenceRegion(id: "c", latitude: 0, longitude: 0, radiusMeters: 200)

        let result = Geofencing.diff(registered: [a, b], planned: [movedB, c, a])

        XCTAssertEqual(result.remove, ["b"])
        XCTAssertEqual(result.add.map(\.id), ["b", "c"])
    }

    func testRoundingAndLimits() {
        XCTAssertEqual(Geofencing.roundCoordinate(51.513_678), 51.51)
        XCTAssertEqual(Geofencing.roundCoordinate(-0.136_5), -0.14)
        XCTAssertEqual(Geofencing.fetchLimit(maxRegions: 20), 19)
        XCTAssertEqual(Geofencing.fetchLimit(maxRegions: 1), 1)
        XCTAssertEqual(Geofencing.fetchLimit(maxRegions: 500), 99)
    }
}

import Foundation
import XCTest

@testable import SequenzyCore

final class FakeTransport: SequenzyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SequenzyHTTPRequest] = []
    private var responders: [(SequenzyHTTPRequest) throws -> SequenzyHTTPResponse?] = []

    var requests: [SequenzyHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    /// Responders run newest first; the first non-nil response wins.
    func respond(_ responder: @escaping (SequenzyHTTPRequest) throws -> SequenzyHTTPResponse?) {
        lock.lock()
        responders.insert(responder, at: 0)
        lock.unlock()
    }

    func respond(path: String, status: Int, json: String, times: Int = .max) {
        var remaining = times
        respond { request in
            guard request.url.path == path, remaining > 0 else { return nil }
            remaining -= 1
            return SequenzyHTTPResponse(status: status, body: Data(json.utf8))
        }
    }

    private func record(_ request: SequenzyHTTPRequest) -> [(SequenzyHTTPRequest) throws -> SequenzyHTTPResponse?] {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
        return responders
    }

    /// Requests to this path wait until `release()` is called.
    private var gatedPath: String?
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func gate(_ path: String) {
        lock.lock()
        gatedPath = path
        lock.unlock()
    }

    func release() {
        lock.lock()
        gatedPath = nil
        let waiters = gateWaiters
        gateWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func shouldWait(_ request: SequenzyHTTPRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gatedPath == request.url.path
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        gateWaiters.append(continuation)
        lock.unlock()
    }

    func send(_ request: SequenzyHTTPRequest) async throws -> SequenzyHTTPResponse {
        if shouldWait(request) {
            await withCheckedContinuation { park($0) }
        }
        for responder in record(request) {
            if let response = try responder(request) { return response }
        }
        switch request.url.path {
        case "/api/v1/app-events":
            return SequenzyHTTPResponse(status: 202, body: Data(#"{"success":true,"accepted":1,"rejected":[]}"#.utf8))
        case "/api/v1/push/app-devices":
            return SequenzyHTTPResponse(status: 201, body: Data(#"{"success":true,"deviceId":"dev_1","identified":true,"pushConfigured":true}"#.utf8))
        default:
            return SequenzyHTTPResponse(status: 200, body: Data(#"{"success":true}"#.utf8))
        }
    }

    func requests(to path: String) -> [SequenzyHTTPRequest] {
        requests.filter { $0.url.path == path }
    }

    func json(_ request: SequenzyHTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

enum Contract {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SequenzyCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()  // mobile-sdks
        .appendingPathComponent("contract/fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func object(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    }

    static var requests: [String: Any] { try! object("requests.json") }

    static func request(_ name: String) -> [String: Any] {
        (requests["requests"] as! [[String: Any]]).first { $0["name"] as? String == name }!
    }

    static var token: String {
        (request("registerAnonymousDevice")["body"] as! [String: Any])["token"] as! String
    }
}

func XCTAssertJSONEqual(_ actual: Any?, _ expected: Any?, file: StaticString = #filePath, line: UInt = #line) {
    let normalize: (Any?) -> String = { value in
        guard let value, JSONSerialization.isValidJSONObject([value]) else { return "nil" }
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
    XCTAssertEqual(normalize(actual), normalize(expected), file: file, line: line)
}

final class SequenzyClientTests: XCTestCase {
    var transport: FakeTransport!
    var store: InMemoryStore!
    var clock: Clock!
    var sleeps: [TimeInterval] = []

    override func setUp() {
        transport = FakeTransport()
        store = InMemoryStore()
        clock = Clock(Date(timeIntervalSince1970: 1_792_000_000))
        sleeps = []
    }

    func makeClient(provider: IdentityTokenProvider? = nil) -> SequenzyClient {
        let config = Contract.requests["config"] as! [String: String]
        let clock = self.clock!
        return SequenzyClient(
            configuration: SequenzyConfiguration(
                publicKey: config["publicKey"]!, companyId: config["companyId"]!,
                appId: config["appId"]!, apiBaseURL: URL(string: config["apiBaseUrl"]!)!),
            transport: transport, store: store,
            device: DeviceInfo(appVersion: "1.0", osVersion: "18.0", deviceName: "Test", locale: "en-US", timezone: "UTC"),
            identityTokenProvider: provider, logLevel: .none,
            now: { clock.now },
            // Retries must not run on their own in tests.
            sleep: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) })
    }

    let email = "jane@example.com"
    let identityToken = "seq_wid_contract.token"

    func assertMatchesContract(_ request: SequenzyHTTPRequest?, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let request else { return XCTFail("missing request \(name)", file: file, line: line) }
        let contract = Contract.request(name)
        if let path = contract["path"] as? String {
            XCTAssertEqual(request.url.absoluteString, "https://api.example.com\(path)", file: file, line: line)
            for (header, value) in Contract.requests["headers"] as! [String: String] {
                XCTAssertEqual(request.headers[header], value, "header \(header)", file: file, line: line)
            }
        } else {
            XCTAssertEqual(request.url.absoluteString, contract["url"] as? String, file: file, line: line)
        }
        XCTAssertEqual(request.method, contract["method"] as? String, file: file, line: line)
        let body = transport.json(request)
        let expected = contract["body"] as! [String: Any]
        for (key, value) in expected where key != "events" {
            XCTAssertJSONEqual(body[key], value, file: file, line: line)
        }
        for key in contract["absentBodyFields"] as! [String] {
            XCTAssertNil(body[key], "\(key) should be absent", file: file, line: line)
        }
        for key in contract["dynamicBodyFields"] as! [String] where !key.contains("[]") {
            XCTAssertFalse((body[key] as? String ?? "").isEmpty, "\(key) should be set", file: file, line: line)
        }
        let allowed = Set(expected.keys)
            .union(contract["dynamicBodyFields"] as! [String])
            .union(contract["optionalBodyFields"] as! [String])
        XCTAssertEqual(Set(body.keys).subtracting(allowed), [], "unexpected body fields", file: file, line: line)
    }

    // MARK: Contract

    func testAnonymousAndIdentifiedDeviceRegistrationMatchTheContract() async {
        let client = makeClient()
        await client.setPushToken(Contract.token)
        assertMatchesContract(transport.requests.last, "registerAnonymousDevice")
        let anonymousId = transport.json(transport.requests.last!)["anonymousId"] as? String

        await client.identify(email: "Jane@Example.com ", identityToken: identityToken)
        let identified = transport.requests(to: "/api/v1/push/app-devices").last
        assertMatchesContract(identified, "registerIdentifiedDevice")
        XCTAssertEqual(transport.json(identified!)["anonymousId"] as? String, anonymousId)
        XCTAssertEqual(transport.json(identified!)["appVersion"] as? String, "1.0")
    }

    func testTrackMatchesTheContract() async throws {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.track("workout_completed", properties: ["minutes": 30])

        let request = try XCTUnwrap(transport.requests(to: "/api/v1/app-events").last)
        assertMatchesContract(request, "trackEvents")
        let events = transport.json(request)["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["name"] as? String, "workout_completed")
        XCTAssertJSONEqual(events[0]["properties"], ["minutes": 30])
        XCTAssertFalse((events[0]["eventId"] as? String ?? "").isEmpty)
        XCTAssertEqual(events[0]["occurredAt"] as? String, "2026-10-14T17:46:40.000Z")
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testFeedAndInAppEventsMatchTheContract() async throws {
        transport.respond(path: "/api/v1/in-app/feed", status: 200, json: String(decoding: try Contract.data("feed-response.json"), as: UTF8.self))
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)

        let messages = try await client.fetchFeed(kind: .message)
        assertMatchesContract(transport.requests(to: "/api/v1/in-app/feed").last, "fetchFeed")
        XCTAssertEqual(messages.map(\.id), ["iam_modal", "iam_banner", "iam_card"])
        XCTAssertEqual(messages[0].resolvedFormat, .modal)
        XCTAssertEqual(messages[0].buttons[0], InAppButton(label: "Upgrade", action: .openUrl, url: "myapp://billing"))
        XCTAssertEqual(messages[0].buttons[1].action, .dismiss)
        XCTAssertEqual(messages[0].style.fontFamilies, ["Inter", "Arial"])
        XCTAssertEqual(messages[1].resolvedPosition, .top)
        XCTAssertEqual(messages[2].kind, .card)
        XCTAssertTrue(messages[2].pinned)

        let reported = await client.report(.displayed, messageId: "iam_modal")
        XCTAssertTrue(reported)
        assertMatchesContract(transport.requests.last, "reportInAppEvent")
    }

    func testResetUnregistersTheDeviceAndForgetsTheUser() async {
        let client = makeClient()
        await client.setPushToken(Contract.token)
        await client.identify(email: email, identityToken: identityToken)
        let before = await client.anonymousId

        await client.reset()

        assertMatchesContract(transport.requests.last, "removeDevice")
        let after = await client.anonymousId
        let storedEmail = await client.email
        XCTAssertNotEqual(before, after)
        XCTAssertNil(storedEmail)
        XCTAssertNil(store.string(forKey: "identityToken"))
    }

    func testPushPayloadsFromTheContractParseAndReportClicks() async throws {
        let apns = try Contract.object("push-payload-apns.json")
        let fromAPNs = try XCTUnwrap(PushPayload.parse(userInfo: apns))
        let fcm = try JSONSerialization.jsonObject(with: Contract.data("push-payload-fcm-data.json")) as! [String: String]
        let fromFCM = try XCTUnwrap(PushPayload.parse(data: fcm))
        XCTAssertEqual(fromAPNs, fromFCM)
        XCTAssertEqual(fromAPNs.url, "myapp://orders/123")
        XCTAssertEqual(fromAPNs.imageUrl, "https://cdn.example.com/box.png")

        XCTAssertNil(PushPayload.parse(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertNil(PushPayload.parse(data: ["title": "Other sender"]))
        XCTAssertNil(PushPayload.parse(data: ["pushSendId": "p", "deviceId": "d", "clickToken": "t", "eventsUrl": "javascript:alert(1)"]))

        let client = makeClient()
        await client.reportPush(.clicked, payload: fromAPNs)
        assertMatchesContract(transport.requests.last, "reportPushClicked")
        XCTAssertNil(transport.requests.last?.headers["x-sequenzy-key"])
    }

    func testAPNsTokenIsHexEncoded() {
        XCTAssertEqual(apnsTokenString(Data([0x00, 0xAB, 0x10, 0xFF])), "00ab10ff")
    }

    // MARK: Queue

    func testEventsTrackedBeforeIdentifyAreSentAfterwards() async {
        let client = makeClient()
        await client.track("viewed_onboarding")
        XCTAssertTrue(transport.requests(to: "/api/v1/app-events").isEmpty)
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 1)

        await client.identify(email: email, identityToken: identityToken)

        let sent = transport.requests(to: "/api/v1/app-events")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((transport.json(sent[0])["events"] as? [[String: Any]])?.first?["name"] as? String, "viewed_onboarding")
    }

    func testQueueSurvivesARestart() async {
        let first = makeClient()
        await first.track("a")
        await first.track("b")

        let second = makeClient()
        let queued = await second.queuedEventCount
        XCTAssertEqual(queued, 2)
    }

    func testLargeQueuesAreSentInBatchesOfTwenty() async {
        let client = makeClient()
        for index in 0..<25 { await client.track("event_\(index)") }
        await client.identify(email: email, identityToken: identityToken)

        let batches = transport.requests(to: "/api/v1/app-events").map { (transport.json($0)["events"] as! [Any]).count }
        XCTAssertEqual(batches, [20, 5])
    }

    func testQueueIsCappedAtOneHundredEvents() async {
        let client = makeClient()
        for index in 0..<105 { await client.track("event_\(index)") }
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 100)
    }

    func testRetryableFailuresKeepTheBatchAndBackOff() async {
        transport.respond(path: "/api/v1/app-events", status: 503, json: #"{"success":false}"#, times: 1)
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.track("a")
        var queued = await client.queuedEventCount
        XCTAssertEqual(queued, 1)

        // Inside the backoff window nothing is sent.
        await client.flush()
        XCTAssertEqual(transport.requests(to: "/api/v1/app-events").count, 1)

        clock.advance(2)
        await client.flush()
        queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(transport.requests(to: "/api/v1/app-events").count, 2)
        // The retry carries the same event id, so the server dedupes it.
        let ids = transport.requests(to: "/api/v1/app-events").map {
            ((transport.json($0)["events"] as! [[String: Any]])[0]["eventId"] as! String)
        }
        XCTAssertEqual(Set(ids).count, 1)
    }

    func testNetworkErrorsAreRetryable() async {
        struct Offline: Error {}
        var failures = 1
        transport.respond { request in
            guard request.url.path == "/api/v1/app-events", failures > 0 else { return nil }
            failures -= 1
            throw Offline()
        }
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.track("a")
        var queued = await client.queuedEventCount
        XCTAssertEqual(queued, 1)
        clock.advance(2)
        await client.flush()
        queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testPermanentFailuresAndPartialRejectionsDropTheBatch() async {
        transport.respond(path: "/api/v1/app-events", status: 400, json: #"{"success":false,"error":"bad"}"#, times: 1)
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.track("a")
        var queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)

        transport.respond(
            path: "/api/v1/app-events", status: 202,
            json: #"{"success":true,"accepted":0,"rejected":[{"index":0,"eventId":"x","error":"built-in"}]}"#, times: 1)
        await client.track("saas.purchase")
        queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testStaleEventsAreDropped() async {
        let client = makeClient()
        await client.track("old")
        clock.advance(SequenzyClient.maxEventAge + 1)
        await client.identify(email: email, identityToken: identityToken)
        XCTAssertTrue(transport.requests(to: "/api/v1/app-events").isEmpty)
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testSwitchingUsersDropsThePreviousUsersQueue() async {
        transport.respond(path: "/api/v1/app-events", status: 503, json: "{}")
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.track("jane_only")
        await client.identify(email: "bob@example.com", identityToken: "seq_wid_bob")
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    // MARK: Identity tokens

    func testRejectedTokenIsRefreshedOnceFromTheProvider() async {
        let calls = Counter()
        transport.respond { request in
            guard request.url.path == "/api/v1/app-events" else { return nil }
            let token = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["identityToken"] as? String
            if token == "seq_wid_fresh" { return nil }
            return SequenzyHTTPResponse(status: 403, body: Data(#"{"success":false,"code":"invalid_web_tracking_identity"}"#.utf8))
        }
        let client = makeClient(provider: { email in
            calls.increment()
            XCTAssertEqual(email, "jane@example.com")
            return "seq_wid_fresh"
        })
        await client.identify(email: email, identityToken: "seq_wid_expired")
        await client.track("a")

        XCTAssertEqual(calls.value, 1)
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(store.string(forKey: "identityToken"), "seq_wid_fresh")
    }

    func testProviderSuppliesTheTokenWhenIdentifyHasNone() async {
        let client = makeClient(provider: { _ in "seq_wid_from_backend" })
        await client.identify(email: email)
        await client.track("a")
        let sent = transport.requests(to: "/api/v1/app-events").last
        XCTAssertEqual(transport.json(sent!)["identityToken"] as? String, "seq_wid_from_backend")
    }

    func testRejectedTokenWithoutProviderKeepsEventsUntilTheNextIdentify() async {
        transport.respond(path: "/api/v1/app-events", status: 403, json: #"{"code":"invalid_web_tracking_identity"}"#, times: 1)
        let client = makeClient()
        await client.identify(email: email, identityToken: "seq_wid_expired")
        await client.track("a")
        await client.track("b")
        XCTAssertEqual(transport.requests(to: "/api/v1/app-events").count, 1)
        var queued = await client.queuedEventCount
        XCTAssertEqual(queued, 2)

        await client.identify(email: email, identityToken: identityToken)
        queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testFeedWithoutIdentityThrows() async {
        let client = makeClient()
        do {
            _ = try await client.fetchFeed()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SequenzyError, .notIdentified)
        }
    }

    // MARK: Races and bad input

    func testIdentifyDuringAnInFlightResetKeepsTheNewUser() async throws {
        let client = makeClient()
        await client.setPushToken(Contract.token)
        await client.identify(email: email, identityToken: identityToken)
        transport.gate("/api/v1/push/app-devices/remove")

        let reset = Task { await client.reset() }
        // Let reset reach the remove request, then sign in as Bob meanwhile.
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.identify(email: "bob@example.com", identityToken: "seq_wid_bob")
        transport.release()
        await reset.value

        let storedEmail = await client.email
        XCTAssertEqual(storedEmail, "bob@example.com")
        XCTAssertEqual(store.string(forKey: "identityToken"), "seq_wid_bob")
        // The device is registered for Bob again after the remove landed.
        let last = transport.requests(to: "/api/v1/push/app-devices").last
        XCTAssertEqual(transport.json(last!)["email"] as? String, "bob@example.com")
        XCTAssertGreaterThan(
            transport.requests.lastIndex { $0.url.path == "/api/v1/push/app-devices" }!,
            transport.requests.lastIndex { $0.url.path == "/api/v1/push/app-devices/remove" }!)
    }

    func testALateRejectionForThePreviousUserDoesNotTouchTheNewOne() async throws {
        transport.respond(path: "/api/v1/app-events", status: 403, json: #"{"code":"invalid_web_tracking_identity"}"#, times: 1)
        transport.gate("/api/v1/app-events")
        let client = makeClient()
        await client.identify(email: email, identityToken: "seq_wid_expired")
        let flush = Task { await client.track("jane_event") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.identify(email: "bob@example.com", identityToken: "seq_wid_bob")
        transport.release()
        await flush.value

        XCTAssertEqual(store.string(forKey: "identityToken"), "seq_wid_bob")
        await client.track("bob_event")
        let sent = transport.requests(to: "/api/v1/app-events").last.map { transport.json($0) }
        XCTAssertEqual(sent?["email"] as? String, "bob@example.com")
    }

    func testAFailingProviderIsNotAskedAgainForAMinute() async {
        struct Down: Error {}
        let calls = Counter()
        let client = makeClient(provider: { _ in
            calls.increment()
            throw Down()
        })
        await client.identify(email: email)
        await client.track("a")
        await client.track("b")
        XCTAssertEqual(calls.value, 1)
        clock.advance(SequenzyClient.providerRetryInterval + 1)
        await client.flush()
        XCTAssertEqual(calls.value, 2)
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 2)
    }

    func testEventsThatCannotBeSentAreDroppedAtTrack() async {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.track("nan", properties: ["value": .number(.nan)])
        await client.track("huge", properties: ["blob": .string(String(repeating: "x", count: 9_000))])
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(transport.requests(to: "/api/v1/app-events").isEmpty)
        await client.track("ok")
        XCTAssertEqual(transport.requests(to: "/api/v1/app-events").count, 1)
    }

    // MARK: Push registration

    func testPushRegistrationIsThrottledUntilTokenOrUserChanges() async {
        let client = makeClient()
        await client.setPushToken(Contract.token)
        await client.setPushToken(Contract.token)
        await client.registerPushIfNeeded()
        XCTAssertEqual(transport.requests(to: "/api/v1/push/app-devices").count, 1)

        clock.advance(SequenzyClient.pushRefreshInterval + 1)
        await client.registerPushIfNeeded()
        XCTAssertEqual(transport.requests(to: "/api/v1/push/app-devices").count, 2)

        await client.setPushToken("b" + Contract.token.dropFirst())
        XCTAssertEqual(transport.requests(to: "/api/v1/push/app-devices").count, 3)
    }

    func testRejectedIdentityStillRegistersTheDeviceAnonymously() async {
        transport.respond(path: "/api/v1/push/app-devices", status: 403, json: #"{"code":"invalid_web_tracking_identity"}"#, times: 1)
        let client = makeClient()
        await client.identify(email: email, identityToken: "seq_wid_expired")
        await client.setPushToken(Contract.token)
        let registrations = transport.requests(to: "/api/v1/push/app-devices")
        XCTAssertEqual(registrations.count, 2)
        XCTAssertNil(transport.json(registrations[1])["email"])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripsAndKeepsWholeNumbersIntegral() throws {
        let value: JSONValue = ["a": 30, "b": 1.5, "c": [true, nil, "x"], "d": ["e": "f"]]
        let data = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"a\":30"))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testHexColorsParse() {
        let color = parseHexColor("#4f46e5")
        XCTAssertEqual(color?.red ?? 0, 79.0 / 255, accuracy: 0.0001)
        XCTAssertNil(parseHexColor("blue"))
        XCTAssertNil(parseHexColor("#12345"))
    }
}

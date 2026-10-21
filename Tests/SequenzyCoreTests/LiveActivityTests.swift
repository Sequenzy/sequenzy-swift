import Foundation
import XCTest

@testable import SequenzyCore

extension SequenzyClientTests {
    static let liveActivitiesPath = "/api/v1/push/live-activities"
    static let liveActivitiesRemovePath = "/api/v1/push/live-activities/remove"

    func contractToken(_ name: String) -> String {
        (Contract.request(name)["body"] as! [String: Any])["token"] as! String
    }

    var pushToStartToken: LiveActivityToken {
        LiveActivityToken(
            kind: .pushToStart, activityType: "DeliveryAttributes",
            token: contractToken("registerLiveActivityPushToStart"))
    }

    var updateToken: LiveActivityToken {
        LiveActivityToken(
            kind: .update, activityType: "DeliveryAttributes", activityId: "order-1234",
            token: contractToken("registerLiveActivityUpdate"))
    }

    func testPushToStartTokenRegistersAnonymouslyPerContract() async {
        let client = makeClient()
        await client.registerLiveActivityToken(pushToStartToken)
        let request = transport.requests(to: Self.liveActivitiesPath).last
        assertMatchesContract(request, "registerLiveActivityPushToStart")
        let anonymousId = await client.anonymousId
        XCTAssertEqual(transport.json(request!)["anonymousId"] as? String, anonymousId)
        let stored1 = await client.liveActivityTokens
        XCTAssertEqual(stored1, [pushToStartToken])
    }

    func testUpdateTokenRegistersForTheIdentifiedContactWithTheDeviceToken() async {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.setPushToken(Contract.token)
        await client.registerLiveActivityToken(updateToken)
        let request = transport.requests(to: Self.liveActivitiesPath).last
        assertMatchesContract(request, "registerLiveActivityUpdate")
        XCTAssertEqual(transport.json(request!)["deviceToken"] as? String, Contract.token)
    }

    func testIdentifySendsStoredTokensAgainSoTheyLinkToTheContact() async {
        let client = makeClient()
        await client.registerLiveActivityToken(pushToStartToken)
        await client.identify(email: email, identityToken: identityToken)
        let registrations = transport.requests(to: Self.liveActivitiesPath)
        XCTAssertEqual(registrations.count, 2)
        XCTAssertNil(transport.json(registrations[0])["email"])
        XCTAssertEqual(transport.json(registrations[1])["email"] as? String, email)

        // Identifying the same user again does not resend.
        await client.identify(email: email)
        XCTAssertEqual(transport.requests(to: Self.liveActivitiesPath).count, 2)
    }

    func testSwitchingUsersWithoutResetMovesOnlyPushToStartTokens() async {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.registerLiveActivityToken(pushToStartToken)
        await client.registerLiveActivityToken(updateToken)
        let before = transport.requests(to: Self.liveActivitiesPath).count

        await client.identify(email: "bob@example.com", identityToken: "seq_wid_bob")
        let resent = transport.requests(to: Self.liveActivitiesPath).dropFirst(before)
        // Jane's running activity stays hers; only the device's push-to-start
        // token moves to Bob.
        XCTAssertEqual(resent.map { transport.json($0)["token"] as? String }, [pushToStartToken.token])
        let stored = await client.liveActivityTokens
        XCTAssertEqual(stored, [pushToStartToken])
    }

    func testANewerTokenReplacesTheStoredOneForTheSameTypeOrActivity() async {
        let client = makeClient()
        await client.registerLiveActivityToken(pushToStartToken)
        await client.registerLiveActivityToken(updateToken)
        let rotated = LiveActivityToken(kind: .pushToStart, activityType: "DeliveryAttributes", token: String(repeating: "e", count: 80))
        let otherType = LiveActivityToken(kind: .pushToStart, activityType: "GameAttributes", token: String(repeating: "c", count: 80))
        await client.registerLiveActivityToken(rotated)
        await client.registerLiveActivityToken(otherType)
        let stored2 = await client.liveActivityTokens
        XCTAssertEqual(stored2, [updateToken, rotated, otherType])
    }

    func testEndedActivitiesAreReportedOnceAndForgotten() async {
        let client = makeClient()
        await client.registerLiveActivityToken(updateToken)
        await client.liveActivityEnded(token: updateToken.token.uppercased())
        assertMatchesContract(transport.requests(to: Self.liveActivitiesRemovePath).last, "endLiveActivity")
        let stored3 = await client.liveActivityTokens
        XCTAssertEqual(stored3, [])

        await client.liveActivityEnded(token: updateToken.token)
        XCTAssertEqual(transport.requests(to: Self.liveActivitiesRemovePath).count, 1)
    }

    func testResetUnlinksTokensAndKeepsOnlyPushToStartForTheNewInstallation() async {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.registerLiveActivityToken(pushToStartToken)
        await client.registerLiveActivityToken(updateToken)
        let before = await client.anonymousId

        await client.reset()

        let removals = transport.requests(to: Self.liveActivitiesRemovePath)
        XCTAssertEqual(Set(removals.map { transport.json($0)["token"] as? String }), [pushToStartToken.token, updateToken.token])
        XCTAssertTrue(removals.allSatisfy { transport.json($0)["unlinkSubscriber"] as? Bool == true })
        let reRegistered = transport.requests(to: Self.liveActivitiesPath).last!
        XCTAssertEqual(transport.json(reRegistered)["token"] as? String, pushToStartToken.token)
        XCTAssertNil(transport.json(reRegistered)["email"])
        XCTAssertNotEqual(transport.json(reRegistered)["anonymousId"] as? String, before)
        let stored4 = await client.liveActivityTokens
        XCTAssertEqual(stored4, [pushToStartToken])
    }

    func testInvalidTokensAreNeverSentOrStored() async {
        let client = makeClient()
        for token in [
            LiveActivityToken(kind: .update, activityType: "DeliveryAttributes", token: String(repeating: "a", count: 80)),
            LiveActivityToken(kind: .update, activityType: "DeliveryAttributes", activityId: "-bad", token: String(repeating: "a", count: 80)),
            LiveActivityToken(kind: .pushToStart, activityType: "Délivery", token: String(repeating: "a", count: 80)),
            LiveActivityToken(kind: .pushToStart, activityType: "DeliveryAttributes", token: "abc"),
        ] {
            XCTAssertFalse(token.isValid)
            await client.registerLiveActivityToken(token)
        }
        XCTAssertTrue(transport.requests(to: Self.liveActivitiesPath).isEmpty)
        let stored5 = await client.liveActivityTokens
        XCTAssertEqual(stored5, [])
    }

    func testTokenDataIsHexEncodedAndPushToStartDropsTheActivityId() {
        let token = LiveActivityToken(kind: .pushToStart, activityType: "A", activityId: "order-1", token: Data([0xAB, 0x01] + Array(repeating: 0xFF, count: 30)))
        XCTAssertEqual(token.token, "ab01" + String(repeating: "ff", count: 30))
        XCTAssertNil(token.activityId)
        XCTAssertTrue(token.isValid)
    }
}

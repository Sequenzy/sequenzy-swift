import Foundation
import XCTest

@testable import SequenzyCore

extension SequenzyClientTests {
    func testScreensAndCommerceEventsAreTypedQueueEntries() async throws {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        await client.screen(" Pricing ", properties: ["plan": "pro"])
        await client.viewedProduct(CommerceProduct(providerProductId: "sku-1", title: "Shoe"))
        await client.addedToCart(CommerceCartLine(product: CommerceProduct(providerProductId: "sku-1"), quantity: 2))
        await client.track("custom_thing")
        let events = transport.requests(to: "/api/v1/app-events").map {
            (transport.json($0)["events"] as! [[String: Any]])[0]
        }
        XCTAssertEqual(events[0]["type"] as? String, "screen")
        XCTAssertEqual((events[0]["properties"] as? [String: Any])?["screen"] as? String, "Pricing")
        XCTAssertEqual(events[1]["type"] as? String, "commerce")
        XCTAssertEqual(events[1]["name"] as? String, "product_viewed")
        XCTAssertEqual(
            ((events[1]["properties"] as? [String: Any])?["product"] as? [String: Any])?["title"] as? String, "Shoe")
        XCTAssertEqual(
            ((events[2]["properties"] as? [String: Any])?["cartLine"] as? [String: Any])?["quantity"] as? Int, 2)
        XCTAssertNil(events[3]["type"])
        await client.screen("   ")
        let queued = await client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testProfileUpdatesMergeWaitForIdentifyAndSurviveAFailure() async throws {
        let client = makeClient()
        await client.setProfile(ProfileUpdate(firstName: .set("Jane"), attributes: ["goal": "run"]))
        await client.setProfile(ProfileUpdate(lastName: .clear, attributes: ["level": 3]))
        XCTAssertTrue(transport.requests(to: "/api/v1/app-attributes").isEmpty)
        transport.respond(path: "/api/v1/app-attributes", status: 503, json: "{}", times: 1)
        await client.identify(email: email, identityToken: identityToken)
        XCTAssertEqual(transport.requests(to: "/api/v1/app-attributes").count, 1)

        clock.advance(2)
        let restarted = makeClient()
        await restarted.flush()
        let sent = transport.requests(to: "/api/v1/app-attributes")
        XCTAssertEqual(sent.count, 2)
        let body = transport.json(sent[1])
        XCTAssertEqual(body["firstName"] as? String, "Jane")
        XCTAssertTrue(body["lastName"] is NSNull)
        XCTAssertJSONEqual(body["attributes"], ["goal": "run", "level": 3])
        await restarted.flush()
        XCTAssertEqual(transport.requests(to: "/api/v1/app-attributes").count, 2)
    }

    func testAProfileChangeMadeDuringASendIsNotLost() async throws {
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)
        transport.gate("/api/v1/app-attributes")
        let first = Task { await client.setProfile(ProfileUpdate(firstName: .set("Jane"))) }
        // Let the first send reach the network and park there.
        try await Task.sleep(nanoseconds: 100_000_000)
        await client.setProfile(ProfileUpdate(attributes: ["goal": "run"]))
        transport.release()
        await first.value
        let sent = transport.requests(to: "/api/v1/app-attributes")
        XCTAssertEqual(sent.count, 2)
        XCTAssertJSONEqual(transport.json(sent[1])["attributes"], ["goal": "run"])
        let stored = store.string(forKey: "profile")
        XCTAssertNil(stored)
    }

    func testResetForgetsAPendingProfile() async {
        let client = makeClient()
        await client.setProfile(ProfileUpdate(firstName: .set("Old")))
        await client.reset()
        await client.identify(email: email, identityToken: identityToken)
        XCTAssertTrue(transport.requests(to: "/api/v1/app-attributes").isEmpty)
    }

    func testSubscribePostsToAFormWithoutIdentifying() async throws {
        let client = makeClient()
        let result = await client.subscribe(
            SubscribeRequest(
                formId: "form_1", email: " new@example.com ", firstName: "Nia", phone: "+14155550123"))
        XCTAssertEqual(result, .success)
        let body = transport.json(try XCTUnwrap(transport.requests(to: "/api/v1/app-subscribe").first))
        XCTAssertEqual(body["formId"] as? String, "form_1")
        XCTAssertEqual(body["email"] as? String, "new@example.com")
        XCTAssertEqual(body["phone"] as? String, "+14155550123")
        let signedIn = await client.email
        XCTAssertNil(signedIn)
        transport.respond(path: "/api/v1/app-subscribe", status: 429, json: #"{"error":"Too many"}"#, times: 1)
        let limited = await client.subscribe(SubscribeRequest(formId: "form_1", email: "a@b.co"))
        XCTAssertEqual(limited, .failure(error: "Too many", retryable: true))
        let invalid = await client.subscribe(SubscribeRequest(formId: "form_1", email: "nope"))
        XCTAssertEqual(invalid, .failure(error: "Enter a valid email address", retryable: false))
    }

    func testFeedItemsDecodeNewFieldsAndTolerateUnknownValues() throws {
        struct Feed: Decodable { let messages: [InAppMessage] }
        let feed = try JSONDecoder().decode(Feed.self, from: Contract.data("feed-response.json"))
        let modal = try XCTUnwrap(feed.messages.first { $0.id == "iam_modal" })
        XCTAssertEqual(modal.eyebrow, "3 days left")
        XCTAssertEqual(modal.imagePlacement, .background)
        XCTAssertEqual(modal.position, .bottom)
        XCTAssertEqual(feed.messages.first { $0.id == "iam_card" }?.eyebrow, "")
        let future = Data(
            ##"{"id":"m","kind":"message","format":"carousel","position":"left","imagePlacement":"side","style":{"backgroundColor":"#ffffff","textColor":"#111827","mutedTextColor":"#4b5563","buttonColor":"#4f46e5","buttonTextColor":"#ffffff","cornerRadius":16,"buttonRadius":8,"fontFamily":"Inter"}}"##
                .utf8)
        let decoded = try JSONDecoder().decode(InAppMessage.self, from: future)
        XCTAssertNil(decoded.format)
        XCTAssertNil(decoded.position)
        XCTAssertNil(decoded.imagePlacement)
    }
}

import XCTest

@testable import SequenzyCore

/// Custom HTML in-app messages: the shared bridge contract
/// (contract/fixtures/in-app-html-bridge.json) and the html feed item.
final class InAppHtmlTests: XCTestCase {
    private func expected(_ message: InAppHtmlBridgeMessage) -> [String: Any] {
        func json(_ value: [String: JSONValue]) -> Any {
            let data = try! JSONEncoder().encode(JSONValue.object(value))
            return try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        switch message {
        case .close:
            return ["method": "close"]
        case .openUrl(let url, let external, let buttonId):
            var object: [String: Any] = ["method": "openUrl", "url": url, "external": external]
            if let buttonId { object["buttonId"] = buttonId }
            return object
        case .logClick(let buttonId):
            var object: [String: Any] = ["method": "logClick"]
            if let buttonId { object["buttonId"] = buttonId }
            return object
        case .track(let name, let properties):
            return ["method": "track", "name": name, "properties": json(properties)]
        case .setAttributes(let attributes):
            return ["method": "setAttributes", "attributes": json(attributes)]
        case .setName(let firstName, let lastName):
            var object: [String: Any] = ["method": "setName"]
            if let firstName { object["firstName"] = firstName }
            if let lastName { object["lastName"] = lastName }
            return object
        }
    }

    func testParsesTheContractBridgeMessages() throws {
        let fixture = try Contract.object("in-app-html-bridge.json")
        for entry in fixture["valid"] as! [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: entry["input"]!)
            let parsed = try XCTUnwrap(InAppHtmlBridgeMessage.parse(json: data), "\(entry["input"]!)")
            XCTAssertJSONEqual(expected(parsed), entry["expected"])
        }
        for input in fixture["invalid"] as! [Any] {
            let data = try JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])
            XCTAssertNil(InAppHtmlBridgeMessage.parse(json: data), "\(input)")
        }
        XCTAssertEqual(fixture["maxMessageBytes"] as? Int, InAppHtmlBridgeMessage.maxMessageBytes)
        XCTAssertEqual(fixture["maxCallsPerDisplay"] as? Int, InAppHtmlBridgeMessage.maxCallsPerDisplay)
        let oversized = Data("{\"__sequenzyInApp\":1,\"method\":\"track\",\"args\":{\"name\":\"\(String(repeating: "x", count: 40_000))\"}}".utf8)
        XCTAssertNil(InAppHtmlBridgeMessage.parse(json: oversized))
    }

    func testAllowsOnlyHttpsAndAppLinks() throws {
        let urls = try Contract.object("in-app-html-bridge.json")["urls"] as! [String: [String]]
        for url in urls["allowed"]! { XCTAssertTrue(InAppHtmlBridgeMessage.isAllowedUrl(url), url) }
        for url in urls["blocked"]! { XCTAssertFalse(InAppHtmlBridgeMessage.isAllowedUrl(url), url) }
    }

    func testDecodesHtmlMessagesAndOldPayloads() throws {
        struct Feed: Decodable { let messages: [InAppMessage] }
        let feed = try JSONDecoder().decode(Feed.self, from: Contract.data("feed-response-html.json"))
        let message = try XCTUnwrap(feed.messages.first)
        XCTAssertEqual(message.format, .html)
        XCTAssertTrue(message.showCloseButton)
        XCTAssertTrue(message.html?.contains("brazeBridge.logClick") == true)

        // Items without the html fields (older servers, native formats).
        let native = try JSONDecoder().decode(Feed.self, from: Contract.data("feed-response.json"))
        XCTAssertNil(native.messages[0].html)
        XCTAssertFalse(native.messages[0].showCloseButton)
    }
}

/// Feed and event requests for custom HTML messages, against requests.json.
extension SequenzyClientTests {
    func testFetchesHtmlOnlyWhenAskedAndReportsButtonIds() async throws {
        transport.respond(
            path: "/api/v1/in-app/feed", status: 200,
            json: String(decoding: try Contract.data("feed-response-html.json"), as: UTF8.self))
        let client = makeClient()
        await client.identify(email: email, identityToken: identityToken)

        let messages = try await client.fetchFeed(kind: .message, formats: [.modal, .banner, .fullscreen, .html])
        assertMatchesContract(transport.requests(to: "/api/v1/in-app/feed").last, "fetchFeedWithHtml")
        XCTAssertEqual(messages.map(\.id), ["iam_html"])

        let reported = await client.report(.clicked, messageId: "iam_html", buttonId: "0")
        XCTAssertTrue(reported)
        assertMatchesContract(transport.requests.last, "reportInAppHtmlClick")

        // Invalid ids are left out rather than failing the report.
        _ = await client.report(.clicked, messageId: "iam_html", buttonId: "<b>")
        XCTAssertNil(transport.json(transport.requests.last!)["buttonId"])
    }
}

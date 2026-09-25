import XCTest
@testable import TransitGo

final class SupportLinksTests: XCTestCase {

    func testPublicPagesLiveUnderYayalinDotComApp() {
        XCTAssertEqual(SupportLinks.support.absoluteString, "https://yayalin.com/app/support/")
        XCTAssertEqual(SupportLinks.privacy.absoluteString, "https://yayalin.com/app/privacy/")
        XCTAssertEqual(SupportLinks.terms.absoluteString, "https://yayalin.com/app/terms/")
        XCTAssertEqual(SupportLinks.email, "app@yayalin.com")
    }

    func testMailtoCarriesVersionsButNoLocation() throws {
        let url = try XCTUnwrap(SupportLinks.mailto(appVersion: "0.1.0", os: "iOS 26.5"))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:app@yayalin.com"))
        let text = url.absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(text.contains("0.1.0") && text.contains("iOS 26.5"))
    }

    func testFeedbackNeedsAMessageAndAnOptionalValidEmail() {
        var d = FeedbackDraft()
        XCTAssertFalse(d.canSend)                       // empty
        d.message = "   \n  "
        XCTAssertFalse(d.canSend)                       // only whitespace
        d.message = "307 到站時間不準"
        XCTAssertTrue(d.canSend)                        // contact is optional
        d.contact = "not an email"
        XCTAssertFalse(d.canSend)
        for bad in ["a@b", "@b.com", "a@.com", "a@b.", "a b@c.com", "a@@b.com"] { d.contact = bad; XCTAssertFalse(d.contactIsValid, bad) }
        for good in ["me@example.com", " me@example.com ", "a.b+c@mail.example.tw"] { d.contact = good; XCTAssertTrue(d.contactIsValid, good) }
    }

    func testMessageIsCappedAtTheLimit() {
        var d = FeedbackDraft()
        d.message = String(repeating: "字", count: 5000)
        XCTAssertEqual(d.trimmedMessage.count, FeedbackDraft.maxMessage)
    }

    func testPayloadShapeForReportsEndpoint() {
        var d = FeedbackDraft()
        d.kind = .idea
        d.message = "  想要小工具  "
        d.contact = " me@example.com "
        let p = d.payload(appVersion: "0.1.0", os: "iOS 26.5", device: "DEV-1")
        XCTAssertEqual(p["type"] as? String, "feedback_idea")
        XCTAssertEqual(p["message"] as? String, "想要小工具")
        XCTAssertEqual(p["appVersion"] as? String, "0.1.0")
        XCTAssertEqual(p["device"] as? String, "DEV-1")
        XCTAssertEqual((p["context"] as? [String: String])?["contact"], "me@example.com")
        XCTAssertNil(p["lat"]); XCTAssertNil(p["lon"])   // never location
        d.contact = ""
        XCTAssertNil(d.payload(appVersion: "v", os: "o", device: "d")["context"])
    }
}

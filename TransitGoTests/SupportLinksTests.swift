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

    // MARK: feedback needs a verified email

    private func draft(message: String = "307 到站時間不準", email: String = "me@example.com", code: String = "123456") -> FeedbackDraft {
        var d = FeedbackDraft(); d.message = message; d.email = email; d.code = code; return d
    }

    func testFeedbackNeedsMessageEmailAndSixDigitCode() {
        XCTAssertTrue(draft().canSend)
        XCTAssertFalse(draft(message: "  \n ").canSend)     // nothing written
        XCTAssertFalse(draft(email: "").canSend)            // the email is required now
        XCTAssertFalse(draft(code: "").canSend)             // not verified
        XCTAssertFalse(draft(code: "12345").canSend)        // 5 digits
        XCTAssertFalse(draft(code: "1234567").canSend)
        XCTAssertFalse(draft(code: "12a456").canSend)
    }

    func testEmailValidation() {
        for bad in ["", "not an email", "a@b", "@b.com", "a@.com", "a@b.", "a b@c.com", "a@@b.com"] {
            XCTAssertFalse(draft(email: bad).emailIsValid, bad)
        }
        for good in ["me@example.com", " ME@Example.com ", "a.b+c@mail.example.tw"] {
            XCTAssertTrue(draft(email: good).emailIsValid, good)
        }
        XCTAssertEqual(draft(email: " ME@Example.com ").trimmedEmail, "me@example.com")
    }

    func testAnEmailIsEnoughToRequestACode() {
        var d = FeedbackDraft()
        XCTAssertFalse(d.canRequestCode)
        d.email = "me@example.com"
        XCTAssertTrue(d.canRequestCode)                     // no message or code needed yet
    }

    func testMessageIsCappedAtTheLimit() {
        XCTAssertEqual(draft(message: String(repeating: "字", count: 5000)).trimmedMessage.count, FeedbackDraft.maxMessage)
    }

    func testBodiesMatchTheWebsitesOwnContactFormRPCs() {
        var d = draft(message: "  想要小工具  ", email: " Me@Example.com ", code: " 123456 ")
        d.kind = .idea
        XCTAssertEqual(d.codeRequestBody(), ["p_email": "me@example.com", "p_purpose": "contact"])
        let body = d.submitBody(appVersion: "0.1.0", os: "iOS 26.6")
        XCTAssertEqual(body["p_name"], "TransitGo App")
        XCTAssertEqual(body["p_email"], "me@example.com")
        XCTAssertEqual(body["p_code"], "123456")
        let message = body["p_message"] ?? ""
        XCTAssertTrue(message.hasPrefix("【TransitGo App・功能建議】"), message)
        XCTAssertTrue(message.contains("App 0.1.0") && message.contains("iOS 26.6") && message.hasSuffix("想要小工具"), message)
        XCTAssertFalse(message.contains("lat") || message.contains("lon"))
    }

    func testRPCAnswersAreUnderstood() {
        // submit_contact returns the case number as a JSON string, or null for a wrong / used / expired code.
        XCTAssertEqual(SiteFeedbackService.caseNumber(fromSubmitBody: Data("\"C-20260926-0007\"".utf8)), "C-20260926-0007")
        XCTAssertNil(SiteFeedbackService.caseNumber(fromSubmitBody: Data("null".utf8)))
        XCTAssertNil(SiteFeedbackService.caseNumber(fromSubmitBody: Data("\"\"".utf8)))
        XCTAssertNil(SiteFeedbackService.caseNumber(fromSubmitBody: Data()))
        // request_email_code raises 'too_many_requests' / 'invalid_email'; PostgREST wraps them as {"message":...}.
        XCTAssertEqual(SiteFeedbackService.error(fromRPCBody: Data(#"{"code":"P0001","message":"too_many_requests"}"#.utf8), status: 400), .tooManyRequests)
        XCTAssertEqual(SiteFeedbackService.error(fromRPCBody: Data(#"{"code":"P0001","message":"invalid_email"}"#.utf8), status: 400), .invalidEmail)
        XCTAssertEqual(SiteFeedbackService.error(fromRPCBody: Data("<html>"  .utf8), status: 502), .network)
    }
}

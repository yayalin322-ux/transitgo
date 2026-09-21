import XCTest
@testable import TransitGo

final class ShareLinkTests: XCTestCase {

    // MARK: token + address

    func testTokensHaveTheServersShapeAndAreUnique() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let t = ShareLink.makeToken()
            XCTAssertEqual(t.count, 22)
            XCTAssertTrue(ShareLink.isValid(t), t)
            XCTAssertNotNil(t.range(of: "^[A-Za-z0-9_-]{22}$", options: .regularExpression), "must match the server's rule: \(t)")
            seen.insert(t)
        }
        XCTAssertEqual(seen.count, 500)
    }

    func testValidityRejectsWrongLengthAndCharacters() {
        XCTAssertFalse(ShareLink.isValid("short"))
        XCTAssertFalse(ShareLink.isValid(String(repeating: "a", count: 23)))
        XCTAssertFalse(ShareLink.isValid("../../etc/passwd/////"))
        XCTAssertFalse(ShareLink.isValid("abcdefghijklmnopqrstu+"))
    }

    func testTheLinkAddressIsBackendSlashSSlashToken() throws {
        let base = try XCTUnwrap(URL(string: "http://MacBook-Neo-2.local:8787"))
        XCTAssertEqual(ShareLink.url(token: "abc", base: base)?.absoluteString, "http://MacBook-Neo-2.local:8787/s/abc")
        XCTAssertNil(ShareLink.url(token: "abc", base: nil), "no backend configured → no link")
    }

    func testPreparedLinkIsMadeInstantlyWithoutAnyNetwork() throws {
        let route = try Nav.walkBusMrtWalk()
        // BackendConfig.baseURL comes from Info.plist (set in the test bundle's host app)
        switch ShareTripService.prepare(route: route, title: "前往南京復興") {
        case .success(let p):
            XCTAssertTrue(ShareLink.isValid(p.token))
            XCTAssertTrue(p.url.absoluteString.hasSuffix("/s/\(p.token)"))
            XCTAssertFalse(p.body.isEmpty)
        case .failure(let f):
            XCTAssertEqual(f, .backendUnavailable, "only acceptable failure: no BackendHost configured in this build")
        }
    }

    // MARK: background upload (no network: the transport is injected)

    private func prepared() throws -> ShareTripService.Prepared {
        ShareTripService.Prepared(token: ShareLink.makeToken(), url: URL(string: "http://x.local/s/t")!, body: Data("{}".utf8))
    }
    private let base = URL(string: "http://x.local:8787")!

    private final class Script: @unchecked Sendable {
        var statuses: [Int?]
        var requests: [URLRequest] = []
        var slept: [TimeInterval] = []
        init(_ s: [Int?]) { statuses = s }
    }

    private func run(_ s: Script, _ p: ShareTripService.Prepared) async -> ShareUploader.Outcome {
        await ShareUploader.upload(p, base: base, transport: { req in
            s.requests.append(req)
            return s.statuses.isEmpty ? nil : s.statuses.removeFirst()
        }, sleep: { s.slept.append($0) })
    }

    func testFirstAttemptSucceedsWithNoWaiting() async throws {
        let s = Script([200]); let p = try prepared()
        let out = await run(s, p)
        XCTAssertEqual(out, .uploaded)
        XCTAssertEqual(s.requests.count, 1)
        XCTAssertEqual(s.requests[0].httpMethod, "PUT")
        XCTAssertEqual(s.requests[0].url?.path, "/v1/shares/\(p.token)")
        XCTAssertEqual(s.requests[0].httpBody, p.body)
        XCTAssertTrue(s.slept.isEmpty, "no delay before the first attempt")
    }

    func testASleepingServerIsRetriedUntilItAnswers() async throws {
        let s = Script([nil, 503, nil, 200])        // offline, waking (503), timeout, then up
        let out = await run(s, try prepared())
        XCTAssertEqual(out, .uploaded)
        XCTAssertEqual(s.requests.count, 4)
        XCTAssertEqual(s.slept, [2, 4, 8], "backs off between attempts")
    }

    func testRateLimitedAndRequestTimeoutAreRetriedToo() async throws {
        let s = Script([429, 408, 200])
        let out = await run(s, try prepared())
        XCTAssertEqual(out, .uploaded)
        XCTAssertEqual(s.requests.count, 3)
    }

    func testARequestTheServerRefusesForGoodIsNotRetried() async throws {
        let s = Script([400, 200])
        let out = await run(s, try prepared())
        XCTAssertEqual(out, .failed)
        XCTAssertEqual(s.requests.count, 1, "a 400 will never succeed: stop at once")
    }

    func testGivesUpAfterTheWholeScheduleAndReportsFailure() async throws {
        let s = Script([])                          // always offline
        let out = await run(s, try prepared())
        XCTAssertEqual(out, .failed)
        XCTAssertEqual(s.requests.count, ShareUploader.schedule.count)
        XCTAssertGreaterThanOrEqual(ShareUploader.schedule.reduce(0, +), 85, "keeps trying about 90 s — longer than a cold start")
    }

    func testAnUploadRetryReusesTheSameTokenSoTheServerCanDeduplicate() async throws {
        let s = Script([nil, 200]); let p = try prepared()
        _ = await run(s, p)
        XCTAssertEqual(Set(s.requests.compactMap { $0.url?.path }).count, 1)
    }

    func testNoBackendMeansFailedWithoutAnyRequest() async throws {
        let s = Script([200])
        let out = await ShareUploader.upload(try prepared(), base: nil, transport: { _ in s.requests.append(URLRequest(url: self.base)); return 200 }, sleep: { _ in })
        XCTAssertEqual(out, .failed)
        XCTAssertTrue(s.requests.isEmpty)
    }
}

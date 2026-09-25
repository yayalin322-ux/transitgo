import XCTest
@testable import TransitGo

final class FeedbackTicketsTests: XCTestCase {

    // What the site's get_app_feedback returns (add_app_feedback.sql), timestamps as Postgres prints them.
    private let json = """
    {"case_number":"A260926-0007","kind":"bug","status":"waiting","created_at":"2026-09-26T03:04:05.123456+00:00",
     "messages":[
       {"direction":"inbound","body":"307 到站時間不準","created_at":"2026-09-26T03:04:05.5+00:00"},
       {"direction":"outbound","body":"謝謝，我們查一下","created_at":"2026-09-26T04:00:00+00:00"},
       {"direction":"inbound","body":"好的","created_at":"2026-09-26T04:05:00.123+08:00"}]}
    """

    private func ticket(_ n: String, created: TimeInterval = 0, replies: Int = 0, seen: Int = 0, status: String = "new") -> FeedbackTicket {
        var t = FeedbackTicket(caseNumber: n, token: "tok-\(n)", kind: "bug", createdAt: Date(timeIntervalSince1970: created))
        t.replyCount = replies; t.seenReplyCount = seen; t.status = status
        return t
    }
    private func thread(replies: Int, status: String = "waiting") -> FeedbackThread {
        let msgs = (0..<replies).map { _ in #"{"direction":"outbound","body":"回覆","created_at":"2026-09-26T04:00:00+00:00"}"# }
        return FeedbackThread.decode(Data(#"{"case_number":"X","kind":"bug","status":"\#(status)","messages":[\#(msgs.joined(separator: ","))]}"#.utf8))!
    }

    func testDecodesThePostgresThread() throws {
        let t = try XCTUnwrap(FeedbackThread.decode(Data(json.utf8)))
        XCTAssertEqual(t.caseNumber, "A260926-0007")
        XCTAssertEqual(t.statusText, "等你回覆")
        XCTAssertEqual(t.messages.count, 3)
        XCTAssertEqual(t.replyCount, 1)                                   // only "outbound" is our reply
        XCTAssertTrue(t.messages[1].isReply)
        XCTAssertNotNil(t.messages[0].createdAt)                          // 6-digit / 1-digit / no fractional seconds all parse
        XCTAssertNotNil(t.messages[1].createdAt)
        XCTAssertNotNil(t.messages[2].createdAt)
        XCTAssertNil(FeedbackThread.decode(Data("null".utf8)))            // unknown token
        XCTAssertNil(FeedbackThread.decode(Data("<html>".utf8)))
    }

    func testStatusWording() {
        XCTAssertEqual(FeedbackThread.statusText("new"), "已收到")
        XCTAssertEqual(FeedbackThread.statusText("in_progress"), "處理中")
        XCTAssertEqual(FeedbackThread.statusText("waiting"), "等你回覆")
        XCTAssertEqual(FeedbackThread.statusText("resolved"), "已結束")
        XCTAssertEqual(FeedbackThread.statusText("???"), "已收到")
    }

    func testSubmitAnswersOldAndNew() {
        XCTAssertEqual(SiteFeedbackService.receipt(fromSubmitBody: Data(#"{"case_number":"A1","token":"abc"}"#.utf8)), .init(caseNumber: "A1", token: "abc"))
        XCTAssertEqual(SiteFeedbackService.receipt(fromSubmitBody: Data("\"C-0007\"".utf8)), .init(caseNumber: "C-0007", token: nil))   // contact-form fallback
        XCTAssertNil(SiteFeedbackService.receipt(fromSubmitBody: Data("null".utf8)))                       // wrong code
        XCTAssertNil(SiteFeedbackService.receipt(fromSubmitBody: Data(#"{"case_number":""}"#.utf8)))
    }

    func testTheTicketSQLNotInstalledYetIsRecognisedSoFeedbackStillArrives() {
        let missing = Data(#"{"code":"PGRST202","message":"Could not find the function public.submit_app_feedback(...) in the schema cache"}"#.utf8)
        XCTAssertTrue(SiteFeedbackService.isMissingFunction(body: missing, status: 404))
        XCTAssertFalse(SiteFeedbackService.isMissingFunction(body: Data(#"{"message":"invalid_email"}"#.utf8), status: 400))
        XCTAssertFalse(SiteFeedbackService.isMissingFunction(body: missing, status: 200))
    }

    func testTicketBodyMatchesTheTicketRPC() {
        var d = FeedbackDraft(); d.kind = .idea; d.message = " 想要小工具 "; d.email = " Me@Example.com "; d.code = "123456"
        let b = d.appFeedbackBody(appVersion: "0.1.0", os: "iOS 26.6")
        XCTAssertEqual(b["p_kind"], "idea")
        XCTAssertEqual(b["p_message"], "想要小工具")            // just what was written; the site adds its own labelling
        XCTAssertEqual(b["p_email"], "me@example.com")
        XCTAssertEqual(b["p_code"], "123456")
        XCTAssertEqual(b["p_app_version"], "0.1.0")
    }

    func testStoreKeepsNewestFirstAndCapsTheList() {
        let store = FeedbackTicketStore(vault: InMemoryVault())
        for i in 0..<(FeedbackTicketStore.maxTickets + 5) { store.add(ticket("A\(i)", created: TimeInterval(i))) }
        let all = store.load()
        XCTAssertEqual(all.count, FeedbackTicketStore.maxTickets)
        XCTAssertEqual(all.first?.caseNumber, "A\(FeedbackTicketStore.maxTickets + 4)")     // newest first
        store.add(ticket("A10", created: 10, replies: 2))
        XCTAssertEqual(store.load().filter { $0.caseNumber == "A10" }.count, 1)             // same case replaces, never duplicates
    }

    func testANewReplyIsUnreadUntilTheThreadIsViewed() {
        let store = FeedbackTicketStore(vault: InMemoryVault())
        store.add(ticket("A1"))
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.apply(thread(replies: 1), to: "A1"), 1)        // refresh in the background: 1 new reply
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.apply(thread(replies: 1), to: "A1"), 0)        // nothing new the second time → no second notification
        XCTAssertEqual(store.unreadCount, 1)
        store.markSeen("A1")
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.apply(thread(replies: 2), to: "A1", viewing: true), 1)   // read while looking at it: seen at once
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testStatusFollowsTheServerAndResolvedIsNotOpen() {
        let store = FeedbackTicketStore(vault: InMemoryVault())
        store.add(ticket("A1"))
        store.apply(thread(replies: 1, status: "resolved"), to: "A1")
        XCTAssertEqual(store.load().first?.status, "resolved")
        XCTAssertFalse(store.load().first!.isOpen)
    }

    func testUnknownCaseIsIgnored() {
        let store = FeedbackTicketStore(vault: InMemoryVault())
        XCTAssertEqual(store.apply(thread(replies: 3), to: "nope"), 0)
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: chat: photos and ending the conversation

    func testThreadCarriesPhotosAndWhoEndedIt() throws {
        let json = #"""
        {"case_number":"A1","kind":"bug","status":"resolved","closed_by":"user","created_at":"2026-09-26T03:00:00+00:00",
         "messages":[{"direction":"inbound","body":"截圖","created_at":"2026-09-26T03:01:00+00:00",
                      "attachments":["https://x.supabase.co/storage/v1/object/public/app-feedback-files/T/a.jpg","https://x.supabase.co/storage/v1/object/public/app-feedback-files/T/b.jpg"]},
                     {"direction":"outbound","body":"收到","created_at":"2026-09-26T03:02:00+00:00","attachments":[]}]}
        """#
        let t = try XCTUnwrap(FeedbackThread.decode(Data(json.utf8)))
        XCTAssertEqual(t.messages[0].attachments.count, 2)
        XCTAssertEqual(t.messages[0].attachments.first?.lastPathComponent, "a.jpg")
        XCTAssertTrue(t.messages[1].attachments.isEmpty)
        XCTAssertTrue(t.isClosed)
        XCTAssertTrue(t.canReopen)               // the person ended it → the person may reopen
        XCTAssertFalse(t.endedByUs)
    }

    func testAConversationWeEndedCannotBeReopenedByThePerson() throws {
        let t = try XCTUnwrap(FeedbackThread.decode(Data(#"{"case_number":"A1","kind":"bug","status":"resolved","closed_by":"owner","messages":[]}"#.utf8)))
        XCTAssertTrue(t.isClosed)
        XCTAssertFalse(t.canReopen)
        XCTAssertTrue(t.endedByUs)
    }

    func testAnOpenConversationAndOldServerAnswersStillDecode() throws {
        let open = try XCTUnwrap(FeedbackThread.decode(Data(#"{"case_number":"A1","kind":"idea","status":"waiting","messages":[{"direction":"inbound","body":"hi","created_at":"2026-09-26T03:00:00+00:00"}]}"#.utf8)))
        XCTAssertFalse(open.isClosed)
        XCTAssertFalse(open.canReopen)
        XCTAssertTrue(open.messages[0].attachments.isEmpty)     // no "attachments" key at all (server v1)
        XCTAssertNil(open.closedBy)
    }

    func testClosedConversationErrorIsRecognised() {
        XCTAssertEqual(SiteFeedbackService.error(fromRPCBody: Data(#"{"code":"P0001","message":"conversation_closed"}"#.utf8), status: 400), .conversationClosed)
    }

    func testPhotoPathsLiveUnderTheTicketsOwnTokenAndAreUnique() {
        let a = FeedbackPhoto.path(token: "TOKEN"), b = FeedbackPhoto.path(token: "TOKEN")
        XCTAssertTrue(a.hasPrefix("TOKEN/") && a.hasSuffix(".jpg"))
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains(".."))
        XCTAssertLessThanOrEqual(a.count, 200)                  // the site refuses longer paths
        XCTAssertEqual(FeedbackPhoto.maxPerMessage, 3)
    }

    func testAPhotoIsShrunkToFitTheUploadLimit() throws {
        // A big noisy picture: 4000×3000 px.
        let size = CGSize(width: 4000, height: 3000)
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            for i in 0..<400 {
                UIColor(hue: CGFloat(i % 50) / 50, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: (i * 97) % 3800, y: (i * 53) % 2800, width: 200, height: 200))
            }
        }
        let data = try XCTUnwrap(FeedbackPhoto.jpeg(from: image))
        XCTAssertLessThanOrEqual(data.count, FeedbackPhoto.maxBytes)
        let out = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(out.size.width, out.size.height), 1600)            // longest side capped
        XCTAssertNil(FeedbackPhoto.jpeg(from: image, maxDimension: 1600, maxBytes: 100))  // cannot fit → nil, never a broken file
    }
}

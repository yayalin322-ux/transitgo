import Foundation
import BackgroundTasks
import UserNotifications

/// "我的回饋": the tickets this phone filed and whether we have replied. The reply itself also goes to the person's Email,
/// which is the reliable channel; this is what makes it visible in the app (a red dot, and a local notification when the
/// app finds a reply while it is not on screen). Real push notifications need a paid Apple Developer account — see AppDelegate.
@MainActor
@Observable
final class FeedbackInbox {
    static let shared = FeedbackInbox()

    private(set) var tickets: [FeedbackTicket] = []
    var unreadCount: Int { tickets.filter(\.hasUnread).count }
    private let store: FeedbackTicketStore

    init(store: FeedbackTicketStore = FeedbackTicketStore()) {
        self.store = store
        tickets = store.load()
    }

    func reload() {
        tickets = store.load()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount) }
    }

    /// Remembers a just-filed ticket (only when the site handed back a token — the old contact-form path has none).
    func register(_ receipt: SiteFeedbackService.Receipt, kind: FeedbackKind) {
        guard let token = receipt.token else { return }
        store.add(FeedbackTicket(caseNumber: receipt.caseNumber, token: token, kind: kind.rawValue, createdAt: Date()))
        reload()
    }

    /// Asks the site about every ticket that can still change. Returns how many NEW replies were found; with
    /// `notifyIfNew` a local notification is posted for each ticket that got one.
    @discardableResult
    func refresh(notifyIfNew: Bool = false) async -> Int {
        var found = 0
        for ticket in store.load().filter(\.isOpen).prefix(10) {
            guard let thread = try? await SiteFeedbackService.thread(token: ticket.token) else { continue }
            let new = store.apply(thread, to: ticket.caseNumber)
            found += new
            if new > 0, notifyIfNew { await Self.notify(caseNumber: ticket.caseNumber) }
        }
        reload()
        return found
    }

    /// Opens one ticket: fetches it fresh and marks its replies as seen.
    func open(_ ticket: FeedbackTicket) async -> FeedbackThread? {
        let thread = try? await SiteFeedbackService.thread(token: ticket.token)
        if let thread { store.apply(thread, to: ticket.caseNumber, viewing: true) } else { store.markSeen(ticket.caseNumber) }
        reload()
        return thread
    }

    /// A message, optionally with photos: each photo is uploaded first, then the message names them.
    func sendFollowUp(_ ticket: FeedbackTicket, body: String, photos: [Data] = []) async throws {
        var paths: [String] = []
        for jpeg in photos { paths.append(try await SiteFeedbackService.uploadPhoto(token: ticket.token, jpeg: jpeg)) }
        try await SiteFeedbackService.sendFollowUp(token: ticket.token, body: body, attachments: paths)
    }

    func close(_ ticket: FeedbackTicket) async throws { try await SiteFeedbackService.close(token: ticket.token) }
    func reopen(_ ticket: FeedbackTicket) async throws { try await SiteFeedbackService.reopen(token: ticket.token) }

    static func notify(caseNumber: String) async {
        let content = UNMutableNotificationContent()
        content.title = "意見回饋有新回覆"
        content.body = "案件 \(caseNumber)：點一下查看回覆"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "feedback-\(caseNumber)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Best-effort check for replies while the app is closed. iOS decides when (if ever) to run it, so this is a bonus on top of
/// the Email and the check on every app launch, not a promise.
enum FeedbackBackgroundRefresh {
    static let identifier = "tw.yayalin.TransitGo.feedback-refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                _ = await FeedbackInbox.shared.refresh(notifyIfNew: true)
                schedule()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Only worth asking iOS for when there is a ticket that a reply could still arrive for.
    @MainActor static func scheduleIfNeeded() {
        if FeedbackInbox.shared.tickets.contains(where: \.isOpen) { schedule() }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

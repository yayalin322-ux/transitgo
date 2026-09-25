import Foundation
import Security

/// One conversation with us, as the site's `get_app_feedback` returns it.
struct FeedbackThread: Decodable, Equatable {
    struct Message: Decodable, Equatable, Identifiable {
        let direction: String          // "inbound" = you, "outbound" = our reply
        let body: String
        let createdAt: Date?
        var id: String { "\(direction)|\(createdAt?.timeIntervalSince1970 ?? 0)|\(body.hashValue)" }
        var isReply: Bool { direction == "outbound" }

        enum CodingKeys: String, CodingKey { case direction, body, createdAt = "created_at" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            direction = try c.decode(String.self, forKey: .direction)
            body = try c.decode(String.self, forKey: .body)
            createdAt = FeedbackThread.date(try c.decodeIfPresent(String.self, forKey: .createdAt))
        }
    }

    let caseNumber: String
    let kind: String
    let status: String                 // new | in_progress | waiting | resolved
    let messages: [Message]

    enum CodingKeys: String, CodingKey { case caseNumber = "case_number", kind, status, messages }

    var replyCount: Int { messages.filter(\.isReply).count }

    /// Words for the status the way a person would say it.
    var statusText: String { Self.statusText(status) }
    static func statusText(_ status: String) -> String {
        switch status {
        case "new": "已收到"
        case "in_progress": "處理中"
        case "waiting": "等你回覆"
        case "resolved": "已解決"
        default: "已收到"
        }
    }

    /// `null` (unknown token) or anything unreadable → nil.
    static func decode(_ data: Data) -> FeedbackThread? { try? JSONDecoder().decode(FeedbackThread.self, from: data) }

    /// Postgres timestamps: "2026-09-26T03:04:05.123456+00:00" — fractional seconds of any length, or none.
    static func date(_ raw: String?) -> Date? {
        guard var s = raw else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let digits = s[s.index(after: dot)..<end]
            s.replaceSubrange(dot..<end, with: "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// A feedback this phone filed. The token is a secret: it is the only thing that lets the phone read the replies.
struct FeedbackTicket: Codable, Equatable, Identifiable {
    var caseNumber: String
    var token: String
    var kind: String
    var createdAt: Date
    var status: String = "new"
    /// How many of our replies exist / how many the person has already looked at.
    var replyCount = 0
    var seenReplyCount = 0

    var id: String { caseNumber }
    var hasUnread: Bool { replyCount > seenReplyCount }
    var isOpen: Bool { status != "resolved" }
}

/// Where the tickets live. A protocol so the rules below are tested without the real Keychain.
protocol TicketVault {
    func read() -> Data?
    func write(_ data: Data)
}

struct KeychainVault: TicketVault {
    var service = "tw.yayalin.TransitGo.feedback"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "tickets"]
    }
    func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    func write(_ data: Data) {
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock   // readable by a background refresh too
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

final class InMemoryVault: TicketVault {
    private var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) { self.data = data }
}

struct FeedbackTicketStore {
    static let maxTickets = 30
    var vault: TicketVault = KeychainVault()

    func load() -> [FeedbackTicket] {
        guard let data = vault.read(), let list = try? JSONDecoder().decode([FeedbackTicket].self, from: data) else { return [] }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ tickets: [FeedbackTicket]) {
        let kept = Array(tickets.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maxTickets))
        if let data = try? JSONEncoder().encode(kept) { vault.write(data) }
    }

    /// Adds a ticket (or replaces the one with the same case number).
    func add(_ ticket: FeedbackTicket) {
        var all = load().filter { $0.caseNumber != ticket.caseNumber }
        all.append(ticket)
        save(all)
    }

    /// Applies what the server says about one ticket. `viewing` = the person is looking at the thread right now, so its
    /// replies count as seen. Returns how many NEW replies arrived (0 if none) so the caller can notify.
    @discardableResult
    func apply(_ thread: FeedbackThread, to caseNumber: String, viewing: Bool = false) -> Int {
        var all = load()
        guard let i = all.firstIndex(where: { $0.caseNumber == caseNumber }) else { return 0 }
        let previous = all[i].replyCount
        all[i].status = thread.status
        all[i].replyCount = thread.replyCount
        if viewing { all[i].seenReplyCount = thread.replyCount }
        save(all)
        return max(0, thread.replyCount - previous)
    }

    func markSeen(_ caseNumber: String) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.caseNumber == caseNumber }) else { return }
        all[i].seenReplyCount = all[i].replyCount
        save(all)
    }

    var unreadCount: Int { load().filter(\.hasUnread).count }
}

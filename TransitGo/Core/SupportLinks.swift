import Foundation

/// Where the public support / legal pages live (static site, see /site in the repo) and how a feedback message is
/// packaged for the backend's /v1/reports.
enum SupportLinks {
    static let base = URL(string: "https://yayalin.com/app")!
    static var support: URL { base.appendingPathComponent("support/") }
    static var privacy: URL { base.appendingPathComponent("privacy/") }
    static var terms: URL { base.appendingPathComponent("terms/") }
    static let email = "app@yayalin.com"

    /// mailto: with a subject and the details that make a bug reproducible (no location, no identifiers).
    static func mailto(subject: String = "交通即時查 意見回饋", appVersion: String, os: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: "\n\n——\nApp 版本：\(appVersion)\n系統：\(os)"),
        ]
        return c.url
    }
}

enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug, idea, other
    var id: String { rawValue }
    var label: String {
        switch self { case .bug: "問題回報"; case .idea: "功能建議"; case .other: "其他" }
    }
}

/// What the feedback form sends. Pure, so its limits and validation are tested without a network.
struct FeedbackDraft: Equatable {
    static let maxMessage = 1000

    var kind: FeedbackKind = .bug
    var message = ""
    var contact = ""      // optional: an email the user chooses to leave so we can answer

    var trimmedMessage: String { String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxMessage)) }
    var trimmedContact: String { contact.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A contact address is optional, but if one is typed it must look like an email — a typo would make it useless.
    var contactIsValid: Bool {
        let c = trimmedContact
        if c.isEmpty { return true }
        let parts = c.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !c.contains(" ")
    }

    var canSend: Bool { !trimmedMessage.isEmpty && contactIsValid }

    func payload(appVersion: String, os: String, device: String) -> [String: Any] {
        var p: [String: Any] = [
            "type": "feedback_" + kind.rawValue,
            "message": trimmedMessage,
            "appVersion": appVersion,
            "os": os,
            "device": device,
        ]
        if !trimmedContact.isEmpty { p["context"] = ["contact": trimmedContact] }
        return p
    }
}

enum FeedbackService {
    enum Failure: Error { case notConfigured, rejected }

    static func send(_ draft: FeedbackDraft) async throws {
        guard let base = BackendConfig.baseURL else { throw Failure.notConfigured }
        let os = "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
        var req = URLRequest(url: base.appendingPathComponent("v1/reports"), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: draft.payload(appVersion: BackendConfig.appVersion, os: os, device: BackendConfig.deviceID))
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.rejected }
    }
}

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

/// What the feedback form sends. Pure, so its rules are tested without a network.
///
/// Feedback goes into the same pipeline as the yayalin.com contact form: a verified Email (a 6-digit code mailed to it),
/// a case number back, replies by Email from the site's inbox.
struct FeedbackDraft: Equatable {
    static let maxMessage = 1000

    var kind: FeedbackKind = .bug
    var message = ""
    var email = ""
    var code = ""

    var trimmedMessage: String { String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxMessage)) }
    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The reply address is required (that is how we answer, and what the code is mailed to), so it must look like one.
    var emailIsValid: Bool {
        let c = trimmedEmail
        let parts = c.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !c.contains(" ")
    }
    var codeIsValid: Bool { trimmedCode.count == 6 && trimmedCode.allSatisfy(\.isNumber) }

    var canRequestCode: Bool { emailIsValid }
    var canSend: Bool { !trimmedMessage.isEmpty && emailIsValid && codeIsValid }

    /// The text the inbox shows: which kind, which build, then what the person wrote.
    func inboxMessage(appVersion: String, os: String) -> String {
        "【TransitGo App・\(kind.label)】App \(appVersion)・\(os)\n\n\(trimmedMessage)"
    }

    /// Body of the site's `submit_contact` RPC.
    func submitBody(appVersion: String, os: String) -> [String: String] {
        ["p_name": "TransitGo App", "p_email": trimmedEmail, "p_message": inboxMessage(appVersion: appVersion, os: os), "p_code": trimmedCode]
    }

    /// Body of the site's `request_email_code` RPC (purpose "contact" — the same one the website's contact form uses).
    func codeRequestBody() -> [String: String] { ["p_email": trimmedEmail, "p_purpose": "contact"] }
}

enum SiteFeedbackError: Error, Equatable {
    case notConfigured, invalidEmail, tooManyRequests, wrongCode, network
}

enum SiteFeedbackService {
    /// The website's public Supabase (the same values its own pages ship to every visitor's browser).
    static var baseURL: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "SiteSupabaseHost") as? String,
              !host.isEmpty, !host.hasPrefix("$(") else { return nil }
        return URL(string: "https://\(host)")
    }
    static var key: String? {
        guard let k = Bundle.main.object(forInfoDictionaryKey: "SiteSupabaseKey") as? String, !k.isEmpty, !k.hasPrefix("$(") else { return nil }
        return k
    }

    /// PostgREST reports the RPC's `raise exception 'x'` as {"message":"x"} with HTTP 400.
    static func error(fromRPCBody data: Data, status: Int) -> SiteFeedbackError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        if message.contains("too_many_requests") { return .tooManyRequests }
        if message.contains("invalid_email") { return .invalidEmail }
        return .network
    }

    /// `submit_contact` answers with the case number, or `null` when the code was wrong / used / expired.
    static func caseNumber(fromSubmitBody data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    static func requestCode(_ draft: FeedbackDraft) async throws {
        let (data, status) = try await call("request_email_code", body: draft.codeRequestBody())
        guard (200..<300).contains(status) else { throw error(fromRPCBody: data, status: status) }
    }

    /// Returns the case number.
    static func submit(_ draft: FeedbackDraft) async throws -> String {
        let os = "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
        let (data, status) = try await call("submit_contact", body: draft.submitBody(appVersion: BackendConfig.appVersion, os: os))
        guard (200..<300).contains(status) else { throw error(fromRPCBody: data, status: status) }
        guard let number = caseNumber(fromSubmitBody: data) else { throw SiteFeedbackError.wrongCode }
        return number
    }

    private static func call(_ function: String, body: [String: String]) async throws -> (Data, Int) {
        guard let base = baseURL, let key else { throw SiteFeedbackError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/\(function)"), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { throw SiteFeedbackError.network }
    }
}

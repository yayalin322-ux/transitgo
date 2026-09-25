import Foundation
import UIKit

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

    /// Body of the site's `submit_app_feedback` RPC (the ticket system: case number, priority, replies).
    func appFeedbackBody(appVersion: String, os: String) -> [String: String] {
        ["p_kind": kind.rawValue, "p_message": trimmedMessage, "p_email": trimmedEmail, "p_code": trimmedCode,
         "p_app_version": appVersion, "p_os": os]
    }

    /// Body of the site's `request_email_code` RPC. Purpose "app" makes the code mail look like the app's own (sender
    /// app@yayalin.com); "contact" is the older shared purpose, used as a fallback until the site knows "app".
    func codeRequestBody(purpose: String = "app") -> [String: String] { ["p_email": trimmedEmail, "p_purpose": purpose] }
}

enum SiteFeedbackError: Error, Equatable {
    case notConfigured, invalidEmail, tooManyRequests, wrongCode, conversationClosed, invalidPurpose, network
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
        if message.contains("invalid_purpose") { return .invalidPurpose }
        if message.contains("conversation_closed") { return .conversationClosed }
        return .network
    }

    /// What a successful submit hands back: the case number, and (ticket system only) the token that lets this phone read
    /// the replies. The old `submit_contact` answered with just the case number as a JSON string.
    struct Receipt: Equatable { let caseNumber: String; let token: String? }

    /// `submit_app_feedback` answers {"case_number":…,"token":…}; a wrong / used / expired code is `null`.
    static func receipt(fromSubmitBody data: Data) -> Receipt? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let s = value as? String, !s.isEmpty { return Receipt(caseNumber: s, token: nil) }
        if let o = value as? [String: Any], let n = o["case_number"] as? String, !n.isEmpty {
            let t = o["token"] as? String
            return Receipt(caseNumber: n, token: (t?.isEmpty == false) ? t : nil)
        }
        return nil
    }

    /// Kept for the old string answer.
    static func caseNumber(fromSubmitBody data: Data) -> String? { receipt(fromSubmitBody: data)?.caseNumber }

    /// PostgREST says a function is not there yet (the ticket SQL has not been run on the site's database): HTTP 404 with
    /// code PGRST202 / "Could not find the function".
    static func isMissingFunction(body: Data, status: Int) -> Bool {
        guard status == 404 || status == 400 else { return false }
        let text = String(data: body, encoding: .utf8) ?? ""
        return text.contains("PGRST202") || text.contains("Could not find the function")
    }

    static func requestCode(_ draft: FeedbackDraft) async throws {
        let (data, status) = try await call("request_email_code", body: draft.codeRequestBody(purpose: "app"))
        if (200..<300).contains(status) { return }
        // The site has not been taught the "app" purpose yet: use the shared one so feedback keeps working.
        guard error(fromRPCBody: data, status: status) == .invalidPurpose else { throw error(fromRPCBody: data, status: status) }
        let (data2, status2) = try await call("request_email_code", body: draft.codeRequestBody(purpose: "contact"))
        guard (200..<300).contains(status2) else { throw error(fromRPCBody: data2, status: status2) }
    }

    /// Files the feedback as a ticket (so replies can come back to this phone). Until the site's ticket SQL is installed it
    /// falls back to the contact-form pipeline: the feedback still arrives, just without in-app replies.
    static func submit(_ draft: FeedbackDraft) async throws -> Receipt {
        let os = "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
        let (data, status) = try await call("submit_app_feedback", body: draft.appFeedbackBody(appVersion: BackendConfig.appVersion, os: os))
        if isMissingFunction(body: data, status: status) {
            let (legacy, legacyStatus) = try await call("submit_contact", body: draft.submitBody(appVersion: BackendConfig.appVersion, os: os))
            guard (200..<300).contains(legacyStatus) else { throw error(fromRPCBody: legacy, status: legacyStatus) }
            guard let receipt = receipt(fromSubmitBody: legacy) else { throw SiteFeedbackError.wrongCode }
            return receipt
        }
        guard (200..<300).contains(status) else { throw error(fromRPCBody: data, status: status) }
        guard let receipt = receipt(fromSubmitBody: data) else { throw SiteFeedbackError.wrongCode }
        return receipt
    }

    /// The conversation for one ticket, or nil when the token is unknown.
    static func thread(token: String) async throws -> FeedbackThread? {
        let (data, status) = try await call("get_app_feedback", body: ["p_token": token])
        guard (200..<300).contains(status) else { throw error(fromRPCBody: data, status: status) }
        return FeedbackThread.decode(data)
    }

    /// A message in the conversation, optionally with photos (paths from `uploadPhoto`).
    static func sendFollowUp(token: String, body: String, attachments: [String] = []) async throws {
        var params: [String: Any] = ["p_token": token, "p_body": body]
        if !attachments.isEmpty { params["p_attachments"] = attachments }
        let (data, status) = try await call("add_app_feedback_message", body: params)
        guard (200..<300).contains(status) else { throw error(fromRPCBody: data, status: status) }
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? Bool) == true else { throw SiteFeedbackError.network }
    }

    /// End the conversation (the person may reopen it later).
    static func close(token: String) async throws {
        try await boolCall("close_app_feedback", token: token)
    }

    /// Reopen a conversation the person ended themselves. A conversation WE ended cannot be reopened (the site says false).
    static func reopen(token: String) async throws {
        try await boolCall("reopen_app_feedback", token: token)
    }

    private static func boolCall(_ function: String, token: String) async throws {
        let (data, status) = try await call(function, body: ["p_token": token])
        guard (200..<300).contains(status) else { throw error(fromRPCBody: data, status: status) }
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? Bool) == true else { throw SiteFeedbackError.conversationClosed }
    }

    /// Uploads one photo into this ticket's folder on the site's storage and returns its path for `sendFollowUp`.
    static func uploadPhoto(token: String, jpeg: Data) async throws -> String {
        guard let base = baseURL, let key else { throw SiteFeedbackError.notConfigured }
        let path = FeedbackPhoto.path(token: token)
        var req = URLRequest(url: base.appendingPathComponent("storage/v1/object/\(FeedbackPhoto.bucket)/\(path)"), timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: jpeg)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 400 || code == 401 || code == 403 { throw SiteFeedbackError.conversationClosed }   // the site only accepts photos into an OPEN ticket
            guard (200..<300).contains(code) else { throw SiteFeedbackError.network }
            return path
        } catch let e as SiteFeedbackError { throw e } catch { throw SiteFeedbackError.network }
    }

    private static func call(_ function: String, body: [String: Any]) async throws -> (Data, Int) {
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

/// Photos in a feedback conversation: where they are stored and how a picture is prepared for upload.
enum FeedbackPhoto {
    static let bucket = "app-feedback-files"
    static let maxPerMessage = 3
    static let maxBytes = 4_000_000            // the site's bucket accepts 5 MB; stay well under

    /// `<token>/<random>.jpg` — the site only accepts uploads under the ticket's own token, and the path is unguessable.
    static func path(token: String) -> String { "\(token)/\(UUID().uuidString.lowercased()).jpg" }

    /// JPEG, longest side ≤ `maxDimension`, compressed until it fits `maxBytes`; nil if it cannot be made small enough
    /// (a truncated image is never sent).
    static func jpeg(from image: UIImage, maxDimension: CGFloat = 1600, maxBytes: Int = FeedbackPhoto.maxBytes) -> Data? {
        let longest = max(image.size.width, image.size.height)
        var scaled = image
        if longest > maxDimension {
            let factor = maxDimension / longest
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
            scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }
}

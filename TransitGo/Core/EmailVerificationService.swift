import Foundation

/// Requests the 6-digit Email verification code used by place reviews and business-landmark
/// claims (see transitgo-server's POST /v1/email-code/request — it borrows yayalin.com's own
/// mail sending, this backend has no mail service of its own). Verifying the code isn't a
/// separate step from here: it's checked server-side at the moment the review/landmark is
/// actually submitted (see PlaceReviewService.submit / UserLandmarkService.submit).
enum EmailVerificationService {
    enum RequestResult { case sent, invalidEmail, tooManyRequests, failed }

    static func requestCode(email: String) async -> RequestResult {
        guard let base = BackendConfig.baseURL else { return .failed }
        var req = URLRequest(url: base.appendingPathComponent("v1/email-code/request"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return .failed }
        switch status {
        case 200: return .sent
        case 400: return .invalidEmail
        case 429: return .tooManyRequests
        default: return .failed
        }
    }
}

import Foundation

enum TDXError: LocalizedError {
    case notConfigured
    case auth(String)
    case network
    case http(status: Int, body: String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未設定 TDX API 金鑰（Config/Secrets.xcconfig）"
        case .auth(let m): return "TDX 認證失敗：\(m)"
        case .network: return "網路連線異常，請稍後再試"
        case .http(let s, _) where s == 429 || s == 503: return "查詢有點頻繁，稍等幾秒會自動再試"
        case .http(let s, _): return "運輸資料平台回應異常（\(s)）"
        case .decoding: return "資料解析失敗"
        }
    }

    /// True when the failure is transient rate-limiting — worth auto-retrying.
    var isRateLimited: Bool {
        if case .http(let s, _) = self { return s == 429 || s == 503 }
        return false
    }
}

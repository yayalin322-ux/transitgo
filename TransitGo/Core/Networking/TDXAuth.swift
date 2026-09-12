import Foundation

/// OAuth2 client-credentials token manager for TDX. Caches the token until shortly before expiry
/// and de-duplicates concurrent refreshes.
actor TDXAuth {
    static let shared = TDXAuth()

    private let tokenURL = URL(string: "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token")!
    private var token: String?
    private var expiresAt: Date = .distantPast
    private var refreshTask: Task<String, Error>?

    func validToken() async throws -> String {
        if let token, Date() < expiresAt.addingTimeInterval(-120) {
            return token
        }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { () throws -> String in
            defer { refreshTask = nil }
            return try await fetchToken()
        }
        refreshTask = task
        return try await task.value
    }

    private func fetchToken() async throws -> String {
        let creds = AppSecrets.tdx
        guard creds.isConfigured else { throw TDXError.notConfigured }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: creds.clientID),
            URLQueryItem(name: "client_secret", value: creds.clientSecret),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TDXError.network
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TDXError.auth(String(data: data, encoding: .utf8) ?? "未知錯誤")
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        token = decoded.accessToken
        expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        return decoded.accessToken
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }
}

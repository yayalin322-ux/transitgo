import SwiftUI

@MainActor
@Observable
final class AnnouncementService {
    static let shared = AnnouncementService()

    private(set) var announcements: [Announcement] = []
    private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private let storeKey = "announcements.cache"
    private let lastReadKey = "announcements.lastReadID"
    private var deviceTokenHex: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var isConfigured: Bool { BackendConfig.isConfigured }

    var unreadCount: Int {
        let lastRead = defaults.integer(forKey: lastReadKey)
        return announcements.filter { $0.id > lastRead && $0.isActiveNow && $0.severity != "info" }.count
    }

    init() {
        if let data = defaults.data(forKey: storeKey),
           let cached = try? decoder.decode([Announcement].self, from: data) {
            announcements = cached
        }
    }

    func active(for categories: Set<String>) -> [Announcement] {
        announcements
            .filter { $0.isActiveNow && $0.matches(categories) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func markAllRead() {
        if let maxID = announcements.map(\.id).max() {
            defaults.set(maxID, forKey: lastReadKey)
        }
    }

    // MARK: networking

    func refresh() async {
        guard let base = BackendConfig.baseURL else { return }
        do {
            let url = base.appendingPathComponent("v1/announcements")
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try decoder.decode(AnnouncementListResponse.self, from: data)
            announcements = decoded.announcements.sorted { $0.createdAt > $1.createdAt }
            if let encoded = try? JSONEncoder().encode(announcements) {
                defaults.set(encoded, forKey: storeKey)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerDevice(token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceTokenHex = hex
        guard let base = BackendConfig.baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("v1/devices"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": hex, "platform": "ios", "appVersion": BackendConfig.appVersion,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Best-effort diagnostic report. Fire-and-forget.
    nonisolated func report(type: String, message: String, context: [String: String]? = nil) {
        guard let base = BackendConfig.baseURL else { return }
        Task {
            var payload: [String: Any] = [
                "type": type,
                "message": message,
                "os": "iOS " + ProcessInfo.processInfo.operatingSystemVersionString,
                "appVersion": BackendConfig.appVersion,
            ]
            if let context { payload["context"] = context }
            var req = URLRequest(url: base.appendingPathComponent("v1/reports"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Installs the `Diagnostics` sink so networking-layer failures get reported.
    static func installDiagnostics() {
        Diagnostics.sink = { type, message, context in
            AnnouncementService.shared.report(type: type, message: message, context: context)
        }
    }
}

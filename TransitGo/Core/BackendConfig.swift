import Foundation
import UIKit

enum BackendConfig {
    /// Stable per-install identifier (resets only if the app is deleted+reinstalled) —
    /// used to enforce "one review per device" server-side. Not used for any tracking
    /// beyond that; never sent anywhere except our own backend.
    static var deviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }

    static var baseURL: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "BackendHost") as? String else { return nil }
        return url(forHost: host)
    }

    /// Where share links are opened: SHARE_BASE_HOST (e.g. `yayalin.com/app`, a proxy in front of the backend that serves the
    /// share page under the website's own domain) when it is set, otherwise the backend itself. Only the LINK uses this;
    /// uploading the trip still goes straight to the backend.
    static var shareBaseURL: URL? {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "ShareBaseHost") as? String, let u = shareBaseURL(fromHost: raw) { return u }
        return baseURL
    }

    static func shareBaseURL(fromHost raw: String) -> URL? {
        let host = raw.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("$(") else { return nil }
        return url(forHost: host)
    }

    /// `host` as written in BACKEND_HOST: a bare host[:port] (http for a computer on the local network, https otherwise) or a
    /// full URL. The "is this local?" test looks at the HOST NAME only — `MacBook.local:8787` ends in `:8787`, so a plain
    /// hasSuffix(".local") on the whole string missed it and the app spoke https to a plain-http server.
    static func url(forHost raw: String) -> URL? {
        let host = raw.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, host != "$(BACKEND_HOST)" else { return nil }
        if host.hasPrefix("http://") || host.hasPrefix("https://") { return URL(string: host) }
        return URL(string: "\(isLocalNetwork(host: host) ? "http" : "https")://\(host)")
    }

    static func isLocalNetwork(host: String) -> Bool {
        let name = (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
        if name == "localhost" || name.hasSuffix(".local") || name.hasPrefix("127.") || name.hasPrefix("10.") || name.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if name.hasPrefix("172."), let second = name.split(separator: ".").dropFirst().first.flatMap({ Int($0) }) { return (16...31).contains(second) }
        return false
    }

    static var isConfigured: Bool { baseURL != nil }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

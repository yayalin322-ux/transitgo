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
        guard var host = Bundle.main.object(forInfoDictionaryKey: "BackendHost") as? String else { return nil }
        host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, host != "$(BACKEND_HOST)" else { return nil }
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            return URL(string: host)
        }
        let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.")
            || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasSuffix(".local")
        return URL(string: "\(isLocal ? "http" : "https")://\(host)")
    }

    static var isConfigured: Bool { baseURL != nil }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

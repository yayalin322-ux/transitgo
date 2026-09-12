import Foundation

/// De-duplicated, rate-limited failure reporting hook. The app installs `sink`
/// (posting to the backend); targets that don't (e.g. the widget) simply no-op.
enum Diagnostics {
    /// (type, message, context) -> Void
    nonisolated(unsafe) static var sink: ((String, String, [String: String]?) -> Void)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reported = Set<String>()
    nonisolated(unsafe) private static var count = 0

    static func noteFailure(path: String, kind: String, detail: String) {
        guard sink != nil else { return }
        lock.lock()
        let key = "\(path)|\(kind)"
        let firstTime = reported.insert(key).inserted
        let underCap = count < 5
        if firstTime && underCap { count += 1 }
        lock.unlock()
        guard firstTime, underCap else { return }
        sink?("app-\(kind)", detail, ["path": path])
    }
}

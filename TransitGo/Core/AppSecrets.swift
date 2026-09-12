import Foundation

/// Reads the TDX credentials that XcodeGen injects into Info.plist from `Config/Secrets.xcconfig`.
enum AppSecrets {
    struct TDXCredentials {
        let clientID: String
        let clientSecret: String
        var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty && clientID != "your-client-id" }
    }

    static var tdx: TDXCredentials {
        let id = Bundle.main.object(forInfoDictionaryKey: "TDXClientID") as? String ?? ""
        let secret = Bundle.main.object(forInfoDictionaryKey: "TDXClientSecret") as? String ?? ""
        return TDXCredentials(clientID: id, clientSecret: secret)
    }
}

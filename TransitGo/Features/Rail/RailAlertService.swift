import Foundation

struct RailAlert: Identifiable, Hashable {
    let system: String       // 台鐵 / 高鐵
    let title: String
    let detail: String
    var id: String { system + title }
}

/// Fetches TRA/THSR operating-status directly from TDX. Only abnormal alerts are surfaced;
/// "全線營運正常" produces nothing.
@MainActor
@Observable
final class RailAlertService {
    static let shared = RailAlertService()

    private(set) var alerts: [RailAlert] = []
    private var lastFetch: Date = .distantPast

    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastFetch) > 120 else { return }
        lastFetch = Date()

        var found: [RailAlert] = []

        if let tra: TRAAlertResponse = try? await TDXClient.shared.get("v3/Rail/TRA/Alert") {
            for a in tra.alerts where isAbnormal(a.title, status: a.status) {
                found.append(RailAlert(system: "台鐵", title: a.title ?? "", detail: a.description ?? ""))
            }
        }
        if let thsr: [THSRAlert] = try? await TDXClient.shared.get("v2/Rail/THSR/AlertInfo") {
            for a in thsr where isAbnormal(a.title, alertID: a.alertID) {
                found.append(RailAlert(system: "高鐵", title: a.title ?? "", detail: a.description ?? ""))
            }
        }
        alerts = found
    }

    private func isAbnormal(_ title: String?, status: Int? = nil, alertID: String? = nil) -> Bool {
        guard let title, !title.isEmpty else { return false }
        if title.contains("正常") || title.localizedCaseInsensitiveContains("normal") { return false }
        if let status, status == 1 { return false }
        if let alertID, alertID == "00000000-0000-0000-0000-000000000000" { return false }
        return true
    }
}

// MARK: - DTOs

private struct TRAAlertResponse: Decodable {
    let alerts: [TRAAlert]
    enum CodingKeys: String, CodingKey { case alerts = "Alerts" }
}

private struct TRAAlert: Decodable {
    let title: String?
    let description: String?
    let status: Int?
    enum CodingKeys: String, CodingKey {
        case title = "Title", description = "Description", status = "Status"
    }
}

private struct THSRAlert: Decodable {
    let alertID: String?
    let title: String?
    let description: String?
    enum CodingKeys: String, CodingKey {
        case alertID = "AlertID", title = "Title", description = "Description"
    }
}

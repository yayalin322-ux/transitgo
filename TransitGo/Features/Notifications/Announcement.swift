import SwiftUI

struct Announcement: Codable, Identifiable, Hashable {
    let id: Int
    let category: String    // metro | rail | bus | general
    let severity: String    // info | warning | critical
    let title: String
    let body: String
    let source: String
    let createdAt: Date
    let expiresAt: Date?

    var isActiveNow: Bool { expiresAt.map { $0 > .now } ?? true }

    var categoryLabel: String {
        switch category {
        case "metro": return "捷運"
        case "rail": return "台鐵 / 高鐵"
        case "bus": return "公車"
        default: return "一般"
        }
    }

    var color: Color {
        switch severity {
        case "critical": return .red
        case "warning": return .orange
        default: return .blue
        }
    }

    var icon: String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    func matches(_ categories: Set<String>) -> Bool {
        categories.contains(category) || category == "general"
    }
}

struct AnnouncementListResponse: Codable {
    let announcements: [Announcement]
}

import SwiftUI

/// Compact banner of active announcements + live rail alerts for the given categories.
/// Renders nothing when there is nothing to show.
struct AnnouncementBanner: View {
    let categories: Set<String>
    var includeRailAlerts = false

    @State private var service = AnnouncementService.shared
    @State private var railAlerts = RailAlertService.shared

    private var items: [BannerItem] {
        var out: [BannerItem] = service.active(for: categories).map {
            BannerItem(id: "a\($0.id)", color: $0.color, icon: $0.icon,
                       title: $0.title, body: $0.body)
        }
        if includeRailAlerts {
            let known = Set(out.map(\.title))
            for a in railAlerts.alerts where !known.contains(a.title) {
                out.append(BannerItem(id: a.id, color: .orange,
                                      icon: "exclamationmark.triangle.fill",
                                      title: "\(a.system)：\(a.title)", body: a.detail))
            }
        }
        return out
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.icon).foregroundStyle(item.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.footnote.weight(.semibold))
                            if !item.body.isEmpty {
                                Text(item.body).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }

    private struct BannerItem: Identifiable {
        let id: String
        let color: Color
        let icon: String
        let title: String
        let body: String
    }
}

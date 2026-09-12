import SwiftUI

struct AnnouncementsView: View {
    @State private var service = AnnouncementService.shared
    @State private var railAlerts = RailAlertService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !railAlerts.alerts.isEmpty {
                    Section("即時營運狀態") {
                        ForEach(railAlerts.alerts) { a in
                            VStack(alignment: .leading, spacing: 3) {
                                Label("\(a.system)：\(a.title)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                                if !a.detail.isEmpty {
                                    Text(a.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                let anns = service.announcements.filter(\.isActiveNow)
                if anns.isEmpty && railAlerts.alerts.isEmpty {
                    ContentUnavailableView("目前沒有通知", systemImage: "bell.slash",
                                           description: Text(service.isConfigured
                                                            ? "台鐵、高鐵營運正常，也沒有其他公告。"
                                                            : "尚未設定通知伺服器（Config/Secrets.xcconfig 的 BACKEND_BASE_URL）。"))
                } else {
                    ForEach(anns) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: a.icon).foregroundStyle(a.color)
                                Text(a.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(a.categoryLabel).font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: Capsule())
                            }
                            if !a.body.isEmpty {
                                Text(a.body).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(a.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("即時通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable {
                await service.refresh()
                await railAlerts.refresh(force: true)
            }
            .task {
                await service.refresh()
                await railAlerts.refresh(force: true)
                service.markAllRead()
            }
        }
    }
}

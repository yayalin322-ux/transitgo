import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var feedStatus: CrowdingProvider.FeedStatus?
    @State private var checking = false
    @AppStorage(HabitLog.enabledKey) private var habitsEnabled = true
    @State private var confirmClearHabits = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("學習我的習慣", isOn: $habitsEnabled)
                    Button("清除學習資料", role: .destructive) { confirmClearHabits = true }
                } header: {
                    Text("個人化")
                } footer: {
                    Text("記下你查過哪些旅程與時段，在首頁「現在常去」建議。資料只存在這支手機上，不會上傳；關閉後不再記錄也不再建議。")
                }
                .confirmationDialog("清除所有學習資料？", isPresented: $confirmClearHabits, titleVisibility: .visible) {
                    Button("清除", role: .destructive) { HabitLog.shared.clear() }
                    Button("取消", role: .cancel) {}
                }

                Section {
                    Toggle("顯示示範資料", isOn: $settings.crowdingDemoMode)
                } header: {
                    Text("擁擠度")
                } footer: {
                    Text("雙北聯營公車的車上擁擠度來自臺北市公車動態資訊中心；其他縣市與公路客運無此資料。開啟本選項後，App 會為每輛車產生示範用的擁擠程度（徽章標示「示範」），僅在官方來源中斷時方便預覽介面。")
                }

                Section {
                    LabeledContent("來源更新時間") {
                        if checking {
                            ProgressView()
                        } else if let s = feedStatus {
                            Text(s.updateTime.map {
                                $0.formatted(date: .abbreviated, time: .shortened)
                            } ?? "無法取得")
                            .foregroundStyle(s.isLive ? .green : .orange)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    if let s = feedStatus {
                        LabeledContent("車輛筆數", value: "\(s.recordCount)")
                        LabeledContent("狀態", value: s.isLive ? "更新中" : "來源異常")
                    }
                    Button("重新檢查") { Task { await check() } }
                        .disabled(checking)
                } header: {
                    Text("擁擠度資料來源狀態")
                } footer: {
                    Text("來源：臺北市公車動態資訊中心\ntcgbusfs.blob.core.windows.net/blobbus/BusSeatEvent.gz")
                        .font(.caption2)
                }

                SupportSection()
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await check() }
        }
    }

    private func check() async {
        checking = true
        feedStatus = await CrowdingProvider.shared.feedStatus()
        checking = false
    }
}

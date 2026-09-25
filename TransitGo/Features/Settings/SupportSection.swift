import SwiftUI

/// 設定 › 支援與法律: feedback form, the public support / privacy / terms pages, and the two facts a support
/// request needs (app + system version, and the device identifier used to find your data for a deletion request).
struct SupportSection: View {
    @State private var copied = false
    private var osText: String { "iOS " + ProcessInfo.processInfo.operatingSystemVersionString }

    var body: some View {
        Section {
            NavigationLink { FeedbackView() } label: { Label("意見回饋", systemImage: "bubble.left.and.text.bubble.right") }
            Link(destination: SupportLinks.support) { Label("客服與常見問題", systemImage: "questionmark.circle") }
            if let mail = SupportLinks.mailto(appVersion: BackendConfig.appVersion, os: osText) {
                Link(destination: mail) { Label("寄信給我們（\(SupportLinks.email)）", systemImage: "envelope") }
            }
            Link(destination: SupportLinks.privacy) { Label("隱私權政策", systemImage: "hand.raised") }
            Link(destination: SupportLinks.terms) { Label("服務條款", systemImage: "doc.text") }
            LabeledContent("App 版本", value: BackendConfig.appVersion)
            LabeledContent("系統", value: osText)
            Button {
                UIPasteboard.general.string = BackendConfig.deviceID
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                LabeledContent("裝置識別碼") {
                    Text(copied ? "已複製" : BackendConfig.deviceID)
                        .font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(copied ? .green : .secondary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("支援與法律")
        } footer: {
            Text("要求查詢或刪除你的資料時，請附上裝置識別碼（點一下即可複製）。")
        }
    }
}

struct FeedbackView: View {
    @State private var draft = FeedbackDraft()
    @State private var sending = false
    @State private var result: Result?
    @Environment(\.dismiss) private var dismiss

    enum Result { case sent, failed }

    var body: some View {
        Form {
            Section {
                Picker("類型", selection: $draft.kind) {
                    ForEach(FeedbackKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                TextEditor(text: $draft.message)
                    .frame(minHeight: 140)
                    .onChange(of: draft.message) { _, new in
                        if new.count > FeedbackDraft.maxMessage { draft.message = String(new.prefix(FeedbackDraft.maxMessage)) }
                    }
            } header: {
                Text("內容")
            } footer: {
                Text("\(draft.message.count)/\(FeedbackDraft.maxMessage)　請描述發生了什麼、在哪條路線或哪個畫面。")
            }
            Section {
                TextField("Email（選填，方便我們回覆）", text: $draft.contact)
                    .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !draft.contactIsValid {
                    Text("Email 格式好像不對").font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("送出時會附上 App 與系統版本，不含你的位置。詳見隱私權政策。")
            }
            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack { Spacer(); if sending { ProgressView() } else { Text("送出").bold() }; Spacer() }
                }
                .disabled(!draft.canSend || sending)
                if result == .failed {
                    Text("送出失敗，請稍後再試，或直接寄信到 \(SupportLinks.email)。").font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("意見回饋")
        .navigationBarTitleDisplayMode(.inline)
        .alert("謝謝你的回饋", isPresented: Binding(get: { result == .sent }, set: { if !$0 { result = nil } })) {
            Button("好") { dismiss() }
        } message: {
            Text("我們收到了，會盡快處理。")
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do { try await FeedbackService.send(draft); result = .sent } catch { result = .failed }
    }
}

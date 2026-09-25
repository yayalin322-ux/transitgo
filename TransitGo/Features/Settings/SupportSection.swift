import SwiftUI
import SafariServices

/// A web page shown inside the app (Safari's engine in a sheet with a Done button) instead of switching to the Safari app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct InAppPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 設定 › 支援與法律: feedback form, the public support / privacy / terms pages (opened inside the app), and the two
/// facts a support request needs (app + system version, and the device identifier used to find your data for a deletion
/// request).
struct SupportSection: View {
    /// Which page to show. The sheet that presents it is attached by the owner of the Form (SettingsView), NOT to this
    /// Section: a presentation modifier on a Section inside a Form is not reliably hosted, and the pages simply never opened.
    @Binding var page: InAppPage?
    @State private var copied = false
    @State private var inbox = FeedbackInbox.shared
    private var osText: String { "iOS " + ProcessInfo.processInfo.operatingSystemVersionString }

    var body: some View {
        Section {
            NavigationLink { FeedbackView() } label: { Label("意見回饋", systemImage: "bubble.left.and.text.bubble.right") }
            NavigationLink { MyFeedbackView() } label: {
                HStack {
                    Label("我的回饋", systemImage: "tray.full")
                    Spacer()
                    if inbox.unreadCount > 0 {
                        Text("\(inbox.unreadCount)").font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(.red, in: Capsule())
                    }
                }
            }
            pageButton("客服與常見問題", "questionmark.circle", SupportLinks.support)
            pageButton("隱私權政策", "hand.raised", SupportLinks.privacy)
            pageButton("服務條款", "doc.text", SupportLinks.terms)
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

    private func pageButton(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { page = InAppPage(url: url) } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
    }
}

struct FeedbackView: View {
    @State private var draft = FeedbackDraft()
    @State private var status = ""              // message under the Email field (code sent / errors)
    @State private var statusIsError = false
    @State private var codeSent = false
    @State private var cooldown = 0
    @State private var requesting = false
    @State private var sending = false
    @State private var caseNumber: String?
    @State private var hasReplyChannel = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

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
                TextField("你的 Email（我們會用它回覆你）", text: $draft.email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: draft.email) { _, _ in draft.code = ""; codeSent = false; status = "" }
                if !draft.email.isEmpty, !draft.emailIsValid {
                    Text("Email 格式好像不對").font(.footnote).foregroundStyle(.red)
                }
                Button {
                    Task { await requestCode() }
                } label: {
                    HStack {
                        if requesting { ProgressView() }
                        Text(cooldown > 0 ? "\(cooldown) 秒後可重寄" : (codeSent ? "重新寄送驗證碼" : "寄驗證碼"))
                    }
                }
                .disabled(!draft.canRequestCode || requesting || cooldown > 0)
                if codeSent {
                    TextField("6 位數驗證碼", text: $draft.code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .onChange(of: draft.code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { draft.code = digits }
                        }
                }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(statusIsError ? .red : .secondary)
                }
            } header: {
                Text("Email 驗證")
            } footer: {
                Text("為了確認是你本人、也讓我們能回覆你，需要先驗證 Email。送出時會附上 App 與系統版本，不含你的位置。詳見隱私權政策。")
            }
            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack { Spacer(); if sending { ProgressView() } else { Text("送出").bold() }; Spacer() }
                }
                .disabled(!draft.canSend || sending)
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("意見回饋")
        .navigationBarTitleDisplayMode(.inline)
        .alert("謝謝你的回饋", isPresented: Binding(get: { caseNumber != nil }, set: { if !$0 { caseNumber = nil } })) {
            Button("好") { dismiss() }
        } message: {
            Text("案件編號 \(caseNumber ?? "")。我們會寄到 \(draft.trimmedEmail) 回覆你" + (hasReplyChannel ? "，回覆也會出現在「我的回饋」。" : "。"))
        }
    }

    private func requestCode() async {
        requesting = true
        defer { requesting = false }
        do {
            try await SiteFeedbackService.requestCode(draft)
            codeSent = true
            statusIsError = false
            status = "驗證碼已寄到 \(draft.trimmedEmail)，10 分鐘內有效（沒收到請看垃圾信件匣）。"
            startCooldown(60)
        } catch let e as SiteFeedbackError {
            statusIsError = true
            switch e {
            case .tooManyRequests: status = "這個信箱寄太多次了，請一小時後再試。"
            case .invalidEmail: status = "Email 格式不正確。"
            case .notConfigured: status = "目前無法使用線上回饋，請改寄信到 \(SupportLinks.email)。"
            default: status = "驗證碼寄送失敗，請確認網路與 Email 後再試一次。"
            }
        } catch { statusIsError = true; status = "驗證碼寄送失敗，請再試一次。" }
    }

    private func startCooldown(_ seconds: Int) {
        cooldown = seconds
        Task {
            while cooldown > 0 { try? await Task.sleep(for: .seconds(1)); cooldown -= 1 }
        }
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            let receipt = try await SiteFeedbackService.submit(draft)
            FeedbackInbox.shared.register(receipt, kind: draft.kind)
            hasReplyChannel = receipt.token != nil
            caseNumber = receipt.caseNumber
        } catch let e as SiteFeedbackError {
            switch e {
            case .wrongCode: failure = "驗證碼不對、已用過或已過期，請重新寄送驗證碼。"
            case .notConfigured: failure = "目前無法使用線上回饋，請改寄信到 \(SupportLinks.email)。"
            default: failure = "送出失敗，請稍後再試，或直接寄信到 \(SupportLinks.email)。"
            }
        } catch { failure = "送出失敗，請稍後再試。" }
    }
}


/// The tickets this phone filed, with a red dot when we replied.
struct MyFeedbackView: View {
    @State private var inbox = FeedbackInbox.shared
    @State private var refreshing = false

    var body: some View {
        List {
            if inbox.tickets.isEmpty {
                ContentUnavailableView("還沒有回饋", systemImage: "tray",
                                       description: Text("送出意見回饋後，我們的回覆會出現在這裡，也會寄到你的 Email。"))
            }
            ForEach(inbox.tickets) { ticket in
                NavigationLink { FeedbackThreadView(ticket: ticket) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(ticket.hasUnread ? Color.red : .clear).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ticket.caseNumber).font(.subheadline.weight(.semibold))
                            Text("\(FeedbackKind(rawValue: ticket.kind)?.label ?? "回饋")・\(FeedbackThread.statusText(ticket.status))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ticket.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("我的回饋")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if refreshing { ProgressView() } }
        .refreshable { _ = await inbox.refresh() }
        .task {
            refreshing = inbox.tickets.isEmpty ? false : true
            _ = await inbox.refresh()
            refreshing = false
        }
    }
}

struct FeedbackThreadView: View {
    let ticket: FeedbackTicket
    @State private var inbox = FeedbackInbox.shared
    @State private var thread: FeedbackThread?
    @State private var loading = true
    @State private var reply = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    if let thread {
                        ForEach(thread.messages) { m in
                            HStack {
                                if !m.isReply { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.isReply ? "我們" : "你").font(.caption2.bold()).foregroundStyle(.secondary)
                                    Text(m.body).textSelection(.enabled)
                                    if let d = m.createdAt { Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
                                }
                                .padding(10)
                                .background(m.isReply ? Color.blue.opacity(0.12) : Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                if m.isReply { Spacer(minLength: 40) }
                            }
                        }
                    } else if !loading {
                        ContentUnavailableView("暫時讀不到這則回饋", systemImage: "wifi.exclamationmark", description: Text("請確認網路後稍後再試；我們的回覆也會寄到你的 Email。"))
                    }
                }
                .padding()
            }
            if thread != nil {
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("追問或補充…", text: $reply, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                    Button { Task { await send() } } label: {
                        if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
                .padding(10)
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.bottom, 6) }
            }
        }
        .navigationTitle(ticket.caseNumber)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .task { await load() }
    }

    private func load() async {
        thread = await inbox.open(ticket)
        loading = false
    }

    private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await inbox.sendFollowUp(ticket, body: reply.trimmingCharacters(in: .whitespacesAndNewlines))
            reply = ""
            await load()
        } catch { self.error = "送出失敗，請稍後再試。" }
    }
}

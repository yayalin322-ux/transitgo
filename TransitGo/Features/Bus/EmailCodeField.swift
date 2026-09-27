import SwiftUI

/// Email + 6-digit verification code entry, shared by "寫評論" and "我是這裡的店家" — both now
/// require a verified Email before they go live (see EmailVerificationService / server's
/// /v1/email-code/request). The code itself is checked at submission time, not here; this view
/// only handles requesting it and the 60-second resend cooldown.
struct EmailCodeField: View {
    @Binding var email: String
    @Binding var code: String
    @State private var status: String?
    @State private var cooldown = 0
    @State private var isRequesting = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("你的 Email，需要驗證", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(cooldown > 0 ? "\(cooldown) 秒後可重寄" : "寄驗證碼") {
                    Task { await requestCode() }
                }
                .font(.caption)
                .disabled(isRequesting || cooldown > 0 || !isPlausibleEmail(email))
            }
            TextField("輸入 6 位數驗證碼", text: $code)
                .keyboardType(.numberPad)
            if let status {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in if cooldown > 0 { cooldown -= 1 } }
    }

    private func isPlausibleEmail(_ s: String) -> Bool {
        s.contains("@") && s.contains(".") && !s.contains(" ")
    }

    private func requestCode() async {
        isRequesting = true
        defer { isRequesting = false }
        switch await EmailVerificationService.requestCode(email: email) {
        case .sent:
            status = "驗證碼已寄到 \(email)，10 分鐘內有效（沒收到請看垃圾信件匣）。"
            cooldown = 60
        case .invalidEmail:
            status = "這個 Email 看起來不對，請確認後再試一次。"
        case .tooManyRequests:
            status = "這個信箱寄太多次了，請一小時後再試。"
        case .failed:
            status = "驗證碼寄送失敗，請稍後再試一次。"
        }
    }
}

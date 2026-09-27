import SwiftUI

/// Shown right before a share sheet opens, for both trip (TRA/HSR/bus) shares and in-app
/// navigation shares. The default is off — sharing a normal link never sends a coordinate; this
/// is the one, explicit moment the sharer can turn "安全分享" (safety live-location) on for THIS
/// link only, e.g. traveling alone and wanting someone to be able to check where they are.
struct ShareLiveLocationConfirmSheet: View {
    let onConfirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("分享即時位置（安全用途）", isOn: $enabled)
                } footer: {
                    Text(enabled
                         ? "任何拿到這個連結的人都能看到你的即時位置，直到連結過期或你自己關閉分享為止。"
                         : "預設不會分享你的位置，連結只會顯示行程或導航的狀態。自己出門怕不安全時，可以開啟這個選項。")
                }
            }
            .navigationTitle("分享行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("分享") { onConfirm(enabled); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

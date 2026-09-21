import Foundation

/// The whole "share" button flow, identical for a trip card and a ticket:
///   1. the link exists at once (the app made its token), so the share sheet opens with no waiting;
///   2. the link's content uploads in the background (retried for about a minute and a half);
///   3. only if that finally fails is the user told — the link they already sent would not open otherwise.
@MainActor
enum InstantShare {
    static func run(_ prepared: Result<ShareTripService.Prepared, ShareTripService.Failure>, message: String,
                    upload: @escaping (ShareTripService.Prepared) async -> ShareUploader.Outcome = { await ShareUploader.upload($0) }) {
        switch prepared {
        case .success(let p):
            SharePresenter.present(items: [message, p.url])
            Task {
                if await upload(p) == .failed {
                    SharePresenter.alert(title: "分享連結沒有建立成功",
                                         message: "剛才送出的連結目前打不開：連不上伺服器。請確認手機與電腦在同一個 Wi‑Fi、後端有在執行，然後重新分享一次。")
                }
            }
        case .failure(.nothingToFollow):
            SharePresenter.alert(title: "無法分享", message: "這趟行程沒有可以追蹤的車輛（只有步行或騎車），或資料不完整。")
        case .failure(.backendUnavailable):
            SharePresenter.alert(title: "無法分享", message: "App 沒有設定後端位址，無法建立分享連結。")
        }
    }
}

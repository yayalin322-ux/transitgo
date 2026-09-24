import UIKit

/// Presents the system share sheet (and simple alerts) straight from UIKit, on top of whatever is showing.
///
/// Why not SwiftUI's `.sheet`: the trip cards and the ticket page live in Lists that re-render whenever realtime data
/// arrives. A sheet hosted by a row that gets rebuilt is dismissed by SwiftUI — the share sheet opened and immediately
/// vanished, and the button had to be pressed a second time. A UIKit controller is not owned by any SwiftUI view.
@MainActor
enum SharePresenter {
    static func present(items: [Any]) {
        guard let top = topController() else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad: a share sheet is a popover and needs an anchor.
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        vc.popoverPresentationController?.permittedArrowDirections = []
        top.present(vc, animated: true)
    }

    static func alert(title: String, message: String) {
        guard let top = topController() else { return }
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        top.present(a, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

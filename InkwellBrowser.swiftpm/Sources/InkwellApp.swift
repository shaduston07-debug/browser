import SwiftUI
import UIKit

@main
struct InkwellApp: App {
    init() {
        // Start loading installed extensions immediately so they're ready
        // before the first tab finishes its first navigation.
        ExtensionManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            BrowserWindowView()
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// Hosts one UIKit `BrowserWindow` per iPad window (scene). Each window has its own tab set,
/// just like separate windows on a Mac.
struct BrowserWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrowserWindow {
        BrowserWindow()
    }

    func updateUIViewController(_ uiViewController: BrowserWindow, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: BrowserWindow, coordinator: ()) {
        uiViewController.windowWillClose()
    }
}

// MARK: - Shared helpers

extension UIApplication {
    /// The top-most view controller in the foreground-active window, used for alerts and sheets.
    static func topViewController(preferring window: UIWindow? = nil) -> UIViewController? {
        let scenes: [UIWindowScene] = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScenes: [UIWindowScene] = scenes.filter { $0.activationState == .foregroundActive }
        let candidates: [UIWindow] = (activeScenes + scenes).flatMap { $0.windows }
        let keyWindow: UIWindow? = window ?? candidates.first(where: { $0.isKeyWindow }) ?? candidates.first

        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

@MainActor
enum Alerts {
    static func show(title: String, message: String?, on presenter: UIViewController? = nil) {
        guard let presenter = presenter ?? UIApplication.topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    static func confirm(title: String,
                        message: String?,
                        confirmTitle: String,
                        cancelTitle: String = "Cancel",
                        destructive: Bool = false,
                        on presenter: UIViewController? = nil,
                        completion: @escaping (Bool) -> Void) {
        guard let presenter = presenter ?? UIApplication.topViewController() else {
            completion(false)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: confirmTitle, style: destructive ? .destructive : .default) { _ in completion(true) })
        presenter.present(alert, animated: true)
    }
}

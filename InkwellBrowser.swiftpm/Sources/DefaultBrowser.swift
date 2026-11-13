import SwiftUI
import UIKit

// MARK: - Opening links from other apps

/// Turns links handed to Inkwell into web addresses:
/// - http(s):// links (when Inkwell is the default browser)
/// - inkwells://example.com/page → https://example.com/page
/// - inkwell://open?url=<encoded URL>
/// - inkwellhttp://example.com → http://example.com
@MainActor
enum LinkRouter {
    private static var pending: [URL] = []

    static func webURL(for incoming: URL) -> URL? {
        guard let scheme = incoming.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return incoming
        case "inkwells", "inkwellhttp":
            let rest = incoming.absoluteString.dropFirst(scheme.count + 3) // drop "scheme://"
            guard !rest.isEmpty else { return nil }
            return URL(string: (scheme == "inkwells" ? "https://" : "http://") + rest)
        case "inkwell":
            let items = URLComponents(url: incoming, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let value = items.first(where: { $0.name == "url" })?.value {
                return AppSettings.url(fromInput: value)
            }
            if let q = items.first(where: { $0.name == "q" })?.value {
                return AppSettings.searchEngine.url(for: q)
            }
            return nil
        default:
            return nil
        }
    }

    static func open(_ incoming: URL) {
        guard let url = webURL(for: incoming) else { return }
        if let window = WindowRegistry.shared.focusedOrAny, window.isReady {
            window.openTab(url: url, select: true)
        } else {
            pending.append(url)
        }
    }

    /// Called by a window once its tabs are restored, so links that launched the app open there.
    static func takePending() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}

// MARK: - Default browser

@MainActor
enum DefaultBrowser {
    private static let dontAskKey = "defaultBrowser.dontAsk"
    private static var askedThisLaunch = false

    /// Whether iOS will let this copy of the app be the default browser at all. That needs Apple's
    /// com.apple.developer.web-browser entitlement, which sideloaded apps signed with a free Apple ID
    /// can't have. We check the provisioning profile the app was signed with.
    static var isEligible: Bool {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path) else {
            // App Store / TestFlight builds have no embedded profile; there the entitlement decides
            // whether iOS lists the app, and isDefault() reports the state.
            return true
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("com.apple.developer.web-browser")
    }

    /// true / false when iOS can tell us; nil on older iPadOS or if iOS declines to answer.
    static func isDefault() -> Bool? {
        if #available(iOS 18.2, *) {
            return try? UIApplication.shared.isDefault(.webBrowser)
        }
        return nil
    }

    static func openSystemSettings() {
        var target = URL(string: UIApplication.openSettingsURLString)
        if #available(iOS 18.3, *) {
            target = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) ?? target
        }
        if let target { UIApplication.shared.open(target) }
    }

    /// Asks once per launch (until "Don't Ask Again"), and only when iOS would actually list Inkwell.
    static func askIfAppropriate(from presenter: UIViewController) {
        guard !askedThisLaunch, isEligible, !UserDefaults.standard.bool(forKey: dontAskKey) else { return }
        askedThisLaunch = true
        guard isDefault() == false else { return }

        let alert = UIAlertController(
            title: "Make Inkwell Browser your default browser?",
            message: "Links you tap in other apps will open in Inkwell, with your extensions.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Set as Default…", style: .default) { _ in openSystemSettings() })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Don't Ask Again", style: .default) { _ in
            UserDefaults.standard.set(true, forKey: dontAskKey)
        })
        presenter.present(alert, animated: true)
    }

    static func resetPrompt() {
        UserDefaults.standard.removeObject(forKey: dontAskKey)
    }
}

/// The "Default Browser" section in Settings.
struct DefaultBrowserSection: View {
    @State private var isDefault: Bool? = nil
    @State private var checked = false

    var body: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                Text(statusText).foregroundStyle(.secondary)
            }
            if DefaultBrowser.isEligible {
                Button("Open Default Apps Settings…") { DefaultBrowser.openSystemSettings() }
                Button("Ask Me Again on Launch") { DefaultBrowser.resetPrompt() }
            }
        } header: {
            Text("Default browser")
        } footer: {
            Text(footerText)
        }
        .onAppear {
            guard !checked else { return }
            checked = true
            isDefault = DefaultBrowser.isDefault()
        }
    }

    private var statusText: String {
        if !DefaultBrowser.isEligible { return "Not available in this build" }
        switch isDefault {
        case .some(true): return "Inkwell is your default browser"
        case .some(false): return "Not the default"
        case .none: return "Unknown"
        }
    }

    private var footerText: String {
        if DefaultBrowser.isEligible {
            return "In iPadOS Settings choose Default Browser App → Inkwell Browser. Links from other apps then open here in a new tab."
        }
        return "iPadOS only lists apps that Apple has given the web-browser entitlement, which needs a paid Apple Developer account and Apple's approval. Sideloaded copies can't be the default. You can still open links in Inkwell from Shortcuts or other apps by starting them with inkwells:// instead of https://, or with inkwell://open?url=<link>."
    }
}

import UIKit
import WebKit

/// A single browser tab: one `WKWebView`, exposed to extensions through `WKWebExtensionTab`
/// so `chrome.tabs` / `browser.tabs` see it exactly like a desktop tab.
@MainActor
final class BrowserTab: NSObject {
    let webView: WKWebView
    weak var window: BrowserWindow?
    /// Called whenever title / URL / loading state changes.
    var onChange: ((BrowserTab) -> Void)?

    private var observations: [NSKeyValueObservation] = []

    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        if let host = webView.url?.host { return host }
        return "New Tab"
    }

    var isBlank: Bool {
        webView.url == nil || webView.url?.absoluteString == "about:blank"
    }

    /// - Parameter configuration: pass WebKit's configuration when it asks us to create a popup window.
    init(configuration: WKWebViewConfiguration? = nil) {
        let config = configuration ?? BrowserTab.makeConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.isFindInteractionEnabled = true
        webView.customUserAgent = AppSettings.userAgent.string
        webView.backgroundColor = .systemBackground

        let notify: (BrowserTab, WKWebExtension.TabChangedProperties) -> Void = { tab, properties in
            tab.onChange?(tab)
            ExtensionManager.shared.controller.didChangeTabProperties(properties, for: tab)
        }
        observations = [
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { notify(self, .title) } }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { notify(self, .URL) } }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { notify(self, .loading) } }
            },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { self.onChange?(self) } }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { self.onChange?(self) } }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { self.onChange?(self) } }
            },
        ]
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.webExtensionController = ExtensionManager.shared.controller
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isTextInteractionEnabled = true
        config.dataDetectorTypes = []

        if AppSettings.hideTouch {
            // Desktop sites often check maxTouchPoints to spot iPads; report a pointer-only device.
            let source = """
            (() => {
              try {
                Object.defineProperty(Navigator.prototype, 'maxTouchPoints', { get: () => 0, configurable: true });
                Object.defineProperty(Navigator.prototype, 'platform', { get: () => 'MacIntel', configurable: true });
              } catch (e) {}
            })();
            """
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        return config
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func applyUserAgent() {
        webView.customUserAgent = AppSettings.userAgent.string
    }
}

// MARK: - WKWebExtensionTab

extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        window?.tabs.firstIndex(of: self) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        webView.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        webView.url
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        window?.activeTab === self
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !webView.isLoading
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView.bounds.size
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(webView.pageZoom)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        webView.pageZoom = CGFloat(zoomFactor)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext,
                 completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.select(self)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.close(self)
        completionHandler(nil)
    }
}

// MARK: - Window registry

/// Tracks every open browser window (iPad scene) in front-to-back order for `chrome.windows`.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()

    private(set) var windows: [BrowserWindow] = []
    private(set) weak var focused: BrowserWindow?

    var focusedOrAny: BrowserWindow? { focused ?? windows.first }

    var orderedWindows: [BrowserWindow] {
        guard let focused else { return windows }
        return [focused] + windows.filter { $0 !== focused }
    }

    func add(_ window: BrowserWindow) {
        guard !windows.contains(where: { $0 === window }) else { return }
        windows.append(window)
        ExtensionManager.shared.controller.didOpenWindow(window)
        focus(window)
    }

    func remove(_ window: BrowserWindow) {
        guard windows.contains(where: { $0 === window }) else { return }
        windows.removeAll { $0 === window }
        ExtensionManager.shared.controller.didCloseWindow(window)
        if focused === window {
            focused = nil
            ExtensionManager.shared.controller.didFocusWindow(windows.first)
            focused = windows.first
        }
    }

    func focus(_ window: BrowserWindow) {
        guard focused !== window else { return }
        focused = window
        ExtensionManager.shared.controller.didFocusWindow(window)
    }
}

// MARK: - Session & bookmarks persistence

@MainActor
enum SessionStore {
    private static let key = "session.tabs"
    private static let selectedKey = "session.selected"
    private static var restored = false

    static func save(_ window: BrowserWindow) {
        // Only the first window's tabs are restored; it's what a single-window Mac session feels like.
        guard WindowRegistry.shared.windows.first === window else { return }
        let urls = window.tabs.compactMap { $0.webView.url?.absoluteString }.filter { $0 != "about:blank" }
        UserDefaults.standard.set(urls, forKey: key)
        UserDefaults.standard.set(window.tabs.firstIndex { $0 === window.activeTab } ?? 0, forKey: selectedKey)
    }

    /// Returns saved tabs the first time it's called per launch, then nothing.
    static func takeSavedSession() -> (urls: [URL], selected: Int)? {
        guard !restored, AppSettings.restoreSession else { return nil }
        restored = true
        let urls = (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(URL.init(string:))
        guard !urls.isEmpty else { return nil }
        return (urls, UserDefaults.standard.integer(forKey: selectedKey))
    }
}

struct Bookmark: Codable, Equatable {
    var title: String
    var url: URL
}

enum BookmarkStore {
    static let didChange = Notification.Name("BookmarksDidChange")
    private static let key = "bookmarks"

    static var all: [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            return [
                Bookmark(title: "Chrome Web Store", url: ChromeWebStore.home),
                Bookmark(title: "Firefox Add-ons", url: URL(string: "https://addons.mozilla.org/firefox/extensions/")!),
            ]
        }
        return items
    }

    static func set(_ items: [Bookmark]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return all.contains { $0.url == url }
    }

    static func toggle(title: String, url: URL) {
        var items = all
        if let index = items.firstIndex(where: { $0.url == url }) {
            items.remove(at: index)
        } else {
            items.append(Bookmark(title: title, url: url))
        }
        set(items)
    }

    static func remove(_ bookmark: Bookmark) {
        set(all.filter { $0 != bookmark })
    }
}

// MARK: - Downloads

/// Saves downloads, then offers to install them (extension packages) or export them to Files.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    private var destinations: [ObjectIdentifier: URL] = [:]

    private var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        var target = directory.appendingPathComponent(suggestedFilename)
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        destinations[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let ext = file.pathExtension.lowercased()
        if ext == "crx" || ext == "xpi" {
            ExtensionManager.shared.installInteractively(from: file)
            return
        }

        guard let presenter = UIApplication.topViewController() else { return }
        let alert = UIAlertController(title: "Downloaded “\(file.lastPathComponent)”", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Save to Files…", style: .default) { _ in
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            presenter.present(picker, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Share…", style: .default) { _ in
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = presenter.view
            share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: 80, width: 1, height: 1)
            presenter.present(share, animated: true)
        })
        if ext == "zip" {
            alert.addAction(UIAlertAction(title: "Install as Extension", style: .default) { _ in
                ExtensionManager.shared.installInteractively(from: file)
            })
        }
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        presenter.present(alert, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        Alerts.show(title: "Download failed", message: error.localizedDescription)
    }
}

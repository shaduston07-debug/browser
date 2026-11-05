import Foundation
import SwiftUI
import WebKit

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, kagi, ecosia, brave

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .ecosia: return "Ecosia"
        case .brave: return "Brave Search"
        }
    }

    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(q)")
        case .kagi: return URL(string: "https://kagi.com/search?q=\(q)")
        case .ecosia: return URL(string: "https://www.ecosia.org/search?q=\(q)")
        case .brave: return URL(string: "https://search.brave.com/search?q=\(q)")
        }
    }
}

/// Which browser the iPad pretends to be. Every option is a *desktop* identity.
enum UserAgentMode: String, CaseIterable, Identifiable {
    case safariMac, chromeMac, edgeMac, firefoxMac

    var id: String { rawValue }

    var name: String {
        switch self {
        case .safariMac: return "Safari on Mac"
        case .chromeMac: return "Chrome on Mac"
        case .edgeMac: return "Edge on Mac"
        case .firefoxMac: return "Firefox on Mac"
        }
    }

    var string: String {
        switch self {
        case .safariMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
        case .chromeMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
        case .edgeMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0"
        case .firefoxMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"
        }
    }
}

/// UserDefaults-backed settings. SwiftUI views use `@AppStorage` with the same keys.
enum AppSettings {
    enum Key {
        static let searchEngine = "searchEngine"
        static let userAgent = "userAgent"
        static let homepage = "homepage"
        static let hideTouch = "hideTouch"
        static let restoreSession = "restoreSession"
        static let showBookmarksBar = "showBookmarksBar"
    }

    static var searchEngine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: Key.searchEngine) ?? "") ?? .google
    }

    static var userAgent: UserAgentMode {
        UserAgentMode(rawValue: UserDefaults.standard.string(forKey: Key.userAgent) ?? "") ?? .safariMac
    }

    static var homepage: String {
        UserDefaults.standard.string(forKey: Key.homepage) ?? ""
    }

    /// Makes `navigator.maxTouchPoints` report 0 so sites can't sniff "iPad pretending to be a Mac"
    /// and fall back to their tablet layout.
    static var hideTouch: Bool {
        UserDefaults.standard.object(forKey: Key.hideTouch) as? Bool ?? true
    }

    static var restoreSession: Bool {
        UserDefaults.standard.object(forKey: Key.restoreSession) as? Bool ?? true
    }

    static var showBookmarksBar: Bool {
        UserDefaults.standard.object(forKey: Key.showBookmarksBar) as? Bool ?? true
    }

    /// Turns whatever was typed in the address bar into a URL: a real URL, a bare domain, or a search.
    static func url(fromInput raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file", "data", "webkit-extension", "safari-web-extension"].contains(scheme) {
            return url
        }

        let looksLikeHost = !text.contains(" ") &&
            (text.contains(".") || text.hasPrefix("localhost") || text.contains(":"))
        if looksLikeHost, let url = URL(string: "https://\(text)"), url.host != nil {
            return url
        }
        return searchEngine.url(for: text)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.searchEngine) private var searchEngine = SearchEngine.google.rawValue
    @AppStorage(AppSettings.Key.userAgent) private var userAgent = UserAgentMode.safariMac.rawValue
    @AppStorage(AppSettings.Key.homepage) private var homepage = ""
    @AppStorage(AppSettings.Key.hideTouch) private var hideTouch = true
    @AppStorage(AppSettings.Key.restoreSession) private var restoreSession = true
    @AppStorage(AppSettings.Key.showBookmarksBar) private var showBookmarksBar = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    Picker("Search engine", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    TextField("Homepage (blank = empty new tab)", text: $homepage)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    Picker("Identify as", selection: $userAgent) {
                        ForEach(UserAgentMode.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Toggle("Hide touch screen from websites", isOn: $hideTouch)
                } header: {
                    Text("Desktop mode")
                } footer: {
                    Text("Every page always loads its desktop version. \"Chrome on Mac\" helps with sites that only allow Chrome (including the Chrome Web Store). Hiding the touch screen stops sites from detecting an iPad and switching to a tablet layout. Changes apply to new page loads.")
                }

                Section("Windows & tabs") {
                    Toggle("Reopen tabs from last time", isOn: $restoreSession)
                    Toggle("Show bookmarks bar", isOn: $showBookmarksBar)
                }

                Section("About") {
                    LabeledContent("Version", value: AppInfo.build)
                }

                Section("Developer") {
                    Text("Every page and extension can be inspected from Safari on a Mac (Develop menu → this iPad) once Web Inspector is turned on in iPad Settings → Apps → Safari → Advanced.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Clear website data (cookies, caches, storage)", role: .destructive) {
                        WebsiteDataCleaner.clearAll()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

enum WebsiteDataCleaner {
    @MainActor
    static func clearAll() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            Task { @MainActor in Alerts.show(title: "Website data cleared", message: nil) }
        }
    }
}

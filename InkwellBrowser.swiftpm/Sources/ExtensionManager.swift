import Foundation
import UIKit
import WebKit

/// One installed extension, persisted to disk.
struct InstalledExtension: Codable, Identifiable, Equatable {
    var id: UUID
    /// Path of the folder containing manifest.json, relative to the Extensions directory.
    var relativePath: String
    var enabled: Bool
    /// Chrome Web Store / AMO identifier, when installed from a store (used for updates).
    var storeID: String?
    var installedAt: Date
}

/// Owns the single `WKWebExtensionController` shared by every tab in every window, installs and
/// loads extensions, and answers WebKit's questions about windows, tabs, popups and permissions.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    static let shared = ExtensionManager()

    /// Fixed identifier so extension storage (chrome.storage, cookies, IndexedDB…) survives relaunches.
    private static let controllerID = UUID(uuidString: "6D3B0F6A-2B1C-4E5B-9C0D-DE5C0B5E1A01")!

    let controller: WKWebExtensionController

    @Published private(set) var records: [InstalledExtension] = []
    @Published private(set) var loadErrors: [UUID: String] = [:]
    /// Bumped whenever toolbar buttons should be rebuilt.
    @Published private(set) var revision = 0

    private(set) var extensions: [UUID: WKWebExtension] = [:]
    private(set) var contexts: [UUID: WKWebExtensionContext] = [:]
    private var loadTask: Task<Void, Never>?

    private let extensionsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL { extensionsDirectory.appendingPathComponent("installed.json") }

    private override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: Self.controllerID)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadAllFromDisk() }
    }

    /// Await this before restoring tabs so content scripts are in place for the first page load.
    func waitUntilReady() async {
        start()
        await loadTask?.value
    }

    private func loadAllFromDisk() async {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            records = saved
        }
        for record in records {
            do {
                ExtensionPatcher.patch(folder(for: record), storeID: record.storeID)
                let ext = try await WKWebExtension(resourceBaseURL: folder(for: record))
                extensions[record.id] = ext
                if record.enabled { try activate(record, ext) }
            } catch {
                loadErrors[record.id] = error.localizedDescription
            }
        }
        revision += 1
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func folder(for record: InstalledExtension) -> URL {
        extensionsDirectory.appendingPathComponent(record.relativePath, isDirectory: true)
    }

    private func activate(_ record: InstalledExtension, _ ext: WKWebExtension) throws {
        let context = WKWebExtensionContext(for: ext)
        // A stable identifier keeps the extension's storage and origin the same across launches.
        context.uniqueIdentifier = record.id.uuidString
        context.isInspectable = true

        // Like a desktop browser, everything the manifest asks for was approved at install time.
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }

        try controller.load(context)
        contexts[record.id] = context
        ChromeCompat.shared.startKeepAlive(for: context)
        loadErrors[record.id] = nil
    }

    private func deactivate(_ id: UUID) {
        if let context = contexts.removeValue(forKey: id) {
            ChromeCompat.shared.contextWillUnload(context)
            try? controller.unload(context)
        }
    }

    // MARK: - Queries

    var activeContexts: [(record: InstalledExtension, context: WKWebExtensionContext)] {
        records.compactMap { record in contexts[record.id].map { (record, $0) } }
    }

    func record(for context: WKWebExtensionContext) -> InstalledExtension? {
        guard let id = contexts.first(where: { $0.value === context })?.key else { return nil }
        return records.first { $0.id == id }
    }

    func displayName(for record: InstalledExtension) -> String {
        extensions[record.id]?.displayName ?? "Extension"
    }

    func icon(for record: InstalledExtension, size: CGFloat = 32) -> UIImage? {
        extensions[record.id]?.icon(for: CGSize(width: size, height: size))
    }

    func errors(for record: InstalledExtension) -> [String] {
        var messages: [String] = []
        if let loadError = loadErrors[record.id] { messages.append(loadError) }
        if let ext = extensions[record.id] { messages += ext.errors.map(\.localizedDescription) }
        if let ctx = contexts[record.id] { messages += ctx.errors.map(\.localizedDescription) }
        return messages
    }

    // MARK: - Mutations

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].enabled = enabled
        if enabled, let ext = extensions[id] {
            do { try activate(records[index], ext) } catch { loadErrors[id] = error.localizedDescription }
        } else {
            deactivate(id)
        }
        save()
        revision += 1
    }

    func remove(_ id: UUID) {
        deactivate(id)
        if let record = records.first(where: { $0.id == id }) {
            let top = record.relativePath.split(separator: "/").first.map(String.init) ?? record.relativePath
            try? FileManager.default.removeItem(at: extensionsDirectory.appendingPathComponent(top))
        }
        records.removeAll { $0.id == id }
        extensions[id] = nil
        loadErrors[id] = nil
        save()
        revision += 1
    }

    /// Maps chrome-extension://<Chrome Web Store ID>/path?query onto the installed copy, if that file exists.
    func localURL(forChromeExtensionURL url: URL) -> URL? {
        guard let host = url.host,
              let record = records.first(where: { $0.storeID == host }),
              let context = contexts[record.id] else { return nil }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: folder(for: record).appendingPathComponent(path).path),
              var components = URLComponents(url: context.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        components.query = url.query
        components.fragment = url.fragment
        return components.url
    }

    func openOptions(for id: UUID) {
        guard let context = contexts[id], let url = context.optionsPageURL else { return }
        WindowRegistry.shared.focusedOrAny?.openTab(url: url, select: true)
    }

    // MARK: - Installing

    struct PendingInstall {
        let id: UUID
        let folderName: String
        let relativePath: String
        let webExtension: WKWebExtension
        let storeID: String?
        let replacing: UUID?
    }

    /// Unpacks a .zip / .crx / .xpi file or copies an unpacked extension folder, then parses it.
    /// Nothing is active until `commit(_:)` is called.
    func prepareInstall(from source: URL, storeID: String? = nil) async throws -> PendingInstall {
        let replacing = storeID.flatMap { sid in records.first { $0.storeID == sid }?.id }
        let id = replacing ?? UUID()
        let folderName = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970))"
        let destination = extensionsDirectory.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        do {
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try fm.copyItem(at: source, to: destination)
            } else {
                let data = try Data(contentsOf: source)
                try ZipArchive.extract(data, to: destination)
            }

            let manifestRoot = try Self.locateManifest(in: destination)
            let rootPath = manifestRoot.resolvingSymlinksInPath().path
            let destinationPath = destination.resolvingSymlinksInPath().path
            let relative = folderName + rootPath.dropFirst(destinationPath.count)
            ExtensionPatcher.patch(manifestRoot, storeID: storeID)
            let ext = try await WKWebExtension(resourceBaseURL: manifestRoot)
            return PendingInstall(id: id, folderName: folderName, relativePath: String(relative),
                                  webExtension: ext, storeID: storeID, replacing: replacing)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    func commit(_ pending: PendingInstall) throws {
        if let old = pending.replacing, let oldRecord = records.first(where: { $0.id == old }) {
            deactivate(old)
            let top = oldRecord.relativePath.split(separator: "/").first.map(String.init) ?? oldRecord.relativePath
            if top != pending.folderName {
                try? FileManager.default.removeItem(at: extensionsDirectory.appendingPathComponent(top))
            }
            records.removeAll { $0.id == old }
        }

        let record = InstalledExtension(id: pending.id, relativePath: pending.relativePath, enabled: true,
                                        storeID: pending.storeID, installedAt: Date())
        extensions[record.id] = pending.webExtension
        try activate(record, pending.webExtension)
        records.append(record)
        save()
        revision += 1
    }

    func cancel(_ pending: PendingInstall) {
        try? FileManager.default.removeItem(at: extensionsDirectory.appendingPathComponent(pending.folderName))
    }

    /// Full interactive flow: unpack → show what it can access → install.
    func installInteractively(from source: URL, storeID: String? = nil, presenter: UIViewController? = nil) {
        Task {
            do {
                let pending = try await prepareInstall(from: source, storeID: storeID)
                let ext = pending.webExtension
                let name = ext.displayName ?? "this extension"
                var lines: [String] = []
                if let version = ext.displayVersion { lines.append("Version \(version)") }
                if let description = ext.displayDescription { lines.append(description) }
                let hosts = ext.allRequestedMatchPatterns.map(\.string).sorted()
                if ext.allRequestedMatchPatterns.contains(where: { $0.matchesAllURLs || $0.matchesAllHosts }) {
                    lines.append("\nIt can read and change your data on all websites.")
                } else if !hosts.isEmpty {
                    lines.append("\nIt can read and change your data on:\n" + hosts.prefix(8).joined(separator: "\n"))
                }
                let permissions = ext.requestedPermissions.map(\.rawValue).sorted()
                if !permissions.isEmpty { lines.append("\nPermissions: " + permissions.joined(separator: ", ")) }

                let verb = pending.replacing == nil ? "Add" : "Update"
                Alerts.confirm(title: "\(verb) “\(name)”?", message: lines.joined(separator: "\n"),
                               confirmTitle: "\(verb) Extension", on: presenter) { [weak self] ok in
                    guard let self else { return }
                    guard ok else { self.cancel(pending); return }
                    do {
                        try self.commit(pending)
                        Alerts.show(title: "“\(name)” was added",
                                    message: "Its button is in the toolbar. Manage it from the puzzle-piece menu.", on: presenter)
                    } catch {
                        Alerts.show(title: "Couldn't load extension", message: error.localizedDescription, on: presenter)
                    }
                }
            } catch {
                Alerts.show(title: "Couldn't install extension", message: error.localizedDescription, on: presenter)
            }
        }
    }

    /// Downloads a CRX straight from Google's update service and installs it.
    func installFromChromeWebStore(id: String, presenter: UIViewController?) {
        let crxURL = URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=142.0.0.0&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")!
        Task { await downloadAndInstall(from: crxURL, fileName: "\(id).crx", storeID: id, presenter: presenter) }
    }

    /// Looks up the latest .xpi through the public addons.mozilla.org API and installs it.
    func installFromFirefoxAddons(slug: String, presenter: UIViewController?) {
        Task {
            do {
                let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
                let (data, _) = try await URLSession.shared.data(from: api)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["current_version"] as? [String: Any],
                      let file = version["file"] as? [String: Any],
                      let link = file["url"] as? String, let xpiURL = URL(string: link) else {
                    throw URLError(.cannotParseResponse)
                }
                await downloadAndInstall(from: xpiURL, fileName: "\(slug).xpi", storeID: "amo:\(slug)", presenter: presenter)
            } catch {
                Alerts.show(title: "Couldn't find that add-on", message: error.localizedDescription, on: presenter)
            }
        }
    }

    private func downloadAndInstall(from remote: URL, fileName: String, storeID: String, presenter: UIViewController?) async {
        do {
            let (temp, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
            installInteractively(from: file, storeID: storeID, presenter: presenter)
        } catch {
            Alerts.show(title: "Download failed", message: error.localizedDescription, on: presenter)
        }
    }

    /// Re-downloads every store-installed extension (keeps settings and storage).
    func checkForUpdates() {
        for record in records {
            guard let sid = record.storeID else { continue }
            if sid.hasPrefix("amo:") {
                installFromFirefoxAddons(slug: String(sid.dropFirst(4)), presenter: nil)
            } else if ChromeWebStore.isExtensionID(sid) {
                installFromChromeWebStore(id: sid, presenter: nil)
            }
        }
    }

    private static func locateManifest(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        // Zips made by "Compress" in Files usually wrap everything in one top-level folder.
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "manifest.json" {
                if enumerator.level <= 3 { return url.deletingLastPathComponent() }
            }
        }
        throw NSError(domain: "Inkwell", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "No manifest.json found. Choose an extension folder, or a .zip / .crx / .xpi that contains one."])
    }
}

// MARK: - Store helpers

enum ChromeWebStore {
    static let home = URL(string: "https://chromewebstore.google.com/category/extensions")!

    static func isExtensionID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Extracts the extension ID from a store listing URL, e.g.
    /// https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh
    static func extensionID(from url: URL?) -> String? {
        guard let url, let host = url.host,
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last(where: isExtensionID)
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension ExtensionManager: WKWebExtensionControllerDelegate {
    /// runtime.sendNativeMessage — used by Inkwell's Chrome compatibility layer.
    func webExtensionController(_ controller: WKWebExtensionController,
                                sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        ChromeCompat.shared.handle(message, from: extensionContext) { reply in
            replyHandler(reply, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        WindowRegistry.shared.orderedWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        WindowRegistry.shared.focused
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindow) ?? WindowRegistry.shared.focusedOrAny
        guard let window else { completionHandler(nil, nil); return }
        let tab = window.openTab(url: configuration.url, select: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // iPadOS creates windows asynchronously and can't hand one back synchronously,
        // so "new window" requests open as tabs in the current window instead.
        guard let window = WindowRegistry.shared.focusedOrAny else { completionHandler(nil, nil); return }
        if configuration.tabURLs.isEmpty {
            window.openTab(url: nil, select: true)
        }
        for url in configuration.tabURLs {
            window.openTab(url: url, select: true)
        }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL {
            WindowRegistry.shared.focusedOrAny?.openTab(url: url, select: true)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = WindowRegistry.shared.focusedOrAny else { completionHandler(nil); return }
        window.presentExtensionPopup(action, for: extensionContext)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let list = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        Alerts.confirm(title: "“\(name)” wants more permissions", message: list, confirmTitle: "Allow",
                       cancelTitle: "Don't Allow") { ok in
            completionHandler(ok ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let hosts = Set(urls.compactMap(\.host)).sorted().joined(separator: "\n")
        Alerts.confirm(title: "Allow “\(name)” to access these sites?", message: hosts, confirmTitle: "Allow",
                       cancelTitle: "Don't Allow") { ok in
            completionHandler(ok ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let list = matchPatterns.map(\.string).sorted().joined(separator: "\n")
        Alerts.confirm(title: "Allow “\(name)” to access these sites?", message: list, confirmTitle: "Allow",
                       cancelTitle: "Don't Allow") { ok in
            completionHandler(ok ? matchPatterns : [], nil)
        }
    }
}

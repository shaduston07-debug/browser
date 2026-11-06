import Combine
import SwiftUI
import UIKit
import WebKit

/// One browser window (one iPad scene). Mac-style layout: tab strip, toolbar with address bar and
/// extension buttons, optional bookmarks bar, then the page.
@MainActor
final class BrowserWindow: UIViewController {
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTab: BrowserTab?
    private var closedTabURLs: [URL] = []

    // MARK: UI

    private let tabStrip = TabStripView()
    private let toolbar = UIStackView()
    private let bookmarksBar = BookmarksBarView()
    private let contentContainer = UIView()
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let addressField = UITextField()
    private let suggestionsView = SuggestionsView()
    private let sidePanelContainer = UIView()
    private let sidePanelTitle = UILabel()
    private var sidePanelWidth: NSLayoutConstraint!
    private var sidePanelWebView: WKWebView?
    private weak var sidePanelContext: WKWebExtensionContext?
    private let extensionButtonStack = UIStackView()
    private var extensionButtons: [UUID: ExtensionActionButton] = [:]
    private var bookmarksBarHeight: NSLayoutConstraint!
    private var cancellables = Set<AnyCancellable>()
    private var badgeTimer: Timer?

    private lazy var startPage: UIHostingController<StartPageView> = {
        let host = UIHostingController(rootView: StartPageView(open: { [weak self] url in self?.navigate(to: url) }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        host.didMove(toParent: self)
        return host
    }()

    private lazy var backButton = Self.toolbarButton("chevron.left", "Back") { [weak self] in self?.activeTab?.webView.goBack() }
    private lazy var forwardButton = Self.toolbarButton("chevron.right", "Forward") { [weak self] in self?.activeTab?.webView.goForward() }
    private lazy var reloadButton = Self.toolbarButton("arrow.clockwise", "Reload") { [weak self] in self?.reloadOrStop() }
    private lazy var bookmarkButton = Self.toolbarButton("star", "Bookmark") { [weak self] in self?.toggleBookmark() }

    private lazy var installButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Add to Inkwell"
        config.image = UIImage(systemName: "puzzlepiece.extension.fill")
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.buttonSize = .small
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.installFromCurrentStorePage() })
        button.isHidden = true
        return button
    }()

    private lazy var extensionsMenuButton: UIButton = {
        let button = Self.toolbarButton("puzzlepiece.extension", "Extensions") {}
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(MainActor.assumeIsolated { self?.extensionsMenuElements() ?? [] })
        }])
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private lazy var mainMenuButton: UIButton = {
        let button = Self.toolbarButton("ellipsis.circle", "More") {}
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(MainActor.assumeIsolated { self?.mainMenuElements() ?? [] })
        }])
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        buildLayout()
        wireUpCallbacks()
        WindowRegistry.shared.add(self)
        ChromeCompat.shared.adoptHiddenViews(into: self)

        Task { [weak self] in
            await ExtensionManager.shared.waitUntilReady()
            self?.restoreOrOpenFirstTab()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        WindowRegistry.shared.focus(self)
    }

    func windowWillClose() {
        badgeTimer?.invalidate()
        let controller = ExtensionManager.shared.controller
        for tab in tabs {
            controller.didCloseTab(tab, windowIsClosing: true)
        }
        WindowRegistry.shared.remove(self)
    }

    private func restoreOrOpenFirstTab() {
        guard tabs.isEmpty else { return }
        if let session = SessionStore.takeSavedSession() {
            for url in session.urls { openTab(url: url, select: false) }
            select(tabs[min(max(session.selected, 0), tabs.count - 1)])
        } else {
            openTab(url: nil, select: true)
        }
    }

    // MARK: Layout

    private func buildLayout() {
        let separator = UIView()
        separator.backgroundColor = .separator
        contentContainer.backgroundColor = .systemBackground
        contentContainer.clipsToBounds = true

        // Toolbar
        addressField.borderStyle = .none
        addressField.backgroundColor = .tertiarySystemFill
        addressField.layer.cornerRadius = 10
        addressField.font = .preferredFont(forTextStyle: .subheadline)
        addressField.placeholder = "Search or enter website name"
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL
        addressField.delegate = self
        let lock = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        lock.tintColor = .secondaryLabel
        lock.contentMode = .center
        lock.frame = CGRect(x: 0, y: 0, width: 32, height: 20)
        addressField.leftView = lock
        addressField.leftViewMode = .always
        bookmarkButton.frame = CGRect(x: 0, y: 0, width: 34, height: 30)
        addressField.rightView = bookmarkButton
        addressField.rightViewMode = .unlessEditing
        addressField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A long URL must shrink the address bar, never push the toolbar buttons off screen.
        addressField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        extensionButtonStack.axis = .horizontal
        extensionButtonStack.spacing = 2

        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 4
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        for v in [backButton, forwardButton, reloadButton, addressField, installButton, extensionButtonStack,
                  extensionsMenuButton, mainMenuButton] as [UIView] {
            toolbar.addArrangedSubview(v)
        }
        toolbar.setCustomSpacing(10, after: reloadButton)
        toolbar.setCustomSpacing(10, after: addressField)

        progressBar.trackTintColor = .clear
        progressBar.isHidden = true

        for v in [tabStrip, toolbar, bookmarksBar, separator, contentContainer, progressBar, sidePanelContainer] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        bookmarksBarHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: AppSettings.showBookmarksBar ? 30 : 0)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: safe.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 38),

            toolbar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 46),

            bookmarksBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bookmarksBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            bookmarksBarHeight,

            separator.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: sidePanelContainer.leadingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: separator.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        buildSidePanel(below: separator)

        suggestionsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(suggestionsView)
        NSLayoutConstraint.activate([
            suggestionsView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -2),
            suggestionsView.leadingAnchor.constraint(equalTo: addressField.leadingAnchor),
            suggestionsView.trailingAnchor.constraint(equalTo: addressField.trailingAnchor),
        ])
    }

    private func wireUpCallbacks() {
        tabStrip.onSelect = { [weak self] index in
            guard let self, self.tabs.indices.contains(index) else { return }
            self.select(self.tabs[index])
        }
        tabStrip.onClose = { [weak self] index in
            guard let self, self.tabs.indices.contains(index) else { return }
            self.close(self.tabs[index])
        }
        tabStrip.onNewTab = { [weak self] in self?.openTab(url: nil, select: true) }
        tabStrip.menuProvider = { [weak self] index in self?.tabMenu(at: index) }

        bookmarksBar.onOpen = { [weak self] url, newTab in
            guard let self else { return }
            if newTab { self.openTab(url: url, select: false, insertAfterActive: true) } else { self.navigate(to: url) }
        }
        bookmarksBar.reload()

        addressField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.suggestionsView.update(for: self.addressField.text ?? "")
        }, for: .editingChanged)
        suggestionsView.onPick = { [weak self] suggestion in self?.pick(suggestion) }

        // Press and hold Back / Forward for the page history, like on a Mac.
        backButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(MainActor.assumeIsolated { self?.navigationHistoryMenu(back: true) ?? [] })
        }])
        forwardButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(MainActor.assumeIsolated { self?.navigationHistoryMenu(back: false) ?? [] })
        }])

        NotificationCenter.default.publisher(for: FaviconStore.didChange)
            .sink { [weak self] _ in self?.reloadTabStrip() }
            .store(in: &cancellables)

        ExtensionManager.shared.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshExtensionButtons() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: BookmarkStore.didChange)
            .sink { [weak self] _ in self?.bookmarksBar.reload(); self?.updateToolbar() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] note in
                guard let self, let scene = note.object as? UIScene, scene === self.view.window?.windowScene else { return }
                WindowRegistry.shared.focus(self)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .sink { [weak self] note in
                guard let self, let scene = note.object as? UIScene, scene === self.view.window?.windowScene else { return }
                self.windowWillClose()
            }
            .store(in: &cancellables)

        // Extensions update badge text (e.g. blocked-ad counts) at any time; poll lightly to reflect it.
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExtensionButtons() }
        }
    }

    private func applySettings() {
        let height: CGFloat = AppSettings.showBookmarksBar ? 30 : 0
        if bookmarksBarHeight.constant != height { bookmarksBarHeight.constant = height }
        let ua = AppSettings.userAgent.string
        for tab in tabs where tab.webView.customUserAgent != ua { tab.applyUserAgent() }
    }

    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, select shouldSelect: Bool = true,
                 configuration: WKWebViewConfiguration? = nil,
                 insertAfterActive: Bool = false) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration)
        tab.window = self
        tab.webView.uiDelegate = self
        tab.webView.navigationDelegate = self
        tab.onChange = { [weak self] tab in self?.tabDidChange(tab) }

        var index = tabs.count
        if insertAfterActive, let active = activeTab, let i = tabs.firstIndex(of: active) { index = i + 1 }
        tabs.insert(tab, at: index)
        ExtensionManager.shared.controller.didOpenTab(tab)

        if let url {
            tab.load(url)
        } else if configuration == nil, let home = AppSettings.url(fromInput: AppSettings.homepage) {
            tab.load(home)
        }

        if shouldSelect || activeTab == nil { select(tab) }
        reloadTabStrip()
        SessionStore.save(self)

        if shouldSelect, url == nil, configuration == nil, AppSettings.homepage.isEmpty {
            DispatchQueue.main.async { self.focusAddressBar() }
        }
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard tab !== activeTab, tabs.contains(tab) else { return }
        let previous = activeTab
        previous?.webView.removeFromSuperview()
        activeTab = tab

        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        ExtensionManager.shared.controller.didActivateTab(tab, previousActiveTab: previous)
        // Give the page keyboard/pointer focus so the first click on it works (not just focuses it).
        if !tab.isBlank, !addressField.isFirstResponder { webView.becomeFirstResponder() }
        updateToolbar()
        reloadTabStrip()
        refreshExtensionButtons()
        SessionStore.save(self)
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        if let url = tab.webView.url, url.absoluteString != "about:blank" { closedTabURLs.append(url) }
        tabs.remove(at: index)
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        ExtensionManager.shared.controller.didCloseTab(tab, windowIsClosing: false)

        if tab === activeTab {
            activeTab = nil
            if tabs.isEmpty {
                openTab(url: nil, select: true)
            } else {
                select(tabs[min(index, tabs.count - 1)])
            }
        }
        reloadTabStrip()
        SessionStore.save(self)
    }

    func navigate(to url: URL) {
        if let tab = activeTab { tab.load(url) } else { openTab(url: url) }
    }

    private func tabDidChange(_ tab: BrowserTab) {
        reloadTabStrip()
        if tab === activeTab { updateToolbar() }
        SessionStore.save(self)
    }

    private func reloadTabStrip() {
        let selected = activeTab.flatMap { tabs.firstIndex(of: $0) } ?? -1
        tabStrip.update(items: tabs.map { ($0.title, $0.webView.isLoading, FaviconStore.shared.icon(for: $0.webView.url)) },
                        selected: selected)
    }

    private func tabMenu(at index: Int) -> UIMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        return UIMenu(children: [
            UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { _ in tab.webView.reload() },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                if let url = tab.webView.url { self?.openTab(url: url, select: false, insertAfterActive: true) }
            },
            UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = tab.webView.url
            },
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.close(tab) },
            UIAction(title: "Close Other Tabs") { [weak self] _ in
                guard let self else { return }
                self.select(tab)
                for other in self.tabs where other !== tab { self.close(other) }
            },
        ])
    }

    // MARK: Toolbar

    private func updateToolbar() {
        guard let tab = activeTab else { return }
        let webView = tab.webView
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        reloadButton.configuration?.image = Self.symbol(webView.isLoading ? "xmark" : "arrow.clockwise")

        if !addressField.isEditing {
            addressField.text = tab.isBlank ? "" : webView.url?.absoluteString
        }
        let secure = webView.hasOnlySecureContent && webView.url?.scheme == "https"
        (addressField.leftView as? UIImageView)?.image = UIImage(systemName: tab.isBlank ? "magnifyingglass" : (secure ? "lock.fill" : "globe"))
        bookmarkButton.configuration?.image = Self.symbol(BookmarkStore.contains(webView.url) ? "star.fill" : "star")

        progressBar.isHidden = !webView.isLoading
        progressBar.setProgress(Float(webView.estimatedProgress), animated: webView.isLoading)

        let isStorePage = ChromeWebStore.extensionID(from: webView.url) != nil || FirefoxAddons.slug(from: webView.url) != nil
        if installButton.isHidden == isStorePage { installButton.isHidden = !isStorePage }

        let showStartPage = tab.isBlank && !webView.isLoading
        startPage.view.isHidden = !showStartPage
        if showStartPage { contentContainer.bringSubviewToFront(startPage.view) }
    }

    private func reloadOrStop() {
        guard let webView = activeTab?.webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    private func toggleBookmark() {
        guard let tab = activeTab, let url = tab.webView.url, !tab.isBlank else { return }
        BookmarkStore.toggle(title: tab.title, url: url)
    }

    func focusAddressBar() {
        addressField.becomeFirstResponder()
        addressField.selectAll(nil)
    }

    private func installFromCurrentStorePage() {
        let url = activeTab?.webView.url
        if let id = ChromeWebStore.extensionID(from: url) {
            ExtensionManager.shared.installFromChromeWebStore(id: id, presenter: self)
        } else if let slug = FirefoxAddons.slug(from: url) {
            ExtensionManager.shared.installFromFirefoxAddons(slug: slug, presenter: self)
        }
    }

    // MARK: Extensions in the toolbar

    private func refreshExtensionButtons() {
        let manager = ExtensionManager.shared
        let active = manager.activeContexts
        let activeIDs = Set(active.map(\.record.id))

        for (id, button) in extensionButtons where !activeIDs.contains(id) {
            button.removeFromSuperview()
            extensionButtons[id] = nil
        }

        for (record, context) in active {
            let button: ExtensionActionButton
            if let existing = extensionButtons[record.id] {
                button = existing
            } else {
                button = ExtensionActionButton()
                button.addAction(UIAction { [weak self, weak context] _ in
                    guard let self, let context else { return }
                    self.extensionButtonTapped(context)
                }, for: .primaryActionTriggered)
                extensionButtons[record.id] = button
                extensionButtonStack.addArrangedSubview(button)
            }
            let action = activeTab.flatMap { context.action(for: $0) } ?? context.action(for: nil)
            let icon = action?.icon(for: CGSize(width: 20, height: 20)) ?? manager.icon(for: record, size: 20)
            let title = action?.label ?? manager.displayName(for: record)
            button.configure(icon: icon, badge: action?.badgeText ?? "", title: title, enabled: action?.isEnabled ?? true)
        }
    }

    /// Called by `ExtensionManager` when an extension wants its popup shown.
    func presentExtensionPopup(_ action: WKWebExtension.Action, for context: WKWebExtensionContext) {
        guard let popup = action.popupViewController else { return }
        let anchor: UIView = ExtensionManager.shared.record(for: context)
            .flatMap { extensionButtons[$0.id] } ?? extensionsMenuButton

        let show = { [weak self] in
            guard let self else { return }
            popup.modalPresentationStyle = .popover
            if popup.preferredContentSize == .zero {
                popup.preferredContentSize = CGSize(width: 380, height: 540)
            }
            if let pop = popup.popoverPresentationController {
                pop.sourceView = anchor
                pop.sourceRect = anchor.bounds
                pop.permittedArrowDirections = [.up]
            }
            self.present(popup, animated: true)
        }
        if let presented = presentedViewController {
            presented.dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }

    private func extensionsMenuElements() -> [UIMenuElement] {
        let manager = ExtensionManager.shared
        var items: [UIMenuElement] = manager.records.map { record in
            let name = manager.displayName(for: record)
            var children: [UIMenuElement] = []
            if let context = manager.contexts[record.id] {
                children.append(UIAction(title: "Open", image: UIImage(systemName: "cursorarrow.click")) { [weak self] _ in
                    context.performAction(for: self?.activeTab)
                })
                if context.optionsPageURL != nil {
                    children.append(UIAction(title: "Options…", image: UIImage(systemName: "gearshape")) { _ in
                        manager.openOptions(for: record.id)
                    })
                }
            }
            if let context = manager.contexts[record.id], let panelURL = ChromeCompat.shared.panelURL(for: context) {
                children.insert(UIAction(title: "Open Side Panel", image: UIImage(systemName: "sidebar.right")) { [weak self] _ in
                    self?.showSidePanel(for: context, url: panelURL)
                }, at: min(1, children.count))
            }
            children.append(UIAction(title: record.enabled ? "Turn Off" : "Turn On",
                                     image: UIImage(systemName: record.enabled ? "pause.circle" : "play.circle")) { _ in
                manager.setEnabled(!record.enabled, for: record.id)
            })
            children.append(UIAction(title: "Remove…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                Alerts.confirm(title: "Remove “\(name)”?", message: "Its settings and data will be deleted.",
                               confirmTitle: "Remove", destructive: true) { ok in
                    if ok { manager.remove(record.id) }
                }
            })
            return UIMenu(title: name, image: manager.icon(for: record, size: 20), children: children)
        }
        if items.isEmpty {
            items.append(UIAction(title: "No extensions yet", attributes: .disabled) { _ in })
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Manage Extensions…", image: UIImage(systemName: "puzzlepiece.extension")) { [weak self] _ in
                self?.showExtensionsManager()
            },
            UIAction(title: "Extension Console", image: UIImage(systemName: "terminal")) { [weak self] _ in
                let host = UIHostingController(rootView: NavigationStack { ExtensionConsoleView() })
                host.modalPresentationStyle = .formSheet
                self?.present(host, animated: true)
            },
            UIAction(title: "Chrome Web Store", image: UIImage(systemName: "bag")) { [weak self] _ in
                self?.openTab(url: ChromeWebStore.home)
            },
            UIAction(title: "Firefox Add-ons", image: UIImage(systemName: "flame")) { [weak self] _ in
                self?.openTab(url: FirefoxAddons.home)
            },
        ]))
        return items
    }

    private func mainMenuElements() -> [UIMenuElement] {
        let tab = activeTab
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Paste and Go", image: UIImage(systemName: "doc.on.clipboard"),
                         attributes: UIPasteboard.general.hasStrings ? [] : .disabled) { [weak self] _ in self?.pasteAndGo() },
                UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in self?.openTab(url: nil) },
                UIAction(title: "New Window", image: UIImage(systemName: "macwindow.badge.plus")) { [weak self] _ in self?.newWindow() },
                UIAction(title: "Reopen Closed Tab", image: UIImage(systemName: "arrow.uturn.backward"),
                         attributes: closedTabURLs.isEmpty ? .disabled : []) { [weak self] _ in self?.reopenClosedTab() },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in self?.findInPage() },
                UIAction(title: "Zoom In", image: UIImage(systemName: "plus.magnifyingglass")) { [weak self] _ in self?.zoom(by: 0.1) },
                UIAction(title: "Zoom Out", image: UIImage(systemName: "minus.magnifyingglass")) { [weak self] _ in self?.zoom(by: -0.1) },
                UIAction(title: "Actual Size", image: UIImage(systemName: "1.magnifyingglass")) { [weak self] _ in self?.resetZoom() },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up"),
                         attributes: tab?.webView.url == nil ? .disabled : []) { [weak self] _ in self?.sharePage() },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Extensions…", image: UIImage(systemName: "puzzlepiece.extension")) { [weak self] _ in self?.showExtensionsManager() },
                UIAction(title: "History", image: UIImage(systemName: "clock")) { [weak self] _ in self?.showHistory() },
                UIAction(title: "Settings…", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.showSettings() },
            ]),
        ]
    }

    // MARK: Commands

    func newWindow() {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) { error in
            Task { @MainActor in
                Alerts.show(title: "Couldn't open a new window", message: error.localizedDescription)
            }
        }
    }

    private func reopenClosedTab() {
        guard let url = closedTabURLs.popLast() else { return }
        openTab(url: url, select: true, insertAfterActive: true)
    }

    private func findInPage() {
        activeTab?.webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    private func zoom(by delta: CGFloat) {
        guard let webView = activeTab?.webView else { return }
        webView.pageZoom = min(3, max(0.3, webView.pageZoom + delta))
    }

    private func resetZoom() {
        activeTab?.webView.pageZoom = 1
    }

    private func sharePage() {
        guard let url = activeTab?.webView.url else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = mainMenuButton
        share.popoverPresentationController?.sourceRect = mainMenuButton.bounds
        present(share, animated: true)
    }

    func showExtensionsManager() {
        let view = ExtensionsView(openURL: { [weak self] url in self?.openTab(url: url) })
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    private func showSettings() {
        let host = UIHostingController(rootView: SettingsView())
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    // MARK: Keyboard shortcuts (hold ⌘ to see them all)

    override var keyCommands: [UIKeyCommand]? {
        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector,
                     _ plist: Any? = nil) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags, propertyList: plist)
            // Only ⌘/⌃ shortcuts may override the system; plain keys must always reach text fields.
            c.wantsPriorityOverSystemBehavior = !flags.isEmpty || input == UIKeyCommand.inputUpArrow
                || input == UIKeyCommand.inputDownArrow
            return c
        }
        var list: [UIKeyCommand] = [
            command("New Tab", "t", .command, #selector(cmdNewTab)),
            command("New Window", "n", .command, #selector(cmdNewWindow)),
            command("Close Tab", "w", .command, #selector(cmdCloseTab)),
            command("Reopen Closed Tab", "t", [.command, .shift], #selector(cmdReopenTab)),
            command("Open Location", "l", .command, #selector(cmdFocusAddress)),
            command("Reload Page", "r", .command, #selector(cmdReload)),
            command("Reload Without Cache", "r", [.command, .alternate], #selector(cmdHardReload)),
            command("Back", "[", .command, #selector(cmdBack)),
            command("Forward", "]", .command, #selector(cmdForward)),
            command("Back", UIKeyCommand.inputLeftArrow, .command, #selector(cmdBack)),
            command("Forward", UIKeyCommand.inputRightArrow, .command, #selector(cmdForward)),
            command("Show Next Tab", "\t", .control, #selector(cmdNextTab)),
            command("Show Previous Tab", "\t", [.control, .shift], #selector(cmdPreviousTab)),
            command("Show Next Tab", "]", [.command, .shift], #selector(cmdNextTab)),
            command("Show Previous Tab", "[", [.command, .shift], #selector(cmdPreviousTab)),
            command("Find…", "f", .command, #selector(cmdFind)),
            command("Zoom In", "=", .command, #selector(cmdZoomIn)),
            command("Zoom In", "+", .command, #selector(cmdZoomIn)),
            command("Zoom Out", "-", .command, #selector(cmdZoomOut)),
            command("Actual Size", "0", .command, #selector(cmdZoomReset)),
            command("Add Bookmark", "d", .command, #selector(cmdBookmark)),
            command("Toggle Bookmarks Bar", "b", [.command, .shift], #selector(cmdToggleBookmarksBar)),
            command("Extensions", "e", [.command, .shift], #selector(cmdExtensions)),
            command("Settings", ",", .command, #selector(cmdSettings)),
            command("Show History", "y", .command, #selector(cmdHistory)),
            command("Stop", UIKeyCommand.inputEscape, [], #selector(cmdEscape)),
        ]
        if !suggestionsView.isHidden {
            list.append(command("Next Suggestion", UIKeyCommand.inputDownArrow, [], #selector(cmdSuggestionDown)))
            list.append(command("Previous Suggestion", UIKeyCommand.inputUpArrow, [], #selector(cmdSuggestionUp)))
        }
        for i in 1...9 {
            list.append(command(i == 9 ? "Show Last Tab" : "Show Tab \(i)", "\(i)", .command, #selector(cmdSelectTab(_:)), i))
        }
        return list
    }

    @objc private func cmdNewTab() { openTab(url: nil) }
    @objc private func cmdNewWindow() { newWindow() }
    @objc private func cmdCloseTab() { if let tab = activeTab { close(tab) } }
    @objc private func cmdReopenTab() { reopenClosedTab() }
    @objc private func cmdFocusAddress() { focusAddressBar() }
    @objc private func cmdReload() { activeTab?.webView.reload() }
    @objc private func cmdHardReload() { activeTab?.webView.reloadFromOrigin() }
    @objc private func cmdBack() { activeTab?.webView.goBack() }
    @objc private func cmdForward() { activeTab?.webView.goForward() }
    @objc private func cmdFind() { findInPage() }
    @objc private func cmdZoomIn() { zoom(by: 0.1) }
    @objc private func cmdZoomOut() { zoom(by: -0.1) }
    @objc private func cmdZoomReset() { resetZoom() }
    @objc private func cmdBookmark() { toggleBookmark() }
    @objc private func cmdExtensions() { showExtensionsManager() }
    @objc private func cmdSettings() { showSettings() }

    @objc private func cmdToggleBookmarksBar() {
        UserDefaults.standard.set(!AppSettings.showBookmarksBar, forKey: AppSettings.Key.showBookmarksBar)
    }

    @objc private func cmdEscape() {
        if !suggestionsView.isHidden {
            suggestionsView.hide()
        } else if addressField.isFirstResponder {
            addressField.resignFirstResponder()
            updateToolbar()
        } else {
            activeTab?.webView.stopLoading()
        }
    }

    @objc private func cmdNextTab() { cycleTab(by: 1) }
    @objc private func cmdPreviousTab() { cycleTab(by: -1) }

    @objc private func cmdSelectTab(_ sender: UIKeyCommand) {
        guard let n = sender.propertyList as? Int, !tabs.isEmpty else { return }
        select(n == 9 ? tabs[tabs.count - 1] : tabs[min(n - 1, tabs.count - 1)])
    }

    private func cycleTab(by delta: Int) {
        guard let active = activeTab, let i = tabs.firstIndex(of: active), tabs.count > 1 else { return }
        select(tabs[(i + delta + tabs.count) % tabs.count])
    }

    private func navigationHistoryMenu(back: Bool) -> [UIMenuElement] {
        guard let webView = activeTab?.webView else { return [] }
        let list = webView.backForwardList
        let items = back ? Array(list.backList.reversed()) : list.forwardList
        return items.prefix(20).map { item in
            let title = item.title?.isEmpty == false ? item.title! : (item.url.host ?? item.url.absoluteString)
            return UIAction(title: title, image: FaviconStore.shared.icon(for: item.url)) { _ in
                webView.go(to: item)
            }
        }
    }

    // MARK: Side panel (chrome.sidePanel)

    private func buildSidePanel(below separator: UIView) {
        sidePanelContainer.translatesAutoresizingMaskIntoConstraints = false
        sidePanelContainer.backgroundColor = .systemBackground
        sidePanelContainer.clipsToBounds = true

        let border = UIView()
        border.backgroundColor = .separator
        let header = UIView()
        header.backgroundColor = .secondarySystemBackground
        sidePanelTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let closeButton = Self.toolbarButton("xmark", "Close Side Panel") { [weak self] in self?.hideSidePanel() }
        for v in [border, header, sidePanelTitle, closeButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        sidePanelContainer.addSubview(header)
        sidePanelContainer.addSubview(border)
        header.addSubview(sidePanelTitle)
        header.addSubview(closeButton)

        sidePanelWidth = sidePanelContainer.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sidePanelContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            sidePanelContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidePanelContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidePanelWidth,
            border.leadingAnchor.constraint(equalTo: sidePanelContainer.leadingAnchor),
            border.topAnchor.constraint(equalTo: sidePanelContainer.topAnchor),
            border.bottomAnchor.constraint(equalTo: sidePanelContainer.bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            header.topAnchor.constraint(equalTo: sidePanelContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: border.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: sidePanelContainer.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            sidePanelTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            sidePanelTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sidePanelTitle.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    func showSidePanel(for context: WKWebExtensionContext, url: URL) {
        if sidePanelContext !== context || sidePanelWebView == nil {
            sidePanelWebView?.removeFromSuperview()
            let configuration = context.webViewConfiguration ?? BrowserTab.makeConfiguration()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.isInspectable = true
            webView.uiDelegate = self
            webView.translatesAutoresizingMaskIntoConstraints = false
            sidePanelContainer.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: sidePanelContainer.topAnchor, constant: 36),
                webView.leadingAnchor.constraint(equalTo: sidePanelContainer.leadingAnchor, constant: 1),
                webView.trailingAnchor.constraint(equalTo: sidePanelContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: sidePanelContainer.bottomAnchor),
            ])
            sidePanelWebView = webView
            sidePanelContext = context
            webView.load(URLRequest(url: url))
        } else if sidePanelWebView?.url != url {
            sidePanelWebView?.load(URLRequest(url: url))
        }
        sidePanelTitle.text = context.webExtension.displayName ?? "Side Panel"
        let width = min(420, max(320, view.bounds.width * 0.32))
        UIView.animate(withDuration: 0.2) {
            self.sidePanelWidth.constant = width
            self.view.layoutIfNeeded()
        }
    }

    func hideSidePanel() {
        UIView.animate(withDuration: 0.2, animations: {
            self.sidePanelWidth.constant = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.sidePanelWebView?.removeFromSuperview()
            self.sidePanelWebView = nil
            self.sidePanelContext = nil
        })
    }

    func hideSidePanel(onlyFor context: WKWebExtensionContext) {
        if sidePanelContext === context { hideSidePanel() }
    }

    private func extensionButtonTapped(_ context: WKWebExtensionContext) {
        if ChromeCompat.shared.opensPanelOnActionClick(context), let url = ChromeCompat.shared.panelURL(for: context) {
            if sidePanelContext === context, sidePanelWidth.constant > 0 {
                hideSidePanel()
            } else {
                showSidePanel(for: context, url: url)
            }
        } else {
            context.performAction(for: activeTab)
        }
    }

    /// A small banner at the top of the page (used for extension notifications).
    func showToast(_ text: String) {
        let label = PaddingLabel()
        label.text = text
        label.numberOfLines = 3
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 4, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    func showHistory() {
        let view = HistoryView(open: { [weak self] url in self?.navigate(to: url) })
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    fileprivate func pick(_ suggestion: Suggestion) {
        suggestionsView.hide()
        guard let url = suggestion.url else { return }
        navigate(to: url)
        addressField.resignFirstResponder()
        activeTab?.webView.becomeFirstResponder()
    }

    /// Opens whatever is on the clipboard (a URL or search text). Also a workaround when no keyboard is available.
    func pasteAndGo() {
        guard let text = UIPasteboard.general.string, let url = AppSettings.url(fromInput: text) else { return }
        suggestionsView.hide()
        addressField.resignFirstResponder()
        navigate(to: url)
    }

    @objc private func cmdHistory() { showHistory() }
    @objc private func cmdSuggestionDown() { suggestionsView.moveHighlight(by: 1) }
    @objc private func cmdSuggestionUp() { suggestionsView.moveHighlight(by: -1) }

    fileprivate func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }
}

// MARK: - Address bar

extension BrowserWindow: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        DispatchQueue.main.async { textField.selectAll(nil) }
    }

    /// Adds "Paste and Go" to the address bar's Paste menu, like Safari.
    func textField(_ textField: UITextField, editMenuForCharactersIn range: NSRange,
                   suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard UIPasteboard.general.hasStrings else { return UIMenu(children: suggestedActions) }
        let pasteAndGo = UIAction(title: "Paste and Go", image: UIImage(systemName: "arrow.right.circle")) { [weak self] _ in
            self?.pasteAndGo()
        }
        return UIMenu(children: [pasteAndGo] + suggestedActions)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        suggestionsView.hide()
        updateToolbar()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if !suggestionsView.isHidden, let suggestion = suggestionsView.highlightedItem {
            pick(suggestion)
            return false
        }
        suggestionsView.hide()
        if let url = AppSettings.url(fromInput: textField.text ?? "") {
            navigate(to: url)
        }
        textField.resignFirstResponder()
        activeTab?.webView.becomeFirstResponder()
        return false
    }
}

// MARK: - WKUIDelegate

extension BrowserWindow: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank links and window.open(): open in a new tab next to the current one.
        openTab(url: nil, select: true, configuration: configuration, insertAfterActive: true).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tab(for: webView) { close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        (UIApplication.topViewController(preferring: view.window) ?? self).present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        (UIApplication.topViewController(preferring: view.window) ?? self).present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        (UIApplication.topViewController(preferring: view.window) ?? self).present(alert, animated: true)
    }

    /// Adds "Open in New Tab" plus every extension's chrome.contextMenus items to the right-click menu.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let tab = tab(for: webView) else { completionHandler(nil); return }

        var leading: [UIMenuElement] = []
        if let link = elementInfo.linkURL {
            leading.append(UIAction(title: "Open Link in New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.openTab(url: link, select: false, insertAfterActive: true)
            })
        }
        let extensionItems = ExtensionManager.shared.activeContexts.flatMap { $0.context.menuItems(for: tab) }

        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
            MainActor.assumeIsolated {
                var children: [UIMenuElement] = leading + suggested
                if !extensionItems.isEmpty {
                    children.append(UIMenu(options: .displayInline, children: extensionItems))
                }
                return UIMenu(children: children)
            }
        }
        completionHandler(configuration)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserWindow: WKNavigationDelegate {
    private static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio",
                                                        "itms-apps", "itms-appss", "maps", "shortcuts"]

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = .desktop

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           Self.externalSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        // chrome-extension://<Chrome Web Store ID>/… → the same file in the installed extension.
        if let url = navigationAction.request.url, url.scheme == "chrome-extension" {
            decisionHandler(.cancel, preferences)
            let mapped = ExtensionManager.shared.localURL(forChromeExtensionURL: url, from: webView.url)
            ExtensionLogStore.shared.add(extension: "Inkwell", level: mapped == nil ? "warn" : "info", where: "app",
                                         text: "Tab navigated to \(url.scheme ?? "")://\(url.host ?? "")\(url.path) → "
                                            + (mapped.map { "opened \($0.path)" } ?? "no installed extension matches"))
            if let mapped {
                webView.load(URLRequest(url: mapped))
            }
            return
        }
        if let url = navigationAction.request.url, ["crx", "xpi"].contains(url.pathExtension.lowercased()) {
            decisionHandler(.download, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let mime = navigationResponse.response.mimeType ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment")
            || mime == "application/x-chrome-extension" || mime == "application/x-xpinstall" {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let nsError = error as NSError
        // Cancelled loads and "frame load interrupted" (downloads) aren't real failures.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let message = nsError.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <html><head><meta name="viewport" content="width=device-width"><style>
        body{font:15px -apple-system,sans-serif;color:#666;display:flex;align-items:center;justify-content:center;height:90vh;text-align:center}
        h1{font-size:22px;color:#333} @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#aaa}h1{color:#eee}}
        </style></head><body><div><h1>This page couldn't be opened</h1><p>\(message)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: failingURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        HistoryStore.shared.record(url: webView.url, title: webView.title)
        let pageURL = webView.url
        let script = "(function(){var l=document.querySelector(\"link[rel~='icon'],link[rel='apple-touch-icon']\");return l?l.href:'';})()"
        webView.evaluateJavaScript(script) { result, _ in
            let href = result as? String
            Task { @MainActor in
                let declared = href.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                FaviconStore.shared.load(pageURL: pageURL, declaredIcon: declared)
            }
        }
        if let tab = tab(for: webView), tab === activeTab {
            updateToolbar()
            if !addressField.isFirstResponder, presentedViewController == nil { webView.becomeFirstResponder() }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKWebExtensionWindow

extension BrowserWindow: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        tabs
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        activeTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        view.window?.frame ?? view.bounds
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        view.window?.windowScene?.screen.bounds ?? view.bounds
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let session = view.window?.windowScene?.session {
            UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil, errorHandler: nil)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let session = view.window?.windowScene?.session {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
        }
        completionHandler(nil)
    }
}

// MARK: - Small helpers

extension BrowserWindow {
    static func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    }

    static func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = symbol(systemImage)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.toolTip = label
        button.isPointerInteractionEnabled = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

enum FirefoxAddons {
    static let home = URL(string: "https://addons.mozilla.org/firefox/extensions/")!

    /// https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/ → "ublock-origin"
    static func slug(from url: URL?) -> String? {
        guard let url, url.host == "addons.mozilla.org" else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "addon"), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }
}

final class PaddingLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 28, height: size.height + 20)
    }
}

import UIKit

/// Mac-style horizontal tab strip with close buttons, a "+" button, and right-click menus.
final class TabStripView: UIView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var menuProvider: ((Int) -> UIMenu?)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var items: [TabItemView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let add = BrowserWindow.toolbarButton("plus", "New Tab") { [weak self] in self?.onNewTab?() }
        add.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(add)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            add.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(items newItems: [(title: String, loading: Bool, icon: UIImage?)], selected: Int) {
        while items.count < newItems.count {
            let item = TabItemView()
            item.onTap = { [weak self, weak item] in
                guard let self, let item, let i = self.items.firstIndex(of: item) else { return }
                self.onSelect?(i)
            }
            item.onClose = { [weak self, weak item] in
                guard let self, let item, let i = self.items.firstIndex(of: item) else { return }
                self.onClose?(i)
            }
            item.menuProvider = { [weak self, weak item] in
                guard let self, let item, let i = self.items.firstIndex(of: item) else { return nil }
                return self.menuProvider?(i)
            }
            items.append(item)
            stack.addArrangedSubview(item)
        }
        while items.count > newItems.count {
            items.removeLast().removeFromSuperview()
        }
        for (i, data) in newItems.enumerated() {
            items[i].configure(title: data.title, loading: data.loading, icon: data.icon, selected: i == selected)
        }
        if items.indices.contains(selected) {
            layoutIfNeeded()
            scrollView.scrollRectToVisible(items[selected].frame, animated: false)
        }
    }
}

private final class TabItemView: UIView, UIContextMenuInteractionDelegate {
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let iconView = UIImageView()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        label.font = .preferredFont(forTextStyle: .footnote)
        label.lineBreakMode = .byTruncatingTail
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.hidesWhenStopped = true
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.isPointerInteractionEnabled = true
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        let row = UIStackView(arrangedSubviews: [closeButton, iconView, label, spinner])
        row.spacing = 4
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 210),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIPointerInteraction(delegate: nil))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, loading: Bool, icon: UIImage?, selected: Bool) {
        label.text = title
        iconView.image = icon ?? UIImage(systemName: "globe")
        accessibilityLabel = title
        label.textColor = selected ? .label : .secondaryLabel
        backgroundColor = selected ? .systemBackground : .clear
        layer.shadowOpacity = selected ? 0.08 : 0
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    @objc private func tapped() { onTap?() }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

/// A toolbar button for one extension: its current action icon plus a badge (e.g. blocked count).
final class ExtensionActionButton: UIButton {
    private let badge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        configuration = config
        isPointerInteractionEnabled = true

        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = .systemRed
        badge.textAlignment = .center
        badge.layer.cornerRadius = 6
        badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.isUserInteractionEnabled = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            badge.heightAnchor.constraint(equalToConstant: 13),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 13),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(icon: UIImage?, badge text: String, title: String, enabled: Bool) {
        let image = (icon ?? UIImage(systemName: "puzzlepiece.extension"))?
            .preparingThumbnail(of: CGSize(width: 20, height: 20)) ?? icon
        if configuration?.image !== image {
            configuration?.image = image
        }
        accessibilityLabel = title
        toolTip = title
        alpha = enabled ? 1 : 0.4
        let trimmed = String(text.prefix(4))
        badge.isHidden = trimmed.isEmpty
        if badge.text != " \(trimmed) " { badge.text = " \(trimmed) " }
    }
}

/// Mac Safari–style favorites bar under the toolbar.
final class BookmarksBarView: UIView {
    var onOpen: ((URL, _ newTab: Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .secondarySystemBackground
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bookmarks = BookmarkStore.all
        if bookmarks.isEmpty {
            let hint = UILabel()
            hint.text = "Press ⌘D to bookmark a page"
            hint.font = .preferredFont(forTextStyle: .caption1)
            hint.textColor = .tertiaryLabel
            stack.addArrangedSubview(hint)
            return
        }
        for bookmark in bookmarks {
            var config = UIButton.Configuration.plain()
            config.title = bookmark.title.count > 28 ? String(bookmark.title.prefix(27)) + "…" : bookmark.title
            config.buttonSize = .mini
            config.baseForegroundColor = .label
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.onOpen?(bookmark.url, false)
            })
            button.isPointerInteractionEnabled = true
            button.toolTip = bookmark.url.absoluteString
            button.menu = UIMenu(children: [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    self?.onOpen?(bookmark.url, true)
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = bookmark.url
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    BookmarkStore.remove(bookmark)
                },
            ])
            // Right-click / long-press shows the menu; a normal click opens the bookmark.
            button.showsMenuAsPrimaryAction = false
            stack.addArrangedSubview(button)
        }
    }
}

// MARK: - Address bar suggestions

enum Suggestion {
    case search(String)
    case page(URL, title: String, isBookmark: Bool)
    case go(URL)

    var url: URL? {
        switch self {
        case .search(let text): return AppSettings.searchEngine.url(for: text)
        case .page(let url, _, _): return url
        case .go(let url): return url
        }
    }
}

/// The dropdown under the address bar: "Go to…", "Search for…", then matching bookmarks and history.
final class SuggestionsView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onPick: ((Suggestion) -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    private var heightConstraint: NSLayoutConstraint!
    private(set) var items: [Suggestion] = []
    private(set) var highlighted = 0
    private let rowHeight: CGFloat = 46

    var highlightedItem: Suggestion? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)

        table.dataSource = self
        table.delegate = self
        table.rowHeight = rowHeight
        table.layer.cornerRadius = 12
        table.layer.cornerCurve = .continuous
        table.clipsToBounds = true
        table.backgroundColor = .systemBackground
        table.separatorInset = UIEdgeInsets(top: 0, left: 48, bottom: 0, right: 0)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.translatesAutoresizingMaskIntoConstraints = false
        addSubview(table)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: topAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor
    func update(for rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        var result: [Suggestion] = []
        var seen = Set<URL>()

        if !text.isEmpty {
            let searchURL = AppSettings.searchEngine.url(for: text)
            if let url = AppSettings.url(fromInput: text), url != searchURL {
                result.append(.go(url))
                seen.insert(url)
            }
            result.append(.search(text))

            let q = text.lowercased()
            for bookmark in BookmarkStore.all where result.count < 4 {
                guard !seen.contains(bookmark.url),
                      bookmark.title.lowercased().contains(q)
                        || HistoryStore.displayString(for: bookmark.url).lowercased().contains(q) else { continue }
                result.append(.page(bookmark.url, title: bookmark.title, isBookmark: true))
                seen.insert(bookmark.url)
            }
            for entry in HistoryStore.shared.suggestions(for: text, limit: 8) where result.count < 8 {
                guard !seen.contains(entry.url) else { continue }
                result.append(.page(entry.url, title: entry.title, isBookmark: false))
                seen.insert(entry.url)
            }
        }

        items = result
        highlighted = 0
        heightConstraint.constant = CGFloat(items.count) * rowHeight
        isHidden = items.isEmpty
        table.reloadData()
    }

    func hide() {
        items = []
        isHidden = true
    }

    func moveHighlight(by delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
        table.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = .secondaryLabel
        content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        switch items[indexPath.row] {
        case .go(let url):
            content.image = UIImage(systemName: "globe")
            content.text = HistoryStore.displayString(for: url)
            content.secondaryText = "Go to site"
        case .search(let text):
            content.image = UIImage(systemName: "magnifyingglass")
            content.text = text
            content.secondaryText = "Search \(AppSettings.searchEngine.name)"
        case .page(let url, let title, let isBookmark):
            content.image = UIImage(systemName: isBookmark ? "star" : "clock")
            content.text = title
            content.secondaryText = HistoryStore.displayString(for: url)
        }
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = indexPath.row == highlighted ? UIColor.tintColor.withAlphaComponent(0.15) : .clear
        cell.backgroundConfiguration = background
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard items.indices.contains(indexPath.row) else { return }
        onPick?(items[indexPath.row])
    }
}

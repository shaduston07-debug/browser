import SwiftUI
import UIKit

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var date: Date
}

/// Browsing history, newest first, saved to disk. Powers ⌘Y, address-bar suggestions and the start page.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(url: URL?, title: String?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let cleanTitle = (title?.isEmpty == false ? title! : (url.host ?? url.absoluteString))
        if let first = entries.first, first.url == url, Date().timeIntervalSince(first.date) < 60 {
            entries[0].title = cleanTitle
        } else {
            entries.insert(HistoryEntry(url: url, title: cleanTitle, date: Date()), at: 0)
            if entries.count > 5000 { entries.removeLast(entries.count - 5000) }
        }
        scheduleSave()
    }

    func delete(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// Distinct pages matching what's typed, best first (host matches, then most visited).
    func suggestions(for text: String, limit: Int = 6) -> [HistoryEntry] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        var counts: [URL: Int] = [:]
        var latest: [URL: HistoryEntry] = [:]
        for entry in entries {
            let key = entry.url
            let display = Self.displayString(for: key).lowercased()
            guard display.contains(query) || entry.title.lowercased().contains(query) else { continue }
            counts[key, default: 0] += 1
            if latest[key] == nil { latest[key] = entry }
        }
        let ranked = latest.values.sorted { a, b in
            let aPrefix = Self.displayString(for: a.url).lowercased().hasPrefix(query)
            let bPrefix = Self.displayString(for: b.url).lowercased().hasPrefix(query)
            if aPrefix != bPrefix { return aPrefix }
            return (counts[a.url] ?? 0) > (counts[b.url] ?? 0)
        }
        return Array(ranked.prefix(limit))
    }

    /// Most-visited sites (one per host) for the start page.
    func topSites(limit: Int = 12) -> [HistoryEntry] {
        var counts: [String: Int] = [:]
        var representative: [String: HistoryEntry] = [:]
        for entry in entries.prefix(3000) {
            guard let host = entry.url.host else { continue }
            counts[host, default: 0] += 1
            if representative[host] == nil {
                // Prefer the site's root page as the tile target.
                var root = URLComponents()
                root.scheme = entry.url.scheme
                root.host = host
                root.path = "/"
                representative[host] = HistoryEntry(url: root.url ?? entry.url,
                                                    title: Self.siteName(for: host), date: entry.date)
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { representative[$0.key] }
    }

    /// "https://www.example.com/a" → "example.com/a"
    static func displayString(for url: URL) -> String {
        var s = url.absoluteString
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func siteName(for host: String) -> String {
        var h = host
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let name = h.split(separator: ".").first.map(String.init) ?? h
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Favicons

/// Small in-memory favicon cache keyed by host.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()
    static let didChange = Notification.Name("FaviconsDidChange")

    private var icons: [String: UIImage] = [:]
    private var inFlight: Set<String> = []

    func icon(for url: URL?) -> UIImage? {
        guard let host = url?.host else { return nil }
        return icons[host]
    }

    /// Loads the page's declared icon (or /favicon.ico) once per host.
    func load(pageURL: URL?, declaredIcon: URL?) {
        guard let pageURL, let host = pageURL.host, icons[host] == nil, !inFlight.contains(host) else { return }
        let candidates = [declaredIcon, URL(string: "https://\(host)/favicon.ico")].compactMap { $0 }
        inFlight.insert(host)
        Task {
            for candidate in candidates {
                guard let result = try? await URLSession.shared.data(from: candidate) else { continue }
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
                guard status < 400, let image = UIImage(data: result.0) else { continue }
                icons[host] = image.preparingThumbnail(of: CGSize(width: 32, height: 32)) ?? image
                NotificationCenter.default.post(name: Self.didChange, object: nil)
                break
            }
            inFlight.remove(host)
        }
    }
}

// MARK: - History window (⌘Y)

struct HistoryView: View {
    var open: (URL) -> Void

    @ObservedObject private var store = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return store.entries }
        let q = query.lowercased()
        return store.entries.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let items: [HistoryEntry]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered.prefix(1500)) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day, items: (grouped[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    Text("Pages you visit will show up here.").foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Section(group.day.formatted(date: .complete, time: .omitted)) {
                        ForEach(group.items) { entry in
                            Button {
                                dismiss()
                                open(entry.url)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(HistoryStore.displayString(for: entry.url))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.delete([entry.id]) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search history")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(store.entries.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .confirmationDialog("Clear all browsing history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { store.clear() }
            }
        }
    }
}

// MARK: - New-tab start page

struct StartPageView: View {
    var open: (URL) -> Void

    @ObservedObject private var history = HistoryStore.shared
    @State private var bookmarks = BookmarkStore.all

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Inkwell")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                if !bookmarks.isEmpty {
                    section("Favourites", sites: bookmarks.map { Site(title: $0.title, url: $0.url) })
                }
                let top = history.topSites()
                if !top.isEmpty {
                    section("Frequently Visited", sites: top.map { Site(title: $0.title, url: $0.url) })
                }
            }
            .padding(32)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .onReceive(NotificationCenter.default.publisher(for: BookmarkStore.didChange)) { _ in
            bookmarks = BookmarkStore.all
        }
    }

    private struct Site: Identifiable {
        let title: String
        let url: URL
        var id: URL { url }
    }

    private func section(_ title: String, sites: [Site]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(sites) { site in
                    SiteTile(title: site.title, url: site.url) { open(site.url) }
                }
            }
        }
    }
}

private struct SiteTile: View {
    let title: String
    let url: URL
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                    AsyncImage(url: URL(string: "https://\(url.host ?? "")/favicon.ico")) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().frame(width: 30, height: 30)
                        } else {
                            Text(String(HistoryStore.siteName(for: url.host ?? "?").prefix(1)))
                                .font(.title2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }
}

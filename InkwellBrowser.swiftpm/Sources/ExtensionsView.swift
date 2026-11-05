import SwiftUI
import UniformTypeIdentifiers

/// The "Manage Extensions" sheet — like chrome://extensions.
struct ExtensionsView: View {
    var openURL: (URL) -> Void

    @ObservedObject private var manager = ExtensionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importingFolder = false
    @State private var pendingRemoval: InstalledExtension?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if manager.records.isEmpty {
                        Text("No extensions installed yet. Open the Chrome Web Store or Firefox Add-ons, go to any extension's page and tap **Add to Inkwell** in the toolbar — or import a file below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.records) { record in
                        ExtensionRow(record: record, manager: manager) {
                            dismiss()
                            manager.openOptions(for: record.id)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { pendingRemoval = record }
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = record }
                        }
                    }
                } header: {
                    Text("Installed")
                }

                Section {
                    Button {
                        dismiss()
                        openURL(ChromeWebStore.home)
                    } label: {
                        Label("Browse the Chrome Web Store", systemImage: "bag")
                    }
                    Button {
                        dismiss()
                        openURL(FirefoxAddons.home)
                    } label: {
                        Label("Browse Firefox Add-ons", systemImage: "flame")
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import .zip, .crx or .xpi…", systemImage: "doc.zipper")
                    }
                    Button {
                        importingFolder = true
                    } label: {
                        Label("Load Unpacked Folder…", systemImage: "folder")
                    }
                    Button {
                        manager.checkForUpdates()
                    } label: {
                        Label("Update Store Extensions", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!manager.records.contains { $0.storeID != nil })
                } header: {
                    Text("Get extensions")
                } footer: {
                    Text("Extensions run on WebKit's Web Extensions engine (the same one Safari uses), so most Chrome and Firefox extensions work unchanged — content scripts, popups, background service workers, storage, tabs, context menus and declarativeNetRequest ad-blocking. APIs Apple doesn't support (e.g. blocking webRequest, debugger, native messaging) won't work. Tip: for ad-blocking use uBlock Origin Lite.")
                }
            }
            .navigationTitle("Extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .data, .item]) { result in
                if case .success(let url) = result {
                    manager.installInteractively(from: url)
                }
            }
            .background {
                // A second importer on a separate view, because one view can only host one importer.
                Color.clear
                    .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
                        if case .success(let url) = result {
                            manager.installInteractively(from: url)
                        }
                    }
            }
            .alert("Remove extension?", isPresented: Binding(get: { pendingRemoval != nil },
                                                            set: { if !$0 { pendingRemoval = nil } }),
                   presenting: pendingRemoval) { record in
                Button("Remove", role: .destructive) { manager.remove(record.id) }
                Button("Cancel", role: .cancel) {}
            } message: { record in
                Text("“\(manager.displayName(for: record))” and its data will be deleted.")
            }
        }
    }
}

private struct ExtensionRow: View {
    let record: InstalledExtension
    @ObservedObject var manager: ExtensionManager
    var openOptions: () -> Void

    var body: some View {
        let ext = manager.extensions[record.id]
        let errors = manager.errors(for: record)

        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = manager.icon(for: record, size: 40) {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(manager.displayName(for: record)).font(.headline)
                    if let version = ext?.displayVersion {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let description = ext?.displayDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let source = record.storeID {
                    Text(source.hasPrefix("amo:") ? "Firefox Add-ons" : "Chrome Web Store")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if record.enabled, manager.contexts[record.id]?.optionsPageURL != nil {
                    Button("Options", action: openOptions)
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                }
            }

            Spacer()

            Toggle("Enabled", isOn: Binding(get: { record.enabled },
                                            set: { manager.setEnabled($0, for: record.id) }))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

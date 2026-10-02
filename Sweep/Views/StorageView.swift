import SwiftUI
import AppKit

struct SWPStorageView: View {
    @ObservedObject var store: SWPStorageStore
    @State private var sortByName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SWPPageHeader(title: "Storage Explorer", subtitle: "Read-only exploration. Nothing here is selected for cleanup.") {
                if store.isScanning {
                    Button(store.isStopping ? "Stopping" : "Stop") { store.cancel() }
                        .buttonStyle(SWPSecondaryButtonStyle()).disabled(store.isStopping)
                        .accessibilityIdentifier("storage.stop")
                } else if store.rootURL != nil {
                    SWPRefreshButton(isBusy: false) { store.refresh() }
                        .accessibilityIdentifier("storage.rescan")
                }
                Button("Choose folder") { chooseFolder() }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .accessibilityIdentifier("storage.choose-folder")
            }
            if let root = store.rootURL { breadcrumbs(root) }
            if store.isScanning {
                SWPEmptyState(title: store.isStopping ? "Stopping the scan" : "Measuring allocated space",
                              message: "Reading metadata only. Large or protected folders can take longer. Stopped scans are labelled as partial.",
                              isLoading: true)
                Spacer()
            } else if let error = store.scanError {
                SWPEmptyState(title: "Folder scan unavailable", message: error, symbol: "exclamationmark.triangle")
                HStack {
                    Spacer()
                    Button("Try Again") { store.refresh() }.buttonStyle(SWPSecondaryButtonStyle())
                    Spacer()
                }
                Spacer()
            } else if let snapshot = store.snapshot, let current = store.currentEntry {
                inventory(snapshot, current: current)
            } else {
                Spacer()
                SWPEmptyState(title: "Explore a folder by size",
                              message: "Compare files and folders, browse their measured contents, or reveal them in Finder.",
                              symbol: "folder")
                HStack {
                    Spacer()
                    Button("Choose Folder") { chooseFolder() }.buttonStyle(SWPPrimaryButtonStyle())
                    Spacer()
                }
                Spacer()
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane).padding(.top, 36)
        .padding(.bottom, SWPTheme.Spacing.pane)
        .background(SWPTheme.Colors.background)
        .foregroundStyle(SWPTheme.Colors.textPrimary).tint(SWPTheme.Colors.accent)
    }

    private func breadcrumbs(_ root: URL) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Button { store.goBack() } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                    .buttonStyle(SWPSecondaryButtonStyle()).disabled(store.currentPath.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel("Parent folder").accessibilityIdentifier("storage.back")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        Button(root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent) { store.goToRoot() }
                            .disabled(store.currentPath.isEmpty)
                            .help(root.path)
                        ForEach(Array(store.currentPath.enumerated()), id: \.offset) { index, component in
                            Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true)
                            Button(component) { store.goToAncestor(depth: index + 1) }
                                .disabled(index == store.currentPath.count - 1)
                        }
                    }
                    .font(SWPTheme.Fonts.body).buttonStyle(.borderless)
                }
                if let current = store.currentEntry { revealButton(current.url) }
            }
            Text((store.currentEntry?.url ?? root).path)
                .font(SWPTheme.Fonts.mono).foregroundStyle(SWPTheme.Colors.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    @ViewBuilder private func inventory(_ snapshot: SWPStorageSnapshot, current: SWPStorageEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.coverage.cancelled ? "Stopped · partial inventory" : snapshot.root.isPartial ? "Partial inventory" : "Measured contents")
                    .font(SWPTheme.Fonts.rowTitle)
                Text("Scanned \(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeLabel(current)).font(SWPTheme.Fonts.number)
                Text("allocated in this folder").font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }
        }
        if snapshot.root.isPartial {
            Label("Incomplete measurements are lower bounds, not complete folder sizes.", systemImage: "exclamationmark.circle")
                .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.review)
        }
        if let note = current.note {
            Text(note).font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
        }
        if current.children.isEmpty {
            SWPEmptyState(title: current.isPartial ? "No measured children available" : "No browsable entries",
                          message: current.kind == .package ? "Packages are measured as one item; their contents are not exposed as folders." : current.isPartial ? "Rescan or choose another folder to try again." : "This folder had no child entries during the scan.", symbol: "folder")
            Spacer()
        } else {
            HStack {
                Text("\(current.children.count) items · bars compare with the largest item")
                    .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                Spacer(minLength: 8)
                Picker("Sort", selection: $sortByName) {
                    Text("Largest first").tag(false)
                    Text("Name").tag(true)
                }
                .labelsHidden().frame(width: 120)
                .accessibilityLabel("Sort folder contents")
            }
            entryTable(current)
        }
        DisclosureGroup("Scan coverage and size information") {
            ScrollView {
                coverage(snapshot.coverage)
                    .padding(.top, 6)
            }.frame(maxHeight: 140)
        }
        .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
        .accessibilityIdentifier("storage.coverage")
        Text("Allocated space is not reclaimable space. This is a dated, read-only observation.")
            .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
    }

    private func entryTable(_ current: SWPStorageEntry) -> some View {
        let entries = sortByName ? current.children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : current.children
        let maximum = current.children.compactMap(\.allocatedBytes).max() ?? 0
        return Table(entries, selection: $store.selectedEntryID) {
            TableColumn("Name") { entry in
                HStack(spacing: 8) {
                    Image(systemName: symbol(entry.kind)).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(SWPTheme.Fonts.list).lineLimit(1).truncationMode(.middle)
                        if let note = entry.note {
                            Text(note).font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(minHeight: 32).help(entry.url.path + (entry.note.map { "\n" + $0 } ?? ""))
            }
            TableColumn("Kind") { entry in
                Text(kindLabel(entry)).font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
            }.width(100)
            TableColumn("Allocated size") { entry in
                VStack(alignment: .trailing, spacing: 4) {
                    Text(sizeLabel(entry)).font(SWPTheme.Fonts.number)
                    GeometryReader { geometry in
                        Capsule().fill(SWPTheme.Colors.accent.opacity(0.55))
                            .frame(width: geometry.size.width * fraction(entry, maximum: maximum))
                    }.frame(height: 3).accessibilityHidden(true)
                }
                .padding(.vertical, 4)
            }.width(112)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(SWPTheme.Colors.surface)
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = current.children.first(where: { ids.contains($0.id) }) {
                Button("Browse Folder") { store.browse(entry) }.disabled(!entry.canBrowse)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            }
        } primaryAction: { ids in
            if let entry = current.children.first(where: { ids.contains($0.id) }) {
                if entry.canBrowse { store.browse(entry) }
                else { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            }
        }
        .onKeyPress(.rightArrow) {
            guard let entry = current.children.first(where: { $0.id == store.selectedEntryID }), entry.canBrowse else { return .ignored }
            store.browse(entry)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !store.currentPath.isEmpty else { return .ignored }
            store.goBack()
            return .handled
        }
        .accessibilityIdentifier("storage.entries")
        .help("Double-click or press Return to browse a folder. Right arrow browses; left arrow goes to its parent.")
    }

    private func coverage(_ value: SWPStorageCoverage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value.visitedEntries.formatted()) entries encountered across the selected root.")
            if value.inaccessibleEntries > 0 { Text("\(value.inaccessibleEntries.formatted()) entries or folders could not be read.") }
            if value.skippedLinks > 0 { Text("\(value.skippedLinks.formatted()) symbolic links skipped; targets were not followed.") }
            if value.cloudOnlyEntries > 0 { Text("\(value.cloudOnlyEntries.formatted()) cloud-only placeholders skipped; no downloads requested.") }
            if value.otherSkippedEntries > 0 { Text("\(value.otherSkippedEntries.formatted()) special, mounted or unrepresentable entries skipped.") }
            if value.unknownAllocations > 0 { Text("\(value.unknownAllocations.formatted()) allocated sizes unavailable.") }
            if value.changedDirectories > 0 { Text("\(value.changedDirectories.formatted()) changed or moved folders were not traversed.") }
            if value.duplicateHardLinks > 0 { Text("\(value.duplicateHardLinks.formatted()) additional hard links counted only at the first path in name order.") }
            if value.reachedLimit { Text("An entry, depth or path-memory limit was reached. Unmeasured contents are not included.") }
            if value.cancelled { Text("The scan was stopped. Unvisited contents are not included.") }
            Text("Package contents are measured without navigation. Mounted filesystems and links are not traversed. No file data is opened or cloud-only contents downloaded.")
            Text("APFS clones, shared blocks and snapshots mean these figures do not predict deletion savings. Hard links are counted once across the scan, so allocation may be attributed to another folder. Bars compare siblings, not percentages of disk capacity.")
        }
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func revealButton(_ url: URL) -> some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Image(systemName: "arrow.up.forward.square").frame(width: 22, height: 24)
        }
        .buttonStyle(.borderless).accessibilityLabel("Reveal in Finder")
        .help("Reveal in Finder; files may have changed since the scan")
    }

    private func sizeLabel(_ entry: SWPStorageEntry) -> String {
        guard let bytes = entry.allocatedBytes else { return "Unknown" }
        return (entry.isPartial ? "≥ " : "") + SWPBytes.string(bytes)
    }

    private func fraction(_ entry: SWPStorageEntry, maximum: Int64) -> Double {
        guard let bytes = entry.allocatedBytes, maximum > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(maximum)))
    }

    private func kindLabel(_ entry: SWPStorageEntry) -> String {
        let label: String
        switch entry.kind {
        case .folder: label = "Folder"
        case .package: label = "Package"
        case .file: label = "File"
        case .symbolicLink: label = "Link · skipped"
        case .other, .unavailable: label = "Unavailable"
        }
        return label + (entry.isPartial ? " · partial" : "")
    }

    private func symbol(_ kind: SWPStorageEntry.Kind) -> String {
        switch kind {
        case .folder: return "folder"
        case .package: return "shippingbox"
        case .file: return "doc"
        case .symbolicLink: return "link"
        case .other, .unavailable: return "questionmark.folder"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to explore"
        panel.prompt = "Explore"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = false
        panel.directoryURL = store.rootURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.selectFolder(url)
        }
    }
}

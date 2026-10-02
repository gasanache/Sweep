import SwiftUI
import AppKit

struct SWPLocalAIView: View {
    @ObservedObject var store: SWPLocalAIStore
    @State private var confirmation: SWPLocalAIPlan?

    private var isBusy: Bool { store.isScanning || store.isRemoving }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("AI view", selection: $store.showsCleanup) {
                Text("Discovery · read-only").tag(false)
                Text("Cleanup reviews").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("ai.view")

            if !store.showsCleanup {
                SWPAIInventoryView(store: store)
            } else {
            Label {
                Text("Shared caches, assistant history and arbitrary model folders are inspection-only. Cleanup is limited to the separately reviewed LM Studio and Ollama locations.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
            }
            .font(SWPTheme.Fonts.caption)
            .foregroundStyle(SWPTheme.Colors.textSecondary)
            .accessibilityIdentifier("local-ai.scope")

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result = store.result { resultCard(result) }
                    if let error = store.scanError {
                        SWPLocalAINotice(title: "Could not refresh local AI", detail: error, isError: true)
                        Button("Try again") { Task { await store.refresh() } }
                            .buttonStyle(SWPSecondaryButtonStyle())
                            .disabled(isBusy)
                    }
                    if store.visiblePlans.isEmpty && store.scanError == nil { emptyState }
                    ForEach(store.visiblePlans) { plan in
                        SWPLocalAIAppCard(plan: plan, isBusy: isBusy,
                                          notes: plan.notes.filter { !store.discoveryNotes.contains($0) }) {
                            confirmation = plan
                        }
                    }
                    if !store.discoveryNotes.isEmpty {
                        DisclosureGroup("Discovery notes (\(store.discoveryNotes.count))") {
                            ForEach(store.discoveryNotes, id: \.self) { note in
                                Text(note).textSelection(.enabled).padding(.top, 6)
                            }
                        }
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                        .accessibilityIdentifier("local-ai.coverage")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
            }
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.top, 36)
        .padding(.bottom, SWPTheme.Spacing.pane)
        .background(SWPTheme.Colors.background)
        .foregroundStyle(SWPTheme.Colors.textPrimary)
        .tint(SWPTheme.Colors.accent)
        .task { await store.refreshIfNeeded() }
        .onChange(of: store.showsCleanup) { _, _ in Task { await store.refreshIfNeeded() } }
        .onChange(of: store.isScanning) { _, active in
            if !active { Task { await store.refreshIfNeeded() } }
        }
        .onChange(of: confirmation?.id) { _, value in store.isConfirming = value != nil }
        .sheet(item: $confirmation, onDismiss: { store.isConfirming = false }) { plan in
            SWPLocalAIConfirmSheet(store: store, plan: plan)
        }
    }

    private var header: some View {
        SWPPageHeader(title: "AI & Models", subtitle: "Included in Scan. Discovery is not a cleanup recommendation.") {
            SWPRefreshButton(isBusy: isBusy) { Task { await store.refresh() } }
                .accessibilityIdentifier("local-ai.refresh")
        }
    }

    private var emptyState: some View {
        SWPEmptyState(title: store.isScanning ? "Checking local AI" : "No app-owned AI data found",
                      message: store.isScanning ? "Measuring known app and model locations." : "LM Studio and Ollama were checked. Shared caches and custom folders are not cleanup targets.",
                      symbol: "cpu", isLoading: store.isScanning)
            .padding(.vertical, 24)
    }

    private func resultCard(_ result: SWPLocalAICleanupResult) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Label(
                    "\(store.resultProduct?.name ?? "Local AI"): \(result.succeeded ? "reviewed cleanup finished" : "cleanup needs attention")",
                    systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(SWPTheme.Fonts.rowTitle)
                .foregroundStyle(result.succeeded ? SWPTheme.Colors.safe : SWPTheme.Colors.caution)
                Spacer(minLength: 0)
                Button { store.clearResult() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .disabled(store.isRemoving)
                    .accessibilityLabel("Dismiss cleanup result")
            }
            Text("\(SWPBytes.string(result.trashedBytes)) moved to Trash. Disk space is freed only after you empty Trash.")
                .foregroundStyle(SWPTheme.Colors.textSecondary)
            ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in
                Text(message).textSelection(.enabled)
            }
            ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(SWPTheme.Colors.caution)
                    .textSelection(.enabled)
            }
            if !result.succeeded {
                Text("Review the details above. Any unfinished work appears in the refreshed plans below; review it again before retrying.")
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }
            Text("This result covers the reviewed actions only. Shared Hugging Face caches, projects and external/custom model folders outside the reviewed paths are kept.")
                .foregroundStyle(SWPTheme.Colors.textSecondary)
        }
        .font(SWPTheme.Fonts.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .swpCard(elevated: true)
        .accessibilityIdentifier("local-ai.result")
    }
}

private struct SWPAIInventoryView: View {
    @ObservedObject var store: SWPLocalAIStore
    @State private var showsCoverage = false

    private var selected: SWPAIFinding? {
        store.visibleFindings.first { $0.id == store.selectedFindingID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SWPSearchField(placeholder: "Search tools, models or paths", text: $store.inventoryQuery, identifier: "ai.search")
                Button("Add folder…", action: chooseFolder)
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .disabled(store.isScanning || store.isRemoving || store.additionalFolders.count >= 32)
                    .accessibilityIdentifier("ai.add-folder")
            }
            HStack {
                Text(store.inventory?.summary ?? "Checking known locations…")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                Spacer(minLength: 4)
                Toggle("Model candidates", isOn: $store.inventoryModelsOnly)
                    .toggleStyle(.checkbox)
                    .font(SWPTheme.Fonts.caption)
            }
            if store.visibleFindings.isEmpty {
                SWPEmptyState(title: store.inventory == nil ? "Discovering AI locations" : "No matching findings",
                              message: store.inventory == nil ? "Reading filesystem metadata, not conversations or credentials." : "Clear the filter or add a model folder. No matches does not mean no AI data exists.",
                              symbol: "cpu", isLoading: store.inventory == nil && store.isScanning)
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("ai.empty")
            } else {
                Table(store.visibleFindings, selection: $store.selectedFindingID, sortOrder: $store.inventorySortOrder) {
                    TableColumn("Tool / model", value: \.name) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.name).font(SWPTheme.Fonts.list).lineLimit(1)
                            Text(finding.kind.rawValue).font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.textSecondary).lineLimit(1)
                        }
                        .help(finding.product + " · " + finding.note)
                        .accessibilityLabel("\(finding.name), \(finding.kind.rawValue), \(finding.sizeText)")
                    }
                    .width(min: 145, ideal: 190)
                    TableColumn("Location", value: \.url.path) { finding in
                        Text(finding.url.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/"))
                            .font(SWPTheme.Fonts.caption).lineLimit(1).truncationMode(.middle)
                            .help(finding.url.path)
                    }
                    .width(min: 130, ideal: 220)
                    TableColumn("Allocated", value: \.sortBytes) { finding in
                        Text(finding.sizeText).font(SWPTheme.Fonts.caption.monospacedDigit())
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                    }
                    .width(min: 105, ideal: 125)
                }
                .accessibilityIdentifier("ai.findings")
                .contextMenu(forSelectionType: String.self) { ids in
                    if let finding = store.visibleFindings.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") { reveal(finding) }
                    }
                } primaryAction: { ids in
                    if let finding = store.visibleFindings.first(where: { ids.contains($0.id) }) { reveal(finding) }
                }
            }
            if let selected {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.url.path).textSelection(.enabled)
                        Text(selected.note.isEmpty ? "Inspection only; not a cleanup target." : selected.note)
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                    }
                    .font(SWPTheme.Fonts.caption)
                    Spacer(minLength: 0)
                    Button("Reveal") { reveal(selected) }.buttonStyle(SWPSecondaryButtonStyle())
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !store.additionalFolders.isEmpty {
                Menu("Added folders (this session)") {
                    ForEach(store.additionalFolders, id: \.path) { url in
                        Button("Stop inspecting \(url.path)") { Task { await store.removeFolder(url) } }
                    }
                }
                .disabled(store.isScanning || store.isRemoving)
                .font(SWPTheme.Fonts.caption)
            }
            DisclosureGroup(store.inventory?.isPartial == true ? "Coverage · partial" : "Coverage & safety", isExpanded: $showsCoverage) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.inventory?.notes ?? [], id: \.self) { Text($0).textSelection(.enabled) }
                        if let inventory = store.inventory {
                            Text("\(inventory.checkedLocations) known or added locations checked. Sizes overlap; they are not a reclaimable total.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .font(SWPTheme.Fonts.caption)
            .foregroundStyle(SWPTheme.Colors.textSecondary)
            .accessibilityIdentifier("ai.coverage")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect"
        panel.message = "Inspect model filenames and allocated sizes. Nothing is removed or added to cleanup."
        if panel.runModal() == .OK, let url = panel.url { Task { await store.addFolder(url) } }
    }

    private func reveal(_ finding: SWPAIFinding) {
        NSWorkspace.shared.activateFileViewerSelecting([finding.url])
    }
}

private struct SWPLocalAIAppCard: View {
    let plan: SWPLocalAIPlan
    let isBusy: Bool
    let notes: [String]
    let review: () -> Void
    @State private var isExpanded = false

    private var canReview: Bool { !isBusy && plan.hasWork && plan.blockers.isEmpty }
    private var status: String {
        if plan.isInstalled { return "Installed" }
        return plan.hasWork ? "Leftovers" : "Not found"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SWPLocalAIAppIcon(plan: plan, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.product.name).font(SWPTheme.Fonts.rowTitle)
                    Text(status)
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(SWPBytes.string(plan.sizeBytes)).font(SWPTheme.Fonts.number)
                    Text("app-owned data")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                }
                Button("Review") { review() }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .disabled(!canReview)
                    .accessibilityLabel("Review \(plan.product.name) cleanup")
                    .accessibilityIdentifier("local-ai.review.\(plan.id)")
            }
            if plan.isInstalled {
                Text(plan.hasBrewPackage
                     ? "Stops verified app processes and its service, if present. Homebrew packages are uninstalled permanently."
                     : "Stops verified running app processes before moving the app and its data to Trash.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !plan.hasWork && plan.blockers.isEmpty {
                Text("No known app or leftover data found. Nothing to remove.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }
            ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, blocker in
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.caution)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.hasWork {
                DisclosureGroup("Exact paths and actions", isExpanded: $isExpanded) {
                    SWPLocalAIPlanContents(plan: plan).padding(.top, 8)
                }
                .font(SWPTheme.Fonts.caption)
                .accessibilityIdentifier("local-ai.paths.\(plan.id)")
            }
        }
        .padding(14)
        .swpCard()
    }
}

private struct SWPLocalAIAppIcon: View {
    let plan: SWPLocalAIPlan
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                SWPIconTile(symbol: plan.product == .lmStudio ? "desktopcomputer" : "terminal", size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: plan.appURLs.first) {
            icon = plan.appURLs.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }
}

/// Used unchanged in the card and the approval sheet so neither hides a target.
private struct SWPLocalAIPlanContents: View {
    let plan: SWPLocalAIPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plan.appURLs.isEmpty {
                sectionTitle("Apps to move to Trash", symbol: "app")
                ForEach(plan.appURLs, id: \.path) { url in path(url.path) }
                if plan.brewPackages.contains(where: \.isCask) {
                    Text("Reviewed app bundles move to Trash first. Their Homebrew cask registration and command-line links are then removed permanently.")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                }
            }
            if !plan.items.isEmpty {
                sectionTitle("Data to move to Trash", symbol: "externaldrive")
                ForEach(plan.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        path(item.url.path)
                        Text("\(item.location) · \(SWPBytes.string(item.sizeBytes))")
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                    }
                }
            }
            if !plan.brewPackages.isEmpty {
                sectionTitle("Homebrew actions · permanent uninstall", symbol: "shippingbox")
                ForEach(Array(plan.brewPackages.enumerated()), id: \.offset) { _, package in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(package.isCask ? "Cask" : "Formula"): \(package.token) · all installed versions")
                            .font(SWPTheme.Fonts.caption)
                        if !package.installedVersions.isEmpty {
                            Text(package.installedVersions.joined(separator: ", "))
                                .font(SWPTheme.Fonts.mono)
                                .foregroundStyle(SWPTheme.Colors.textSecondary)
                        }
                        let executable = package.prefix.appendingPathComponent("bin/brew").path
                        if !package.isCask {
                            path("\(executable) services stop \(package.token)")
                        }
                        path("\(executable) uninstall \(package.isCask ? "--cask" : "--formula") --force \(package.token)")
                    }
                }
                Text("Packages cannot be restored with Trash’s Put Back. Formula removal is refused if another installed package depends on it.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }
            if !plan.shellProfiles.isEmpty {
                sectionTitle("Shell profiles to back up and edit", symbol: "terminal")
                ForEach(plan.shellProfiles, id: \.path) { url in path(url.path) }
                Text("Each profile is backed up before only the exact generated three-line LM Studio CLI block is removed. Other profile content is preserved; backup locations appear in the result.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(SWPTheme.Fonts.rowTitle)
    }

    private func path(_ value: String) -> some View {
        Text(value)
            .font(SWPTheme.Fonts.mono)
            .foregroundStyle(SWPTheme.Colors.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SWPLocalAINotice: View {
    let title: String
    let detail: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(SWPTheme.Fonts.rowTitle)
            Text(detail)
                .font(SWPTheme.Fonts.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isError ? SWPTheme.Colors.caution : SWPTheme.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SWPLocalAIConfirmSheet: View {
    @ObservedObject var store: SWPLocalAIStore
    // This value is captured when Review is clicked, never looked up after a rescan.
    let plan: SWPLocalAIPlan
    @Environment(\.dismiss) private var dismiss
    @State private var hasConfirmed = false
    @State private var isSubmitting = false

    private var isBusy: Bool { isSubmitting || store.isRemoving }
    private var canSubmit: Bool {
        hasConfirmed && !isBusy && !store.isScanning && plan.blockers.isEmpty && plan.hasWork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SWPLocalAIAppIcon(plan: plan, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remove \(plan.product.name)?").font(SWPTheme.Fonts.title)
                    Text("\(SWPBytes.string(plan.sizeBytes)) of app-owned data · review every action below")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SWPLocalAINotice(
                        title: "Models, chats and settings leave their working locations",
                        detail: "Listed apps and data move to Trash batches. Use Restore Last Batch in Sweep for supported files, or recover them manually; Finder’s Put Back is not available. Disk space is freed only after you empty Trash."
                    )
                    SWPLocalAINotice(
                        title: "Verified app processes are stopped before cleanup",
                        detail: "A process may still be running even when only leftovers remain. Sweep must verify that it belongs to this app; uncertain ownership blocks cleanup."
                    )
                    if plan.isInstalled && plan.hasBrewPackage {
                        SWPLocalAINotice(
                            title: "Homebrew packages are removed permanently",
                            detail: plan.brewPackages.contains(where: { !$0.isCask })
                                ? "The listed Homebrew service is stopped first. Packages cannot be restored with Put Back; they must be reinstalled."
                                : "The reviewed app bundles move to Trash first. Package registrations and command-line links cannot be restored with Put Back; reinstall the package to restore them."
                        )
                    }
                    SWPHairline()
                    SWPLocalAIPlanContents(plan: plan)
                    ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Shared Hugging Face caches, projects and arbitrary model folders are excluded. Changed or newly discovered targets require another review.")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .swpCard()
            Toggle(plan.hasBrewPackage
                   ? "I understand: listed data moves to Trash; package removal is permanent."
                   : "I reviewed the listed apps, data and any shell-profile edits.", isOn: $hasConfirmed)
                .toggleStyle(.checkbox)
                .font(SWPTheme.Fonts.body)
                .disabled(isBusy)
                .accessibilityIdentifier("local-ai.confirm-acknowledgement")
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Cleaning up").font(SWPTheme.Fonts.caption)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button("Remove \(plan.product.name)") { submit() }
                    .buttonStyle(SWPPrimaryButtonStyle(tint: SWPTheme.Colors.caution, isEnabled: canSubmit))
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("local-ai.confirm-remove")
            }
        }
        .padding(20)
        .frame(width: 560, height: 490)
        .background(SWPTheme.Colors.background)
        .foregroundStyle(SWPTheme.Colors.textPrimary)
        .tint(SWPTheme.Colors.accent)
        .interactiveDismissDisabled(isBusy)
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            await store.remove(plan)
            isSubmitting = false
            dismiss()
        }
    }
}

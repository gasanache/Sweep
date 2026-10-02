import SwiftUI
import AppKit

// MARK: - Uninstall pane

/// Two screens: pick an app, then review its removal plan.
struct SWPUninstallView: View {

    @EnvironmentObject private var store: SWPUninstallStore
    let onOpenLocalAI: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Above the switch, so a failure message survives whichever screen
            // is showing. It used to live inside `picker` alone — and every
            // path that sets it (won't quit, policy refused, couldn't move)
            // leaves the plan on screen, so the message was unreachable.
            if let message = store.statusMessage, store.plan != nil {
                statusCard(message)
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.top, SWPTheme.Spacing.row)
            }

            if let plan = store.plan {
                if let product = SWPLocalAIScanner.product(forAppBundleID: plan.app.bundleID) {
                    VStack(alignment: .leading, spacing: SWPTheme.Spacing.section) {
                        Text(product.name)
                            .font(SWPTheme.Fonts.title)
                        Text("Use AI & Models to review hidden model folders, runtimes and shell entries, and safely stop background services before removal.")
                            .font(SWPTheme.Fonts.body)
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                        HStack {
                            Button("Back") { store.clearPlan() }
                                .buttonStyle(SWPSecondaryButtonStyle())
                            Button("Review in AI & Models") {
                                store.clearPlan()
                                onOpenLocalAI()
                            }
                                .buttonStyle(SWPPrimaryButtonStyle())
                        }
                    }
                    .padding(SWPTheme.Spacing.pane)
                    .padding(.top, 20)
                } else {
                    SWPUninstallPlanView(plan: plan)
                }
            } else {
                picker
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.loadAppsIfNeeded() }
        .sheet(isPresented: $store.isConfirming) {
            SWPUninstallConfirmSheet()
                .environmentObject(store)
        }
    }

    // MARK: Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            SWPPageHeader(title: "Uninstaller", subtitle: "Review an app and its files before moving anything to Trash.") {
                SWPRefreshButton(isBusy: store.isLoadingApps || store.isBuildingPlan) { store.refreshApps() }
                    .accessibilityIdentifier("uninstaller.refresh")
            }
            .padding(.horizontal, SWPTheme.Spacing.pane)
            .padding(.top, 34)
            .padding(.bottom, SWPTheme.Spacing.section)

            HStack(spacing: 8) {
                SWPSearchField(placeholder: "Search \(store.apps.count) apps", text: $store.query,
                               identifier: "uninstaller.search")
                Picker("Sort by", selection: $store.sortOrder) {
                    ForEach(SWPUninstallStore.SortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 155)
                .tint(SWPTheme.Colors.accent)
            }
            .padding(.horizontal, SWPTheme.Spacing.pane)

            if let message = store.statusMessage {
                statusCard(message)
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.top, SWPTheme.Spacing.row)
            }

            if store.isLoadingApps && store.apps.isEmpty {
                SWPEmptyState(title: "Finding apps", message: "The app list will appear before sizes finish measuring.", isLoading: true)
                Spacer()
            } else if store.filteredApps.isEmpty {
                SWPEmptyState(title: store.query.isEmpty ? "No apps found" : "No matching apps",
                              message: "Try another name or bundle identifier, or refresh the inventory.")
                    .padding(.top, 30)
                HStack {
                    Spacer()
                    Button(store.query.isEmpty ? "Refresh Apps" : "Clear Search") {
                        if store.query.isEmpty { store.refreshApps() } else { store.query = "" }
                    }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .accessibilityIdentifier("uninstaller.empty-action")
                    Spacer()
                }
                Spacer()
            } else {
                appList.padding(.top, SWPTheme.Spacing.row)
                HStack {
                    Text("\(store.filteredApps.count) apps")
                    Spacer()
                    Text(store.isMeasuringSizes ? "Measuring app sizes…" : "Select an app, then Review · double-click to open")
                }
                .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                .padding(.horizontal, SWPTheme.Spacing.pane).padding(.vertical, 10)
            }
        }
        .disabled(store.isBuildingPlan)
        .overlay { if store.isBuildingPlan { measuringOverlay } }
        .onChange(of: store.query) { _, _ in
            if let id = store.selectedAppID, !store.filteredApps.contains(where: { $0.id == id }) {
                store.selectedAppID = nil
            }
        }
    }

    private var appList: some View {
        Table(store.filteredApps, selection: $store.selectedAppID) {
            TableColumn("App") { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                    Text(app.name).font(SWPTheme.Fonts.list).lineLimit(1)
                    if store.isRunning(app) {
                        Image(systemName: "circle.fill").font(.system(size: 5))
                            .foregroundStyle(SWPTheme.Colors.safe).accessibilityLabel("Running")
                    }
                }
                .frame(minHeight: 32)
                .help(app.name + "\n" + app.url.path)
            }
            TableColumn("Last used") { app in
                Text(app.lastUsedText).font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
            }.width(96)
            TableColumn("App size") { app in
                Text(store.size(of: app).map(SWPBytes.string) ?? "Unknown")
                    .font(SWPTheme.Fonts.number).foregroundStyle(SWPTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(74)
            TableColumn("") { app in
                Button("Review") { review(app) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Review files for \(app.name)")
            }.width(55)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(SWPTheme.Colors.surface)
        .contextMenu(forSelectionType: String.self) { ids in
            if let app = store.filteredApps.first(where: { ids.contains($0.id) }) {
                Button("Review files") { review(app) }
            }
        } primaryAction: { ids in
            if let app = store.filteredApps.first(where: { ids.contains($0.id) }) { review(app) }
        }
        .accessibilityIdentifier("uninstaller.apps")
        .padding(.horizontal, SWPTheme.Spacing.pane)
    }

    private func review(_ app: SWPInstalledApp) {
        if SWPLocalAIScanner.product(forAppBundleID: app.bundleID) != nil { onOpenLocalAI() }
        else { store.select(app) }
    }

    private func statusCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(SWPTheme.Colors.accent)
            Text(message)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .swpCard()
    }

    private var measuringOverlay: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Preparing the removal review")
                .font(SWPTheme.Fonts.body)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
            Button("Cancel") { store.clearPlan() }
                .buttonStyle(SWPSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .swpCard(elevated: true)
    }
}

// MARK: - Plan view

private struct SWPUninstallPlanView: View {

    @EnvironmentObject private var store: SWPUninstallStore
    let plan: SWPUninstallPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: SWPTheme.Spacing.row) {
                    appCard
                    if !plan.exclusive.isEmpty {
                        section("ITS FILES", subtitle: "matched by bundle identifier — ticked for removal")
                        ForEach(plan.exclusive) { item in residueRow(item) }
                    }
                    if !plan.nameMatches.isEmpty {
                        section("POSSIBLE MATCHES", subtitle: "name evidence only — review before ticking")
                        ForEach(plan.nameMatches) { item in residueRow(item) }
                    }
                    if !plan.shared.isEmpty {
                        section("SHARED — LEFT ALONE", subtitle: "used by other installed apps; Sweep will not touch these")
                        sharedList
                    }
                    if !plan.receipts.isEmpty {
                        section("INSTALLER RECEIPTS", subtitle: "metadata owned by macOS; left alone")
                        receiptList
                    }
                }
                .padding(.horizontal, SWPTheme.Spacing.pane)
                .padding(.bottom, SWPTheme.Spacing.pane)
            }
            .scrollContentBackground(.hidden)

            SWPHairline()
            bottomBar
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                store.clearPlan()
            } label: {
                Label("All Apps", systemImage: "chevron.left")
            }
            .buttonStyle(SWPSecondaryButtonStyle())

            Spacer()

            if plan.app.hasSystemExtension {
                SWPBadge(text: "Ships a system extension", tint: SWPTheme.Colors.review)
                    .help("Removing the app does not unload its system extension — open the app and remove the extension there first.")
            }
            if store.isRunning(plan.app) {
                SWPBadge(text: "Running — will be quit", tint: SWPTheme.Colors.review)
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.top, 34)
        .padding(.bottom, SWPTheme.Spacing.row)
    }

    private var appCard: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.url.path))
                .resizable()
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(plan.app.name)
                    .font(SWPTheme.Fonts.title)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text("\(plan.app.version.isEmpty ? "" : "v\(plan.app.version) · ")\(plan.app.bundleID)")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .lineLimit(1)
                Text(plan.appItem.displayPath)
                    .font(SWPTheme.Fonts.mono)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if plan.bundleAlreadyTrashed {
                SWPBadge(text: "Already in Trash", tint: SWPTheme.Colors.safe)
            } else {
                Text(SWPBytes.string(plan.appItem.sizeBytes))
                    .font(SWPTheme.Fonts.number)
                    .foregroundStyle(SWPTheme.Colors.accent)
            }
        }
        .padding(12)
        .swpCard(elevated: true)
    }

    // MARK: Sections

    private func section(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(SWPTheme.Fonts.badge)
                .tracking(0.7)
                .foregroundStyle(SWPTheme.Colors.textDim)
            Text("· \(subtitle)")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
        }
        .padding(.top, SWPTheme.Spacing.tight)
    }

    private func residueRow(_ item: SWPItem) -> some View {
        let ticked = store.tickedIDs.contains(item.id)
        return HStack(spacing: 10) {
            Button { store.toggle(item) } label: {
                SWPCheckbox(isOn: ticked)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayPath)
                    .font(SWPTheme.Fonts.mono)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(item.location)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }

            Spacer(minLength: 8)

            if item.requiresAdmin {
                SWPBadge(text: "Admin", tint: SWPTheme.Colors.review)
            }
            Text(SWPBytes.string(item.sizeBytes))
                .font(SWPTheme.Fonts.caption.monospacedDigit())
                .foregroundStyle(ticked ? SWPTheme.Colors.accent : SWPTheme.Colors.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .swpCard(elevated: ticked)
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.displayPath), \(item.location), \(SWPBytes.string(item.sizeBytes))"
                            + (item.requiresAdmin ? ", needs administrator" : ""))
        .accessibilityValue(ticked ? "selected" : "not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.toggle(item) }
    }

    private var sharedList: some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.shared.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { SWPHairline().opacity(0.5) }
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 9))
                        .foregroundStyle(SWPTheme.Colors.inUse)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName)
                            .font(SWPTheme.Fonts.mono)
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(entry.location) · \(entry.sharedWithText)")
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textDim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .swpCard()
    }

    /// Receipts, listed but never removable — `pkgutil --forget` is the only
    /// correct way to drop one, and it is not Sweep's call to make.
    private var receiptList: some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.receipts.enumerated()), id: \.element) { index, identifier in
                if index > 0 { SWPHairline().opacity(0.5) }
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 9))
                        .foregroundStyle(SWPTheme.Colors.textDim)
                    Text(identifier)
                        .font(SWPTheme.Fonts.mono)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .swpCard()
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: SWPTheme.Spacing.row) {
            let bytes = SWPBytes.split(store.selectedBytes)
            Text(bytes.value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(SWPTheme.Colors.accent)
            Text(bytes.unit)
                .font(SWPTheme.Fonts.heroUnit)
                .foregroundStyle(SWPTheme.Colors.accent)

            Text(plan.bundleAlreadyTrashed
                 ? "\(store.tickedItems.count) leftover file\(store.tickedItems.count == 1 ? "" : "s")"
                 : "app + \(store.tickedItems.count) file\(store.tickedItems.count == 1 ? "" : "s")")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)

            if store.selectionNeedsAdmin {
                SWPBadge(text: "Admin", tint: SWPTheme.Colors.review)
            }

            Spacer(minLength: SWPTheme.Spacing.section)

            Button(store.isUninstalling ? "Working"
                   : plan.bundleAlreadyTrashed ? "Remove Leftovers" : "Uninstall") {
                store.isConfirming = true
            }
            .buttonStyle(SWPPrimaryButtonStyle(isEnabled: !store.isUninstalling))
            .disabled(store.isUninstalling)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.vertical, 12)
        .background(SWPTheme.Colors.surface)
    }
}

// MARK: - Confirm sheet

private struct SWPUninstallConfirmSheet: View {

    @EnvironmentObject private var store: SWPUninstallStore

    private var adminCount: Int { store.tickedItems.filter(\.requiresAdmin).count }

    var body: some View {
        VStack(alignment: .leading, spacing: SWPTheme.Spacing.section) {
            HStack(spacing: 11) {
                SWPIconTile(symbol: "app.dashed", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.plan?.bundleAlreadyTrashed == true
                     ? "Remove \(store.plan?.app.name ?? "")'s leftovers?"
                     : "Uninstall \(store.plan?.app.name ?? "")?")
                        .font(SWPTheme.Fonts.title)
                        .foregroundStyle(SWPTheme.Colors.textPrimary)
                    Text(store.plan?.bundleAlreadyTrashed == true
                         ? "\(store.tickedItems.count) leftover file\(store.tickedItems.count == 1 ? "" : "s") (\(SWPBytes.string(store.selectedBytes))) move to a Trash batch — the app is already there. Use Restore Last Batch in Sweep or recover files manually."
                         : "The app and \(store.tickedItems.count) file\(store.tickedItems.count == 1 ? "" : "s") (\(SWPBytes.string(store.selectedBytes))) move to a Trash batch. Use Restore Last Batch in Sweep or recover files manually; Finder’s Put Back is not available.")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let plan = store.plan, store.isRunning(plan.app) {
                note(symbol: "power",
                     text: "\(plan.app.name) is running. Sweep will ask it to quit first and stop if it refuses.")
            }
            if adminCount > 0 {
                note(symbol: "lock.shield",
                     text: "\(adminCount) item\(adminCount == 1 ? " needs" : "s need") your password; any background daemon is unloaded first.")
            }
            if let plan = store.plan, !plan.shared.isEmpty {
                note(symbol: "lock",
                     text: "\(plan.shared.count) shared item\(plan.shared.count == 1 ? "" : "s") stay untouched for the apps that still use them.")
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { store.isConfirming = false }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { store.performUninstall() }
                    .buttonStyle(SWPPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SWPTheme.Spacing.pane)
        .frame(width: 430)
        .background(SWPTheme.Colors.background)
    }

    private func note(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(SWPTheme.Colors.review)
            Text(text)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .swpCard()
    }
}

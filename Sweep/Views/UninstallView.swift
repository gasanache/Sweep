import SwiftUI
import AppKit

// MARK: - Uninstall pane

/// Two screens: pick an app, then review its removal plan.
struct SWPUninstallView: View {

    @EnvironmentObject private var store: SWPUninstallStore
    @FocusState private var isSearchFocused: Bool

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
                SWPUninstallPlanView(plan: plan)
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
            VStack(alignment: .leading, spacing: 3) {
                Text("Uninstaller")
                    .font(SWPTheme.Fonts.title)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text("Pick an app to see everything it would leave behind. The app and the files you tick move to the Trash together.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
            .padding(.horizontal, SWPTheme.Spacing.pane)
            .padding(.top, 34)
            .padding(.bottom, SWPTheme.Spacing.section)

            HStack(spacing: 8) {
                searchField
                Picker("", selection: $store.sortOrder) {
                    ForEach(SWPUninstallStore.SortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .tint(SWPTheme.Colors.accent)
            }
            .padding(.horizontal, SWPTheme.Spacing.pane)

            if let message = store.statusMessage {
                statusCard(message)
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.top, SWPTheme.Spacing.row)
            }

            if store.isLoadingApps {
                Spacer()
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                Spacer()
            } else {
                appList
                    .padding(.top, SWPTheme.Spacing.row)
            }
        }
        .overlay { if store.isBuildingPlan { measuringOverlay } }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(SWPTheme.Colors.textDim)
            TextField("Search \(store.apps.count) apps", text: $store.query)
                .textFieldStyle(.plain)
                .font(SWPTheme.Fonts.body)
                .foregroundStyle(SWPTheme.Colors.textPrimary)
                .focused($isSearchFocused)
            // Zero-sized owner for the shortcut; attaching it to the field
            // itself would fight the field's own key handling.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .swpCard()
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.filteredApps) { app in
                    SWPAppPickerRow(app: app,
                                    isRunning: store.isRunning(app),
                                    size: store.size(of: app)) {
                        store.select(app)
                    }
                }
            }
            .padding(.horizontal, SWPTheme.Spacing.pane)
            .padding(.bottom, SWPTheme.Spacing.pane)
        }
        .scrollContentBackground(.hidden)
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
            Text("Measuring…")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
        }
        .padding(18)
        .swpCard(elevated: true)
    }
}

// MARK: - Picker row

private struct SWPAppPickerRow: View {
    let app: SWPInstalledApp
    let isRunning: Bool
    let size: Int64?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 24, height: 24)

                Text(app.name)
                    .font(SWPTheme.Fonts.rowTitle)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                    .lineLimit(1)

                if isRunning {
                    Circle()
                        .fill(SWPTheme.Colors.safe)
                        .frame(width: 5, height: 5)
                        .help("Running")
                }

                Spacer(minLength: 8)

                Text(app.lastUsedText)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .frame(width: 96, alignment: .trailing)

                Text(size.map(SWPBytes.string) ?? "—")
                    .font(SWPTheme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                    .frame(width: 66, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(app.name), version \(app.version), \(app.lastUsedText)"
                                + (isRunning ? ", running" : ""))
            .accessibilityAddTraits(.isButton)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusRow, style: .continuous)
                    .fill(isHovering ? SWPTheme.Colors.surfaceHigh : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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

            Button(store.isUninstalling ? "Working…"
                   : plan.bundleAlreadyTrashed ? "Remove Leftovers…" : "Uninstall…") {
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
                         ? "\(store.tickedItems.count) leftover file\(store.tickedItems.count == 1 ? "" : "s") (\(SWPBytes.string(store.selectedBytes))) move to the Trash — the app is already there. Recoverable with Put Back."
                         : "The app and \(store.tickedItems.count) file\(store.tickedItems.count == 1 ? "" : "s") (\(SWPBytes.string(store.selectedBytes))) move to the Trash — recoverable with Put Back.")
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

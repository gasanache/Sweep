import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SWPPrivacyView: View {
    @ObservedObject var store: SWPPrivacyStore
    @State private var showingHelp = false
    @State private var confirmation: SWPPrivacyResetTarget?
    @State private var settingsError: String?

    private let commonServices: [SWPPrivacyService] = [
        .camera, .microphone, .screenCapture, .fullDiskAccess,
        .accessibility, .appleEvents, .inputMonitoring, .photos, .addressBook,
    ]
    private var isBusy: Bool { store.isLoading || store.isResetting }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.bottom, SWPTheme.Spacing.section)
            if store.inspectedApp != nil {
                HStack {
                    Button { store.showApps() } label: {
                        Label("Back to Apps", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("privacy.back")
                    Spacer()
                }
                .padding(.bottom, SWPTheme.Spacing.section)
                detailPane
            } else {
                browserToolbar.padding(.bottom, SWPTheme.Spacing.row)
                if let result = store.result {
                    ScrollView { resultCard(result) }.frame(maxHeight: 160)
                        .padding(.bottom, SWPTheme.Spacing.row)
                }
                appBrowser
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.top, 36)
        .padding(.bottom, SWPTheme.Spacing.pane)
        .background(SWPTheme.Colors.background)
        .tint(SWPTheme.Colors.accent)
        .task { if !store.hasLoaded { await store.refresh() } }
        .sheet(item: $confirmation) { target in
            SWPPrivacyResetSheet(store: store, target: target)
        }
        .alert("Could not open System Settings", isPresented: Binding(
            get: { settingsError != nil }, set: { if !$0 { settingsError = nil } }
        )) {
            Button("OK") { settingsError = nil }
        } message: { Text(settingsError ?? "") }
    }

    private var header: some View {
        SWPPageHeader(title: "App Permissions",
                      subtitle: "Inspect recorded decisions. Manage access in System Settings.") {
            SWPRefreshButton(isBusy: isBusy) { Task { await store.refresh() } }
                .accessibilityIdentifier("privacy.refresh")
            Button { showingHelp.toggle() } label: {
                Image(systemName: "questionmark.circle").frame(width: 16, height: 16)
            }
            .buttonStyle(SWPSecondaryButtonStyle())
            .accessibilityLabel("About recorded permissions")
            .accessibilityIdentifier("privacy.help")
            .popover(isPresented: $showingHelp, arrowEdge: .bottom) { helpContent }
            Menu {
                Button("Reset across apps") {
                    confirmation = SWPPrivacyResetTarget(service: .all, app: nil)
                }
                .disabled(isBusy)
                .accessibilityIdentifier("privacy.all-apps-reset")
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Advanced permission actions")
            .accessibilityIdentifier("privacy.advanced")
            .help("Advanced: reset decisions across apps")
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 12) {
            SWPSearchField(placeholder: "Search apps", text: $store.query, identifier: "privacy.search")
            Menu {
                Picker("Apps", selection: $store.appScope) {
                    ForEach(SWPPrivacyStore.AppScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Divider()
                Toggle("Include Apple apps", isOn: $store.showAppleApps)
            } label: { Text(store.appScope.title).font(SWPTheme.Fonts.body) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Filter apps")
            .accessibilityIdentifier("privacy.filter")
            Button { chooseApp() } label: { Label("Add app", systemImage: "plus") }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .fixedSize()
                .accessibilityIdentifier("privacy.choose-app")
        }
    }

    private var appBrowser: some View {
        let apps = store.filteredApps
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
            Table(apps, selection: $store.selectedAppID) {
                TableColumn("App") { app in
                    HStack(spacing: 8) {
                        SWPPrivacyAppIcon(app: app, size: 24)
                        Text(app.name).font(SWPTheme.Fonts.list)
                            .foregroundStyle(SWPTheme.Colors.textPrimary).lineLimit(1)
                    }
                    .frame(minHeight: 32)
                    .id(app.id)
                    .help(app.name + "\n" + (app.bundleID ?? app.id))
                }
                TableColumn("Inventory") { app in
                    Text(app.isInstalled ? "Installed" : "Recorded only")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                }.width(100)
                TableColumn("Records") { app in
                    Text(store.readableSources.isEmpty ? "Unavailable" : "\(app.grants.count)")
                        .font(SWPTheme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                        .help("Readable database records, not a count of current permissions")
                }.width(90)
                TableColumn("") { app in
                    Button("Inspect") { store.inspect(app) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Inspect permissions for \(app.name)")
                        .accessibilityIdentifier("privacy.inspect.\(app.id)")
                }.width(55)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(SWPTheme.Colors.surface)
            .accessibilityIdentifier("privacy.apps")
            .contextMenu(forSelectionType: String.self) { ids in
                if let app = apps.first(where: { ids.contains($0.id) }) {
                    Button("Inspect permissions") { store.inspect(app) }
                }
            } primaryAction: { ids in
                if let app = apps.first(where: { ids.contains($0.id) }) { store.inspect(app) }
            }
            .onAppear {
                if let id = store.selectedAppID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: store.isLoading) { _, loading in
                if !loading, let id = store.selectedAppID { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay {
                if apps.isEmpty {
                    VStack(spacing: 0) {
                        SWPEmptyState(title: store.isLoading ? "Finding apps" : "No matching apps",
                                      message: store.isLoading ? "Reading the available inventory." : "Try another search or change the app filters.",
                                      isLoading: store.isLoading)
                        if !store.query.isEmpty {
                            Button("Clear Search") { store.query = "" }
                                .buttonStyle(SWPSecondaryButtonStyle())
                        }
                    }
                }
            }
            }
            HStack(spacing: 6) {
                Text("\(apps.count) apps").monospacedDigit()
                Text(store.showAppleApps ? "· Apple apps included" : "· Apple apps hidden")
                Spacer(minLength: 0)
                Text("Select an app, then Inspect · double-click to open")
            }
            .font(SWPTheme.Fonts.caption)
            .foregroundStyle(SWPTheme.Colors.textSecondary)
            .padding(.vertical, 10)
        }
    }

    private var detailPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let result = store.result { resultCard(result) }
                    if let app = store.inspectedApp { appDetails(app) }
                }
                .id("privacy-top")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
                .padding(.bottom, 12)
            }
            .onChange(of: store.inspectedAppID) { _, _ in proxy.scrollTo("privacy-top", anchor: .top) }
            .onChange(of: store.result) { _, result in
                if result != nil { proxy.scrollTo("privacy-top", anchor: .top) }
            }
        }
    }

    private func appDetails(_ app: SWPPrivacyApp) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                SWPPrivacyAppIcon(app: app, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(SWPTheme.Fonts.title)
                        .foregroundStyle(SWPTheme.Colors.textPrimary).textSelection(.enabled)
                    Text(app.isInstalled ? "Installed app" : "Recorded app or helper")
                        .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { appActions(app) }
                VStack(alignment: .leading, spacing: 8) { appActions(app) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Recorded decisions are not verified current access.")
                    .font(SWPTheme.Fonts.body).foregroundStyle(SWPTheme.Colors.textPrimary)
                DisclosureGroup(store.coverageSummary) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Missing records mean unknown, not denied. Recent decisions may not appear in these checkpointed snapshots.")
                        ForEach(Array(store.coverage.enumerated()), id: \.offset) { _, item in
                            Text(item).textSelection(.enabled)
                        }
                        if store.readableSources.count < 2 {
                            Button("Open Full Disk Access Settings") { openSettings(.fullDiskAccess) }
                                .buttonStyle(SWPSecondaryButtonStyle())
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }
                .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                .accessibilityIdentifier("privacy.coverage")
            }
            if !app.canReset {
                Text("This helper can only be managed in System Settings.")
                    .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Permissions").font(SWPTheme.Fonts.rowTitle)
                    Spacer()
                    Toggle("All categories", isOn: $store.showsAllCategories)
                        .toggleStyle(.checkbox).font(SWPTheme.Fonts.caption)
                        .accessibilityIdentifier("privacy.all-categories")
                }
                let services = displayedServices(for: app)
                VStack(spacing: 0) {
                    ForEach(services) { service in
                        SWPPrivacyPermissionRow(app: app, service: service, isBusy: isBusy,
                                                openSettings: { openSettings(service) },
                                                reset: { reviewReset(service, app: app) })
                            .id(app.id + service.rawValue)
                        if service != services.last { SWPHairline().padding(.leading, 12) }
                    }
                }
                .background(SWPTheme.Colors.surface)
                Text("Open Settings to change access. Reset forgets allowed and denied decisions, so the app may ask again.")
                    .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let otherRecords = app.grants.filter { $0.service == nil }
            if !otherRecords.isEmpty {
                DisclosureGroup("Other recorded categories (\(otherRecords.count))") {
                    ForEach(otherRecords) { grant in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(grant.serviceName).font(SWPTheme.Fonts.rowTitle)
                            Text(grant.status).font(SWPTheme.Fonts.caption).textSelection(.enabled)
                        }.padding(.top, 8)
                    }
                }
                .font(SWPTheme.Fonts.body).foregroundStyle(SWPTheme.Colors.textSecondary)
            }
            DisclosureGroup("App details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.bundleID ?? app.id)
                    ForEach(app.paths, id: \.self) { Text($0) }
                    if app.paths.count > 1 { Text("Copies with this bundle identifier share the same reset scope.") }
                }
                .font(SWPTheme.Fonts.mono).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .font(SWPTheme.Fonts.body).foregroundStyle(SWPTheme.Colors.textSecondary)
            .id(app.id + "-details")
        }
    }

    private func displayedServices(for app: SWPPrivacyApp) -> [SWPPrivacyService] {
        let recorded = Set(app.grants.compactMap(\.service))
        let services = SWPPrivacyService.allCases.filter {
            $0 != .all && (store.showsAllCategories || commonServices.contains($0) || recorded.contains($0))
        }
        return services.sorted {
            if recorded.contains($0) != recorded.contains($1) { return recorded.contains($0) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    @ViewBuilder private func appActions(_ app: SWPPrivacyApp) -> some View {
        Button("Open System Settings") { openSettings(.all) }
            .buttonStyle(SWPPrimaryButtonStyle()).fixedSize()
            .accessibilityIdentifier("privacy.disable-settings")
        Button("Reset decisions") { reviewReset(.all, app: app) }
            .buttonStyle(SWPSecondaryButtonStyle()).fixedSize()
            .disabled(!app.canReset || isBusy)
            .accessibilityIdentifier("privacy.app-reset")
    }

    private var helpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("About app permissions").font(SWPTheme.Fonts.title)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text("Change access in System Settings using macOS’s controls. Sweep does not write to protected permission databases or pretend to offer live switches.")
                Text("Reset removes allowed and denied decisions, so apps may ask again. It does not keep access blocked, and cannot be undone.")
                Text("Full Disk Access may be needed to read records. Sweep works without it, but cannot establish what an app is currently allowed to access. Recent decisions may be missing from checkpointed records.")
                Button("Open Full Disk Access Settings") { openSettings(.fullDiskAccess) }
                    .buttonStyle(SWPSecondaryButtonStyle())
                Text("Location Services, Local Network, notifications, login items and extensions have their own settings. Managed policies and permissions outside TCC are not reset.")
                Text("Advanced → Reset across apps opens a separate review with explicit category and account scope. A failed reset is never retried with broader scope.")
            }
            .font(SWPTheme.Fonts.body).foregroundStyle(SWPTheme.Colors.textSecondary)
            .padding(20)
        }
        .frame(width: 390, height: 370)
    }

    private func resultCard(_ result: SWPPrivacyOutcome) -> some View {
        let needsAttention = result.status == .failed || result.status == .unknown
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(result.title, systemImage: needsAttention ? "exclamationmark.triangle" : result.status == .completed ? "checkmark.circle" : "info.circle")
                    .font(SWPTheme.Fonts.rowTitle)
                    .foregroundStyle(needsAttention ? SWPTheme.Colors.caution : SWPTheme.Colors.textPrimary)
                Spacer()
                Button { store.clearResult() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).disabled(store.isResetting)
                    .accessibilityLabel("Dismiss result")
            }
            Text(result.summary).font(SWPTheme.Fonts.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let details = result.details {
                DisclosureGroup("Details") {
                    Text(details).font(SWPTheme.Fonts.mono).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(SWPTheme.Fonts.caption)
            }
        }
        .foregroundStyle(SWPTheme.Colors.textSecondary)
        .padding(14).swpCard(elevated: true)
        .accessibilityIdentifier("privacy.result")
    }

    private func reviewReset(_ service: SWPPrivacyService, app: SWPPrivacyApp) {
        confirmation = SWPPrivacyResetTarget(service: service, app: app)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Add an app"
        panel.message = "Choose an application to inspect its permissions. Nothing will be changed."
        panel.prompt = "Add App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in _ = await store.includeApp(at: url) }
        }
    }

    private func openSettings(_ service: SWPPrivacyService) {
        if !NSWorkspace.shared.open(service.settingsURL) {
            settingsError = "Open System Settings from the Apple menu, then choose Privacy & Security."
        }
    }
}

private struct SWPPrivacyPermissionRow: View {
    let app: SWPPrivacyApp
    let service: SWPPrivacyService
    let isBusy: Bool
    let openSettings: () -> Void
    let reset: () -> Void
    @State private var isExpanded = false

    private var records: [SWPPrivacyGrant] { app.records(for: service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(records.isEmpty).opacity(records.isEmpty ? 0 : 1)
                .accessibilityHidden(records.isEmpty)
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(service.title) records")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.title).font(SWPTheme.Fonts.list)
                        .foregroundStyle(SWPTheme.Colors.textPrimary)
                    Text(app.recordedSummary(for: service))
                        .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                    if !records.isEmpty {
                        Text("\(records.count) record\(records.count == 1 ? "" : "s") · expand for source and scope")
                            .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textDim)
                    }
                }
                Spacer(minLength: 0)
                Button(action: openSettings) {
                    Image(systemName: "arrow.up.forward.square").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Open \(service.title) in System Settings")
                .accessibilityLabel("Open \(service.title) in System Settings")
                .accessibilityIdentifier("privacy.settings.\(service.rawValue)")
                Menu {
                    Button("Reset decisions", action: reset)
                        .disabled(!app.canReset || isBusy)
                        .accessibilityIdentifier("privacy.reset.\(service.rawValue)")
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 28) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions for \(service.title)")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if isExpanded {
                ForEach(records) { grant in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(grant.serviceName).font(SWPTheme.Fonts.rowTitle)
                        Text(grant.status).font(SWPTheme.Fonts.caption)
                    }
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 36).padding(.trailing, 12).padding(.bottom, 10)
                }
            }
        }
    }
}

private struct SWPPrivacyAppIcon: View {
    let app: SWPPrivacyApp
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: app.isInstalled ? "app" : "terminal")
                    .resizable().scaledToFit()
                    .foregroundStyle(SWPTheme.Colors.textSecondary).padding(size * 0.15)
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
        .task(id: app.paths.first) { icon = app.paths.first.map { NSWorkspace.shared.icon(forFile: $0) } }
    }
}

// The exact app identity is captured when review opens; browser changes cannot retarget it.
private struct SWPPrivacyResetTarget: Identifiable {
    let id = UUID()
    let service: SWPPrivacyService
    let app: SWPPrivacyApp?
}

private struct SWPPrivacyResetSheet: View {
    @ObservedObject var store: SWPPrivacyStore
    let target: SWPPrivacyResetTarget
    @Environment(\.dismiss) private var dismiss
    @State private var service: SWPPrivacyService
    @State private var scope: SWPPrivacyScope = .currentUser
    @State private var typedConfirmation = ""
    @State private var isSubmitting = false

    init(store: SWPPrivacyStore, target: SWPPrivacyResetTarget) {
        self.store = store
        self.target = target
        _service = State(initialValue: target.service)
    }

    private var isBusy: Bool { isSubmitting || store.isResetting }
    private var requiresTyping: Bool { target.app == nil || scope == .allUsers }
    private var canSubmit: Bool { !isBusy && (!requiresTyping || typedConfirmation == "RESET") }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let app = target.app { SWPPrivacyAppIcon(app: app, size: 40) }
                else { SWPIconTile(symbol: "arrow.counterclockwise", tint: SWPTheme.Colors.caution, size: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.app == nil ? "Reset across apps" : "Reset app decisions")
                        .font(SWPTheme.Fonts.title)
                    Text(target.app?.name ?? "Every app, including ones not listed in Sweep")
                        .font(SWPTheme.Fonts.body).foregroundStyle(SWPTheme.Colors.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Permissions", selection: $service) {
                    ForEach(SWPPrivacyService.allCases) { category in
                        Text(category == .all ? "All resettable permissions" : category.title).tag(category)
                    }
                }.accessibilityIdentifier("privacy.confirm-category")
                Picker("Accounts", selection: $scope) {
                    Text("Only my account").tag(SWPPrivacyScope.currentUser)
                    Text("Everyone on this Mac (administrator)").tag(SWPPrivacyScope.allUsers)
                }.accessibilityIdentifier("privacy.scope")
                if let app = target.app {
                    Text(app.bundleID ?? app.id).font(SWPTheme.Fonts.mono)
                        .foregroundStyle(SWPTheme.Colors.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(SWPTheme.Fonts.body).disabled(isBusy).padding(14).swpCard()
            VStack(alignment: .leading, spacing: 10) {
                consequence("Apps can ask again", symbol: "bubble.left",
                            detail: "Allowed and denied decisions are forgotten. This does not keep access blocked.")
                consequence("Quit affected apps first", symbol: "app.badge",
                            detail: "Sweep won’t close them. Reopen them or sign out for changes to take effect.")
                if scope == .allUsers {
                    consequence("All accounts on this Mac", symbol: "person.2",
                                detail: "macOS will request administrator authorization. Sweep never receives your password.")
                }
            }
            Text(target.app == nil
                 ? "No undo. Sweep’s own access may reset too. Managed policies and controls outside TCC are not reset."
                 : "No undo. Managed policies and controls outside TCC are not reset. Resetting Sweep may affect its own access.")
                .font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if requiresTyping {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type RESET to confirm").font(SWPTheme.Fonts.body)
                    TextField("RESET", text: $typedConfirmation)
                        .textFieldStyle(.roundedBorder).disabled(isBusy)
                        .accessibilityIdentifier("privacy.confirm-text")
                }
            }
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Resetting…").font(SWPTheme.Fonts.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SWPSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(isBusy).accessibilityIdentifier("privacy.confirm-cancel")
                Button("Reset decisions") { submit() }
                    .buttonStyle(SWPPrimaryButtonStyle(tint: SWPTheme.Colors.caution, isEnabled: canSubmit))
                    .disabled(!canSubmit).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("privacy.confirm-reset")
            }
        }
        .foregroundStyle(SWPTheme.Colors.textPrimary).padding(24).frame(width: 480)
        .background(SWPTheme.Colors.background).interactiveDismissDisabled(isBusy)
        .onChange(of: service) { _, _ in typedConfirmation = "" }
        .onChange(of: scope) { _, _ in typedConfirmation = "" }
    }

    private func consequence(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(SWPTheme.Colors.textSecondary)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(SWPTheme.Fonts.rowTitle)
                Text(detail).font(SWPTheme.Fonts.caption).foregroundStyle(SWPTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let selectedService = service
        let selectedScope = scope
        isSubmitting = true
        store.clearResult()
        Task {
            await store.reset(service: selectedService, app: target.app, scope: selectedScope)
            isSubmitting = false
            dismiss()
        }
    }
}

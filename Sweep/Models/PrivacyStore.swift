import Foundation
import Combine

/// Browser context survives navigation; inventory refresh cannot retarget a reset.
@MainActor
final class SWPPrivacyStore: ObservableObject {
    enum AppScope: String, CaseIterable, Identifiable {
        case all, installed, recordedOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All apps"
            case .installed: return "Installed"
            case .recordedOnly: return "Recorded only"
            }
        }
    }

    @Published private(set) var apps: [SWPPrivacyApp] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isResetting = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var coverage: [String] = []
    @Published private(set) var readableSources: [SWPPrivacyDatabaseSource] = []
    @Published private(set) var result: SWPPrivacyOutcome?
    @Published var selectedAppID: String?
    @Published private(set) var inspectedAppID: String?
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published var showAppleApps = false { didSet { reconcileSelection() } }
    @Published var appScope: AppScope = .all { didSet { reconcileSelection() } }
    @Published var showsAllCategories = false

    var filteredApps: [SWPPrivacyApp] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter { app in
            guard showAppleApps || !(app.bundleID?.hasPrefix("com.apple.") ?? false) else { return false }
            if appScope == .installed && !app.isInstalled { return false }
            if appScope == .recordedOnly && app.isInstalled { return false }
            return search.isEmpty || app.name.localizedStandardContains(search)
                || app.id.localizedStandardContains(search)
                || app.paths.contains { $0.localizedStandardContains(search) }
        }
    }

    var selectedApp: SWPPrivacyApp? { apps.first { $0.id == selectedAppID } }
    var inspectedApp: SWPPrivacyApp? { apps.first { $0.id == inspectedAppID } }

    func inspect(_ app: SWPPrivacyApp) {
        guard !isResetting, apps.contains(where: { $0.id == app.id }) else { return }
        selectedAppID = app.id
        inspectedAppID = app.id
    }

    func showApps() {
        guard !isResetting else { return }
        inspectedAppID = nil
    }

    var coverageSummary: String {
        guard hasLoaded else { return "Reading available permission records" }
        if readableSources.isEmpty { return "Permission records are unavailable" }
        return readableSources.count == 2
            ? "Records read from current-account and system sources"
            : "Records read from one of two sources"
    }

    private var refreshGeneration: UInt64 = 0
    private var additionalBundleURLs: [URL] = []
    private let loadSnapshot: @Sendable ([URL]) async -> SWPPrivacySnapshot
    private let performReset: @Sendable (SWPPrivacyService, SWPPrivacyApp?, SWPPrivacyScope) async -> SWPPrivacyOutcome

    init(
        loadSnapshot: @escaping @Sendable ([URL]) async -> SWPPrivacySnapshot = {
            await SWPPrivacyBackend.load(additionalBundleURLs: $0)
        },
        performReset: @escaping @Sendable (SWPPrivacyService, SWPPrivacyApp?, SWPPrivacyScope) async -> SWPPrivacyOutcome = {
            await SWPPrivacyBackend.reset(service: $0, app: $1, scope: $2)
        }
    ) {
        self.loadSnapshot = loadSnapshot
        self.performReset = performReset
    }

    func refresh() async {
        guard !isResetting else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        let snapshot = await loadSnapshot(additionalBundleURLs)
        guard generation == refreshGeneration, !isResetting else { return }
        apps = snapshot.apps
        coverage = snapshot.coverage
        readableSources = snapshot.readableSources
        hasLoaded = true
        isLoading = false
        reconcileSelection()
        // Refresh is not a reset and must never claim or clear its outcome.
    }

    /// Includes an app without changing registration or permission decisions.
    /// Additional paths are retained in memory, never persisted on disk.
    func includeApp(at url: URL) async -> String? {
        guard !isResetting else { return nil }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        let inspected = await Task.detached(priority: .utility) {
            Result { try SWPPrivacyBackend.chosenApp(at: url) }
        }.value
        guard generation == refreshGeneration, !isResetting else { return nil }
        isLoading = false
        switch inspected {
        case .failure(let error):
            result = SWPPrivacyOutcome(operation: .addApp, status: .failed, summary: error.localizedDescription)
            return nil
        case .success(var app):
            let standard = url.standardizedFileURL
            if !additionalBundleURLs.contains(standard) { additionalBundleURLs.append(standard) }
            if let index = apps.firstIndex(where: { $0.id == app.id }) {
                let previous = apps[index]
                app.paths = Array(Set(previous.paths + app.paths)).sorted()
                app.grants = previous.grants
                apps[index] = app
            } else {
                apps.append(app)
            }
            apps.sort {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            query = ""
            appScope = .all
            if app.bundleID?.hasPrefix("com.apple.") == true { showAppleApps = true }
            selectedAppID = app.id
            inspectedAppID = app.id
            return app.id
        }
    }

    /// Scope has no default. An invalid non-nil app never becomes all apps.
    func reset(service: SWPPrivacyService, app: SWPPrivacyApp?, scope: SWPPrivacyScope) async {
        guard !isResetting else { return }
        do { _ = try SWPPrivacyBackend.resetArguments(service: service, app: app) }
        catch {
            result = SWPPrivacyOutcome(status: .failed, summary: error.localizedDescription)
            return
        }
        isResetting = true
        refreshGeneration &+= 1
        isLoading = false
        result = nil
        let outcome = await performReset(service, app, scope)
        result = outcome
        isResetting = false
        await refresh()
    }

    func clearResult() {
        guard !isResetting else { return }
        result = nil
    }

    private func reconcileSelection() {
        if let selectedAppID, !filteredApps.contains(where: { $0.id == selectedAppID }) {
            self.selectedAppID = nil
        }
        if let inspectedAppID, !apps.contains(where: { $0.id == inspectedAppID }) {
            self.inspectedAppID = nil
        }
    }
}

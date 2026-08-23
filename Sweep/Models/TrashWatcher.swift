import Foundation
import os

// MARK: - Trash watcher

/// Notices when an application lands in the Trash and offers to clean up what
/// it left behind.
///
/// The bundle itself is already handled — the user dragged it there — so this
/// never touches it. What it offers is the *residue*: the containers, caches
/// and preferences that a drag-to-Trash uninstall leaves scattered through
/// `~/Library` and which become tomorrow's orphans.
///
/// Two deliberate limits. It is **off by default** and must be switched on in
/// Settings, because a background watcher nobody asked for is exactly the
/// behaviour that makes this category of app unwelcome. And it only runs while
/// Sweep is open: there is no helper, no login item, and nothing installed
/// outside the app bundle. That is a real limitation, stated plainly in the
/// Settings copy rather than papered over.
@MainActor
final class SWPTrashWatcher: ObservableObject {

    /// An app seen arriving in the Trash, waiting for the user to decide.
    struct Catch: Identifiable, Equatable {
        let app: SWPInstalledApp
        var id: String { app.url.path }
    }

    @Published private(set) var pending: Catch?
    @Published private(set) var isWatching = false

    private let log = Logger(subsystem: "com.gasanache.sweep", category: "trashwatch")
    private var source: DispatchSourceFileSystemObject?
    /// Block-based observers are identified by the returned token, not by
    /// `self` — `removeObserver(self, …)` silently does nothing for them, so
    /// every start() used to add another live observer.
    private var suppressionObserver: NSObjectProtocol?
    private var descriptor: CInt = -1
    private var known: Set<String> = []

    private var trashURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true)
    }

    /// Posted by the uninstaller when *Sweep* puts a bundle in the Trash.
    ///
    /// Without this the watcher answers its own work: an uninstall trashes the
    /// bundle, the watcher sees a new `.app` and immediately asks whether to
    /// clean up after the app the user just finished cleaning up after.
    static let didTrashBundle = Notification.Name("SWPDidTrashBundle")

    // MARK: Lifecycle

    /// Starts or stops the watcher to match the stored preference.
    func syncWithPreference() {
        SWPSettings.watchesTrash ? start() : stop()
    }

    func start() {
        guard source == nil else { return }
        descriptor = open(trashURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("could not open the Trash for watching")
            return
        }

        // Seed with what is already there so switching the setting on does not
        // immediately "discover" every app trashed weeks ago.
        known = appBundleNames()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source.resume()
        self.source = source

        // Suppress bundles Sweep itself trashed.
        suppressionObserver = NotificationCenter.default.addObserver(
            forName: Self.didTrashBundle, object: nil, queue: .main
        ) { [weak self] note in
            guard let name = note.object as? String else { return }
            // The observer is registered with `queue: .main`, so this already
            // runs on the main thread; `assumeIsolated` states that to the
            // compiler without a hop. Its result (Set.insert's tuple) is
            // deliberately discarded — re-suppressing an already-known bundle
            // is a no-op.
            MainActor.assumeIsolated { _ = self?.known.insert(name) }
        }

        isWatching = true
        log.info("watching the Trash")
    }

    func stop() {
        if let suppressionObserver {
            NotificationCenter.default.removeObserver(suppressionObserver)
            self.suppressionObserver = nil
        }
        source?.cancel()
        source = nil
        isWatching = false
        pending = nil
    }

    func dismiss() { pending = nil }

    // MARK: Detection

    private func directoryChanged() {
        let current = appBundleNames()
        let added = current.subtracting(known)
        // Anything that vanished can be offered again if it comes back.
        known.formIntersection(current)
        guard !added.isEmpty else { return }

        // A single write event can coalesce several bundles. Marking them all
        // seen and then handling only the first meant the rest were dropped
        // permanently — never offered, and never reconsidered.
        for name in added.sorted() {
            if consider(name) { return }
        }
    }

    /// Returns true once something has been offered, so one event produces at
    /// most one prompt; the rest stay unseen and are picked up next time.
    private func consider(_ name: String) -> Bool {
        let url = trashURL.appendingPathComponent(name)
        // The bundle is in the Trash, so its Info.plist is still readable —
        // that identity is what the residue finder needs.
        guard let app = SWPInstalledApps.info(at: url) else { return false }

        // A bundle in the Trash does NOT mean the app is gone. Sparkle
        // self-updates by trashing the old copy while the new one stays
        // installed; so does a drag-install over an existing app, and so does
        // trashing one of two copies. Offering "clean up after Foo" then would
        // pre-tick the *live* app's containers and preferences — and the
        // uninstall path would terminate the running copy first. If anything
        // outside the Trash still answers to this identity, say nothing.
        if !app.bundleID.isEmpty,
           SWPInstalledApps.list().contains(where: { $0.bundleID == app.bundleID }) {
            log.info("ignoring trashed copy of still-installed \(app.name, privacy: .public)")
            known.insert(name)
            return false
        }

        log.info("app entered the Trash: \(app.name, privacy: .public)")
        known.insert(name)
        pending = Catch(app: app)
        return true
    }

    private func appBundleNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".app") })
    }
}

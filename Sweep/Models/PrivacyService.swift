import Foundation
import SQLite3
import Darwin

// MARK: - Privacy categories and recorded inventory

enum SWPPrivacyService: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case camera = "Camera"
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case screenCapture = "ScreenCapture"
    case appleEvents = "AppleEvents"
    case addressBook = "AddressBook"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case photos = "Photos"
    case fullDiskAccess = "SystemPolicyAllFiles"
    case desktop = "SystemPolicyDesktopFolder"
    case documents = "SystemPolicyDocumentsFolder"
    case downloads = "SystemPolicyDownloadsFolder"
    case inputMonitoring = "ListenEvent"
    case speechRecognition = "SpeechRecognition"
    case mediaLibrary = "MediaLibrary"
    case bluetooth = "BluetoothAlways"
    case audioCapture = "AudioCapture"
    case developerTool = "DeveloperTool"
    case energyKitGuidance = "EnergyKitGuidance"
    case externalCameraMedia = "ExternalCameraMedia"
    case fileProviderDomain = "FileProviderDomain"
    case fileProviderPresence = "FileProviderPresence"
    case focusStatus = "FocusStatus"
    case gameCenterFriends = "GameCenterFriends"
    case homeKit = "HomeKit"
    case motion = "Motion"
    case photosAdd = "PhotosAdd"
    case postEvent = "PostEvent"
    case remoteDesktop = "RemoteDesktop"
    case siri = "Siri"
    case appBundles = "SystemPolicyAppBundles"
    case appData = "SystemPolicyAppData"
    case networkVolumes = "SystemPolicyNetworkVolumes"
    case removableVolumes = "SystemPolicyRemovableVolumes"
    case sysAdminFiles = "SystemPolicySysAdminFiles"
    case userTracking = "UserTracking"
    case virtualMachineNetworking = "VirtualMachineNetworking"
    case voiceBanking = "VoiceBanking"
    case webBrowserPublicKeyCredential = "WebBrowserPublicKeyCredential"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All privacy categories"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .screenCapture: "Screen & System Audio Recording"
        case .appleEvents: "Automation"
        case .addressBook: "Contacts"
        case .calendar: "Calendars"
        case .reminders: "Reminders"
        case .photos: "Photos"
        case .fullDiskAccess: "Full Disk Access"
        case .desktop: "Desktop Folder"
        case .documents: "Documents Folder"
        case .downloads: "Downloads Folder"
        case .inputMonitoring: "Input Monitoring"
        case .speechRecognition: "Speech Recognition"
        case .mediaLibrary: "Media & Apple Music"
        case .bluetooth: "Bluetooth"
        case .audioCapture: "System Audio Recording"
        case .developerTool: "Developer Tools"
        case .energyKitGuidance: "Energy Usage Guidance"
        case .externalCameraMedia: "External Camera Media"
        case .fileProviderDomain: "File Provider Files"
        case .fileProviderPresence: "File Provider Presence"
        case .focusStatus: "Focus Status"
        case .gameCenterFriends: "Game Center Friends"
        case .homeKit: "Home"
        case .motion: "Motion"
        case .photosAdd: "Photos (add only)"
        case .postEvent: "Sending Keystrokes"
        case .remoteDesktop: "Remote Desktop"
        case .siri: "Siri"
        case .appBundles: "App Management"
        case .appData: "Other Apps' Data"
        case .networkVolumes: "Network Volumes"
        case .removableVolumes: "Removable Volumes"
        case .sysAdminFiles: "System Administration Files"
        case .userTracking: "Tracking"
        case .virtualMachineNetworking: "Virtual Machine Networking"
        case .voiceBanking: "Personal Voice"
        case .webBrowserPublicKeyCredential: "Web Browser Passkeys"
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .all: anchor = ""
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenCapture: anchor = "Privacy_ScreenCapture"
        case .appleEvents: anchor = "Privacy_Automation"
        case .addressBook: anchor = "Privacy_Contacts"
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .photos: anchor = "Privacy_Photos"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .desktop, .documents, .downloads: anchor = "Privacy_FilesAndFolders"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .mediaLibrary: anchor = "Privacy_Media"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .audioCapture: anchor = "Privacy_ScreenCapture"
        case .developerTool: anchor = "Privacy_DevTools"
        case .homeKit: anchor = "Privacy_HomeKit"
        case .photosAdd: anchor = "Privacy_Photos"
        case .appBundles: anchor = "Privacy_AppBundles"
        case .appData, .networkVolumes, .removableVolumes, .sysAdminFiles:
            anchor = "Privacy_FilesAndFolders"
        // Categories without a dependable public deep link open the privacy
        // root rather than pretending macOS exposes a particular toggle.
        case .energyKitGuidance, .externalCameraMedia, .fileProviderDomain,
             .fileProviderPresence, .focusStatus, .gameCenterFriends, .motion,
             .postEvent, .remoteDesktop, .siri, .userTracking,
             .virtualMachineNetworking, .voiceBanking, .webBrowserPublicKeyCredential:
            anchor = ""
        }
        let root = "x-apple.systempreferences:com.apple.preference.security"
        return URL(string: anchor.isEmpty ? root : "\(root)?\(anchor)")!
    }

    static func recordedService(_ name: String) -> Self? {
        let raw = name.hasPrefix("kTCCService") ? String(name.dropFirst("kTCCService".count)) : name
        if raw == "CalendarFullAccess" || raw == "CalendarWriteOnly" { return .calendar }
        let service = Self(rawValue: raw)
        return service == .all ? nil : service
    }

    static func title(forRecordedService name: String) -> String {
        let raw = name.hasPrefix("kTCCService") ? String(name.dropFirst("kTCCService".count)) : name
        if let service = Self(rawValue: raw), service != .all { return service.title }
        switch raw {
        case "CalendarFullAccess": return "Calendars (full access)"
        case "CalendarWriteOnly": return "Calendars (write only)"
        default: return "\(raw) (unrecognized category)"
        }
    }
}

enum SWPPrivacyScope: String, CaseIterable, Identifiable, Sendable {
    case currentUser, allUsers

    var id: String { rawValue }
    var title: String {
        self == .currentUser ? "Current user account" : "All user accounts"
    }
}

enum SWPPrivacyDecision: String, Hashable, Sendable {
    case allowed, denied, limited, undetermined, unknown

    var title: String {
        switch self {
        case .allowed: return "Recorded allowed"
        case .denied: return "Recorded denied"
        case .limited: return "Recorded limited access"
        case .undetermined: return "Recorded not determined"
        case .unknown: return "Recorded value unknown"
        }
    }

    static func decode(_ value: Int64?, legacy: Bool) -> Self {
        guard let value else { return .unknown }
        if legacy {
            return value == 0 ? .denied : value == 1 ? .allowed : .unknown
        }
        switch value {
        case 0: return .denied
        case 1: return .undetermined
        case 2: return .allowed
        case 3: return .limited
        default: return .unknown
        }
    }
}

struct SWPPrivacyGrant: Identifiable, Hashable, Sendable {
    let id: String
    let serviceName: String
    /// A historical database value, never a claim about effective access.
    let status: String
    var service: SWPPrivacyService? = nil
    var decision: SWPPrivacyDecision = .unknown
    var source: SWPPrivacyDatabaseSource? = nil
}

struct SWPPrivacyApp: Identifiable, Hashable, Sendable {
    /// Exact TCC identity. Unknown client types are namespaced to avoid merging
    /// an unrecognized record into a resettable bundle identity.
    let id: String
    let name: String
    let bundleID: String?
    var paths: [String]
    var grants: [SWPPrivacyGrant]
    let canReset: Bool
    /// True only when an app bundle was discovered on disk, not inferred from
    /// a possibly stale TCC path. Mutable default preserves the simple initializer.
    var isInstalled = false

    func records(for service: SWPPrivacyService) -> [SWPPrivacyGrant] {
        grants.filter { $0.service == service }
    }

    func recordedSummary(for service: SWPPrivacyService) -> String {
        let records = records(for: service)
        guard !records.isEmpty else { return "No readable record" }
        let decisions = Set(records.map(\.decision))
        return decisions.count == 1 ? records[0].decision.title : "Mixed recorded decisions"
    }
}

struct SWPPrivacySnapshot: Sendable {
    let apps: [SWPPrivacyApp]
    let coverage: [String]
    var readableSources: [SWPPrivacyDatabaseSource] = []
}

enum SWPPrivacyDatabaseSource: String, Sendable {
    case user, system

    var title: String {
        self == .user ? "Current-user database" : "System database"
    }
}

enum SWPPrivacyClientType: Equatable, Sendable {
    case bundleID
    case absolutePath
    case unknown(Int64?)
}

struct SWPPrivacyRecordedEntry: Sendable {
    let client: String
    let clientType: SWPPrivacyClientType
    let grant: SWPPrivacyGrant
}

struct SWPPrivacyDatabaseSnapshot: Sendable {
    let entries: [SWPPrivacyRecordedEntry]
    let coverage: [String]
    var isReadable = false
}

struct SWPPrivacyOutcome: Equatable, Sendable {
    enum Operation: Sendable { case reset, addApp }
    enum Status: Sendable { case completed, failed, cancelled, unknown }
    var operation: Operation = .reset
    let status: Status
    let summary: String
    var details: String? = nil

    var title: String {
        if operation == .addApp { return "Could not add app" }
        switch status {
        case .completed: return "Reset command completed"
        case .failed: return "Reset needs attention"
        case .cancelled: return "Reset cancelled"
        case .unknown: return "Reset completion unknown"
        }
    }
}

enum SWPPrivacyResetError: LocalizedError {
    case unresettableClient
    case invalidBundleID
    case identityMismatch
    case invalidApp

    var errorDescription: String? {
        switch self {
        case .unresettableClient:
            "This client cannot be reset individually with tccutil. Use System Settings; Sweep will not broaden the reset to other apps."
        case .invalidBundleID:
            "The app does not have a valid, nonempty bundle identifier. No reset was started."
        case .identityMismatch:
            "The selected app identity does not match its bundle identifier. No reset was started."
        case .invalidApp:
            "Choose an existing .app bundle with a readable Info.plist and valid bundle identifier. No reset was started."
        }
    }
}

// MARK: - Read-only inspection and supported reset command

/// AppKit-free so decoding, fixture reads, and command validation can be tested
/// without touching real privacy decisions. Only `reset` can change decisions.
enum SWPPrivacyBackend {
    static func isValidBundleID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              let first = value.utf8.first,
              (65...90).contains(first) || (97...122).contains(first) || (48...57).contains(first)
        else { return false }
        guard value.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 45 || byte == 46
        }) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.contains { $0 != 45 }
        }
    }

    /// `nil` is the explicit all-apps scope. An invalid app never becomes nil
    /// and never falls back to an all-apps invocation.
    static func resetArguments(service: SWPPrivacyService, app: SWPPrivacyApp?) throws -> [String] {
        var arguments = ["reset", service.rawValue]
        if let app {
            guard app.canReset else { throw SWPPrivacyResetError.unresettableClient }
            guard let bundleID = app.bundleID, isValidBundleID(bundleID) else {
                throw SWPPrivacyResetError.invalidBundleID
            }
            guard app.id == bundleID else { throw SWPPrivacyResetError.identityMismatch }
            arguments.append(bundleID)
        }
        return arguments
    }

    static func decodeClientType(_ value: Int64?) -> SWPPrivacyClientType {
        switch value {
        case 0: .bundleID
        case 1: .absolutePath
        default: .unknown(value)
        }
    }

    static func recordedStatus(authValue: Int64?, legacyAllowed: Bool = false) -> String {
        guard let authValue else { return "Recorded authorization unavailable (unknown)" }
        if legacyAllowed {
            switch authValue {
            case 0: return "Recorded denied (legacy)"
            case 1: return "Recorded allowed (legacy)"
            default: return "Recorded legacy value \(authValue) (unknown)"
            }
        }
        switch authValue {
        case 0: return "Recorded denied"
        case 1: return "Recorded unknown / not determined"
        case 2: return "Recorded allowed"
        case 3: return "Recorded limited access"
        default: return "Recorded authorization value \(authValue) (unknown)"
        }
    }

    static func load(additionalBundleURLs: [URL] = []) async -> SWPPrivacySnapshot {
        await Task.detached(priority: .utility) {
            loadSynchronously(additionalBundleURLs: additionalBundleURLs)
        }.value
    }

    private static func loadSynchronously(additionalBundleURLs: [URL]) -> SWPPrivacySnapshot {
        var installed = SWPInstalledApps.listForAttribution().map(\.url)
        // The uninstaller intentionally excludes Safari and Sweep. Privacy
        // management must not inherit that destructive-action inventory filter.
        installed += [
            URL(fileURLWithPath: "/Applications/Safari.app"),
            URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
            Bundle.main.bundleURL,
        ]
        installed += additionalBundleURLs
        let user = readDatabase(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"), source: .user)
        let system = readDatabase(
            at: URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"), source: .system)
        return SWPPrivacySnapshot(
            apps: mergeInventory(bundleURLs: installed, entries: user.entries + system.entries),
            coverage: [
                "Database records are not effective access. Missing records and unreadable data mean unknown, not denied or permission-free.",
                "Inventory reads checkpointed database snapshots without writing SQLite sidecars. Recent, uncheckpointed decisions may be absent; changes during a read may require Refresh.",
                "App discovery covers /Applications, ~/Applications, /System/Applications and one subfolder, plus Safari, Sweep and apps you choose. Other locations, helpers, extensions and command-line clients may appear only when their database records are readable.",
                "The inventory never reads other users' databases. Reset scope is chosen separately: current account, or all user accounts with administrator authorization. Managed/system policies and non-TCC permissions are not removed. Some categories depend on your macOS version.",
            ] + user.coverage + system.coverage,
            readableSources: (user.isReadable ? [.user] : []) + (system.isReadable ? [.system] : []))
    }

    static func chosenApp(at url: URL) throws -> SWPPrivacyApp {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let app = mergeInventory(bundleURLs: [url], entries: []).first,
              app.canReset else { throw SWPPrivacyResetError.invalidApp }
        return app
    }

    /// Merges exact, case-preserved Info.plist identifiers, not the lowercased
    /// attribution IDs. Path clients and unknown client types cannot be reset
    /// individually even if their spelling resembles a bundle identifier.
    static func mergeInventory(bundleURLs: [URL], entries: [SWPPrivacyRecordedEntry]) -> [SWPPrivacyApp] {
        var apps: [String: SWPPrivacyApp] = [:]
        var seenPaths = Set<String>()
        for url in bundleURLs where url.pathExtension.lowercased() == "app" {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted,
                  url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let plist = SWPInstalledApps.infoPlist(in: url) else { continue }
            let identifier = (plist["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let id = identifier.map { isValidBundleID($0) ? $0 : "invalid-bundle:\($0)" } ?? path
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            if apps[id] != nil {
                apps[id]?.paths.append(path)
            } else {
                apps[id] = SWPPrivacyApp(id: id, name: name, bundleID: identifier,
                    paths: [path], grants: [], canReset: identifier.map(isValidBundleID) ?? false,
                    isInstalled: true)
            }
        }
        for entry in entries {
            let id: String
            let bundleID: String?
            let paths: [String]
            switch entry.clientType {
            case .bundleID:
                id = isValidBundleID(entry.client) ? entry.client : "invalid-bundle:\(entry.client)"
                bundleID = entry.client
                paths = []
            case .absolutePath:
                id = entry.client.hasPrefix("/") ? entry.client : "invalid-path:\(entry.client)"
                bundleID = nil
                paths = entry.client.hasPrefix("/") ? [entry.client] : []
            case .unknown(let value):
                id = "unknown-\(value.map(String.init) ?? "null"):\(entry.client)"
                bundleID = nil
                paths = []
            }
            if apps[id] != nil {
                apps[id]?.grants.append(entry.grant)
                for path in paths where apps[id]?.paths.contains(path) == false {
                    apps[id]?.paths.append(path)
                }
            } else {
                let name = paths.first.map {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                } ?? entry.client
                apps[id] = SWPPrivacyApp(id: id, name: name, bundleID: bundleID,
                    paths: paths, grants: [entry.grant], canReset: bundleID.map(isValidBundleID) ?? false)
            }
        }
        return apps.values.map { app in
            SWPPrivacyApp(id: app.id, name: app.name, bundleID: app.bundleID, paths: app.paths.sorted(),
                grants: app.grants.sorted {
                    if $0.serviceName != $1.serviceName { return $0.serviceName < $1.serviceName }
                    return $0.id < $1.id
                }, canReset: app.canReset, isInstalled: app.isInstalled)
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Fixture-friendly and read-only, including sidecars. immutable=1 is
    /// intentional: plain SQLITE_OPEN_READONLY can still create/update -shm.
    /// It also means this is a checkpointed snapshot, not live WAL state.
    static func readDatabase(at url: URL, source: SWPPrivacyDatabaseSource) -> SWPPrivacyDatabaseSnapshot {
        func unavailable(_ detail: String) -> SWPPrivacyDatabaseSnapshot {
            SWPPrivacyDatabaseSnapshot(entries: [], coverage: ["\(source.title): \(detail)"])
        }
        guard url.isFileURL else { return unavailable("Not a local database URL; not read.") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let error = errno
            if error == ENOENT {
                return unavailable("Not present. Recorded decisions are unavailable, not permission-free.")
            }
            return unavailable("Unreadable (\(String(cString: strerror(error)))). macOS may require Full Disk Access; access remains unknown.")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return unavailable("Not a regular database file; not read.")
        }
        var database: OpaquePointer?
        let uri = url.standardizedFileURL.absoluteString + "?mode=ro&immutable=1"
        let opened = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the file"
            return unavailable("Unreadable (\(detail)). macOS may require Full Disk Access; access remains unknown.")
        }
        sqlite3_busy_timeout(database, 200)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(access)", -1, &schema, nil) == SQLITE_OK else {
            return unavailable("Schema could not be read: \(String(cString: sqlite3_errmsg(database))).")
        }
        defer { sqlite3_finalize(schema) }
        var columns = Set<String>()
        var step = sqlite3_step(schema)
        while step == SQLITE_ROW {
            if let name = textColumn(schema, 1) { columns.insert(name) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return unavailable("Schema read timed out; decisions remain unknown.")
            }
            step = sqlite3_step(schema)
        }
        guard step == SQLITE_DONE else {
            return unavailable("Schema read failed: \(String(cString: sqlite3_errmsg(database))).")
        }
        let required: Set<String> = ["client", "client_type", "service"]
        guard required.isSubset(of: columns), columns.contains("auth_value") || columns.contains("allowed") else {
            return unavailable("Unsupported or missing access-table schema. No authorization values were inferred.")
        }
        let legacy = !columns.contains("auth_value")
        let authorization = legacy ? "allowed" : "auth_value"
        let policy = columns.contains("policy_id") ? "policy_id" : "NULL"
        let indirect = columns.contains("indirect_object_identifier")
            ? "CASE WHEN service IN ('kTCCServiceAppleEvents', 'AppleEvents') THEN indirect_object_identifier ELSE NULL END"
            : "NULL"
        // Fixed identifiers only. No SQL constructed from app or database data.
        let query = "SELECT client, client_type, service, \(authorization), \(policy), \(indirect) FROM access LIMIT 20001"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return unavailable("Decision query failed: \(String(cString: sqlite3_errmsg(database))).")
        }
        defer { sqlite3_finalize(statement) }
        var entries: [SWPPrivacyRecordedEntry] = []
        var issues: [String] = []
        var row = 0
        var skipped = 0
        step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard row < 20_000, ProcessInfo.processInfo.systemUptime < deadline else {
                issues.append("\(source.title): Read limit reached; only a partial snapshot is shown.")
                break
            }
            row += 1
            if let client = textColumn(statement, 0), !client.isEmpty,
               let service = textColumn(statement, 2), !service.isEmpty {
                let clientType = decodeClientType(integerColumn(statement, 1))
                var status = recordedStatus(authValue: integerColumn(statement, 3), legacyAllowed: legacy)
                if sqlite3_column_type(statement, 4) != SQLITE_NULL { status += " · policy-linked record" }
                if case .unknown(let type) = clientType {
                    status += " · unknown client type \(type.map(String.init) ?? "null")"
                }
                status += " · \(source.title)"
                var serviceName = SWPPrivacyService.title(forRecordedService: service)
                if service == "kTCCServiceAppleEvents" || service == "AppleEvents" {
                    if let target = textColumn(statement, 5), !target.isEmpty, target != "UNUSED" {
                        serviceName += " → \(target)"
                    } else {
                        serviceName += " (target not recorded)"
                    }
                }
                entries.append(SWPPrivacyRecordedEntry(client: client, clientType: clientType,
                    grant: SWPPrivacyGrant(id: "\(source.rawValue)-\(row)",
                        serviceName: serviceName, status: status,
                        service: SWPPrivacyService.recordedService(service),
                        decision: .decode(integerColumn(statement, 3), legacy: legacy), source: source)))
            } else {
                skipped += 1
            }
            step = sqlite3_step(statement)
        }
        if step != SQLITE_DONE && step != SQLITE_ROW {
            issues.append("\(source.title): Read failed after \(entries.count) records (\(String(cString: sqlite3_errmsg(database)))); snapshot is incomplete.")
        }
        if skipped > 0 {
            issues.append("\(source.title): \(skipped) malformed or oversized records could not be interpreted.")
        }
        issues.insert("\(source.title): Read \(entries.count) checkpointed records. This does not establish current access.", at: 0)
        return SWPPrivacyDatabaseSnapshot(entries: entries, coverage: issues, isReadable: true)
    }

    private static func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, index) <= 16_384,
              let text = sqlite3_column_text(statement, index) else { return nil }
        let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index)))
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func integerColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_INTEGER ? sqlite3_column_int64(statement, index) : nil
    }

    /// Both quoting layers match the existing native-authorization pattern.
    /// Validation happens before any command is constructed; no arbitrary
    /// executable, service string, path, or shell fragment can enter the script.
    static func administratorScript(service: SWPPrivacyService, app: SWPPrivacyApp?) throws -> String {
        let arguments = try resetArguments(service: service, app: app)
        let command = (["/usr/bin/tccutil"] + arguments).map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ") + " 2>&1"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func reset(service: SWPPrivacyService, app: SWPPrivacyApp?, scope: SWPPrivacyScope) async -> SWPPrivacyOutcome {
        let arguments: [String]
        let administratorSource: String?
        do {
            arguments = try resetArguments(service: service, app: app)
            administratorSource = scope == .allUsers ? try administratorScript(service: service, app: app) : nil
        } catch { return SWPPrivacyOutcome(status: .failed, summary: error.localizedDescription) }
        guard getuid() != 0, geteuid() != 0 else {
            return SWPPrivacyOutcome(status: .failed, summary: "Do not launch Sweep as root. Run Sweep normally and explicitly choose All user accounts if administrator authorization is intended. No reset was started.")
        }
        return await Task.detached(priority: .userInitiated) {
            let target = app.map { "\($0.name) [\($0.bundleID ?? $0.id)]" } ?? "all apps"
            return runReset(arguments: arguments, administratorSource: administratorSource,
                target: "\(service.title) — \(target) — \(scope.title)")
        }.value
    }

    /// One owned process, fixed executable and argv, bounded runtime/output.
    /// Only explicit all-users scope uses native administrator authorization.
    /// Never retries or broadens a failed request.
    private static func runReset(arguments: [String], administratorSource: String?, target: String) -> SWPPrivacyOutcome {
        let process = Process()
        let elevated = administratorSource != nil
        process.executableURL = URL(fileURLWithPath: elevated ? "/usr/bin/osascript" : "/usr/bin/tccutil")
        process.arguments = administratorSource.map { ["-e", $0] } ?? arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return SWPPrivacyOutcome(status: .failed, summary: "Could not configure bounded tccutil output capture. No reset was started.")
        }
        do { try process.run() }
        catch { return SWPPrivacyOutcome(status: .failed, summary: "Could not start the privacy reset process. No reset was started. \(error.localizedDescription)") }
        try? pipe.fileHandleForWriting.close()

        var captured = Data()
        var truncated = false
        var outputError: Int32?
        var buffer = [UInt8](repeating: 0, count: 4_096)
        func drain() {
            // Bound every drain so a noisy child cannot postpone its deadline.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    let remaining = max(0, 65_536 - captured.count)
                    captured.append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { truncated = true }
                } else {
                    if count < 0, errno != EAGAIN, errno != EINTR { outputError = errno }
                    break
                }
            }
        }
        func poll(until deadline: TimeInterval) {
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                drain()
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        poll(until: ProcessInfo.processInfo.systemUptime + (elevated ? 120 : 20))
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            poll(until: ProcessInfo.processInfo.systemUptime + 1)
            if process.isRunning {
                // Only this still-running, directly launched child is targeted.
                _ = kill(process.processIdentifier, SIGKILL)
                poll(until: ProcessInfo.processInfo.systemUptime + 1)
            }
        }
        drain()
        var output = String(decoding: captured, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if truncated { output += "\n[tccutil output truncated at 64 KiB]" }
        if let outputError { output += "\n[Output capture incomplete: \(String(cString: strerror(outputError)))]" }
        let detail = output.isEmpty ? "tccutil returned no output." : "tccutil output:\n\(output)"
        if timedOut {
            let ongoing = elevated
                ? " The administrator helper may still be running, even if the authorization process was stopped."
                : (process.isRunning ? " The child has not exited and may still be running." : "")
            return SWPPrivacyOutcome(status: .unknown, summary: "Reset timed out for \(target). Completion is unknown; some decisions may already have changed.\(ongoing) Check System Settings before trying again.", details: detail)
        }
        if elevated, process.terminationStatus != 0, output.hasSuffix("(-128)") {
            return SWPPrivacyOutcome(status: .cancelled, summary: "Administrator authorization was cancelled for \(target). No reset was authorized by this request.", details: detail)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return SWPPrivacyOutcome(status: .failed, summary: "tccutil did not complete successfully for \(target) (\(process.terminationReason == .exit ? "exit" : "signal") \(process.terminationStatus)). Some decisions may already have changed. No broader reset was attempted.", details: detail)
        }
        return SWPPrivacyOutcome(status: .completed, summary: "tccutil completed for \(target). Reset removes resettable allowed AND denied decisions; it does not persistently deny access. Apps may ask again. Managed or non-resettable decisions may remain; verify changes in System Settings.", details: detail)
    }
}

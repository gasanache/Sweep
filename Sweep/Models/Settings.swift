import Foundation

// MARK: - Keys

/// One place for the defaults keys, so a rename cannot silently orphan a
/// user's stored preference.
enum SWPSettings {
    static let appearanceKey = "appearance"
    static let foldThresholdKey = "foldThresholdKB"
    static let scanDeveloperKey = "scanDeveloperArtefacts"
    static let watchTrashKey = "watchTrash"

    static var foldThresholdBytes: Int64 {
        let stored = UserDefaults.standard.object(forKey: foldThresholdKey) as? Int
        return Int64(stored ?? 64) * 1024
    }

    static var scansDeveloper: Bool {
        UserDefaults.standard.object(forKey: scanDeveloperKey) as? Bool ?? true
    }

    /// Off unless the user turns it on. A background watcher nobody asked for
    /// is the behaviour that makes cleaners unwelcome.
    static var watchesTrash: Bool {
        UserDefaults.standard.object(forKey: watchTrashKey) as? Bool ?? false
    }
}

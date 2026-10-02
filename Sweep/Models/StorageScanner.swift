import Foundation
import Darwin
import UniformTypeIdentifiers

struct SWPStorageIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64

    fileprivate init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}

struct SWPStorageEntry: Identifiable, Sendable {
    enum Kind: Sendable { case folder, package, file, symbolicLink, other, unavailable }

    let url: URL
    let kind: Kind
    var allocatedBytes: Int64?
    var isPartial = false
    var note: String?
    var children: [SWPStorageEntry] = []

    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    var canBrowse: Bool { kind == .folder }
}

struct SWPStorageCoverage: Sendable {
    var visitedEntries = 0
    var inaccessibleEntries = 0
    var skippedLinks = 0
    var cloudOnlyEntries = 0
    var otherSkippedEntries = 0
    var duplicateHardLinks = 0
    var unknownAllocations = 0
    var changedDirectories = 0
    var reachedLimit = false
    var cancelled = false
}

struct SWPStorageSnapshot: Sendable {
    let root: SWPStorageEntry
    let rootIdentity: SWPStorageIdentity
    let coverage: SWPStorageCoverage
    let scannedAt: Date
}

/// A synchronous, metadata-only walk. File data is never opened. Directory
/// descriptors and no-follow opens prevent a path replacement from redirecting
/// the walk through a symbolic link. Results are an observation, not a snapshot
/// of a live filesystem and never a promise of reclaimable space.
struct SWPStorageScanner: Sendable {
    let maximumEntries: Int
    let maximumDepth: Int
    let maximumPathBytes: Int

    init(maximumEntries: Int = 100_000, maximumDepth: Int = 128,
         maximumPathBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumDepth = max(1, maximumDepth)
        self.maximumPathBytes = max(1, maximumPathBytes)
    }

    func scan(rootURL: URL, expectedIdentity: SWPStorageIdentity? = nil) throws -> SWPStorageSnapshot {
        guard rootURL.isFileURL, !rootURL.pathComponents.contains("..") else {
            throw StorageError("Choose a local folder without parent-path components.")
        }
        // This policy is thread-local; this synchronous function never suspends.
        // Refuse the scan if the OS cannot guarantee no placeholder hydration.
        let oldPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard oldPolicy >= 0,
              setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                            IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw StorageError("macOS could not disable cloud-file downloading for this scan.")
        }
        defer {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, oldPolicy)
        }

        let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard rootFD >= 0 else { throw posixError(rootURL) }
        defer { close(rootFD) }
        var metadata = stat()
        guard fstat(rootFD, &metadata) == 0 else { throw posixError(rootURL) }
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw StorageError("This folder is cloud-only. Sweep will not download it.")
        }
        let identity = SWPStorageIdentity(metadata)
        guard expectedIdentity == nil || expectedIdentity == identity else {
            throw StorageError("The selected folder was replaced. Choose the folder again before scanning it.")
        }
        // F_GETPATH provides the actual opened path, including /private aliases.
        let root = try descriptorURL(rootFD)
        var walk = Walk(scanner: self, rootURL: root, rootIdentity: identity)
        var entry = SWPStorageEntry(url: root, kind: packageKind(root), allocatedBytes: allocation(metadata))
        if entry.allocatedBytes == nil {
            entry.isPartial = true
            walk.coverage.unknownAllocations += 1
        }
        walk.descend(fd: rootFD, metadata: metadata, entry: &entry, depth: 0, exposeChildren: entry.kind == .folder)
        return SWPStorageSnapshot(root: entry, rootIdentity: identity,
                                  coverage: walk.coverage, scannedAt: Date())
    }

    private struct Walk {
        let scanner: SWPStorageScanner
        let rootURL: URL
        let rootIdentity: SWPStorageIdentity
        var coverage = SWPStorageCoverage()
        var pathBytes = 0
        var hardLinks: Set<SWPStorageIdentity> = []

        var stopped: Bool {
            mutating get {
                if Task.isCancelled { coverage.cancelled = true }
                return coverage.cancelled || coverage.reachedLimit
            }
        }

        mutating func descend(fd: Int32, metadata: stat, entry: inout SWPStorageEntry,
                              depth: Int, exposeChildren: Bool) {
            guard !stopped else { entry.isPartial = true; return }
            guard depth < scanner.maximumDepth else {
                coverage.reachedLimit = true
                entry.isPartial = true
                entry.note = "Depth limit reached"
                return
            }
            // Validate both the selected root and the directory being entered.
            // A descriptor remains bound to its inode even if its name changes.
            switch validate(fd: fd, url: entry.url, identity: SWPStorageIdentity(metadata)) {
            case .valid:
                break
            case .alias(let canonical):
                // APFS firmlinks (`/System/Volumes/Data/Users` ↔ `/Users`)
                // report their canonical path. Counting them here as well would
                // double the total; they are measured at their canonical path.
                coverage.otherSkippedEntries += 1
                entry.isPartial = true
                entry.note = "Firmlink: measured at \(canonical)"
                return
            case .changed:
                coverage.changedDirectories += 1
                entry.isPartial = true
                entry.note = "Folder changed or moved during the scan"
                return
            }
            let names = directoryNames(fd: fd, entry: &entry)
            for name in names {
                let url = entry.url.appendingPathComponent(name)
                var child = SWPStorageEntry(url: url, kind: .unavailable, allocatedBytes: nil)
                if stopped {
                    child.isPartial = true
                    child.note = coverage.cancelled ? "Not measured: scan stopped" : "Not measured: scan limit reached"
                } else {
                    child = measure(parentFD: fd, url: url, name: name, depth: depth + 1,
                                    exposeChildren: exposeChildren)
                }
                if let bytes = child.allocatedBytes {
                    let sum = (entry.allocatedBytes ?? 0).addingReportingOverflow(bytes)
                    if sum.overflow {
                        entry.isPartial = true
                        coverage.unknownAllocations += 1
                    } else { entry.allocatedBytes = sum.partialValue }
                }
                entry.isPartial = entry.isPartial || child.isPartial
                if exposeChildren { entry.children.append(child) }
            }
            // No partial walk is ever presented as a completed zero-size folder.
            if stopped { entry.isPartial = true }
            entry.children.sort {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return ($0.allocatedBytes ?? -1) > ($1.allocatedBytes ?? -1)
                }
                return $0.name < $1.name
            }
        }

        mutating func directoryNames(fd: Int32, entry: inout SWPStorageEntry) -> [String] {
            let duplicate = dup(fd)
            guard duplicate >= 0 else {
                coverage.inaccessibleEntries += 1
                entry.isPartial = true
                entry.note = "Cannot read this folder"
                return []
            }
            guard let directory = fdopendir(duplicate) else {
                close(duplicate)
                coverage.inaccessibleEntries += 1
                entry.isPartial = true
                entry.note = "Cannot list this folder"
                return []
            }
            defer { closedir(directory) }
            var names: [String] = []
            let parentPathBytes = entry.url.path.utf8.count
            while !stopped {
                errno = 0
                guard let item = readdir(directory) else {
                    if errno != 0 {
                        coverage.inaccessibleEntries += 1
                        entry.isPartial = true
                        entry.note = "Some entries could not be listed"
                        return []
                    }
                    // Only sort a fully enumerated directory: otherwise hard-link
                    // attribution could depend on the filesystem's enumeration order.
                    names.sort()
                    return names
                }
                let nameLength = Int(item.pointee.d_namlen)
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) {
                        String(validatingCString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                let bytes = parentPathBytes + nameLength + 1
                guard coverage.visitedEntries < scanner.maximumEntries,
                      bytes <= scanner.maximumPathBytes - pathBytes else {
                    coverage.reachedLimit = true
                    break
                }
                coverage.visitedEntries += 1
                pathBytes += bytes
                guard let name else {
                    coverage.otherSkippedEntries += 1
                    entry.isPartial = true
                    continue
                }
                names.append(name)
            }
            entry.isPartial = true
            entry.note = coverage.cancelled ? "Listing stopped before completion" : "Listing exceeded the scan limit"
            return []
        }

        mutating func measure(parentFD: Int32, url: URL, name: String, depth: Int,
                              exposeChildren: Bool) -> SWPStorageEntry {
            var metadata = stat()
            guard fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                coverage.inaccessibleEntries += 1
                return SWPStorageEntry(url: url, kind: .unavailable, allocatedBytes: nil,
                                       isPartial: true, note: "Metadata unavailable")
            }
            let mode = metadata.st_mode & S_IFMT
            if mode == S_IFLNK {
                coverage.skippedLinks += 1
                return SWPStorageEntry(url: url, kind: .symbolicLink, allocatedBytes: nil,
                                       isPartial: true, note: "Symbolic link: target not followed")
            }
            if metadata.st_flags & UInt32(SF_DATALESS) != 0 || name.hasSuffix(".icloud") {
                coverage.cloudOnlyEntries += 1
                return SWPStorageEntry(url: url, kind: mode == S_IFDIR ? packageKind(url) : .file,
                                       allocatedBytes: nil, isPartial: true, note: "Cloud-only: not downloaded")
            }
            guard mode == S_IFDIR || mode == S_IFREG else {
                coverage.otherSkippedEntries += 1
                return SWPStorageEntry(url: url, kind: .other, allocatedBytes: nil,
                                       isPartial: true, note: "Special filesystem entry: skipped")
            }
            var entry = SWPStorageEntry(url: url, kind: mode == S_IFDIR ? packageKind(url) : .file,
                                        allocatedBytes: allocation(metadata))
            if entry.allocatedBytes == nil {
                entry.isPartial = true
                entry.note = "Allocated size unavailable"
                coverage.unknownAllocations += 1
            }
            if mode == S_IFREG {
                if metadata.st_nlink > 1, !hardLinks.insert(SWPStorageIdentity(metadata)).inserted {
                    coverage.duplicateHardLinks += 1
                    entry.allocatedBytes = 0
                    entry.note = "Hard link: allocation counted at the first path in name order"
                }
                return entry
            }
            // Do not cross mounted filesystems, even when mounted under the root.
            guard metadata.st_dev == rootIdentity.device else {
                coverage.otherSkippedEntries += 1
                entry.isPartial = true
                entry.note = "Mounted filesystem: not traversed"
                return entry
            }
            let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard childFD >= 0 else {
                coverage.inaccessibleEntries += 1
                entry.isPartial = true
                entry.note = "Cannot open this folder"
                return entry
            }
            defer { close(childFD) }
            var opened = stat()
            guard fstat(childFD, &opened) == 0,
                  SWPStorageIdentity(opened) == SWPStorageIdentity(metadata),
                  opened.st_flags & UInt32(SF_DATALESS) == 0 else {
                coverage.changedDirectories += 1
                entry.isPartial = true
                entry.note = "Folder changed during the scan"
                return entry
            }
            descend(fd: childFD, metadata: opened, entry: &entry, depth: depth,
                    exposeChildren: exposeChildren && entry.kind == .folder)
            return entry
        }

        enum Validation: Equatable {
            case valid
            /// Still reachable at the walked path, but the kernel reports a
            /// different canonical path for it.
            case alias(String)
            case changed
        }

        func validate(fd: Int32, url: URL, identity: SWPStorageIdentity) -> Validation {
            let checkRoot = open(rootURL.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard checkRoot >= 0 else { return .changed }
            defer { close(checkRoot) }
            var rootMetadata = stat()
            guard fstat(checkRoot, &rootMetadata) == 0,
                  SWPStorageIdentity(rootMetadata) == rootIdentity,
                  let actual = try? descriptorURL(fd) else {
                return .changed
            }
            // The walked name must still resolve to the same inode; a folder
            // renamed mid-scan fails here even though its descriptor is valid.
            let checkChild = open(url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard checkChild >= 0 else { return .changed }
            defer { close(checkChild) }
            var childMetadata = stat()
            guard fstat(checkChild, &childMetadata) == 0,
                  SWPStorageIdentity(childMetadata) == identity else { return .changed }
            guard actual.path == url.path else { return .alias(actual.path) }
            let inside = actual.path == rootURL.path
                || actual.path.hasPrefix(rootURL.path == "/" ? "/" : rootURL.path + "/")
            return inside ? .valid : .changed
        }
    }
}

private struct StorageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func posixError(_ url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
}

private func descriptorURL(_ fd: Int32) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
        throw StorageError("The folder's physical path could not be verified.")
    }
    let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func allocation(_ metadata: stat) -> Int64? {
    guard metadata.st_blocks >= 0 else { return nil }
    let bytes = Int64(metadata.st_blocks).multipliedReportingOverflow(by: 512)
    return bytes.overflow ? nil : bytes.partialValue
}

private func packageKind(_ url: URL) -> SWPStorageEntry.Kind {
    // Extension classification needs no path-based resource lookup, which might
    // otherwise follow a concurrently replaced directory or hydrate a provider.
    let suffix = url.pathExtension.lowercased()
    if storagePackageExtensions.contains(suffix) || UTType(filenameExtension: suffix)?.conforms(to: .package) == true {
        return .package
    }
    return .folder
}

private let storagePackageExtensions: Set<String> = [
    "app", "bundle", "framework", "plugin", "appex", "xpc", "photoslibrary",
    "photolibrary", "playground", "rtfd", "sparsebundle", "xcassets", "xcodeproj", "xcworkspace"
]

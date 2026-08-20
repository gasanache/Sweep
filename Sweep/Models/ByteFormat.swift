import Foundation

// MARK: - Byte formatting

/// Every size string in the UI comes from here so that a "1.2 GB" in the
/// sidebar and a "1.2 GB" in the confirmation sheet can never disagree.
enum SWPBytes {

    /// `.file` count style (base-10, matching Finder) rather than `.binary`.
    /// Users compare Sweep's numbers against Get Info, so we match Finder even
    /// though the on-disk allocation we measure is technically binary.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "Zero KB" }
        return formatter.string(fromByteCount: bytes)
    }

    /// Number and unit as separate strings.
    ///
    /// The scan hero renders the magnitude at 46 pt and the unit at 15 pt, so it
    /// needs the two halves apart. Splitting the formatted string keeps
    /// localisation intact — we never rebuild the number ourselves.
    static func split(_ bytes: Int64) -> (value: String, unit: String) {
        splitFormatted(string(bytes))
    }

    /// Split on the last *whitespace character*, not a literal U+0020:
    /// `ByteCountFormatter` separates number from unit with a non-breaking
    /// space in many locales, and matching only the ASCII space returned the
    /// whole string as the "value" with an empty unit everywhere outside
    /// English.
    static func splitFormatted(_ text: String) -> (value: String, unit: String) {
        guard let index = text.lastIndex(where: { $0.isWhitespace }) else { return (text, "") }
        return (String(text[text.startIndex..<index]), String(text[text.index(after: index)...]))
    }
}

// MARK: - On-disk size

/// Measuring how much space something actually occupies.
enum SWPDiskSize {

    /// Bytes a file or folder occupies on disk, following no symlinks.
    ///
    /// Uses *allocated* size, not logical size: a 1-byte file still costs a
    /// 4 KB block, and reporting the logical size would under-promise what a
    /// clean-up actually frees. Sparse bundles and clones make the two differ
    /// wildly, and users judge us against the space Finder gives back.
    ///
    /// Enumeration errors are swallowed deliberately. A cleaner walks
    /// thousands of directories it may not own; one `EPERM` deep inside a
    /// folder must degrade that folder's number, never fail the whole scan.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .fileResourceIdentifierKey]

        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }

        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        // No `.skipsPackageDescendants`: frameworks and nested bundles are
        // packages, and skipping their contents under-reported Microsoft Word
        // by 900 MB (1.9 GB shown, 2.7 GB real — `du` agrees with the full
        // walk exactly). Sweep's numbers are promises about reclaimed space,
        // so they must match what Finder and `du` say.
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        )

        // Hard links are counted once per inode, like `du`: pnpm and Homebrew
        // hard-link aggressively, and counting every link over-promises the
        // space a removal frees.
        var seenIdentifiers = Set<NSObject>()

        while let child = enumerator?.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
            if childValues.isSymbolicLink == true { continue }
            if childValues.isDirectory == true { continue }
            if let identifier = childValues.fileResourceIdentifier as? NSObject,
               !seenIdentifiers.insert(identifier).inserted {
                continue
            }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }

        return total
    }

    /// Sizes for a batch of URLs, measured in parallel.
    ///
    /// Sizing is almost entirely I/O wait, and a single `~/Library/Caches`
    /// sweep can span tens of gigabytes across sixty folders. Measuring them
    /// serially made a scan take about eight seconds on this machine; fanning
    /// out across cores brings it under two. Results stay index-aligned with
    /// the input, so callers can zip them back together.
    static func sizes(of urls: [URL]) -> [Int64] {
        guard !urls.isEmpty else { return [] }
        var results = [Int64](repeating: 0, count: urls.count)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let size = self.size(of: urls[index])
            lock.lock()
            results[index] = size
            lock.unlock()
        }
        return results
    }

    /// Modification date, used to show "last touched" so a user can sanity-check
    /// that a leftover really is stale before ticking it.
    static func modified(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

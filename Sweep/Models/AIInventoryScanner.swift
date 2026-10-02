import Foundation
import Darwin

/// Discovery evidence, never a removal target. A model-looking filename is not
/// proof of ownership, disuse, or even a valid model; file contents are not read.
struct SWPAIFinding: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case modelFile = "Model file candidate"
        case modelRepository = "Model repository cache"
        case modelStore = "Model / runtime data"
        case sharedCache = "Shared cache"
        case assistantData = "Assistant data"
        case application = "Application path"
        case command = "Command path"

        var isModel: Bool { self == .modelFile || self == .modelRepository }
    }

    let url: URL
    let product: String
    let kind: Kind
    let allocatedBytes: Int64?
    var isPartial = false
    var note: String = ""
    var id: String { url.path }
    var name: String { kind.isModel ? url.lastPathComponent : product }
    var sortBytes: Int64 { allocatedBytes ?? -1 }
    var sizeText: String {
        guard let allocatedBytes else { return "Not measured" }
        return SWPBytes.string(allocatedBytes) + (isPartial ? " · partial" : "")
    }
}

struct SWPAIInventory: Sendable {
    var findings: [SWPAIFinding] = []
    var checkedLocations = 0
    var additionalFolderPaths: Set<String> = []
    var notes: [String] = []
    var isPartial = false
    var scannedAt = Date()
    var locationCount: Int { findings.filter { !$0.kind.isModel }.count }
    var modelCount: Int { findings.filter { $0.kind.isModel }.count }
    var summary: String { "\(locationCount) locations · \(modelCount) model files / repositories" }
}

/// Common locations, not an ownership allow-list. Version-specific, project,
/// remote and custom locations may differ. Assistant stores can contain login
/// credentials and conversation history: discovery never opens those files.
enum SWPAICatalog {
    struct Location: Sendable {
        let url: URL
        let product: String
        let kind: SWPAIFinding.Kind
    }

    static func homeLocations(home: URL) -> [Location] {
        let definitions: [(String, SWPAIFinding.Kind, [String])] = [
            ("LM Studio", .modelStore, [".lmstudio", ".cache/lm-studio", "Library/Application Support/LM Studio"]),
            ("Ollama", .modelStore, [".ollama"]),
            ("Hugging Face / MLX / Transformers", .sharedCache, [".cache/huggingface"]),
            ("PyTorch", .sharedCache, [".cache/torch"]),
            ("llama.cpp", .modelStore, [".cache/llama.cpp"]),
            ("Jan", .modelStore, ["jan", ".jan", "Library/Application Support/Jan"]),
            ("GPT4All", .modelStore, ["Library/Application Support/nomic.ai/GPT4All", ".cache/gpt4all"]),
            ("Msty", .modelStore, [".msty", "Library/Application Support/Msty"]),
            ("Local models", .modelStore, ["Models"]),
            ("Codex", .assistantData, [".codex", "Library/Application Support/Codex"]),
            ("Claude Code", .assistantData, [".claude", ".claude.json"]),
            ("Claude", .assistantData, ["Library/Application Support/Claude"]),
            ("ChatGPT", .assistantData, ["Library/Application Support/ChatGPT"]),
            ("Cursor", .assistantData, ["Library/Application Support/Cursor", ".cursor"]),
            ("Gemini CLI", .assistantData, [".gemini"]),
            ("OpenCode", .assistantData, [".local/share/opencode", ".config/opencode", ".cache/opencode"])
        ]
        var locations = definitions.flatMap { product, kind, paths in
            paths.map { Location(url: home.appendingPathComponent($0), product: product, kind: kind) }
        }
        // Exact known bundle identifiers only. These paths may survive an app's
        // removal; their presence does not mean the app is still installed.
        let assistants = [("ChatGPT", "com.openai.chat"), ("Codex", "com.openai.codex"),
                          ("Claude", "com.anthropic.claudefordesktop")]
        for (product, bundleID) in assistants {
            for parent in ["Containers", "Caches", "HTTPStorages", "WebKit", "Application Support"] {
                locations.append(Location(url: home.appendingPathComponent("Library/\(parent)/\(bundleID)"),
                                          product: product, kind: .assistantData))
            }
            locations.append(Location(url: home.appendingPathComponent("Library/Group Containers/group.\(bundleID)"),
                                      product: product, kind: .assistantData))
        }
        return locations
    }

    static func locations(home: URL, applicationRoots: [URL], commandRoots: [URL], environment: [String: String]) -> [Location] {
        var result = homeLocations(home: home)
        for root in applicationRoots {
            for name in ["LM Studio", "Ollama", "Jan", "GPT4All", "Msty", "ChatGPT", "Codex", "Claude", "Cursor"] {
                result.append(Location(url: root.appendingPathComponent(name + ".app"), product: name, kind: .application))
            }
        }
        for root in commandRoots {
            for name in ["codex", "claude", "ollama", "lms", "gemini", "opencode", "llama-cli", "aider"] {
                result.append(Location(url: root.appendingPathComponent(name), product: name, kind: .command))
            }
        }
        let overrides: [(String, String, SWPAIFinding.Kind)] = [
            ("OLLAMA_MODELS", "Ollama", .modelStore), ("HF_HOME", "Hugging Face", .sharedCache),
            ("HF_HUB_CACHE", "Hugging Face", .sharedCache), ("HUGGINGFACE_HUB_CACHE", "Hugging Face", .sharedCache),
            ("TRANSFORMERS_CACHE", "Transformers", .sharedCache), ("TORCH_HOME", "PyTorch", .sharedCache),
            ("CODEX_HOME", "Codex", .assistantData), ("CLAUDE_CONFIG_DIR", "Claude Code", .assistantData)
        ]
        for (key, product, kind) in overrides {
            guard let path = environment[key], path.hasPrefix("/"),
                  !path.split(separator: "/").contains("..") else { continue }
            result.append(Location(url: URL(fileURLWithPath: path), product: product + " (\(key))", kind: kind))
        }
        return result
    }

    /// Keep newly discovered shared models and sensitive assistant data out of
    /// bulk cleanup, including an aggregate ancestor. Dedicated LM Studio and
    /// Ollama removal retains its separate, stricter policy.
    static func protectsFromGenericRemoval(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return homeLocations(home: home).contains { location in
            let root = location.url.standardizedFileURL.path.lowercased()
            return path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
        }
    }
}

/// User-added inspection roots remain protected for this process's lifetime,
/// even after leaving the browser, so an older cleanup plan cannot sweep them.
/// Only the safety gate consumes this registry; it never authorizes removal.
final class SWPAIInspectionProtection: @unchecked Sendable {
    static let shared = SWPAIInspectionProtection()
    private let lock = NSLock()
    private var paths: Set<String> = []

    func reserve(_ urls: [URL]) {
        lock.withLock {
            paths.formUnion(urls.filter { $0.isFileURL }.map { $0.standardizedFileURL.path.lowercased() })
        }
    }

    func protects(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return lock.withLock {
            paths.contains { root in
                path == root || path.hasPrefix(root == "/" ? "/" : root + "/") || root.hasPrefix(path + "/")
            }
        }
    }
}

/// Bounded metadata-only discovery built on the Storage Explorer's no-follow,
/// no-hydration walker. No subprocesses, configuration parsing or network API calls.
struct SWPAIInventoryScanner: Sendable {
    var home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var applicationRoots: [URL]? = nil
    var commandRoots: [URL]? = nil
    var environment = ProcessInfo.processInfo.environment
    var additionalFolders: [URL] = []
    var maximumEntries = 100_000
    var maximumEntriesPerLocation = 15_000
    var maximumFindings = 2_000

    func scan() -> SWPAIInventory {
        let started = Date()
        let roots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let commands = commandRoots ?? [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        var locations = SWPAICatalog.locations(home: home, applicationRoots: roots, commandRoots: commands, environment: environment)
        locations += additionalFolders.prefix(32).map { .init(url: $0, product: "Added folder", kind: .modelStore) }
        var result = SWPAIInventory(additionalFolderPaths: Set(additionalFolders.prefix(32).map { $0.path }), scannedAt: started)
        result.notes = [
            "Read-only inventory. No model, credential, conversation or project file contents are read. Nothing here is selected for cleanup.",
            "Common locations and inherited environment overrides are checked, not the entire disk. App-specific custom settings, project-local tools, containers and remote models are not searched. Add a model folder to inspect another location.",
            "Model files are filename candidates, not verified models or proof they are unused. Repository caches can include configuration and other files. Ollama blobs are reported as a store, not counted as individual models.",
            "Allocated sizes are not reclaimable space. Parent locations include their model rows; do not add them together. Hard links are counted once per location; separate locations and APFS clones may share blocks.",
            "Links, cloud-only data and inaccessible paths are not followed or downloaded. Application and command paths are evidence of presence, not verified installations."
        ]
        var seen = Set<String>()
        var remaining = max(0, maximumEntries)
        for location in locations {
            if Task.isCancelled { result.isPartial = true; result.notes.append("Discovery was cancelled."); break }
            let url = location.url
            guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains(".."),
                  seen.insert(url.standardizedFileURL.path).inserted else { continue }
            result.checkedLocations += 1
            // Opening for events reads metadata only, never file data. ANY also
            // refuses linked ancestors instead of silently escaping the root.
            let fd = open(url.path, O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            if fd < 0 {
                let code = errno
                if code == ENOENT || code == ENOTDIR { continue }
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: nil, isPartial: true,
                                    note: code == ELOOP ? "Path or ancestor is linked; presence and size unverified" : "Metadata unavailable: \(String(cString: strerror(code)))"), to: &result)
                continue
            }
            var metadata = stat()
            let measured = fstat(fd, &metadata) == 0
            close(fd)
            guard measured else {
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: nil, isPartial: true, note: "Metadata unavailable"), to: &result)
                continue
            }
            if metadata.st_flags & UInt32(SF_DATALESS) != 0 {
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: nil, isPartial: true, note: "Cloud-only: not downloaded"), to: &result)
                continue
            }
            if metadata.st_mode & S_IFMT != S_IFDIR {
                let allocation = Int64(metadata.st_blocks).multipliedReportingOverflow(by: 512)
                let bytes = metadata.st_blocks >= 0 && !allocation.overflow ? allocation.partialValue : nil
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: bytes, isPartial: bytes == nil,
                                    note: location.kind == .assistantData ? "May contain credentials or conversation history; preserved." : "File contents not read."), to: &result)
                continue
            }
            guard remaining > 0 else {
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: nil, isPartial: true, note: "Not measured: scan entry limit reached"), to: &result)
                continue
            }
            do {
                let snapshot = try SWPStorageScanner(maximumEntries: min(remaining, max(1, maximumEntriesPerLocation)),
                                                     maximumDepth: 48, maximumPathBytes: 4 * 1_024 * 1_024).scan(rootURL: url)
                remaining -= snapshot.coverage.visitedEntries
                let coverage = snapshot.coverage
                var notes: [String] = []
                if location.kind == .assistantData { notes.append("May contain credentials, conversations and settings; preserved.") }
                if coverage.reachedLimit { notes.append("Scan limit reached.") }
                if coverage.skippedLinks > 0 { notes.append("\(coverage.skippedLinks) links not followed.") }
                if coverage.inaccessibleEntries > 0 { notes.append("\(coverage.inaccessibleEntries) entries inaccessible.") }
                if coverage.cloudOnlyEntries > 0 { notes.append("\(coverage.cloudOnlyEntries) cloud-only entries skipped.") }
                if coverage.duplicateHardLinks > 0 { notes.append("\(coverage.duplicateHardLinks) hard links counted at their first path only.") }
                if snapshot.root.isPartial && notes.isEmpty { notes.append("Incomplete measurement; files may have changed or could not be measured.") }
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: snapshot.root.allocatedBytes, isPartial: snapshot.root.isPartial,
                                    note: notes.joined(separator: " ")), to: &result)
                if location.kind == .modelStore || location.kind == .sharedCache {
                    collectModels(snapshot.root, product: location.product, into: &result)
                }
            } catch {
                append(SWPAIFinding(url: url, product: location.product, kind: location.kind,
                                    allocatedBytes: nil, isPartial: true, note: error.localizedDescription), to: &result)
            }
        }
        // An environment override or added folder may overlap a known root.
        // Stable path identities prevent duplicate rows, not additive totals.
        var ids = Set<String>()
        result.findings = result.findings.filter { ids.insert($0.id).inserted }.sorted {
            if $0.product != $1.product { return $0.product.localizedStandardCompare($1.product) == .orderedAscending }
            return $0.url.path < $1.url.path
        }
        if result.isPartial { result.notes.append("Coverage is partial. Missing rows do not prove that models or software are absent.") }
        return result
    }

    private func append(_ finding: SWPAIFinding, to result: inout SWPAIInventory) {
        guard result.findings.count < max(1, maximumFindings) else {
            result.isPartial = true
            if !result.notes.contains("Finding limit reached.") { result.notes.append("Finding limit reached.") }
            return
        }
        result.findings.append(finding)
        result.isPartial = result.isPartial || finding.isPartial
    }

    private func collectModels(_ entry: SWPStorageEntry, product: String, into result: inout SWPAIInventory) {
        guard !Task.isCancelled, result.findings.count < max(1, maximumFindings) else {
            result.isPartial = true
            if !Task.isCancelled && !result.notes.contains("Finding limit reached.") { result.notes.append("Finding limit reached.") }
            return
        }
        if entry.kind == .folder, entry.name.hasPrefix("models--") {
            append(SWPAIFinding(url: entry.url, product: product, kind: .modelRepository,
                                allocatedBytes: entry.allocatedBytes, isPartial: entry.isPartial,
                                note: "Repository cache, including blobs and metadata. Shared by tools; preserved."), to: &result)
            return // Do not count cached revisions and weight shards as separate models.
        }
        let modelPackage = entry.kind == .folder && ["mlpackage", "mlmodelc"].contains(entry.url.pathExtension.lowercased())
        if (entry.kind == .file || entry.kind == .package || modelPackage), Self.isModelFilename(entry.name) {
            append(SWPAIFinding(url: entry.url, product: product, kind: .modelFile,
                                allocatedBytes: entry.allocatedBytes, isPartial: entry.isPartial,
                                note: "Identified by filename only; contents and usage are not verified." + (entry.note.map { " " + $0 } ?? "")), to: &result)
            return
        }
        for child in entry.children { collectModels(child, product: product, into: &result) }
    }

    static func isModelFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["gguf", "ggml", "safetensors", "onnx", "pt", "pth", "ckpt", "tflite", "keras", "h5", "hdf5", "npz", "mlmodel", "mlpackage", "mlmodelc"].contains(ext) { return true }
        if ["saved_model.pb", "frozen_inference_graph.pb", "model.bin"].contains(lower) { return true }
        return ext == "bin" && ["pytorch_model", "ggml-", "consolidated"].contains { lower.hasPrefix($0) }
    }
}

import Foundation
import Darwin

/// Mutations use only data created here. This executable refuses to run against
/// a real home. It never invokes Local AI runtime/package commands or admin moves.
@main
struct WorkflowVerification {
    static func main() {
        do { try verify() }
        catch {
            FileHandle.standardError.write(Data("FAIL — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func verify() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let expected = ProcessInfo.processInfo.environment["SWEEP_WORKFLOW_HOME"],
              home.path == expected, NSHomeDirectory() == expected,
              home.deletingLastPathComponent().path == "/Users/Shared",
              home.lastPathComponent.hasPrefix("sweep-workflow."),
              SWPLocalAIPathIdentity.resolvedURL(home) == home else {
            FileHandle.standardError.write(Data("Refusing a non-fixture home; invoke verify-workflows.sh\n".utf8))
            exit(2)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: false)
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            let passed = condition()
            FileHandle.standardOutput.write(Data(((passed ? "PASS — " : "FAIL — ") + message + "\n").utf8))
            if !passed { exit(1) }
        }
        func create(_ relative: String, _ text: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return url
        }
        func item(_ url: URL) -> SWPItem {
            SWPItem(url: url, sizeBytes: 7, modified: nil, location: "Fixture", requiresAdmin: false)
        }
        func restore(_ original: URL) throws {
            let batch = SWPRemovalService.restorableFolders().first {
                SWPRemovalService.entries(in: $0).contains { $0.original.path == original.path }
            }
            check(batch != nil, "moved fixture remains discoverable for recovery")
            let result = SWPRemovalService().restore(from: batch!)
            check(result.restored == 1 && result.failed == 0 && !result.cancelled,
                  "dedicated-workflow fixture restores through the recovery gate")
            check(manager.fileExists(atPath: original.path), "restored fixture is back at its original path")
        }
        let settings = try create("Library/Application Support/LM Studio/settings.json", "not JSON")
        let support = settings.deletingLastPathComponent()
        let scanner = SWPLocalAIScanner(home: home, applicationRoots: [], brewPrefixes: [])
        check(scanner.scan().first { $0.product == .lmStudio }?.blockers.isEmpty == false,
              "invalid settings block the dedicated LM Studio plan")
        let inventory = SWPAppInventory.fixture(bundleIDs: Set((0..<40).map { "org.fixture\($0).app" }), appCount: 80)
        var unreadable: [String] = []
        let orphans = SWPOrphanScanner(inventory: inventory).scan(unreadable: &unreadable) { _ in }
        check(!orphans.flatMap(\.items).contains { $0.url == support }, "ordinary orphan scan excludes Local AI support data")
        let refused = SWPRemovalService().trash([item(support)])
        check(refused.trashedCount == 0 && refused.refusedByPolicy.count == 1,
              "generic removal independently refuses a Local AI target")
        check(manager.fileExists(atPath: settings.path), "refused data is untouched")

        try Data("{}".utf8).write(to: settings)
        check(scanner.scan().first { $0.product == .lmStudio }?.blockers.isEmpty == true,
              "supported fixture configuration is reviewable")
        let moved = SWPRemovalService().trashLocalAI([item(support)], product: .lmStudio)
        check(moved.trashedCount == 1 && moved.failures.isEmpty, "dedicated removal still works for approved data (\(moved.failures))")
        try restore(support)
        check((try? String(contentsOf: settings, encoding: .utf8)) == "{}", "recovery preserves data bytes")

        let localCache = try create("Library/Caches/Homebrew/downloads/" + String(repeating: "a", count: 64) + "--ollama-1.2.3.tar.gz", "owned")
        let otherCache = try create("Library/Caches/Homebrew/downloads/" + String(repeating: "b", count: 64) + "--wget-1.2.3.tar.gz", "unrelated")
        var junk = SWPJunkScanner(inventory: inventory, claimed: [])
        let developer = junk.scanDeveloper { _ in }.flatMap(\.items).map(\.url)
        check(!developer.contains(localCache), "ordinary developer cleanup excludes owned Local AI installers")
        check(developer.contains(otherCache), "ordinary Homebrew downloads remain available for cleanup")
        let caches = junk.scanCaches { _ in }.flatMap(\.items).map(\.url)
        check(!caches.contains(home.appendingPathComponent("Library/Caches/Homebrew")),
              "aggregate cache parents cannot bypass the dedicated workflow")

        let appInfo = try create("Applications/LM Studio.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>ai.elementlabs.lmstudio</string>
        <key>CFBundleName</key><string>LM Studio</string></dict></plist>
        """)
        let app = appInfo.deletingLastPathComponent().deletingLastPathComponent()
        let generic = SWPRemovalService().uninstall(bundle: item(app), residues: [])
        check(generic.trashedCount == 0 && generic.refusedByPolicy.count == 1,
              "generic uninstall cannot bypass Local AI app checks")
        let dedicated = SWPRemovalService().trashLocalAI([item(app)], product: .lmStudio, application: true)
        check(dedicated.trashedCount == 1 && dedicated.failures.isEmpty,
              "dedicated approved application move still works")
        try restore(app)
        UserDefaults.standard.synchronize()
        print("PASS — all filesystem workflow checks; no real apps, packages, services or permissions changed")
    }
}

import XCTest
import Darwin

final class LocalAIRemovalTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let home: URL
        let prefix: URL
        var commands: [[String]] = []
        var commandFailure: String?
        var dependents = ""
        var processes: [SWPLocalAIRemovalService.Runtime] = []
        var trashPaths: [String] = []
        var backups: [URL] = []
        var caskJSON = ""
        var backupFailure = false
        var restartOnSecondDependencyCheck = false

        init() throws {
            let physical = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
            defer { free(physical) }
            root = URL(fileURLWithPath: String(cString: physical))
                .appendingPathComponent("SweepLocalAIRemoval-" + UUID().uuidString)
            home = root.appendingPathComponent("home")
            prefix = root.appendingPathComponent("brew")
            for url in [home.appendingPathComponent("Applications"), prefix.appendingPathComponent("bin"), root.appendingPathComponent("Trash")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        func create(_ relative: String, content: String = "fixture") throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
            return url
        }

        func installFormula() throws {
            for version in ["0.1", "0.2"] {
                try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Cellar/ollama/" + version), withIntermediateDirectories: true)
            }
            let executable = prefix.appendingPathComponent("bin/brew")
            try Data("fixture only; never execute".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func installCask(unsafeHook: Bool = false) throws -> URL {
            let app = home.appendingPathComponent("Applications/LM Studio.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "ai.elementlabs.lmstudio"], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            let metadata = prefix.appendingPathComponent("Caskroom/lm-studio/.metadata")
            let receiptFolder = metadata.appendingPathComponent("1/installed/Casks")
            try FileManager.default.createDirectory(at: receiptFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/lm-studio/1"), withIntermediateDirectories: true)
            let artifacts: [[String: Any]] = unsafeHook
                ? [["app": ["LM Studio.app"]], ["uninstall": [["script": "/unrelated/remove"]]]]
                : [["app": ["LM Studio.app"], "target": app.path], ["uninstall": [["quit": ["ai.elementlabs.lmstudio"]]]]]
            let receipt: [String: Any] = ["token": "lm-studio", "artifacts": artifacts]
            try JSONSerialization.data(withJSONObject: receipt).write(to: receiptFolder.appendingPathComponent("lm-studio.json"))
            try Data("{\"default\":{\"appdir\":\"/Applications\"}}".utf8).write(to: metadata.appendingPathComponent("config.json"))
            caskJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["casks": [receipt]]), as: UTF8.self)
            let brew = prefix.appendingPathComponent("bin/brew")
            try Data("fixture only; never execute".utf8).write(to: brew)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew.path)
            return app
        }

        func useModernCaskReceipt(unsafeHook: Bool = false) throws {
            let metadata = prefix.appendingPathComponent("Caskroom/lm-studio/.metadata")
            try Data("{}".utf8).write(to: metadata.appendingPathComponent("1/installed/Casks/lm-studio.json"))
            let artifacts: [[String: Any]] = unsafeHook
                ? [["app": ["LM Studio.app"]], ["uninstall": [["script": "/unrelated/remove"]]]]
                : [["app": ["LM Studio.app"]], ["uninstall": [["quit": ["ai.elementlabs.lmstudio"]]]]]
            let tab: [String: Any] = ["uninstall_flight_blocks": false,
                                      "source": ["tap": "homebrew/cask", "version": "1"],
                                      "uninstall_artifacts": artifacts]
            try JSONSerialization.data(withJSONObject: tab).write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        }

        func plans() -> [SWPLocalAIPlan] {
            SWPLocalAIScanner(home: home, applicationRoots: [home.appendingPathComponent("Applications")], brewPrefixes: [prefix]).scan()
        }

        func plan(_ product: SWPLocalAIProduct) throws -> SWPLocalAIPlan {
            try XCTUnwrap(plans().first { $0.product == product })
        }

        func service() -> SWPLocalAIRemovalService {
            SWPLocalAIRemovalService(fixture: .init(root: root, home: home, scan: { self.plans() }, command: { executable, args in
                self.commands.append(args)
                if args.contains(self.commandFailure ?? "never-a-command") {
                    return .init(status: 1, output: "injected refusal")
                }
                if executable.lastPathComponent == "launchctl" { return .init(status: 113, output: "not registered") }
                if args.first == "uses" {
                    if self.restartOnSecondDependencyCheck, self.commands.filter({ $0.first == "uses" }).count == 2 {
                        self.processes = [.init(pid: 999_999, uid: getuid(), executable: self.prefix.appendingPathComponent("Cellar/ollama/0.2/bin/ollama").path)]
                    }
                    return .init(status: 0, output: self.dependents)
                }
                if args == ["services", "list", "--json"] { return .init(status: 0, output: "[]") }
                if args.first == "info" { return .init(status: 0, output: self.caskJSON) }
                if args.first == "uninstall" {
                    if args.contains("--cask") {
                        guard !FileManager.default.fileExists(atPath: self.home.appendingPathComponent("Applications/LM Studio.app").path) else {
                            return .init(status: 1, output: "app was not trashed before cask uninstall")
                        }
                    }
                    let source = self.prefix.appendingPathComponent(args.contains("--cask") ? "Caskroom/lm-studio" : "Cellar/ollama")
                    try FileManager.default.moveItem(at: source, to: self.root.appendingPathComponent("uninstalled-package"))
                }
                return .init(status: 0, output: "")
            }, runtimes: { self.processes }, terminate: { runtime in
                self.processes.removeAll { $0 == runtime }
            }, trash: { items, _ in
                var outcome = SWPRemovalOutcome()
                for item in items {
                    do {
                        let target = self.root.appendingPathComponent("Trash/" + UUID().uuidString)
                        try FileManager.default.moveItem(at: item.url, to: target)
                        self.trashPaths.append(item.url.path)
                        outcome.trashedCount += 1
                        outcome.trashedBytes += item.sizeBytes
                    } catch { outcome.failures.append((item.url.path, error.localizedDescription)) }
                }
                return outcome
            }, backup: { _, bytes in
                if self.backupFailure { throw CocoaError(.fileWriteNoPermission) }
                let target = self.root.appendingPathComponent("Trash/backup-" + UUID().uuidString)
                try bytes.write(to: target)
                self.backups.append(target)
                return target
            }))
        }

        func dispose() throws { try FileManager.default.removeItem(at: root) }
    }

    func testServiceStopFailureLeavesPackageAndDataUntouched() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        try fixture.installFormula()
        let model = try fixture.create(".ollama/models/model")
        fixture.commandFailure = "stop"
        let result = fixture.service().remove(try fixture.plan(.ollama))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("Cellar/ollama/0.1").path))
        XCTAssertTrue(fixture.trashPaths.isEmpty)
        XCTAssertFalse(fixture.commands.contains { $0.first == "uninstall" })
    }

    func testDependentsPreventForceUninstallAndServiceChanges() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        try fixture.installFormula()
        fixture.dependents = "dependent-app\n"
        let result = fixture.service().remove(try fixture.plan(.ollama))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(fixture.commands.contains { $0.first == "services" || $0.first == "uninstall" })
    }

    func testFormulaCleanupRemovesAllVersionsOnlyAfterRuntimeStops() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        try fixture.installFormula()
        let model = try fixture.create(".ollama/models/model")
        fixture.processes = [.init(pid: 999_999, uid: getuid(), executable: fixture.prefix.appendingPathComponent("Cellar/ollama/0.2/bin/ollama").path)]
        let result = fixture.service().remove(try fixture.plan(.ollama))
        XCTAssertTrue(result.succeeded, result.failures.joined(separator: "\n"))
        XCTAssertTrue(fixture.processes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("Cellar/ollama").path))
        XCTAssertTrue(fixture.commands.contains(["uninstall", "--formula", "--force", "ollama"]))
    }

    func testRestartedRuntimeBlocksFormulaUninstallBeforeAnyPackageMutation() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        try fixture.installFormula()
        let model = try fixture.create(".ollama/models/model")
        fixture.restartOnSecondDependencyCheck = true
        let result = fixture.service().remove(try fixture.plan(.ollama))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(fixture.commands.contains { $0.first == "uninstall" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("Cellar/ollama").path))
        XCTAssertTrue(fixture.trashPaths.isEmpty)
    }

    func testForgedUnrelatedSelectionNeverReachesTrash() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let document = try fixture.create("Documents/keep.txt")
        let item = SWPItem(url: document, sizeBytes: 7, modified: nil, location: "forged", requiresAdmin: false)
        var plan = SWPLocalAIPlan(product: .ollama, items: [item], appURLs: [], brewExecutable: nil,
                                  hasBrewPackage: false, shellProfiles: [], blockers: [], notes: [])
        plan.pathIdentities[document.path] = try SWPLocalAIPathIdentity.capture(document)
        let result = fixture.service().remove(plan)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "fixture")
        XCTAssertTrue(fixture.trashPaths.isEmpty)
    }

    func testNewlyDiscoveredPathRequiresAnotherReview() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let original = try fixture.create(".lmstudio/models/model")
        let reviewed = try fixture.plan(.lmStudio)
        let added = try fixture.create("Library/Logs/LM Studio/log")
        let result = fixture.service().remove(reviewed)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testReplacedDirectoryIdentityRequiresAnotherReview() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        _ = try fixture.create(".ollama/models/first")
        let reviewed = try fixture.plan(.ollama)
        let data = fixture.home.appendingPathComponent(".ollama")
        try FileManager.default.moveItem(at: data, to: fixture.root.appendingPathComponent("old-data"))
        let replacement = try fixture.create(".ollama/models/replacement")
        let result = fixture.service().remove(reviewed)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testShellEditPreservesOtherContentPermissionsAndTrashBackup() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let original = "export EDITOR=vim\n# Added by LM Studio CLI (lms)\nexport PATH=\"$PATH:\(fixture.home.path)/.lmstudio/bin\"\n# End of LM Studio CLI section\nalias keep='echo keep'\n"
        let profile = try fixture.create(".zshrc", content: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: profile.path)
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertTrue(result.succeeded, result.failures.joined(separator: "\n"))
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), "export EDITOR=vim\nalias keep='echo keep'\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: profile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(fixture.backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fixture.backups.first)), Data(original.utf8))
    }

    func testShellContentChangedAfterReviewIsNeverOverwritten() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let original = "# Added by LM Studio CLI (lms)\nexport PATH=\"$PATH:\(fixture.home.path)/.lmstudio/bin\"\n# End of LM Studio CLI section\n"
        let profile = try fixture.create(".profile", content: original)
        let reviewed = try fixture.plan(.lmStudio)
        let edited = original + "export IMPORTANT=value\n"
        try Data(edited.utf8).write(to: profile)
        let result = fixture.service().remove(reviewed)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), edited)
        XCTAssertTrue(fixture.backups.isEmpty)
    }

    func testUnrelatedLlamaServerIsNeverSignalled() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        _ = try fixture.create(".lmstudio/models/model")
        let unrelated = SWPLocalAIRemovalService.Runtime(pid: 888_888, uid: getuid(), executable: "/unrelated/project/llama-server")
        fixture.processes = [unrelated]
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertTrue(result.succeeded, result.failures.joined(separator: "\n"))
        XCTAssertEqual(fixture.processes, [unrelated])
    }

    func testCaskAppReachesTrashBeforePermanentRegistrationRemoval() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let app = try fixture.installCask()
        let originalInfo = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertTrue(result.succeeded, result.failures.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("Caskroom/lm-studio").path))
        let trashed = try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent("Trash"), includingPropertiesForKeys: nil)
        let recoveredApp = try XCTUnwrap(trashed.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) })
        XCTAssertEqual(try Data(contentsOf: recoveredApp.appendingPathComponent("Contents/Info.plist")), originalInfo)
        XCTAssertGreaterThan(result.trashedBytes, 0)
    }

    func testModernCaskReceiptSupportsSafeRegistrationCleanup() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let app = try fixture.installCask()
        try fixture.useModernCaskReceipt()
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertTrue(result.succeeded, result.failures.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("Caskroom/lm-studio").path))
    }

    func testModernCaskReceiptCannotHideAnInstalledScriptBehindSafeCurrentMetadata() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let app = try fixture.installCask()
        try fixture.useModernCaskReceipt(unsafeHook: true)
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(fixture.trashPaths.isEmpty)
        XCTAssertFalse(fixture.commands.contains { $0.first == "uninstall" })
    }

    func testCaskTargetOutsideReviewedLocationsIsRefused() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let app = try fixture.installCask()
        let cask: [String: Any] = ["token": "lm-studio",
                                  "artifacts": [["app": ["LM Studio.app"],
                                                  "target": fixture.home.appendingPathComponent("Documents/keep.app").path]]]
        fixture.caskJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["casks": [cask]]), as: UTF8.self)
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(fixture.trashPaths.isEmpty)
    }

    func testCaskScriptRefusesBeforeAppOrPackageRemoval() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let app = try fixture.installCask(unsafeHook: true)
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(fixture.commands.contains { $0.first == "uninstall" })
        XCTAssertTrue(fixture.trashPaths.isEmpty)
    }

    func testFailedBackupLeavesShellProfileUnchanged() throws {
        let fixture = try Fixture(); defer { try? fixture.dispose() }
        let original = "# Added by LM Studio CLI (lms)\nexport PATH=\"$PATH:\(fixture.home.path)/.lmstudio/bin\"\n# End of LM Studio CLI section\n"
        let profile = try fixture.create(".bashrc", content: original)
        fixture.backupFailure = true
        let result = fixture.service().remove(try fixture.plan(.lmStudio))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), original)
    }
}

import XCTest
import Darwin

final class LocalAIScannerTests: XCTestCase {
    private let fm = FileManager.default

    private func fixture() throws -> URL {
        // Foundation preserves /var aliases on macOS; use a physical fixture
        // root so the intentional symlink refusal is not triggered by /var.
        let physical = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("SweepLocalAI-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func file(_ root: URL, _ path: String, _ content: Data = Data("fixture".utf8)) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        return url
    }

    private func plan(_ product: SWPLocalAIProduct, home: URL, applications: [URL] = [], brew: [URL] = []) throws -> SWPLocalAIPlan {
        try XCTUnwrap(SWPLocalAIScanner(home: home, applicationRoots: applications, brewPrefixes: brew).scan().first { $0.product == product })
    }

    func testExactHomeAllowlistNeverAuthorizesDescendantsOrCustomModels() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        for name in [".lmstudio", ".lmstudio-home-pointer"] {
            XCTAssertTrue(SWPSafety.validateLocalAI(home.appendingPathComponent(name), product: .lmStudio, home: home).isAllowed)
        }
        XCTAssertTrue(SWPSafety.validateLocalAI(home.appendingPathComponent(".ollama"), product: .ollama, home: home).isAllowed)
        for name in ["", "Documents", ".lmstudio/models", ".ollama/models", ".cache/huggingface", ".cache/huggingface/hub", "SharedModels"] {
            for product in SWPLocalAIProduct.allCases {
                XCTAssertFalse(SWPSafety.validateLocalAI(home.appendingPathComponent(name), product: product, home: home).isAllowed, name)
            }
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            XCTAssertTrue(SWPSafety.validateLocalAI(URL(fileURLWithPath: prefix + "/var/log/ollama.log"), product: .ollama).isAllowed)
            XCTAssertFalse(SWPSafety.validateLocalAI(URL(fileURLWithPath: prefix + "/var/log"), product: .ollama).isAllowed)
            XCTAssertFalse(SWPSafety.validateLocalAI(URL(fileURLWithPath: prefix + "/var/log/ollama.log/other"), product: .ollama).isAllowed)
        }
    }

    func testSymlinkToAnotherAllowedLocationAndLinkedAncestorAreRejected() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        let target = try file(home, "Library/Caches/ai.elementlabs.lmstudio/model")
        let link = home.appendingPathComponent(".lmstudio")
        try fm.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        XCTAssertFalse(SWPSafety.validateLocalAI(link, product: .lmStudio, home: home).isAllowed)
        var result = try plan(.lmStudio, home: home)
        XCTAssertFalse(result.items.contains { $0.url == link })
        XCTAssertTrue(result.blockers.contains { $0.contains(link.path) })

        let other = try fixture()
        defer { try? fm.removeItem(at: other) }
        try fm.createSymbolicLink(at: other.appendingPathComponent("Library"), withDestinationURL: home.appendingPathComponent("Library"))
        result = try plan(.lmStudio, home: other)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.blockers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), Data("fixture".utf8))
    }

    func testCustomPointerAndModelSettingsAreWarningsNotRemovalTargets() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        let shared = try file(home, "SharedModels/model.gguf")
        let customInsideSupport = try file(home, "Library/Application Support/LM Studio/custom/model.gguf")
        try file(home, ".lmstudio-home-pointer", Data(shared.deletingLastPathComponent().path.utf8))
        let settings = try JSONSerialization.data(withJSONObject: ["downloadsFolder": customInsideSupport.deletingLastPathComponent().path])
        try file(home, ".lmstudio/settings.json", settings)
        let result = try plan(.lmStudio, home: home)
        XCTAssertTrue(result.blockers.isEmpty, result.blockers.joined(separator: "\n"))
        XCTAssertTrue(result.items.contains { $0.url == home.appendingPathComponent(".lmstudio") })
        XCTAssertFalse(result.items.contains { shared.path.hasPrefix($0.url.path + "/") || customInsideSupport.path.hasPrefix($0.url.path + "/") })
        XCTAssertTrue(result.notes.contains { $0.contains(shared.deletingLastPathComponent().path) })
        XCTAssertTrue(result.notes.contains { $0.contains(customInsideSupport.deletingLastPathComponent().path) })
        XCTAssertEqual(try Data(contentsOf: shared), Data("fixture".utf8))
    }

    func testIdentityAndIndependentBrewVersionsPreventCLIOnlyOrphanClassification() throws {
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let applications = root.appendingPathComponent("Applications")
        let brew = root.appendingPathComponent("brew")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "ai.elementlabs.lmstudio"], format: .xml, options: 0)
        try file(applications, "Renamed.app/Contents/Info.plist", plist)
        let wrong = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.unrelated"], format: .xml, options: 0)
        try file(applications, "Ollama.app/Contents/Info.plist", wrong)
        try file(home, ".ollama/models/blob")
        for version in ["0.11.0", "0.12.0"] { try file(brew, "Cellar/ollama/\(version)/INSTALL_RECEIPT.json", Data("{}".utf8)) }
        try file(brew, "Caskroom/lm-studio/.metadata/0.3.30/20260101000000/Casks/lm-studio.json", Data("{}".utf8))
        let executable = try file(brew, "bin/brew", Data("#!/bin/sh\nexit 99\n".utf8))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let ollama = try plan(.ollama, home: home, applications: [applications], brew: [brew])
        XCTAssertTrue(ollama.isInstalled)
        XCTAssertTrue(ollama.appURLs.isEmpty, "A similar app name cannot substitute for a bundle identity")
        XCTAssertEqual(ollama.brewPackages.first?.installedVersions, ["0.11.0", "0.12.0"])
        XCTAssertTrue(ollama.items.contains { $0.url == home.appendingPathComponent(".ollama") && $0.sizeBytes > 0 })
        let lm = try plan(.lmStudio, home: home, applications: [applications], brew: [brew])
        XCTAssertEqual(lm.appURLs, [applications.appendingPathComponent("Renamed.app")])
        XCTAssertEqual(lm.brewPackages.first?.token, "lm-studio")
        XCTAssertTrue(lm.brewPackages.first?.isCask == true)

        try fm.removeItem(at: brew.appendingPathComponent("Cellar/ollama"))
        let leftovers = try plan(.ollama, home: home, applications: [applications], brew: [brew])
        XCTAssertFalse(leftovers.isInstalled)
        XCTAssertTrue(leftovers.hasWork)
        let standaloneCLI = try file(brew, "bin/ollama", Data("#!/bin/sh\nexit 99\n".utf8))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standaloneCLI.path)
        XCTAssertTrue(try plan(.ollama, home: home, applications: [applications], brew: [brew]).isInstalled)
    }

    func testCacheMatchingRequiresExactPackageAndValidDownloadHash() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        let cache = "Library/Caches/Homebrew/downloads/"
        let hash = String(repeating: "a", count: 64) + "--"
        let lm = try file(home, cache + hash + "LM-Studio-0.3.30-1-arm64.dmg")
        let ollama = try file(home, cache + hash + "ollama--0.12.0.arm64_sequoia.bottle.tar.gz")
        let manifest = try file(home, cache + hash + "ollama-0.12.0.bottle_manifest.json")
        for name in ["notahash--LM-Studio-0.3.30-1-arm64.dmg", hash + "my-ollama-0.12.0.tar.gz", hash + "ollama-python-0.12.0.tar.gz", hash + "LM-Studio-0.3.30-1-arm64.dmg.backup"] {
            try file(home, cache + name)
        }
        XCTAssertEqual(Set(try plan(.lmStudio, home: home).items.map(\.url)), [lm])
        XCTAssertEqual(Set(try plan(.ollama, home: home).items.map(\.url)), [ollama, manifest])
    }

    func testOnlySameProductDownloadAliasesAreAllowedAndNeverDoubleCounted() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        let name = String(repeating: "b", count: 64) + "--ollama--0.34.2.arm64_tahoe.bottle.tar.gz"
        let download = try file(cache, "downloads/" + name)
        let alias = cache.appendingPathComponent("ollama--0.34.2")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "downloads/" + name)
        XCTAssertTrue(SWPLocalAIScanner.isOwnedBrewCacheAlias(alias, product: .ollama, home: home))
        XCTAssertTrue(SWPSafety.validateLocalAI(alias, product: .ollama, home: home).isAllowed)
        let result = try plan(.ollama, home: home)
        XCTAssertEqual(Set(result.items.map(\.url)), [download, alias])
        XCTAssertEqual(result.items.first { $0.url == alias }?.sizeBytes, 0)
        XCTAssertEqual(result.sizeBytes, result.items.first { $0.url == download }?.sizeBytes)

        let outside = try file(home, "Documents/" + name)
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertFalse(SWPLocalAIScanner.isOwnedBrewCacheAlias(alias, product: .ollama, home: home))
        XCTAssertFalse(SWPSafety.validateLocalAI(alias, product: .ollama, home: home).isAllowed)
        XCTAssertFalse(try plan(.ollama, home: home).items.contains { $0.url == alias })
        XCTAssertEqual(try Data(contentsOf: outside), Data("fixture".utf8))
    }

    func testUnrelatedMalformedAppDoesNotBlockKnownProductDiscovery() throws {
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        try file(applications, "Unrelated.app/Contents/Info.plist", Data("invalid plist".utf8))
        let valid = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.electron.ollama"], format: .xml, options: 0)
        try file(applications, "Ollama.app/Contents/Info.plist", valid)
        let result = try plan(.ollama, home: root, applications: [applications])
        XCTAssertTrue(result.blockers.isEmpty, result.blockers.joined(separator: "\n"))
        XCTAssertEqual(result.appURLs, [applications.appendingPathComponent("Ollama.app")])
        XCTAssertTrue(result.notes.contains { $0.contains("Unrelated.app") })
    }

    func testUnreadableSettingsAreBlockersNotAbsentData() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        let settings = try file(home, ".lmstudio/settings.json", Data("{}".utf8))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }
        guard !fm.isReadableFile(atPath: settings.path) else { throw XCTSkip("Current account bypasses fixture file permissions") }
        let result = try plan(.lmStudio, home: home)
        XCTAssertTrue(result.blockers.contains { $0.contains(settings.path) })
    }

    func testShellRemovalPreservesAllOtherBytesAndRejectsEditedBlocks() {
        let home = URL(fileURLWithPath: "/Users/Fixture")
        let block = "# Added by LM Studio CLI (lms)\nexport PATH=\"$PATH:/Users/Fixture/.lmstudio/bin\"\n# End of LM Studio CLI section"
        let before = "# unrelated café\r\nexport KEEP=' two spaces  '\n\n"
        let after = "alias lms='echo mine'\n# no final newline"
        XCTAssertEqual(SWPLocalAIScanner.shellBlock(in: before + block + "\n" + after, home: home), before + after)
        XCTAssertEqual(SWPLocalAIScanner.shellBlock(in: before + block, home: home), before)
        XCTAssertEqual(SWPLocalAIScanner.shellBlock(in: before + block.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n" + after, home: home), before + after)
        XCTAssertNil(SWPLocalAIScanner.shellBlock(in: block.replacingOccurrences(of: "$PATH:", with: "$PATH:/custom:"), home: home))
        XCTAssertNil(SWPLocalAIScanner.shellBlock(in: block + " edited", home: home))
        XCTAssertNil(SWPLocalAIScanner.shellBlock(in: block + "\n# Added by LM Studio CLI (lms)\nexport PATH=custom", home: home))
        XCTAssertNil(SWPLocalAIScanner.shellBlock(in: "export PATH=\"$PATH:/Users/Fixture/.lmstudio/bin\"\n", home: home))
    }

    func testMalformedConfigurationAndUnownedLaunchAgentBlockCleanup() throws {
        let home = try fixture()
        defer { try? fm.removeItem(at: home) }
        try file(home, ".lmstudio/settings.json", Data("not json".utf8))
        let badSettings = try plan(.lmStudio, home: home)
        XCTAssertFalse(badSettings.blockers.isEmpty)
        let agent = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "homebrew.mxcl.ollama", "ProgramArguments": ["/bin/sh", "-c", "echo unrelated"],
            "EnvironmentVariables": ["OLLAMA_MODELS": home.appendingPathComponent("Documents/models").path]
        ], format: .xml, options: 0)
        let launch = try file(home, "Library/LaunchAgents/homebrew.mxcl.ollama.plist", agent)
        let result = try plan(.ollama, home: home)
        XCTAssertFalse(result.items.contains { $0.url == launch })
        XCTAssertFalse(result.blockers.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("Documents/models") })
        XCTAssertEqual(try Data(contentsOf: launch), agent)
    }
}

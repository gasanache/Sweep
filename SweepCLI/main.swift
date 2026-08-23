import Foundation

// MARK: - sweep

/// Read-only command-line face for Sweep's engine.
///
/// Deliberately has no removal verb. Everything destructive in Sweep is gated
/// on a human reading a list and ticking rows, and a CLI that could delete
/// would be a way to route around that — the one thing the whole design exists
/// to prevent. This tool reports; the app acts.
///
/// Shares the exact model files the app compiles, so what it prints is what the
/// app would show.
enum SweepCLI {

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let json = arguments.contains("--json")
        // Positional arguments only, flags removed first. Taking the verb by
        // filtering but the operand by index meant `sweep --json plan Foo`
        // planned an app called "plan".
        let positional = arguments.filter { !$0.hasPrefix("-") }
        let command = positional.first ?? "help"
        let operand = positional.dropFirst().first

        switch command {
        case "scan":    scan(json: json)
        case "plan":    plan(app: operand, json: json)
        case "apps":    apps(json: json)
        case "verify":  verify()
        case "help", "--help", "-h": usage()
        default:
            // An unrecognised verb is a usage error, not a success.
            FileHandle.standardError.write(
                Data("sweep: unknown command '\(command)'\n".utf8))
            usage()
            exit(2)
        }
    }

    // MARK: Commands

    private static func scan(json: Bool) {
        let inventory = SWPAppInventory.build()
        var unreadable: [String] = []
        let orphans = SWPOrphanScanner(inventory: inventory)
            .scan(unreadable: &unreadable) { _ in }
        var junk = SWPJunkScanner(
            inventory: inventory,
            claimed: Set(orphans.flatMap(\.items).map { $0.url.standardizedFileURL.path }))
        let developer = junk.scanDeveloper { _ in }
        let caches = junk.scanCaches { _ in }
        let logs = junk.scanLogs { _ in }
        let startup = SWPStartupScanner(inventory: inventory).scan { _ in }
        let groups = orphans + developer + caches + logs + startup.groups

        if json {
            emit(["appsInventoried": inventory.appCount,
                  "inventoryTrustworthy": inventory.isTrustworthy,
                  "totalBytes": groups.reduce(0) { $0 + $1.sizeBytes },
                  "unreadable": unreadable,
                  "groups": groups.map(encode)])
            return
        }

        print("Sweep — scan (read-only)\n")
        for category in SWPCategory.allCases {
            let inCategory = groups.filter { $0.category == category }
            guard !inCategory.isEmpty else { continue }
            let bytes = inCategory.reduce(0) { $0 + $1.sizeBytes }
            print("\(category.title) — \(inCategory.count) groups, \(SWPBytes.string(bytes))")
            for group in inCategory.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(8) {
                print("   [\(group.confidence.label)] \(group.name) — \(SWPBytes.string(group.sizeBytes))")
            }
            if inCategory.count > 8 { print("   … \(inCategory.count - 8) more") }
            print("")
        }
        print("Total: \(SWPBytes.string(groups.reduce(0) { $0 + $1.sizeBytes }))")
        if !unreadable.isEmpty {
            print("\(unreadable.count) location(s) unreadable — grant Full Disk Access for a complete scan.")
        }
    }

    private static func plan(app name: String?, json: Bool) {
        guard let name else { print("usage: sweep plan <app name>"); exit(2) }
        let all = SWPInstalledApps.list()
        guard let match = all.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) ?? all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            print("No installed app matches \"\(name)\".")
            exit(1)
        }

        let plan = SWPResidueFinder(app: match).buildPlan()
        if json {
            emit(["app": match.name,
                  "bundleID": match.bundleID,
                  "appBytes": plan.appItem.sizeBytes,
                  "exclusive": plan.exclusive.map(encode),
                  "nameMatches": plan.nameMatches.map(encode),
                  "shared": plan.shared.map { ["path": $0.url.path, "sharedWith": $0.apps] },
                  "receipts": plan.receipts])
            return
        }

        print("\(match.name)  \(match.bundleID)  \(SWPBytes.string(plan.appItem.sizeBytes))\n")
        print("ITS FILES (\(plan.exclusive.count))")
        for item in plan.exclusive { print("   \(item.displayPath)  \(SWPBytes.string(item.sizeBytes))") }
        if !plan.nameMatches.isEmpty {
            print("\nPOSSIBLE MATCHES (\(plan.nameMatches.count))")
            for item in plan.nameMatches { print("   \(item.displayPath)  \(SWPBytes.string(item.sizeBytes))") }
        }
        if !plan.shared.isEmpty {
            print("\nSHARED — LEFT ALONE (\(plan.shared.count))")
            for entry in plan.shared.prefix(12) { print("   \(entry.displayName) — \(entry.sharedWithText)") }
        }
        if !plan.receipts.isEmpty {
            print("\nRECEIPTS (\(plan.receipts.count), left alone)")
            for receipt in plan.receipts { print("   \(receipt)") }
        }
        print("\nRun the app to act on this. The CLI never removes anything.")
    }

    private static func apps(json: Bool) {
        let list = SWPInstalledApps.list()
        if json {
            emit(["apps": list.map {
                ["name": $0.name, "bundleID": $0.bundleID, "version": $0.version,
                 "path": $0.url.path]
            }])
            return
        }
        for app in list { print("\(app.name)\t\(app.bundleID)\t\(app.version)") }
    }

    /// The invariants the harness checks, as a command.
    private static func verify() {
        let inventory = SWPAppInventory.build()
        var failures: [String] = []

        // An untrustworthy inventory makes every other check vacuous — the
        // scanners fail closed and return nothing, which would otherwise look
        // like a clean pass.
        if !inventory.isTrustworthy {
            failures.append("inventory below the trust floor (\(inventory.appCount) apps)")
        }

        var unreadable: [String] = []
        let orphans = SWPOrphanScanner(inventory: inventory)
            .scan(unreadable: &unreadable) { _ in }
        var junk = SWPJunkScanner(
            inventory: inventory,
            claimed: Set(orphans.flatMap(\.items).map { $0.url.standardizedFileURL.path }))
        let developer = junk.scanDeveloper { _ in }
        let caches = junk.scanCaches { _ in }
        let logs = junk.scanLogs { _ in }
        let startup = SWPStartupScanner(inventory: inventory).scan { _ in }
        let all = orphans + developer + caches + logs + startup.groups

        // Every category, not just leftovers.
        for group in all {
            for item in group.items where !SWPSafety.validate(item.url).isAllowed {
                failures.append("policy violation: \(item.url.path)")
            }
        }
        // An in-use cache must never be labelled Safe, and a leftover must
        // never be labelled In Use.
        for group in orphans where group.confidence == .inUse {
            failures.append("leftover group labelled In Use: \(group.name)")
        }
        // The uninstaller's own gate must accept every app it lists.
        for app in SWPInstalledApps.list()
        where !SWPSafety.validateAppBundle(app.url).isAllowed {
            failures.append("listed app refused by the bundle gate: \(app.name)")
        }

        print("inventory: \(inventory.appCount) apps  ·  groups: \(all.count)  ·  items: \(all.flatMap(\.items).count)")
        if failures.isEmpty {
            print("PASS — every finding inside policy, every listed app removable")
            exit(0)
        }
        for failure in failures { print("FAIL \(failure)") }
        exit(1)
    }

    // MARK: Helpers

    private static func encode(_ group: SWPGroup) -> [String: Any] {
        ["name": group.name, "category": group.category.rawValue,
         "confidence": group.confidence.label, "bytes": group.sizeBytes,
         "items": group.items.map(encode)]
    }

    private static func encode(_ item: SWPItem) -> [String: Any] {
        ["path": item.url.path, "bytes": item.sizeBytes,
         "location": item.location, "requiresAdmin": item.requiresAdmin]
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    private static func usage() {
        print("""
        sweep — read-only command line for Sweep's scanning engine

          sweep scan  [--json]     what a scan would find
          sweep plan <app> [--json] what uninstalling an app would remove
          sweep apps  [--json]     installed apps Sweep can uninstall
          sweep verify             assert every finding passes the safety policy

        This tool never removes anything. Use the app to act on what it reports.
        """)
    }
}

SweepCLI.main()

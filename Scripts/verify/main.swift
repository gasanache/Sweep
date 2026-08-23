// Ground-truth harness.
//
// Compiles Sweep's real model files into a command-line tool and runs them
// against the machine it is invoked on, then asserts the properties that unit
// tests cannot: that nothing an installed app owns is ever presented as a
// leftover, that every proposed path passes the safety policy, and that
// uninstall plans never offer another app's shared data.
//
// Run with Scripts/verify.sh. Read-only — it never removes anything.
import Foundation

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

// MARK: Inventory

let inventory = SWPAppInventory.build()
print("=== INVENTORY ===")
print("  apps: \(inventory.appCount)   bundle ids: \(inventory.bundleIDs.count)")
print("  live identifiers (receipts + launchd): \(inventory.liveIdentifiers.count)")
print("  trustworthy: \(inventory.isTrustworthy)")
check(inventory.isTrustworthy, "inventory is below the trust floor on a real machine")

// MARK: Scan

var unreadable: [String] = []
let orphans = SWPOrphanScanner(inventory: inventory).scan(unreadable: &unreadable) { _ in }
var junk = SWPJunkScanner(
    inventory: inventory,
    claimed: Set(orphans.flatMap(\.items).map { $0.url.standardizedFileURL.path }))
let developer = junk.scanDeveloper { _ in }
let caches = junk.scanCaches { _ in }
let logs = junk.scanLogs { _ in }
let startup = SWPStartupScanner(inventory: inventory).scan { _ in }
let all = orphans + developer + caches + logs + startup.groups

print("\n=== SCAN ===")
for (label, groups) in [("leftovers", orphans), ("developer", developer),
                        ("caches", caches), ("logs", logs), ("startup", startup.groups)] {
    let bytes = groups.reduce(0) { $0 + $1.sizeBytes }
    print("  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(groups.count) groups, \(SWPBytes.string(bytes))")
}
print("  healthy startup entries left alone: \(startup.healthy.count)")
if !unreadable.isEmpty { print("  unreadable locations: \(unreadable.count)") }

// MARK: Invariants

print("\n=== SAFETY GATE ===")
var offenders = 0
for group in all {
    for item in group.items where !SWPSafety.validate(item.url).isAllowed {
        offenders += 1
        print("  VIOLATION \(item.url.path)")
    }
}
check(offenders == 0, "\(offenders) proposed paths fail the safety policy")
print(offenders == 0 ? "  PASS — all \(all.flatMap(\.items).count) items inside policy" : "  FAIL")

print("\n=== FALSE POSITIVES ===")
// Only inferential categories: nothing owned by installed software or a
// toolchain may be presented as the leftovers of a deleted app.
let inferential = all.filter { $0.category == .leftovers || $0.category == .startup }
let forbidden = ["cisco", "anyconnect", "ihg", "versa", "vsg", "radiogarden", "premiumsoft",
                 "navicat", "logic", "garageband", "microsoft", "onedrive", "chrome",
                 "google", "steam", "wireshark", "cloudflare", "warp", "paragon",
                 "crystalidea", "macsfancontrol", "protonvpn", "razer", "geoservices",
                 "cloudkit", "staticcheck", "playwright", "swiftpm", "paddle", "flexnet",
                 "setapp", "mobilemeaccounts"]
var hits: Set<String> = []
for group in inferential {
    let hay = (group.name + " " + group.items.map(\.url.path).joined(separator: " ")).lowercased()
    for needle in forbidden where hay.contains(needle) {
        hits.insert("\(needle) → \(group.name) [\(group.category.rawValue)]")
    }
}
check(hits.isEmpty, "\(hits.count) installed/toolchain items presented as leftovers")
print(hits.isEmpty ? "  PASS — nothing installed is presented as a leftover" : "  FAIL")
for hit in hits.sorted() { print("    \(hit)") }

print("\n=== IN-USE LABELLING ===")
let inUse = caches.filter { $0.confidence == .inUse }.count
let safe = caches.filter { $0.confidence == .safe }.count
print("  caches: \(inUse) In Use, \(safe) Safe")
check(!orphans.contains { $0.confidence == .inUse }, "In Use leaked into leftovers")

print("\n=== UNINSTALL PLANS ===")
let apps = SWPInstalledApps.list()
print("  uninstallable apps: \(apps.count)")
var planned = 0
for app in apps.prefix(40) {
    let plan = SWPResidueFinder(app: app).buildPlan()
    planned += 1
    for item in plan.exclusive + plan.nameMatches {
        check(SWPSafety.validate(item.url).isAllowed,
              "\(app.name): plan offers policy-refused \(item.displayPath)")
    }
    check(SWPSafety.validateAppBundle(plan.appItem.url).isAllowed,
          "\(app.name): own bundle refused by the app gate")
}
print("  plans built and validated: \(planned)")

// A vendor with siblings installed must have its shared machinery detected.
if let word = apps.first(where: { $0.bundleID == "com.microsoft.word" }) {
    let plan = SWPResidueFinder(app: word).buildPlan()
    print("  Word: \(plan.exclusive.count) exclusive, \(plan.shared.count) shared, \(plan.receipts.count) receipts")
    check(!plan.shared.isEmpty, "Word plan detected no shared Microsoft data")
    for item in plan.exclusive + plan.nameMatches {
        let name = item.url.lastPathComponent.lowercased()
        check(name.contains("word"), "Word plan offers non-Word item \(item.displayPath)")
    }
}

print("\n=== RESULT ===")
if failures.isEmpty {
    print("  PASS — all invariants hold")
} else {
    print("  FAIL — \(failures.count):")
    for failure in failures { print("    \(failure)") }
    exit(1)
}

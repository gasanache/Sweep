import SwiftUI
import AppKit

// MARK: - Preferences

/// The handful of knobs worth exposing, and no more.
///
/// Every option here earns its place by changing a decision the app would
/// otherwise make silently on the user's behalf: how aggressively small
/// findings are folded away, whether a whole category is scanned at all, and
/// what the window looks like. Anything that would weaken a safety guarantee
/// is deliberately absent — there is no "select automatically", no "skip the
/// confirmation", and no way to turn the policy gate off.
struct SWPSettingsView: View {

    @EnvironmentObject private var engine: SWPScanEngine
    @AppStorage(SWPSettings.appearanceKey) private var appearance = SWPAppearance.system
    @AppStorage(SWPSettings.foldThresholdKey) private var foldThresholdKB = 64
    @AppStorage(SWPSettings.scanDeveloperKey) private var scanDeveloper = true
    @AppStorage(SWPSettings.watchTrashKey) private var watchTrash = false
    /// These two only apply on the next scan, so the panel says so and offers
    /// to run one rather than letting the change look like it did nothing.
    @State private var scanSettingsChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: SWPTheme.Spacing.section) {
            Text("Settings")
                .font(SWPTheme.Fonts.title)
                .foregroundStyle(SWPTheme.Colors.textPrimary)

            section("Appearance") {
                row("Theme") {
                    Picker("", selection: $appearance) {
                        ForEach(SWPAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .tint(SWPTheme.Colors.accent)
                    .frame(width: 210)
                }
            }

            section("Scanning") {
                if scanSettingsChanged {
                    HStack(spacing: 8) {
                        Text("Takes effect on the next scan.")
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textDim)
                        Spacer()
                        Button("Rescan Now") {
                            engine.scan()
                            scanSettingsChanged = false
                        }
                        .buttonStyle(SWPSecondaryButtonStyle())
                        .disabled(!engine.hasResults)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    SWPHairline().opacity(0.6)
                }
                row("Scan developer artefacts",
                    note: "Xcode derived data, archives, device support and package caches. Often the largest category on a developer's Mac.") {
                    Toggle("", isOn: $scanDeveloper)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(SWPTheme.Colors.accent)
                        .onChange(of: scanDeveloper) { _, _ in scanSettingsChanged = true }
                }
                SWPHairline().opacity(0.6)
                row("Fold findings under",
                    note: "Small name-only findings collect into one row so they cannot bury the large ones. They stay listed inside it.") {
                    Picker("", selection: $foldThresholdKB) {
                        Text("16 KB").tag(16)
                        Text("64 KB").tag(64)
                        Text("256 KB").tag(256)
                        Text("1 MB").tag(1024)
                        Text("Never").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .tint(SWPTheme.Colors.accent)
                    .onChange(of: foldThresholdKB) { _, _ in scanSettingsChanged = true }
                }
            }

            section("Drag to Trash") {
                row("Offer cleanup when I trash an app",
                    note: "Sweep offers to remove the files an app leaves behind — never the app itself, you already moved that. Works only while Sweep is open; no background helper is installed.") {
                    Toggle("", isOn: $watchTrash)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(SWPTheme.Colors.accent)
                }
            }

            section("Ignored items") {
                row(engine.ignoredCount == 0
                    ? "Nothing is being ignored"
                    : "\(engine.ignoredCount) path\(engine.ignoredCount == 1 ? "" : "s") excluded from every scan",
                    note: "Right-click any group in the results and choose Always Ignore This.") {
                    Button("Clear") { engine.clearIgnoreList() }
                        .buttonStyle(SWPSecondaryButtonStyle())
                        .disabled(engine.ignoredCount == 0)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(SWPTheme.Spacing.pane)
        // Sized to its content. The stock `Form(.grouped)` was replaced because
        // it forced system chrome and system-blue controls into a window built
        // around one gold accent — and padded four options past the point of
        // scrolling.
        .frame(width: 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(SWPTheme.Colors.background)
        .onChange(of: appearance) { _, newValue in newValue.apply() }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(SWPTheme.Fonts.badge)
                .tracking(0.7)
                .foregroundStyle(SWPTheme.Colors.textDim)
            VStack(spacing: 0) { content() }
                .swpCard()
        }
    }

    /// One setting: label and optional explanation on the left, control right.
    private func row<Control: View>(_ label: String, note: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(SWPTheme.Fonts.rowTitle)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                if let note {
                    Text(note)
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Appearance

enum SWPAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// The AppKit appearance to install on `NSApp`.
    ///
    /// `.preferredColorScheme` alone is not enough on macOS: it styles SwiftUI
    /// content when a window is *created*, but an already-open window keeps its
    /// appearance, and the window chrome (title bar, traffic lights, the
    /// Settings window itself) never follows at all. Setting `NSApp.appearance`
    /// re-renders every window immediately, which is what "apply instantly"
    /// actually requires.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil          // nil = follow the system
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this choice to the running app, right now.
    ///
    /// Clearing `NSApp.appearance` is not enough on its own. SwiftUI's
    /// `.preferredColorScheme` sets an appearance override on each individual
    /// `NSWindow`, and a per-window override outranks the application one — so
    /// switching from Light or Dark back to System left every open window
    /// pinned to the old choice while new windows followed the system. The
    /// per-window overrides have to be cleared so the windows inherit again.
    @MainActor
    func apply() {
        NSApplication.shared.appearance = nsAppearance
        for window in NSApplication.shared.windows {
            window.appearance = nsAppearance
        }
    }
}

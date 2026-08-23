import SwiftUI
import AppKit

// MARK: - Scan hero

/// The idle and scanning states: one dial, one sentence, one button.
///
/// Resisted the urge to put statistics here. Before a scan there is nothing
/// true to say about this Mac, and inventing a "health score" — the standard
/// move for this category of app — would be theatre that undermines every real
/// number shown later.
struct SWPScanHeroView: View {

    @EnvironmentObject private var engine: SWPScanEngine
    /// Shown once, then never again. Full Disk Access is genuinely optional —
    /// most of what Sweep reads needs no special permission — so this explains
    /// the trade rather than nagging for a grant the app can work without.
    @AppStorage("hasSeenAccessNote") private var hasSeenAccessNote = false

    private var isScanning: Bool {
        if case .scanning = engine.phase { return true }
        return false
    }

    private var statusLine: String {
        if case .scanning(let message) = engine.phase { return message }
        return "Find what apps left behind"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                SWPSweepRing(progress: isScanning ? engine.stageProgress : nil,
                             isActive: isScanning)
                centerContent
            }

            if isScanning {
                stageTrack
                    .padding(.top, 22)
            }

            Spacer().frame(height: 34)

            Text(statusLine)
                .font(isScanning ? SWPTheme.Fonts.body : SWPTheme.Fonts.title)
                .foregroundStyle(isScanning
                                 ? SWPTheme.Colors.textSecondary
                                 : SWPTheme.Colors.textPrimary)
                // No animation on the ticker: cross-fading between strings of
                // different lengths rendered both at once as ghosted overlap.
                // A scan status that changes several times a second should
                // snap, not fade.
                // Fixed height so the button below never shifts as the status
                // text changes length mid-scan.
                .frame(height: 22)

            if !isScanning {
                Text("Sweep reads your Library and works out what no longer has an\nowner. Nothing is ever selected for you — you tick, and what you\ntick goes to the Trash, never straight to deletion.")
                    .font(SWPTheme.Fonts.body)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 6)
            }

            if !hasSeenAccessNote, !isScanning {
                accessNote
                    .padding(.top, SWPTheme.Spacing.section)
                    .frame(maxWidth: 460)
            }

            lastScanSummary

            Spacer().frame(height: 26)

            actionButton

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SWPTheme.Spacing.pane)
    }

    // MARK: Centre

    @ViewBuilder
    private var centerContent: some View {
        if isScanning {
            VStack(spacing: 5) {
                Image(systemName: "wind")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(SWPTheme.Colors.accent)
                Text("Scanning")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
        } else {
            VStack(spacing: 3) {
                Image(systemName: "wind")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(SWPTheme.Colors.accent.opacity(0.85))
                if let date = engine.lastScanDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                }
            }
        }
    }

    // MARK: Stage track

    /// Five segments, one per scan stage.
    ///
    /// A percentage would be a lie — the scanners have no way to know how much
    /// of the disk is left. Named stages are honest and more useful: they say
    /// which part of the Library is being read right now.
    private var stageTrack: some View {
        HStack(spacing: 6) {
            ForEach(SWPScanStage.allCases) { stage in
                let isDone = engine.completedStages.contains(stage)
                let isCurrent = engine.currentStage == stage && !isDone
                VStack(spacing: 5) {
                    Capsule()
                        .fill(isDone ? SWPTheme.Colors.accent
                              : isCurrent ? SWPTheme.Colors.accent.opacity(0.45)
                              : SWPTheme.Colors.border)
                        .frame(height: 2.5)
                    Text(stage.title)
                        .font(SWPTheme.Fonts.badge)
                        .foregroundStyle(isDone || isCurrent
                                         ? SWPTheme.Colors.textSecondary
                                         : SWPTheme.Colors.textDim)
                }
                .frame(width: 74)
                .animation(.easeOut(duration: 0.25), value: isDone)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scanning \(engine.currentStage.title), \(engine.completedStages.count) of \(SWPScanStage.allCases.count) stages complete")
    }

    // MARK: Hero summary

    /// What the last scan found, so the idle screen says something true (3.8).
    @ViewBuilder
    private var lastScanSummary: some View {
        if let date = engine.lastScanDate, engine.hasResults {
            let formatter = RelativeDateTimeFormatter()
            HStack(spacing: 6) {
                Text(SWPBytes.string(engine.result.totalBytes))
                    .font(SWPTheme.Fonts.rowTitle)
                    .foregroundStyle(SWPTheme.Colors.accent)
                Text("found · scanned \(formatter.localizedString(for: date, relativeTo: Date()))")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                Button("Review") { engine.showResults() }
                    .buttonStyle(.plain)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.accent)
                Text("·").foregroundStyle(SWPTheme.Colors.textDim)
                Button("Uninstaller") { engine.isUninstallerActive = true }
                    .buttonStyle(.plain)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.accent)
            }
            .padding(.top, 10)
        }
    }

    // MARK: First-launch note

    private var accessNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundStyle(SWPTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("Sweep works without any special permission.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                Text("A few protected folders stay invisible until you grant Full Disk Access. That is optional — Sweep will tell you if a scan actually hit one.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    Button("Got It") { hasSeenAccessNote = true }
                        .buttonStyle(.plain)
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.accent)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .swpCard()
    }

    // MARK: Button

    @ViewBuilder
    private var actionButton: some View {
        if isScanning {
            Button("Cancel") { engine.cancelScan() }
                .buttonStyle(SWPSecondaryButtonStyle())
        } else {
            Button(engine.lastScanDate == nil ? "Scan My Mac" : "Scan Again") {
                engine.scan()
            }
            .buttonStyle(SWPPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}

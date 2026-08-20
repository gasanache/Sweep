import SwiftUI

// MARK: - Scan hero

/// The idle and scanning states: one dial, one sentence, one button.
///
/// Resisted the urge to put statistics here. Before a scan there is nothing
/// true to say about this Mac, and inventing a "health score" — the standard
/// move for this category of app — would be theatre that undermines every real
/// number shown later.
struct SWPScanHeroView: View {

    @EnvironmentObject private var engine: SWPScanEngine

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
                SWPSweepRing(progress: nil, isActive: isScanning)
                centerContent
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

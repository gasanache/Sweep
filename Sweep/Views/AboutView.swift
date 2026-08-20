import SwiftUI
import AppKit

// MARK: - About

/// Custom About window, replacing the stock grey panel.
///
/// Same design language as the app itself: near-black ground, one gold
/// accent, and a short statement of the three promises that make Sweep worth
/// trusting — because "About" is where a user who just watched a cleaner ask
/// for their password goes to decide how they feel about that.
struct SWPAboutView: View {

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: SWPTheme.Colors.accent.opacity(0.18), radius: 18, y: 4)
                .padding(.top, 34)

            Text("Sweep")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .foregroundStyle(SWPTheme.Colors.textPrimary)
                .padding(.top, 10)

            Text(version)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
                .padding(.top, 2)

            Text("Cleans what apps leave behind.")
                .font(SWPTheme.Fonts.body)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 9) {
                promise(symbol: "trash",
                        text: "Never deletes — everything goes to the Trash, recoverable with Put Back.")
                promise(symbol: "checkmark.square",
                        text: "Never selects anything for you. Every removal is your explicit tick.")
                promise(symbol: "network.slash",
                        text: "No dependencies, no telemetry, no network. Apple frameworks only.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .swpCard()
            .padding(.horizontal, 24)
            .padding(.top, 18)

            Spacer(minLength: 16)

            Link(destination: URL(string: "https://github.com/gasanache/Sweep")!) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("github.com/gasanache/Sweep")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(SWPTheme.Colors.textDim)
                }
                .foregroundStyle(SWPTheme.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Text("© 2026 George Asanache · GPL-3.0")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
        .frame(width: 360, height: 470)
        .background(SWPTheme.Colors.background)
        .preferredColorScheme(.dark)
    }

    private func promise(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SWPTheme.Colors.accent)
                .frame(width: 15)
            Text(text)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
